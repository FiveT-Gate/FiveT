import Foundation

/// The official Windscribe command line (`windscribe-cli`), driven the way AutoScribe
/// (github.com/rasool-mrr/AutoScribe) does it: `connect -n`, then `status` once a second, then
/// `ping` through the tunnel. FiveT never bundles Windscribe or its CLI: the user installs the
/// Windscribe app, and this only looks for its command line and runs it as the user.
enum WindscribeCLI {
    static let protocols = ["wireguard", "ikev2", "udp", "tcp", "stealth", "wstunnel"]

    /// What Windscribe offers when `windscribe-cli ports <protocol>` cannot be read: the same lists as
    /// `ports` gives on a current install. The first port of each is Windscribe's own default.
    static let defaultPorts: [String: [Int]] = [
        "wireguard": [443, 80, 53, 123, 1194, 65142],
        "ikev2": [500],
        "udp": [443, 80, 53, 123, 1194, 54783],
        "tcp": [443, 587, 21, 22, 80, 123, 143, 3306, 8080, 54783, 1194],
        "stealth": [443, 587, 21, 22, 80, 123, 143, 3306, 8080, 54783, 8443],
        "wstunnel": [443],
    ]

    static let downloadURL = URL(string: "https://windscribe.com/download")!

    // MARK: Finding it

    private static let appFolders = ["/Applications", NSHomeDirectory() + "/Applications"]
    private static let cliCandidates = [
        "/usr/local/bin/windscribe-cli", "/opt/homebrew/bin/windscribe-cli",
    ] + appFolders.map { $0 + "/Windscribe.app/Contents/MacOS/windscribe-cli" }

    #if !DISTRIBUTION
    /// Test copies only: FIVET_WINDSCRIBE_CLI=none pretends Windscribe is not installed, =nocli that only the
    /// app is (to see the panel's messages); any other value is the path of a stand-in command line.
    private static let pretend = ProcessInfo.processInfo.environment["FIVET_WINDSCRIBE_CLI"]
    #endif

    /// Where the command line is, or nil when it is not installed.
    static var path: String? {
        #if !DISTRIBUTION
        if let pretend { return pretend == "none" || pretend == "nocli" ? nil : pretend }
        #endif
        return cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Windscribe app is on this Mac (its command line may still be missing from an old version).
    static var appInstalled: Bool {
        #if !DISTRIBUTION
        if let pretend { return pretend != "none" }
        #endif
        return appFolders.contains { FileManager.default.fileExists(atPath: $0 + "/Windscribe.app") }
    }

    // MARK: Running it

    struct Output {
        /// What the command printed, without Windscribe's JSON log lines (the CLI prints them too).
        var text: String
        var status: Int32
        var timedOut = false
        var lines: [String] { text.split(whereSeparator: \.isNewline).map { String($0) } }
    }

    /// The process of one call, so cancelling the task that waits for it stops it at once.
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func set(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; if cancelled { return false }; process = p; return true }
        func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if p?.isRunning == true { p?.terminate() } }
    }

    /// Runs `exe` with `args` away from the main thread; ends it after `timeout` seconds. Windscribe's
    /// log lines (`{"tm": …}`) are taken out of the output.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 30) async -> Output {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Output, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { k.resume(returning: runSync(exe, args, timeout, handle)) }
            }
        } onCancel: { handle.cancel() }
    }

    /// `windscribe-cli` with `args`; a missing CLI is an empty failure.
    static func cli(_ args: [String], timeout: TimeInterval = 30) async -> Output {
        guard let path else { return Output(text: "windscribe-cli is not installed", status: 127) }
        var out = await run(path, args, timeout: timeout)
        // The command line runs one command at a time: while another is going (a connect waits up to a minute),
        // it answers "Windscribe CLI is already running" and does nothing. Wait for its turn, a few seconds at most.
        for _ in 0..<8 where isBusyAnswer(out.text) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            out = await run(path, args, timeout: timeout)
        }
        return out
    }

    /// Another `windscribe-cli` command is running, so this one was not run: not an answer about Windscribe.
    static func isBusyAnswer(_ text: String) -> Bool { text.lowercased().contains("cli is already running") }

    private static func runSync(_ exe: String, _ args: [String], _ timeout: TimeInterval, _ handle: Handle) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        do { try p.run() } catch { return Output(text: error.localizedDescription, status: 127) }
        guard handle.set(p) else { p.terminate(); return Output(text: "", status: 15) }
        // Read while it runs: output past the pipe's buffer would otherwise stop it.
        let drained = DispatchGroup()
        var data = Data()
        drained.enter()
        DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); drained.leave() }
        var timedOut = false
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            // A command that ignores the polite stop is killed: FiveT would otherwise wait for it for ever.
            if ended.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 2)
            }
        }
        // Not for ever either: a helper the command left behind can keep the pipe open after the command is gone.
        _ = drained.wait(timeout: .now() + (timedOut ? 2 : 10))
        let text = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("{\"tm\"") }
            .joined(separator: "\n")
        return Output(text: text, status: p.terminationStatus, timedOut: timedOut)
    }

    // MARK: Status

    /// `windscribe-cli status`, which prints "Key: value" lines.
    struct Status: Equatable {
        var internet = ""
        var login = ""
        var firewall = ""
        /// The connection line: "Disconnected", "Connecting to <city>", "Connected to <city>" (Windscribe 2.25 and
        /// newer), or "Connected: <city - nickname>" (2.24 and older).
        var connect = ""
        var publicIP = ""
        /// "wireguard:443", when connected (2.25 and newer).
        var protocolInUse = ""
        var usage = ""
        var update = ""

        /// The CLI answered at all (the Windscribe app is running): a signed-out app has no connection line.
        var known: Bool { !connect.isEmpty || !login.isEmpty }
        var isLoggedIn: Bool { login.lowercased() == "logged in" }
        var isConnected: Bool { connect.lowercased().hasPrefix("connected") }
        var isConnecting: Bool { connect.lowercased().hasPrefix("connecting") }
        /// "Error: <reason>" (Windscribe 2.25 and newer): the attempt is over and failed.
        var isError: Bool { connect.lowercased().hasPrefix("error") }
        /// "Always On" counts: the firewall then cannot be turned off from here.
        var firewallOn: Bool { let f = firewall.lowercased(); return f.hasPrefix("on") || f.hasPrefix("always") }
        /// The place, when connected and the CLI says it.
        var place: String? {
            guard isConnected else { return nil }
            let rest: String
            if connect.lowercased().hasPrefix("connected to ") { rest = String(connect.dropFirst("connected to ".count)) }
            else if let i = connect.firstIndex(of: ":") { rest = String(connect[connect.index(after: i)...]) }
            else { return nil }
            let clean = rest.trimmingCharacters(in: .whitespaces)
            return clean.isEmpty ? nil : clean
        }
    }

    /// Reads `status` from Windscribe 2.25 and newer ("Login:", "Connection:", "IP:", "Firewall:") and from 2.24
    /// and older ("Login state:", "Connect state:", "Public IP:", "Firewall state:").
    static func parseStatus(_ text: String) -> Status {
        var s = Status()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "internet", "internet connectivity": s.internet = value
            case "login", "login state": s.login = value
            case "firewall", "firewall state": s.firewall = value
            case "connection", "connect state": s.connect = value
            case "ip", "public ip": s.publicIP = value.split(separator: " ").first.map(String.init) ?? value   // "1.2.3.4 (public)"
            case "protocol": s.protocolInUse = value
            case "data usage": s.usage = value
            case "update", "update available": s.update = value.replacingOccurrences(of: " available", with: "")
            default: break
            }
        }
        return s
    }

    static func status() async -> (status: Status, text: String) {
        let out = await cli(["status"], timeout: 15)
        return (parseStatus(out.text), out.text)
    }

    /// `windscribe-cli ports <protocol>` prints "443, 80, 53".
    static func ports(for proto: String) async -> [Int] {
        let out = await cli(["ports", proto], timeout: 15)
        let ports = out.text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...65535).contains($0) }
        return ports.isEmpty ? (defaultPorts[proto] ?? []) : ports
    }

    /// The words Windscribe uses when it has no such location (or it is switched off).
    static func refusesLocation(_ text: String) -> Bool {
        text.contains("Location does not exist") || text.contains("is disabled")
    }

    // MARK: Ping

    struct Ping: Equatable {
        var avg: Double?
        var min: Double?
        var max: Double?
        var loss: Double
        /// How much the ping time varies (ping's own standard deviation): the jitter.
        var stddev: Double?
        var answered: Bool { loss < 100 && avg != nil }
    }

    /// Pings `host` `count` times through whatever route the Mac uses now (Windscribe's tunnel, once up).
    /// macOS `ping -W` counts milliseconds (AutoScribe's Windows and Linux values are seconds).
    static func ping(host: String, count: Int) async -> Ping {
        let total = count * 3 + 4
        let out = await run("/sbin/ping", ["-c", "\(count)", "-W", "2000", "-t", "\(total)", host], timeout: TimeInterval(total + 3))
        return parsePing(out.text)
    }

    static func parsePing(_ text: String) -> Ping {
        var loss = 100.0
        var avg: Double?, lo: Double?, hi: Double?, sd: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("packet loss"), let r = line.range(of: "% packet loss") {
                let head = line[..<r.lowerBound]
                if let v = head.split(whereSeparator: { !($0.isNumber || $0 == ".") }).last, let d = Double(v) { loss = d }
            } else if line.hasPrefix("round-trip") || line.hasPrefix("rtt"), let eq = line.range(of: "= ") {
                let nums = line[eq.upperBound...].split(whereSeparator: { $0 == "/" || $0 == " " }).compactMap { Double($0) }
                if nums.count >= 3 { lo = nums[0]; avg = nums[1]; hi = nums[2] }
                if nums.count >= 4 { sd = nums[3] }
            }
        }
        return Ping(avg: avg, min: lo, max: hi, loss: loss, stddev: sd)
    }

    // MARK: Web page and download speed

    /// One download through the Mac's route (Windscribe's tunnel, once up).
    struct Transfer: Equatable {
        /// Milliseconds until the first byte came: DNS, connecting, TLS and the answer.
        var firstByteMs: Double?
        /// Megabits per second over the whole download; nil when nothing came.
        var mbps: Double?
    }

    /// What a failed page test is stored as (a route whose pings come back but whose web pages do not).
    static let webFailedMs = 9999.0
    private static let webURL = "https://cp.cloudflare.com/generate_204"
    private static let speedURL = "https://speed.cloudflare.com/__down?bytes=25000000"

    /// `curl` on `url` for at most `maxSeconds`; a download cut off by the limit still counts, over the time it ran.
    /// `socksPort`: through FiveT's local SOCKS proxy (a VPN that carries only apps) instead of the Mac's route.
    static func fetch(_ url: String, maxSeconds: Int, socksPort: Int? = nil) async -> Transfer {
        let proxy = socksPort.map { ["--socks5-hostname", "127.0.0.1:\($0)"] } ?? []
        let out = await run("/usr/bin/curl", ["-s", "-o", "/dev/null", "--max-time", "\(maxSeconds)"] + proxy
                                              + ["-w", "%{time_starttransfer} %{speed_download} %{http_code} %{size_download} %{time_total}", url],
                            timeout: TimeInterval(maxSeconds + 3))
        return parseTransfer(out.text)
    }

    static func parseTransfer(_ text: String) -> Transfer {
        let f = text.split(whereSeparator: \.isWhitespace)
        guard f.count >= 3, f[2] == "200" || f[2] == "204", let t = Double(f[0]), t > 0 else { return Transfer() }
        var bytesPerSecond = Double(f[1]) ?? 0
        // The speed of the download itself: the time before the first byte (DNS, connecting, TLS) is not part of it.
        // Counting it made every fast route look slow, because a short download is mostly that wait.
        if f.count >= 5, let size = Double(f[3]), let total = Double(f[4]), total - t > 0.2 { bytesPerSecond = size / (total - t) }
        return Transfer(firstByteMs: t * 1000, mbps: bytesPerSecond > 0 ? bytesPerSecond * 8 / 1_000_000 : nil)
    }

    /// How long a fresh HTTPS request takes to start answering, in ms: the middle of three tries.
    /// `webFailedMs` when it does not.
    static func webResponse(socksPort: Int? = nil) async -> Double {
        var times: [Double] = []
        for i in 0..<3 {
            if let t = await fetch(webURL, maxSeconds: 5, socksPort: socksPort).firstByteMs { times.append(t) }
            if times.isEmpty && i == 1 { break }   // two misses in a row: no need to wait for a third
        }
        return times.count >= 2 ? times.sorted()[times.count / 2] : webFailedMs
    }

    /// Download speed in Mbit/s: as much of 25 MB as comes within 4 s (a fixed time, so a fast route is measured at
    /// full speed and a slow one does not hold the test up); 0 when nothing came.
    static func downloadSpeed(socksPort: Int? = nil) async -> Double {
        await fetch(speedURL, maxSeconds: 4, socksPort: socksPort).mbps ?? 0
    }
}

// MARK: - Locations

struct WindscribeCountry: Identifiable, Hashable {
    let code: String
    let name: String
    let continent: String
    let cities: [String]
    // The US (US Central, East, West) and Canada (East, West) are several groups under one country code.
    var id: String { "\(code)|\(name)" }
}

/// Windscribe's servers by country and city: the list AutoScribe's "Update list" downloads, kept in
/// FiveT's folder, or the one built into FiveT when nothing was downloaded yet.
enum WindscribeCatalog {
    static let listURL = URL(string: "https://api.windscribe.com/WebsiteStatus")!

    /// Country codes FiveT never lists, scans or connects to, whatever list they come from (built in, downloaded, saved results).
    static let leftOut: Set<String> = ["IL"]

    /// "CODE|Country|Continent|City,City" lines.
    static func parseSnapshot(_ text: String) -> [WindscribeCountry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, !f[3].isEmpty, !leftOut.contains(f[0]) else { return nil }
            return WindscribeCountry(code: f[0], name: f[1], continent: f[2], cities: f[3].components(separatedBy: ","))
        }
    }

    /// The JSON of Windscribe's public server status page: `data.locations` holds each country with
    /// its `pops` (datacenters, named "City - Nickname"; `status` 1 is working).
    static func parseStatusPage(_ data: Data) -> [WindscribeCountry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = (root["data"] as? [String: Any])?["locations"] as? [String: Any] else { return nil }
        var out: [WindscribeCountry] = []
        for case let v as [String: Any] in locations.values {
            guard let name = v["name"] as? String, let code = v["country_code"] as? String, !leftOut.contains(code) else { continue }
            var cities: [String] = []
            for case let pop as [String: Any] in (v["pops"] as? [Any]) ?? [] where (pop["status"] as? Int) == 1 {
                let city = ((pop["name"] as? String) ?? "").components(separatedBy: " - ")[0].trimmingCharacters(in: .whitespaces)
                if !city.isEmpty && !cities.contains(city) { cities.append(city) }
            }
            if !cities.isEmpty { out.append(WindscribeCountry(code: code, name: name, continent: (v["continent"] as? String) ?? "", cities: cities)) }
        }
        return out.isEmpty ? nil : out.sorted { ($0.continent, $0.name) < ($1.continent, $1.name) }
    }

    private static var cacheURL: URL { ConnectionStore.shared.directory.appendingPathComponent("windscribe-servers.json") }

    /// The downloaded list if there is one, else the built-in one.
    static func load() -> (countries: [WindscribeCountry], downloaded: Bool) {
        if let data = try? Data(contentsOf: cacheURL), let list = parseStatusPage(data) { return (list, true) }
        return (parseSnapshot(WindscribeSnapshot.text), false)
    }

    /// Downloads the list (the page windscribe.com's server list is drawn from) and keeps it.
    static func download() async throws -> [WindscribeCountry] {
        var req = URLRequest(url: listURL, timeoutInterval: 20)
        req.setValue("Bearer 1234", forHTTPHeaderField: "Authorization")   // the placeholder token windscribe.com's own page sends
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let list = parseStatusPage(data) else { throw NSError(domain: "FiveT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Windscribe's answer held no servers."]) }
        try data.write(to: cacheURL, options: .atomic)
        return list
    }
}

// MARK: - Self-check

/// `FiveT --check-windscribe`: the parsers against sample output, then (read only) what the Windscribe
/// on this Mac answers to `status` and `ports`. It never connects.
enum WindscribeCheck {
    /// Home and office: each network keeps its own results and settings, and they swap when the Wi-Fi does.
    @MainActor private static func profileCheck(_ check: (Bool, String) -> Void) {
        let m = WindscribeMax.windscribe
        func result(_ city: String) -> WindscribeResult {
            WindscribeResult(code: "DE", country: "Germany", city: city, proto: "wireguard", port: 443, outcome: .works, avg: 50, loss: 0,
                             seconds: 10, date: Date(), jitter: 1, web: 200, speed: 20)
        }
        let home = NetworkIdentity.Net(key: "home", ssid: "armys", routerIP: "192.168.1.1")
        let office = NetworkIdentity.Net(key: "office", ssid: "office-wifi", routerIP: "192.168.1.1")   // the same router address on purpose
        m.adopt(home)
        m.settings.pingCount = 7
        m.record(result("Frankfurt"))
        m.adopt(office)
        check(m.results.isEmpty && m.networkName == "office-wifi", "profiles: a new network starts with no results")
        check(m.settings.pingCount == 7, "profiles: a new network keeps the last settings")
        m.settings.pingCount = 3
        m.record(result("Berlin")); m.record(result("Munich"))
        m.adopt(home)
        check(m.results.map(\.city) == ["Frankfurt"] && m.settings.pingCount == 7 && m.networkName == "armys", "profiles: back home, home's results and settings")
        m.adopt(NetworkIdentity.Net(key: "home", ssid: "", routerIP: "192.168.1.1"))
        check(m.networkName == "armys", "profiles: a missing Wi-Fi name does not erase the saved one")
        m.adopt(office)
        check(m.results.count == 2 && m.settings.pingCount == 3 && m.otherNetworks.map(\.profile.name) == ["armys"], "profiles: at the office again, its own two results")
        m.renameNetwork("Main office")
        m.adopt(NetworkIdentity.Net(key: "office", ssid: "office-wifi", routerIP: "192.168.1.1"))
        check(m.networkName == "Main office", "profiles: a name the person gave is kept when the Wi-Fi name shows up")
        let express = WindscribeMax.express
        express.adopt(office)
        check(express.networkName == "Main office", "profiles: a name given in one service shows in the other")
        express.renameNetwork("")
        check(m.networkName == "office-wifi" && express.networkName == "office-wifi", "profiles: an empty name goes back to the Wi-Fi name in both")
        m.renameNetwork("Main office")
        m.forgetNetwork("home")
        check(m.otherNetworks.isEmpty && !express.profiles.keys.contains("home"), "profiles: forgetting a network in one service forgets it in the other")
        m.forgetNetwork("office")
        check(m.profiles.keys.contains("office") && express.networkName == "Main office", "profiles: the network on screen cannot be forgotten")
        let file = ConnectionStore.shared.directory.appendingPathComponent(m.backend.fileName)
        let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        check((saved?["networks"] as? [String: Any])?.keys.sorted() == ["office"] && saved?["last"] as? String == "office", "profiles: the one left is saved to the file")
    }

    static func run() -> Int32 {
        #if !DISTRIBUTION
        // `--check-windscribe scan <city> <protocol> <port>`: really scans that one route, through the same
        // code as the Scan tab (it connects Windscribe, and puts the firewall back as it found it).
        let a = Array(CommandLine.arguments.dropFirst(2))
        if a.count == 4, a[0] == "scan", let port = Int(a[3]) { return scanOnce(city: a[1], proto: a[2], port: port) }
        // `--check-windscribe connect [stop-after-seconds]`: Connect on "Scanned locations" with the saved results.
        if a.first == "connect" { return connectOnce(stopAfter: a.count > 1 ? Double(a[1]) : nil) }
        // `--check-windscribe smart`: Smart Connect's background check of every VPN that is on; connects nothing.
        if a.first == "smart" {
            Task { @MainActor in
                let began = Date()
                for (name, m) in await SmartConnect.shared.checkAll() {
                    print("\(name): " + (m.failure ?? "score \(m.score.map(String.init) ?? "-"), web \(m.web.map { "\(Int($0)) ms" } ?? "-"), \(m.speed.map { String(format: "%.1f Mbit/s", $0) } ?? "-") \(m.note ?? "")"))
                }
                print(String(format: "took %.1f s", Date().timeIntervalSince(began)))
                exit(0)
            }
            RunLoop.main.run()
        }
        #endif
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1 }; print((ok ? "ok    " : "FAIL  ") + what) }

        let off = WindscribeCLI.parseStatus("Internet connectivity: available\nLogin state: Logged in\nFirewall state: Off\nConnect state: Disconnected\nPublic IP: 31.56.197.202\nData usage: 230.55 MB / Unlimited\nUpdate available: 2.25.8")
        check(off.known && off.isLoggedIn && !off.isConnected && !off.isConnecting && !off.firewallOn && off.publicIP == "31.56.197.202", "status: logged in, disconnected")
        let on = WindscribeCLI.parseStatus("Login state: Logged in\nFirewall state: On\nConnect state: Connected: Frankfurt - Hirsch")
        check(on.isConnected && on.firewallOn && on.place == "Frankfurt - Hirsch", "status: connected with a place")
        check(WindscribeCLI.parseStatus("Connect state: Connecting").isConnecting, "status: connecting")
        let v25 = WindscribeCLI.parseStatus("Login:       Logged in\nConnection:  Disconnected\nIP:          31.56.197.202 (public)\nFirewall:    Off\nData usage:  230.55 MB / Unlimited\nInternet:    Available\nUpdate:      2.26.1 available")
        check(v25.known && v25.isLoggedIn && !v25.isConnected && v25.publicIP == "31.56.197.202" && !v25.firewallOn && v25.internet == "Available" && v25.update == "2.26.1", "status 2.25: disconnected")
        let v25on = WindscribeCLI.parseStatus("Login:       Logged in\nConnection:  Connected to Frankfurt (checking the connection)\nProtocol:    wireguard:443\nIP:          185.1.2.3 (VPN)\nFirewall:    Always On")
        check(v25on.isConnected && v25on.place == "Frankfurt (checking the connection)" && v25on.protocolInUse == "wireguard:443" && v25on.firewallOn && v25on.publicIP == "185.1.2.3", "status 2.25: connected, firewall Always On")
        check(WindscribeCLI.parseStatus("Connection:  Connecting to Berlin").isConnecting && !WindscribeCLI.parseStatus("Connection:  Disconnecting").isConnecting, "status 2.25: connecting, disconnecting")
        let out = WindscribeCLI.parseStatus("Login:       Logged out\nFirewall:    Off")
        check(out.known && !out.isLoggedIn, "status 2.25: logged out has no connection line but is an answer")
        let err = WindscribeCLI.parseStatus("Login:       Logged in\nConnection:  Error: Location does not exist or is disabled")
        check(err.isError && !err.isConnected && WindscribeCLI.refusesLocation(err.connect), "status 2.25: error line")
        check(!WindscribeCLI.parseStatus("Unable to connect to the Windscribe app").known, "status: no answer")
        check(WindscribeCLI.isBusyAnswer("Windscribe CLI is already running") && !WindscribeCLI.isBusyAnswer("Login: Logged in"), "busy answer: another command is running")

        let ping = WindscribeCLI.parsePing("PING 1.1.1.1 (1.1.1.1): 56 data bytes\n--- 1.1.1.1 ping statistics ---\n5 packets transmitted, 4 packets received, 20.0% packet loss\nround-trip min/avg/max/stddev = 33.1/34.5/36.0/1.1 ms")
        check(ping.answered && ping.avg == 34.5 && ping.min == 33.1 && ping.max == 36.0 && ping.loss == 20, "ping: 4 of 5 answered")
        check(ping.stddev == 1.1, "ping: jitter")
        let fetched = WindscribeCLI.parseTransfer("0.312000 1250000.000 200")
        check(fetched.firstByteMs == 312 && fetched.mbps == 10, "transfer: first byte and Mbit/s")
        check(WindscribeCLI.parseTransfer("0.000000 0.000 000") == WindscribeCLI.Transfer(), "transfer: nothing came")
        func route(_ ping: Double, _ speed: Double?, web: Double? = 300) -> WindscribeResult {
            WindscribeResult(code: "DE", country: "Germany", city: "Berlin", proto: "wireguard", port: 443, outcome: .works,
                             avg: ping, loss: 0, seconds: 20, date: Date(), jitter: 2, web: web, speed: speed)
        }
        check(route(90, 80).score! > route(20, 4).score!, "score: speed counts more than ping")
        check(route(40, 50).score! > route(40, 50, web: WindscribeCLI.webFailedMs).score!, "score: a failed web page costs points")
        check(route(40, 100, web: 150).score! >= 95, "score: a fast route is near 100")
        check(WindscribeResult(code: "DE", country: "Germany", city: "Berlin", proto: "tcp", port: 443, outcome: .failed, avg: nil, loss: nil, seconds: 25, date: Date()).score == nil, "score: only for routes that work")
        check(WindscribeResult.score(ping: nil, loss: nil, jitter: nil, web: 150, speed: 100) == 100
              && WindscribeResult.score(ping: nil, loss: nil, jitter: nil, web: nil, speed: nil) == nil, "score: web page and speed alone are enough (Smart Connect)")
        let (v1, v2, v3) = (UUID(), UUID(), UUID())
        check(SmartConnect.pick([(v1, 80, 20, 300), (v2, 90, 10, 400), (v3, nil, nil, nil)]) == v2, "smart connect: the best score wins")
        check(SmartConnect.pick([(v1, 80, 20, 300), (v2, 80, 40, 400)]) == v2, "smart connect: the same score, the faster download wins")
        check(SmartConnect.pick([(v1, nil, nil, nil)]) == nil, "smart connect: nothing worked, nothing picked")
        var (f1, f2, f3, forti) = (Connection(), Connection(), Connection(), Connection())
        f1.kind = .v2ray; f2.kind = .v2ray; f3.kind = .openvpn; forti.kind = .fortinet
        check(VPNManager.failoverRing([f1, forti, f2, f3], off: [f2.id], from: f1.id).map(\.id) == [f1.id, f3.id], "failover: skips Forti and a VPN switched off in Smart Connect")
        check(VPNManager.failoverRing([f1, f2, f3], off: [f1.id, f2.id], from: f1.id).map(\.id) == [f1.id, f3.id], "failover: the failing VPN stays in the ring though it is switched off")
        let dead = WindscribeCLI.parsePing("5 packets transmitted, 0 packets received, 100.0% packet loss")
        check(!dead.answered && dead.loss == 100, "ping: nothing answered")
        check(!WindscribeCLI.parsePing("ping: cannot resolve nope: Unknown host").answered, "ping: unknown host")

        check(WindscribeCLI.refusesLocation("Location does not exist") && WindscribeCLI.refusesLocation("Paris is disabled") && !WindscribeCLI.refusesLocation("Connecting"), "refused locations")

        let snap = WindscribeCatalog.parseSnapshot(WindscribeSnapshot.text)
        check(snap.count > 60 && snap.contains { $0.code == "DE" && $0.cities.contains("Frankfurt") }, "built-in list: \(snap.count) countries")
        check(Set(snap.map(\.id)).count == snap.count && snap.filter { $0.code == "US" }.count == 3, "built-in list: US West, East and Central each have their own id")
        let page = Data(#"{"data":{"locations":{"1":{"name":"Germany","country_code":"DE","continent":"Europe","pops":[{"status":1,"name":"Frankfurt - Hirsch"},{"status":1,"name":"Frankfurt - Roe"},{"status":0,"name":"Berlin - Zoo"}]},"2":{"name":"Nowhere","country_code":"NW","pops":[{"status":0,"name":"X - Y"}]}}}}"#.utf8)
        let parsed = WindscribeCatalog.parseStatusPage(page)
        check(parsed?.count == 1 && parsed?.first?.cities == ["Frankfurt"], "server page: working datacenters only, one entry per city")
        check(WindscribeCatalog.parseStatusPage(Data("{}".utf8)) == nil, "server page: junk refused")
        let withIL = Data(#"{"data":{"locations":{"1":{"name":"Germany","country_code":"DE","pops":[{"status":1,"name":"Frankfurt - Hirsch"}]},"2":{"name":"Israel","country_code":"IL","pops":[{"status":1,"name":"Tel Aviv - Dead Sea"}]}}}}"#.utf8)
        check(WindscribeCatalog.parseStatusPage(withIL)?.map(\.code) == ["DE"] && !snap.contains { $0.code == "IL" }, "Israel never listed: downloaded page and built-in list")

        var s = WindscribeScanSettings()
        s.cities = ["Frankfurt"]
        check(s.ports["wireguard"] == [443] && s.protocols.count == 6, "scan settings: first port of each protocol")

        // The per-Wi-Fi profiles write the model's file, so they are checked only against a throwaway data folder.
        if ProcessInfo.processInfo.environment["FIVET_DATA_DIR"] != nil {
            MainActor.assumeIsolated { profileCheck(check) }
        } else {
            print("skip  Wi-Fi profiles (run with FIVET_DATA_DIR=<an empty folder>)")
        }

        print("install: app=\(WindscribeCLI.appInstalled) cli=\(WindscribeCLI.path ?? "none")")
        if WindscribeCLI.path != nil {
            let done = DispatchSemaphore(value: 0)
            Task {
                let (st, text) = await WindscribeCLI.status()
                print("live status: known=\(st.known) login=\(st.login) connect=\(st.connect) firewall=\(st.firewall) ip=\(st.publicIP)")
                if !st.known { print("  raw: \(text)") }
                for p in ["wireguard", "stealth"] { print("live ports \(p): \(await WindscribeCLI.ports(for: p))") }
                done.signal()
            }
            done.wait()
        }
        print(failed == 0 ? "all checks passed" : "\(failed) CHECK(S) FAILED")
        return failed == 0 ? 0 : 1
    }
}

#if !DISTRIBUTION
extension WindscribeCheck {
    static func connectOnce(stopAfter: Double?) -> Int32 {
        var code: Int32 = 1
        Task { @MainActor in
            let m = WindscribeMax.windscribe
            await m.refresh()
            m.target = WindscribeMax.scanned
            print("routes in order: \(m.best.map { "\($0.city) \($0.route) \(Int($0.avg ?? 0)) ms" })")
            m.connect()
            if let t = stopAfter { Task { try? await Task.sleep(nanoseconds: UInt64(t * 1e9)); print("-- Stop pressed"); m.stopConnect() } }
            var last = ""
            while m.busy != nil {
                if let b = m.busy, b != last { print(b); last = b }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("connected: \(m.connected) place: \(m.status?.place ?? "-")")
            print("notice: \(m.notice?.text ?? "-")")
            code = m.connected ? 0 : 2
            exit(code)
        }
        RunLoop.main.run()
        return code
    }

    static func scanOnce(city: String, proto: String, port: Int) -> Int32 {
        var code: Int32 = 1
        Task { @MainActor in
            let m = WindscribeMax.windscribe
            m.settings.cities = [city]
            m.settings.protocols = [proto]
            m.settings.ports = [proto: [port]]
            m.settings.resume = false
            if let t = ProcessInfo.processInfo.environment["FIVET_SCAN_TIMEOUT"].flatMap(Int.init) { m.settings.timeout = t }
            m.settings.pingCount = 2
            m.startScan()
            var last = ""
            while m.scanning {
                let line = "\(m.scan?.step ?? "") \(m.scan?.current ?? "")"
                if line != last { print(line); last = line }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            for r in m.results where r.city == city && r.proto == proto && r.port == port {
                print("RESULT \(r.place) \(r.route): \(r.outcome.label) avg=\(r.avg.map { String($0) } ?? "-") loss=\(r.loss.map { String($0) } ?? "-") jitter=\(r.jitter.map { String($0) } ?? "-") web=\(r.web.map { String($0) } ?? "-") ms speed=\(r.speed.map { String($0) } ?? "-") Mbit/s score=\(r.score.map { String($0) } ?? "-") in \(Int(r.seconds)) s")
                code = r.works ? 0 : 2
            }
            print("notice: \(m.notice?.text ?? "-")")
            exit(code)
        }
        RunLoop.main.run()
        return code
    }
}
#endif
