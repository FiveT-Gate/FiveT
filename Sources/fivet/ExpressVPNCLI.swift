import Foundation
import AppKit

/// The official ExpressVPN command line (`expressvpnctl`, inside ExpressVPN.app), driven the way Windscribe Max
/// drives `windscribe-cli`: `connect <region>` returns at once, then `get connectionstate` is read until it says
/// Connected, then the route is pinged. FiveT never bundles ExpressVPN: the user installs the app, and this only runs
/// its command line as the user.
enum ExpressVPNCLI {
    /// ExpressVPN's own names for the protocols `set protocol` takes ("" is Automatic).
    static let protocols = ["lightwayudp", "lightwaytcp", "wireguard", "openvpnudp", "openvpntcp"]

    static let downloadURL = URL(string: "https://www.expressvpn.com/download")!
    static let appName = "ExpressVPN"

    private static let appFolders = ["/Applications", NSHomeDirectory() + "/Applications"]
    static var appPath: String? { appFolders.map { $0 + "/ExpressVPN.app" }.first { FileManager.default.fileExists(atPath: $0) } }

    #if !DISTRIBUTION
    /// Test copies only: FIVET_EXPRESSVPN_CLI=none pretends ExpressVPN is not installed, =nocli that only the app is.
    private static let pretend = ProcessInfo.processInfo.environment["FIVET_EXPRESSVPN_CLI"]
    #endif

    /// The command line lives inside the app (`/usr/local/bin/expressvpnctl` is only a link to it, and not always there).
    static var path: String? {
        #if !DISTRIBUTION
        if let pretend { return pretend == "none" || pretend == "nocli" ? nil : pretend }
        #endif
        guard let app = appPath else { return nil }
        let p = app + "/Contents/MacOS/expressvpnctl"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var appInstalled: Bool {
        #if !DISTRIBUTION
        if let pretend { return pretend != "none" }
        #endif
        return appPath != nil
    }

    static var version: String? {
        guard let app = appPath, let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    // MARK: Running it

    static func ctl(_ args: [String], timeout: TimeInterval = 15) async -> WindscribeCLI.Output {
        guard let path else { return WindscribeCLI.Output(text: "expressvpnctl is not installed", status: 127) }
        return await WindscribeCLI.run(path, args, timeout: timeout)
    }

    /// `expressvpnctl get <type>`: the one line it prints.
    static func get(_ type: String) async -> WindscribeCLI.Output {
        var out = await ctl(["get", type])
        out.text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    // MARK: The window app

    /// `connect` needs ExpressVPN's window app to be running (or its background mode, which is a permanent setting
    /// FiveT leaves alone). FiveT opens it without showing it, and closes it again when it started it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedByFiveT = false

    static var appRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.express.vpn").contains { !$0.isTerminated }
    }

    /// Makes sure the window app runs; true when it does. Waits up to ~12 s for it to start.
    static func ensureApp() async -> Bool {
        if appRunning { return true }
        guard let app = appPath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-j", app]   // in the background, hidden
        try? p.run()
        lock.lock(); startedByFiveT = true; lock.unlock()
        for _ in 0..<24 {
            if appRunning { try? await Task.sleep(nanoseconds: 1_500_000_000); return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return appRunning
    }

    /// Quits the window app if FiveT opened it. Never while a connection is up: without background mode the VPN would end with it.
    static func closeAppIfOurs() {
        lock.lock(); let ours = startedByFiveT; startedByFiveT = false; lock.unlock()
        guard ours else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.express.vpn").forEach { $0.terminate() }
    }

    // MARK: Status

    /// What `get connectionstate` says, as the Status the panel shows. A signed-out or unsubscribed account is
    /// told by the command line's own words.
    static func status() async -> (status: WindscribeCLI.Status, text: String) {
        let state = await get("connectionstate")
        return (buildStatus(state: state.text, status: state.status, region: nil, ip: nil, proto: nil), state.text)
    }

    /// The same, with the region, address and protocol read too (the panel's Status card).
    static func fullStatus() async -> (status: WindscribeCLI.Status, text: String) {
        let state = await get("connectionstate")
        guard parseState(state.text) != nil else { return (buildStatus(state: state.text, status: state.status, region: nil, ip: nil, proto: nil), state.text) }
        async let region = get("region"), pub = get("pubip"), vpn = get("vpnip"), proto = get("protocol")
        let (r, p, v, pr) = await (region.text, pub.text, vpn.text, proto.text)
        let ip = [p, v].first { !$0.isEmpty && $0.lowercased() != "unknown" && !$0.contains("\n") } ?? ""
        return (buildStatus(state: state.text, status: state.status, region: r, ip: ip, proto: pr), state.text)
    }

    /// "Connected", "Connecting", "Disconnected"…: the answer when it is a state.
    static func parseState(_ text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let states = ["Disconnected", "Connecting", "Connected", "Interrupted", "Reconnecting", "DisconnectingToReconnect", "Disconnecting"]
        return states.first { $0 == first.trimmingCharacters(in: .whitespaces) }
    }

    static func buildStatus(state: String, status code: Int32, region: String?, ip: String?, proto: String?) -> WindscribeCLI.Status {
        var s = WindscribeCLI.Status()
        let lower = state.lowercased()
        if lower.contains("logged in") || lower.contains("login first") {
            s.login = "Signed out"   // "This command requires a logged in account" / "Not logged in. Please login first…"
            s.connect = "Disconnected"
            return s
        }
        if lower.contains("active subscription") { s.login = "No active subscription"; s.connect = "Disconnected"; return s }
        guard let st = parseState(state) else { return s }   // the daemon did not answer: unknown
        s.login = "Logged in"
        switch st {
        case "Connected":
            let place = region.flatMap { ExpressCatalog.label(forSlug: $0) }
            s.connect = place.map { "Connected to \($0)" } ?? "Connected"
        case "Connecting", "Interrupted", "Reconnecting", "DisconnectingToReconnect": s.connect = "Connecting"
        default: s.connect = "Disconnected"
        }
        s.publicIP = ip ?? ""
        s.protocolInUse = proto ?? ""
        return s
    }

    // MARK: Connecting

    // `connect <region>` and `set protocol` change ExpressVPN's own settings (the location and protocol its app shows): they are
    // written down before the first change and put back when FiveT lets go.
    nonisolated(unsafe) private static var saved: (region: String, proto: String)?

    #if !DISTRIBUTION
    static func rememberSettingsForCheck() async { await rememberSettings() }
    #endif

    private static func rememberSettings() async {
        lock.lock(); let have = saved != nil; lock.unlock()
        guard !have else { return }
        let r = await get("region"), p = await get("protocol")
        guard r.status == 0, p.status == 0, !r.text.isEmpty, !p.text.isEmpty, !r.text.contains(" "), !p.text.contains(" ") else { return }
        lock.lock(); saved = (r.text, p.text); lock.unlock()
    }

    static func restoreSettings() async {
        lock.lock(); let s = saved; saved = nil; lock.unlock()
        guard let s else { return }
        _ = await ctl(["set", "region", s.region])
        _ = await ctl(["set", "protocol", s.proto])
    }

    /// `set protocol <p>` (Automatic for ""), then `connect <slug>`; the answer is the command line's.
    /// The window app is started first when it is not running. This returns once the attempt is started.
    static func connect(slug: String, proto: String) async -> WindscribeCLI.Output {
        guard await ensureApp() else { return WindscribeCLI.Output(text: "ExpressVPN's window app did not start.", status: 4) }
        await rememberSettings()
        let set = await ctl(["set", "protocol", proto.isEmpty ? "auto" : proto])
        if set.status != 0 { return set }
        var out = await ctl(["connect", slug], timeout: 30)
        if out.status == 4 {   // the app was still starting up: once more
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            out = await ctl(["connect", slug], timeout: 30)
        }
        return out
    }

    static func disconnect() async {
        _ = await ctl(["disconnect"], timeout: 30)
    }

    /// The words it uses for a region it does not have.
    static func refusesLocation(_ text: String) -> Bool {
        text.contains("Cannot find region") || text.contains("Unknown location") || text.contains("No match found for specified location")
    }
}

// MARK: - Locations

struct ExpressRegion: Equatable {
    let slug: String
    let countrySlug: String
    let label: String   // the city part, or the country when the region is the whole country
}

/// ExpressVPN's regions (`get regions`: 215 of them, named like `usa-san-francisco` or `germany-frankfurt-1`) grouped
/// by country, which the command line does not do. A small table names the countries; a region of a country that is not in it
/// is a country of its own.
enum ExpressCatalog {
    /// `slug|CODE|Country|Continent`. FiveT does not offer Israel (see `leftOut`).
    private static let countries = """
usa|US|USA|North America
canada|CA|Canada|North America
mexico|MX|Mexico|North America
guatemala|GT|Guatemala|North America
honduras|HN|Honduras|North America
costa-rica|CR|Costa Rica|North America
panama|PA|Panama|North America
jamaica|JM|Jamaica|North America
cuba|CU|Cuba|North America
bahamas|BS|Bahamas|North America
bermuda|BM|Bermuda|North America
cayman-islands|KY|Cayman Islands|North America
dominican-republic|DO|Dominican Republic|North America
puerto-rico|PR|Puerto Rico|North America
trinidad-and-tobago|TT|Trinidad and Tobago|North America
greenland|GL|Greenland|North America
guam|GU|Guam|Oceania
argentina|AR|Argentina|South America
bolivia|BO|Bolivia|South America
brazil|BR|Brazil|South America
chile|CL|Chile|South America
colombia|CO|Colombia|South America
ecuador|EC|Ecuador|South America
peru|PE|Peru|South America
uruguay|UY|Uruguay|South America
venezuela|VE|Venezuela|South America
australia|AU|Australia|Oceania
new-zealand|NZ|New Zealand|Oceania
albania|AL|Albania|Europe
andorra|AD|Andorra|Europe
armenia|AM|Armenia|Europe
austria|AT|Austria|Europe
azerbaijan|AZ|Azerbaijan|Europe
belarus|BY|Belarus|Europe
belgium|BE|Belgium|Europe
bosnia-and-herzegovina|BA|Bosnia and Herzegovina|Europe
bulgaria|BG|Bulgaria|Europe
croatia|HR|Croatia|Europe
cyprus|CY|Cyprus|Europe
czech-republic|CZ|Czech Republic|Europe
denmark|DK|Denmark|Europe
estonia|EE|Estonia|Europe
finland|FI|Finland|Europe
france|FR|France|Europe
gaming-europe|EU|Gaming Europe|Europe
georgia|GE|Georgia|Europe
germany|DE|Germany|Europe
greece|GR|Greece|Europe
hungary|HU|Hungary|Europe
iceland|IS|Iceland|Europe
ireland|IE|Ireland|Europe
isle-of-man|IM|Isle of Man|Europe
italy|IT|Italy|Europe
jersey|JE|Jersey|Europe
kazakhstan|KZ|Kazakhstan|Europe
latvia|LV|Latvia|Europe
liechtenstein|LI|Liechtenstein|Europe
lithuania|LT|Lithuania|Europe
luxembourg|LU|Luxembourg|Europe
malta|MT|Malta|Europe
moldova|MD|Moldova|Europe
monaco|MC|Monaco|Europe
montenegro|ME|Montenegro|Europe
netherlands|NL|Netherlands|Europe
north-macedonia|MK|North Macedonia|Europe
norway|NO|Norway|Europe
poland|PL|Poland|Europe
portugal|PT|Portugal|Europe
romania|RO|Romania|Europe
serbia|RS|Serbia|Europe
slovakia|SK|Slovakia|Europe
slovenia|SI|Slovenia|Europe
spain|ES|Spain|Europe
sweden|SE|Sweden|Europe
switzerland|CH|Switzerland|Europe
turkey|TR|Turkey|Europe
uk|GB|United Kingdom|Europe
ukraine|UA|Ukraine|Europe
algeria|DZ|Algeria|Africa
egypt|EG|Egypt|Africa
ghana|GH|Ghana|Africa
kenya|KE|Kenya|Africa
morocco|MA|Morocco|Africa
nigeria|NG|Nigeria|Africa
south-africa|ZA|South Africa|Africa
bangladesh|BD|Bangladesh|Asia
bhutan|BT|Bhutan|Asia
brunei|BN|Brunei|Asia
cambodia|KH|Cambodia|Asia
china|CN|China|Asia
hong-kong|HK|Hong Kong|Asia
india|IN|India|Asia
indonesia|ID|Indonesia|Asia
japan|JP|Japan|Asia
laos|LA|Laos|Asia
lebanon|LB|Lebanon|Asia
macau|MO|Macau|Asia
malaysia|MY|Malaysia|Asia
mongolia|MN|Mongolia|Asia
myanmar|MM|Myanmar|Asia
nepal|NP|Nepal|Asia
pakistan|PK|Pakistan|Asia
philippines|PH|Philippines|Asia
qatar|QA|Qatar|Asia
saudi-arabia|SA|Saudi Arabia|Asia
singapore|SG|Singapore|Asia
south-korea|KR|South Korea|Asia
sri-lanka|LK|Sri Lanka|Asia
taiwan|TW|Taiwan|Asia
thailand|TH|Thailand|Asia
united-arab-emirates|AE|United Arab Emirates|Asia
uzbekistan|UZ|Uzbekistan|Asia
vietnam|VN|Vietnam|Asia
"""

    /// Country codes FiveT never lists, scans or connects to (the same rule as Windscribe Max).
    static let leftOut: Set<String> = ["IL"]
    private static let leftOutSlugs: Set<String> = ["israel"]

    private struct Country { let slug, code, name, continent: String }
    private static let table: [Country] = countries.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return f.count == 4 ? Country(slug: f[0], code: f[1], name: f[2], continent: f[3]) : nil
    }

    // The last list read, for turning a slug into words and a city name back into a slug.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var regions: [ExpressRegion] = []

    static func label(forSlug slug: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let r = regions.first(where: { $0.slug == slug }) {
            let c = table.first { $0.slug == r.countrySlug }
            return r.label == c?.name || c == nil ? r.label : "\(r.label), \(c!.name)"
        }
        return slug == "smart" ? "Smart location" : slug.isEmpty ? nil : words(slug)
    }

    /// The slug `connect` takes for a name the panel shows (a city name), a country (its code or name: its first region), or "best".
    static func slug(for place: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if place == "best" || place == "smart" { return "smart" }
        if let r = regions.first(where: { $0.label == place }) { return r.slug }
        if let c = table.first(where: { $0.code == place || $0.name == place }),
           let r = regions.first(where: { $0.countrySlug == c.slug }) { return r.slug }
        // A country FiveT's table does not know is listed under its slug in words ("New Country").
        if let r = regions.first(where: { words($0.countrySlug) == place }) { return r.slug }
        return place
    }

    private static func words(_ s: String) -> String {
        s.split(separator: "-").map { w -> String in
            let up = ["cbd", "dc", "uk", "usa", "uae"]
            if up.contains(w.lowercased()) { return w.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// `get regions` (one slug per line) as countries with their cities, in the Windscribe list's shape.
    static func parse(_ text: String) -> [WindscribeCountry] {
        var found: [ExpressRegion] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let slug = line.trimmingCharacters(in: .whitespaces)
            guard !slug.isEmpty, slug != "smart", !slug.contains(" "), !leftOutSlugs.contains(where: { slug == $0 || slug.hasPrefix($0 + "-") }) else { continue }
            let known = table.filter { slug == $0.slug || slug.hasPrefix($0.slug + "-") }.max { $0.slug.count < $1.slug.count }
            let countrySlug = known?.slug ?? slug
            let countryName = known?.name ?? words(slug)
            let rest = String(slug.dropFirst(countrySlug.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            var label: String
            if rest.isEmpty { label = countryName }
            else if rest.allSatisfy(\.isNumber) { label = "\(countryName) \(rest)" }
            else if rest.hasPrefix("(") { label = words(rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) }   // "india-(via-uk)"
            else { label = words(rest) }
            if seen.contains(label) { label = "\(label) (\(slug))" }   // names must be unique: they are what a result is filed under
            seen.insert(label)
            found.append(ExpressRegion(slug: slug, countrySlug: countrySlug, label: label))
        }
        lock.lock(); regions = found; lock.unlock()
        var order: [String] = []
        var by: [String: [ExpressRegion]] = [:]
        for r in found { if by[r.countrySlug] == nil { order.append(r.countrySlug) }; by[r.countrySlug, default: []].append(r) }
        let list = order.map { cs -> WindscribeCountry in
            let c = table.first { $0.slug == cs }
            return WindscribeCountry(code: c?.code ?? "", name: c?.name ?? words(cs), continent: c?.continent ?? "", cities: by[cs]!.map(\.label))
        }
        return list.sorted { ($0.continent, $0.name) < ($1.continent, $1.name) }
    }

    /// The regions ExpressVPN lists now.
    static func read() async -> [WindscribeCountry] {
        let out = await ExpressVPNCLI.get("regions")
        guard out.status == 0 else { return [] }
        return parse(out.text)
    }
}

// MARK: - Self-check

/// `FiveT --check-expressvpn`: the parsers against sample output, then (read only) what the ExpressVPN on this Mac
/// answers. It never connects.
enum ExpressCheck {
    static func run() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok    \(what)" : "FAIL  \(what)"); if !ok { failed += 1 } }

        #if !DISTRIBUTION
        // `--check-expressvpn app`: starts ExpressVPN's window app hidden and closes it again, and changes the region and
        // protocol and puts them back. It never connects.
        if CommandLine.arguments.dropFirst(2).first == "app" {
            let done = DispatchSemaphore(value: 0)
            Task {
                let wasRunning = ExpressVPNCLI.appRunning
                let region = await ExpressVPNCLI.get("region").text, proto = await ExpressVPNCLI.get("protocol").text
                print("before: running=\(wasRunning) region=\(region) protocol=\(proto)")
                check(await ExpressVPNCLI.ensureApp(), "window app started")
                let refused = await ExpressVPNCLI.ctl(["connect", "nowhere-land"])
                check(refused.status != 0 && ExpressVPNCLI.refusesLocation(refused.text), "a bogus region is refused (exit \(refused.status): \(refused.text))")
                await ExpressVPNCLI.rememberSettingsForCheck()
                _ = await ExpressVPNCLI.ctl(["set", "region", "uk-london"]); _ = await ExpressVPNCLI.ctl(["set", "protocol", "openvpntcp"])
                print("changed: region=\(await ExpressVPNCLI.get("region").text) protocol=\(await ExpressVPNCLI.get("protocol").text)")
                await ExpressVPNCLI.restoreSettings()
                let r2 = await ExpressVPNCLI.get("region").text, p2 = await ExpressVPNCLI.get("protocol").text
                check(r2 == region && p2 == proto, "region and protocol put back (\(r2), \(p2))")
                ExpressVPNCLI.closeAppIfOurs()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                check(wasRunning || !ExpressVPNCLI.appRunning, "window app closed again")
                done.signal()
            }
            done.wait()
            print(failed == 0 ? "all checks passed" : "\(failed) check(s) FAILED")
            return failed == 0 ? 0 : 1
        }
        #endif

        check(ExpressVPNCLI.parseState("Connected\n") == "Connected" && ExpressVPNCLI.parseState("Disconnected") == "Disconnected", "state: read")
        check(ExpressVPNCLI.parseState("Cannot connect - start the ExpressVPN client") == nil, "state: an error is not a state")
        let up = ExpressVPNCLI.buildStatus(state: "Connected", status: 0, region: "uk-london", ip: "1.2.3.4", proto: "lightwayudp")
        check(up.isConnected && up.isLoggedIn && up.publicIP == "1.2.3.4" && up.protocolInUse == "lightwayudp", "status: connected")
        check(ExpressVPNCLI.buildStatus(state: "Connecting", status: 0, region: nil, ip: nil, proto: nil).isConnecting, "status: connecting")
        check(ExpressVPNCLI.buildStatus(state: "Reconnecting", status: 0, region: nil, ip: nil, proto: nil).isConnecting, "status: reconnecting counts as connecting")
        check(!ExpressVPNCLI.buildStatus(state: "Disconnected", status: 0, region: nil, ip: nil, proto: nil).isConnected, "status: disconnected")
        check(!ExpressVPNCLI.buildStatus(state: "This command requires a logged in account", status: 1, region: nil, ip: nil, proto: nil).isLoggedIn, "status: signed out")
        check(!ExpressVPNCLI.buildStatus(state: "This command requires an active subscription", status: 1, region: nil, ip: nil, proto: nil).isLoggedIn, "status: no subscription")
        check(!ExpressVPNCLI.buildStatus(state: "", status: 127, region: nil, ip: nil, proto: nil).known, "status: no answer is unknown")
        check(ExpressVPNCLI.refusesLocation("Cannot find region \"nowhere\""), "refused regions")

        let sample = """
        smart
        usa-san-francisco
        usa-new-jersey-2
        usa-new-jersey-1
        uk-london
        germany-frankfurt-1
        germany-berlin
        thailand
        india-(via-uk)
        taiwan-3
        switzerland
        switzerland-2
        israel
        gaming-europe
        hong-kong-1
        singapore-cbd
        brand-new-land
        """
        let list = ExpressCatalog.parse(sample)
        let all = list.flatMap(\.cities)
        check(!list.contains { $0.code == "IL" } && !all.contains("Israel"), "Israel never listed")
        check(list.first { $0.code == "US" }?.cities == ["San Francisco", "New Jersey 2", "New Jersey 1"], "regions grouped by country: \(list.first { $0.code == "US" }?.cities ?? [])")
        check(list.first { $0.code == "DE" }?.cities == ["Frankfurt 1", "Berlin"], "regions: Germany")
        check(list.first { $0.code == "CH" }?.cities == ["Switzerland", "Switzerland 2"], "regions: numbered countries")
        check(all.contains("Via UK") && list.first { $0.code == "IN" }?.cities == ["Via UK"], "regions: (via UK)")
        check(list.first { $0.name == "Brand New Land" }?.cities == ["Brand New Land"], "regions: a country not in the table stands alone")
        check(Set(all).count == all.count, "region names are unique")
        check(ExpressCatalog.slug(for: "Frankfurt 1") == "germany-frankfurt-1" && ExpressCatalog.slug(for: "best") == "smart"
              && ExpressCatalog.slug(for: "GB") == "uk-london" && ExpressCatalog.slug(for: "Thailand") == "thailand", "slug lookup")
        check(ExpressCatalog.label(forSlug: "uk-london") == "London, United Kingdom", "label of a slug")

        print("install: app=\(ExpressVPNCLI.appInstalled) cli=\(ExpressVPNCLI.path ?? "none") version=\(ExpressVPNCLI.version ?? "-")")
        if ExpressVPNCLI.path != nil {
            let done = DispatchSemaphore(value: 0)
            Task {
                let (st, text) = await ExpressVPNCLI.fullStatus()
                print("live status: known=\(st.known) login=\(st.login) connect=\(st.connect) ip=\(st.publicIP) protocol=\(st.protocolInUse)")
                if !st.known { print("  raw: \(text)") }
                let live = await ExpressCatalog.read()
                print("live regions: \(live.flatMap(\.cities).count) in \(live.count) countries")
                check(!live.isEmpty && !live.contains { $0.code == "IL" }, "live regions read, without Israel")
                done.signal()
            }
            done.wait()
        }
        print(failed == 0 ? "all checks passed" : "\(failed) check(s) FAILED")
        return failed == 0 ? 0 : 1
    }
}
