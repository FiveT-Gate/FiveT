import Foundation
import AppKit
import Combine

extension Notification.Name {
    /// A scan of Windscribe Max or Express Max started or ended.
    static let windscribeScanChanged = Notification.Name("FiveTWindscribeScanChanged")
}

/// One tested route: a city, a protocol and a port, and whether the Windscribe tunnel came up and
/// carried traffic on this network. Saved so a scan can be resumed and the best routes found later.
struct WindscribeResult: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable {
        case works          // connected and the ping was answered
        case noTraffic      // Windscribe says connected, but no ping came back through it
        case failed         // never came up within the timeout
        case unavailable    // Windscribe has no such location (or it is switched off)

        var label: String {
            switch self {
            case .works: return "Works"
            case .noTraffic: return "No traffic"
            case .failed: return "Failed"
            case .unavailable: return "Not available"
            }
        }
    }
    var code: String
    var country: String
    var city: String
    var proto: String
    var port: Int
    var outcome: Outcome
    var avg: Double?
    var loss: Double?
    var seconds: Double
    var date: Date
    /// Ping's standard deviation in ms. nil: not measured (a result saved before FiveT measured it).
    var jitter: Double?
    /// ms until a fresh HTTPS request started answering (`WindscribeCLI.webFailedMs`: it never did). nil: not measured.
    var web: Double?
    /// Mbit/s of a short download through the tunnel (0: nothing came). nil: not measured (speed test off).
    var speed: Double?

    var id: String { Self.key(city, proto, port) }
    static func key(_ city: String, _ proto: String, _ port: Int) -> String { "\(city)|\(proto)|\(port)" }
    var works: Bool { outcome == .works }
    var pingSort: Double { avg ?? .infinity }
    var lossSort: Double { loss ?? 100 }
    var scoreSort: Double { Double(score ?? -1) }
    var speedSort: Double { speed ?? -1 }
    var webSort: Double { web ?? .infinity }

    /// 0 to 100, for a route that works: how good it is to use. Speed counts most, then how fast a web page
    /// starts, then ping, jitter and loss. What the scan did not measure is left out and the rest count more,
    /// so scores of scans with and without the speed test are only roughly comparable.
    var score: Int? {
        guard works, let ping = avg else { return nil }
        return Self.score(ping: ping, loss: loss, jitter: jitter, web: web, speed: speed)
    }

    /// The score of a set of measurements; Smart Connect uses it for whole VPNs. `ping` nil (a tunnel that only
    /// carries apps cannot be pinged): ping and loss are left out like any other measurement that was not made.
    static func score(ping: Double?, loss: Double?, jitter: Double?, web: Double?, speed: Double?) -> Int? {
        /// 1 at `good` or better, 0 at `bad` or worse, a straight line between.
        func part(_ v: Double, good: Double, bad: Double) -> Double { min(1, max(0, (bad - v) / (bad - good))) }
        var parts: [(weight: Double, value: Double)] = []
        if let ping {
            parts.append((15, part(ping, good: 30, bad: 300)))
            parts.append((10, part(loss ?? 0, good: 0, bad: 10)))
        }
        if let jitter { parts.append((10, part(jitter, good: 0, bad: 50))) }
        if let web { parts.append((20, part(web, good: 200, bad: 2000))) }
        // Speed on a log scale, 1 Mbit/s (0) to 100 (1): from 5 to 10 is felt as much as from 50 to 100. On a straight
        // line every slow route got nearly the same score, however different they were to use.
        if let speed { parts.append((45, min(1, max(0, log10(max(speed, 0.01)) / 2)))) }
        let total = parts.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        return Int((parts.reduce(0) { $0 + $1.weight * $1.value } / total * 100).rounded())
    }
    var place: String { "\(city), \(country)" }
    var route: String { port > 0 ? "\(proto):\(port)" : proto }
}

/// What a scan tests and how, saved with the results (AutoScribe's configuration and profile).
struct WindscribeScanSettings: Codable, Equatable {
    /// City names to test; empty means every city (AutoScribe: "ticking nothing means all servers").
    var cities: Set<String> = []
    var protocols: [String] = WindscribeCLI.protocols
    /// The ports to try per protocol: each protocol's first (Windscribe's own default) to begin with.
    var ports: [String: [Int]] = WindscribeCLI.defaultPorts.mapValues { [$0[0]] }
    var pingHost = "1.1.1.1"
    var pingCount = 5
    var timeout = 25
    var settle = 2
    var stopOnFirst = false
    var resume = true
    /// Download for up to 4 s through each route that works, to measure its speed.
    var speedTest = true

    init() {}
    init(protocols: [String], ports: [String: [Int]]) { self.protocols = protocols; self.ports = ports }
    // A file saved before a setting existed keeps the others (and the new one at its default).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cities = try c.decodeIfPresent(Set<String>.self, forKey: .cities) ?? cities
        protocols = try c.decodeIfPresent([String].self, forKey: .protocols) ?? protocols
        ports = try c.decodeIfPresent([String: [Int]].self, forKey: .ports) ?? ports
        pingHost = try c.decodeIfPresent(String.self, forKey: .pingHost) ?? pingHost
        pingCount = try c.decodeIfPresent(Int.self, forKey: .pingCount) ?? pingCount
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? timeout
        settle = try c.decodeIfPresent(Int.self, forKey: .settle) ?? settle
        stopOnFirst = try c.decodeIfPresent(Bool.self, forKey: .stopOnFirst) ?? stopOnFirst
        resume = try c.decodeIfPresent(Bool.self, forKey: .resume) ?? resume
        speedTest = try c.decodeIfPresent(Bool.self, forKey: .speedTest) ?? speedTest
    }
}

/// Windscribe Max and Express Max: the built-in entries of the VPN tab. Each drives the official command line of
/// its service, and AutoScribe's way of finding which locations, protocols and ports work on this network. The class is
/// the same for both; what differs is the `backend`. It lives here for the whole run of the app, so a scan goes on when
/// Settings is closed. (The names say Windscribe because it came first.)
@MainActor
final class WindscribeMax: ObservableObject {
    static let windscribe = WindscribeMax(backend: WindscribeBackend())
    static let express = WindscribeMax(backend: ExpressBackend())
    static let all = [windscribe, express]
    /// The tags of their rows in the VPN tab's list (never saved connections, so they cannot be removed).
    static let rowID = UUID(uuidString: "57D1B5C0-0000-4000-8000-00000000AAA1")!
    static let expressRowID = UUID(uuidString: "57D1B5C0-0000-4000-8000-00000000AAA2")!
    static let rowIDs: Set<UUID> = [rowID, expressRowID]
    /// The service whose row has this tag.
    static func service(for id: UUID?) -> WindscribeMax? { id == rowID ? windscribe : id == expressRowID ? express : nil }

    let backend: MaxBackend
    var rowID: UUID { backend.rowID }

    enum Install { case notInstalled, noCLI, ready }
    struct Notice: Equatable { var text: String; var isError: Bool }
    struct Scan: Equatable {
        var total: Int
        var done = 0
        var worked = 0
        var current = ""
        var step = ""
        var started = Date()
        /// Seconds the tests finished so far took, for the time left.
        var spent = 0.0
        var tested = 0
        var left: TimeInterval? { tested > 0 ? spent / Double(tested) * Double(total - done) : nil }
    }

    @Published private(set) var install: Install = .ready
    /// nil until Windscribe has answered once.
    @Published private(set) var status: WindscribeCLI.Status?
    /// Windscribe has been asked at least once (so "no answer" is a fact, not "not yet").
    @Published private(set) var asked = false
    @Published private(set) var rawStatus = ""
    @Published private(set) var ports: [String: [Int]]
    @Published private(set) var countries: [WindscribeCountry] = []
    @Published private(set) var serversDownloaded = false
    @Published private(set) var updatingServers = false
    @Published private(set) var busy: String?
    /// A Connect is running (it may be trying several routes): Stop can end it.
    @Published private(set) var connectingHere = false
    @Published var notice: Notice?
    @Published private(set) var scan: Scan? {
        didSet {   // the menu bar icon follows a scan starting and ending, not each step of it
            let now = scan != nil
            if now != Self.scanning.contains(rowID) {
                if now { Self.scanning.insert(rowID) } else { Self.scanning.remove(rowID) }
                NotificationCenter.default.post(name: .windscribeScanChanged, object: nil)
            }
        }
    }
    /// The services whose scan is running. A plain set, so the menu bar icon can ask without waking the models.
    static private var scanning = Set<UUID>()
    static var scanActive: Bool { !scanning.isEmpty }
    @Published private(set) var results: [WindscribeResult] = []
    @Published var settings: WindscribeScanSettings { didSet { if settings != oldValue { save() } } }
    /// What Connect uses: `scanned` (the routes that passed a scan, lowest ping first), "best" (Windscribe's own
    /// pick), a country code ("DE"), or a city name; "" protocol is Windscribe's own choice.
    static let scanned = "scanned"
    @Published var target = WindscribeMax.scanned
    @Published var proto = ""
    @Published var port = 0

    private var scanTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var watchGeneration = 0
    /// Windscribe is up because of a click here (or a scan that kept its route): FiveT's own VPNs
    /// then end it, one VPN at a time. A Windscribe someone started in its own app is left alone.
    private var connectedByMax = false
    /// Windscribe's firewall as it was before Windscribe Max connected: a failed or ended connection can
    /// leave it ON (the Mac's internet blocked), so it is put back as it was. nil: leave it alone.
    private var firewallBefore: Bool?
    /// This service's Connect is still making room (it has not touched its own connection yet).
    private var clearing = false

    var scanning: Bool { scan != nil }
    var connected: Bool { status?.isConnected == true }

    private init(backend: MaxBackend) {
        self.backend = backend
        ports = backend.defaultPorts
        settings = WindscribeScanSettings(protocols: backend.defaultProtocols, ports: backend.defaultPorts.mapValues { [$0[0]] })
        if let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: data) {
            profiles = f.networks ?? [:]
            profileKey = f.last
            // A file from before profiles held one scan: it goes to the network the Mac is on once that is known (`adopt`).
            if profiles.isEmpty, f.settings != nil || f.results != nil {
                legacy = Profile(name: "This network", settings: f.settings ?? settings, results: f.results ?? [])
            }
            if let key = profileKey, let p = profiles[key] ?? legacy { load(p) } else if let l = legacy { load(l) }
            // A name given before names were shared by both services lived in this file: it moves to the shared list.
            for (key, p) in profiles where p.custom == true { NetworkIdentity.shared.setName(p.name, for: key, onlyIfNew: true) }
        }
        detect()
        Task { await loadCatalog() }
        // The Wi-Fi changed (home, office…): the other network's results and settings come in.
        NetworkIdentity.shared.$current.compactMap { $0 }.sink { [weak self] in self?.adopt($0) }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    /// The locations: from the service (or the list built into FiveT), once at the start and whenever there are none yet.
    private func loadCatalog() async {
        let loaded = await backend.catalog()
        guard !loaded.countries.isEmpty else { return }
        countries = loaded.countries
        serversDownloaded = loaded.downloaded
        if !settings.cities.isEmpty { settings.cities.formIntersection(countries.flatMap(\.cities)) }   // a city chosen before it was left out
    }

    // MARK: Saved state

    /// What one network keeps: its own scan settings and results.
    struct Profile: Codable {
        var name: String
        var settings: WindscribeScanSettings
        var results: [WindscribeResult]
        var seen = Date()
        /// Only read, to move a name given before names were shared (`NetworkIdentity.names`).
        var custom: Bool?
    }

    private struct File: Codable {
        /// The profiles by network key (see `NetworkIdentity`), and the one in use when FiveT quit.
        var networks: [String: Profile]?
        var last: String?
        /// Before profiles the file held a single scan.
        var settings: WindscribeScanSettings?
        var results: [WindscribeResult]?
        init(networks: [String: Profile], last: String?) { self.networks = networks; self.last = last }
        // Any part may be unreadable (an older or newer FiveT wrote it): the others still count.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            networks = try? c.decode([String: Profile].self, forKey: .networks)
            last = try? c.decode(String.self, forKey: .last)
            settings = try? c.decode(WindscribeScanSettings.self, forKey: .settings)
            results = try? c.decode([WindscribeResult].self, forKey: .results)
        }
    }

    /// The network the panel shows (nil: none known yet), its saved profiles, and a network change waiting for a scan to end.
    @Published private(set) var network: NetworkIdentity.Net?
    @Published private(set) var profiles: [String: Profile] = [:]
    private var profileKey: String?
    private var legacy: Profile?
    private var pendingNet: NetworkIdentity.Net?
    private var loading = false

    private var fileURL: URL { ConnectionStore.shared.directory.appendingPathComponent(backend.fileName) }

    private func save() {
        guard !loading else { return }
        if let key = profileKey {
            var p = profiles[key] ?? Profile(name: network?.name ?? "Network", settings: settings, results: results)
            p.settings = settings
            p.results = results
            p.seen = Date()
            profiles[key] = p
        }
        guard let data = try? JSONEncoder().encode(File(networks: profiles, last: profileKey)) else { return }
        do { try data.write(to: fileURL, options: .atomic) } catch { Log.shared.write("\(backend.title): could not save its results: \(error)", level: .error) }
    }

    /// Puts a profile's settings and results on screen (without saving over the profile just left).
    private func load(_ p: Profile) {
        loading = true
        defer { loading = false }
        results = p.results.filter { !backend.leftOut.contains($0.code) }
        var s = p.settings
        s.protocols = s.protocols.filter { backend.protocols.contains($0) }   // a file of another service's protocols is not ours
        for proto in backend.protocols where s.ports[proto] == nil { s.ports[proto] = [backend.defaultPorts[proto]?.first ?? 0] }
        if !countries.isEmpty { s.cities.formIntersection(countries.flatMap(\.cities)) }
        settings = s
    }

    /// The Mac joined another network: its own profile replaces the one on screen. A new network starts with no
    /// results, and with the settings the last one had. A running scan ends first, so its results land on the network it ran on.
    func adopt(_ net: NetworkIdentity.Net) {
        if net.key == profileKey {
            network = net
            if !net.ssid.isEmpty, profiles[net.key]?.name != net.ssid { profiles[net.key]?.name = net.ssid; save() }
            return
        }
        if scanning {
            pendingNet = net
            stopScan()
            return
        }
        pendingNet = nil
        let inherited = settings
        profileKey = net.key
        network = net
        if profiles[net.key] == nil, var l = legacy { l.name = net.name; profiles[net.key] = l; legacy = nil }   // the scan from before profiles
        if profiles[net.key] == nil { profiles[net.key] = Profile(name: net.name, settings: inherited, results: []) }
        if !net.ssid.isEmpty { profiles[net.key]?.name = net.ssid }
        if let p = profiles[net.key] { load(p) }
        save()
        Log.shared.write("\(backend.title): network changed, \(results.count) saved results for the new one")
    }

    /// The name of the network on screen: the one the person gave it (shared by both services), else its Wi-Fi name once it was ever seen.
    var networkName: String? { profileKey.map { displayName($0) } ?? network?.name }
    func displayName(_ key: String) -> String { NetworkIdentity.shared.names[key] ?? profiles[key]?.name ?? network?.name ?? "Network" }
    /// The saved networks other than this one, most recently used first.
    var otherNetworks: [(key: String, profile: Profile)] {
        profiles.filter { $0.key != profileKey }.map { (key: $0.key, profile: $0.value) }.sorted { $0.profile.seen > $1.profile.seen }
    }

    /// The person names the network on screen ("Home", "Office"): macOS often hides the Wi-Fi name. Empty: back to the automatic name.
    func renameNetwork(_ name: String) {
        guard let key = profileKey, profiles[key] != nil else { return }
        NetworkIdentity.shared.setName(name, for: key)
    }

    func clearResults() { results = []; save() }
    /// Forgets another network in every service (its results, settings and name): a network is the same network in Windscribe Max and Express Max.
    func forgetNetwork(_ key: String) {
        guard key != profileKey else { return }
        for m in WindscribeMax.all where m.profileKey != key { m.profiles[key] = nil; m.save() }
        NetworkIdentity.shared.setName("", for: key)
    }

    // MARK: Looking at Windscribe

    /// Is the app (and its command line) on this Mac?
    func detect() {
        let now = backend.installState()
        if now != install { install = now }
        if now != .ready, status != nil { status = nil }
    }

    /// Asks Windscribe for its state, and for the ports of each protocol the first time.
    func refresh() async {
        detect()
        guard install == .ready else { return }
        let (s, text) = await backend.status()
        if backend.isBusyAnswer(text) { return }   // our own connect or scan is using the command line: no news, not "no answer"
        // Windscribe misses an answer now and then while it connects or disconnects: only a third miss in a
        // row (about 12 s) takes the state away, so the panel does not flash "not answering".
        if s.known { misses = 0; status = s } else { misses += 1; if misses >= 3 { status = nil } }
        rawStatus = text
        asked = true
        if status?.isConnected != true { connectedByMax = false }
        if s.known && s.isLoggedIn && countries.isEmpty { await loadCatalog() }
        guard s.known, s.isLoggedIn, !portsRead else { return }
        portsRead = true
        if let found = await backend.readPorts() { ports = found }
    }
    private var portsRead = false
    private var misses = 0

    /// Keeps the state fresh while the VPN tab is in front: every few seconds, and not at all otherwise.
    func watch() async {
        // A newer watch (the tab was left and came back) replaces this one.
        watchGeneration += 1
        let mine = watchGeneration
        while !Task.isCancelled && mine == watchGeneration {
            // A scan asks Windscribe for its state itself, once a second, and a connect holds the command line for up
            // to a minute: a second asker only makes it miss answers, or makes the command itself fail.
            if SettingsRouter.shared.tab == .openvpn && !scanning && busy == nil { await refresh() } else { detect() }
            try? await Task.sleep(nanoseconds: install == .ready ? 4_000_000_000 : 2_000_000_000)
        }
    }

    func openApp() { backend.openApp() }

    // MARK: Server list

    func updateServers() {
        guard !updatingServers else { return }
        updatingServers = true
        Task {
            defer { updatingServers = false }
            do {
                let list = try await backend.downloadCatalog()
                let before = Set(countries.flatMap(\.cities)), after = Set(list.flatMap(\.cities))
                countries = list
                serversDownloaded = true
                settings.cities.formIntersection(after)
                notice = Notice(text: "Server list updated: \(after.subtracting(before).count) new, \(before.subtracting(after).count) gone.", isError: false)
            } catch {
                notice = Notice(text: "Could not download the server list (\(error.localizedDescription)). The list FiveT has stays in use.", isError: true)
            }
        }
    }

    /// What Connect is given for a whole group: its country code, or its own name ("US West") when other groups share the code.
    func target(of group: WindscribeCountry) -> String {
        group.code.isEmpty || countries.filter { $0.code == group.code }.count > 1 ? group.name : group.code
    }

    func country(of city: String) -> WindscribeCountry? { countries.first { $0.cities.contains(city) } }

    /// What `target` means in words.
    func targetLabel(_ t: String) -> String {
        if t == Self.scanned {
            let cities = Set(best.map(\.city)).count
            return cities == 0 ? "Scanned locations (none yet)" : "Scanned locations (\(cities))"
        }
        if t == "best" { return "Best location" }
        if let c = countries.first(where: { $0.code == t || $0.name == t }) { return "\(c.name) (any city)" }
        if let c = country(of: t) { return "\(t), \(c.name)" }
        return t
    }

    // MARK: Control

    private func tell(_ text: String, error: Bool = false) { notice = Notice(text: text, isError: error) }

    /// Lets go of FiveT's own VPNs first, and of the other built-in service: one VPN at a time.
    private func clearTheWay() async {
        clearing = true
        defer { clearing = false }
        var stopped = VPNManager.shared.stopOtherVPNs()
        for other in Self.all where other !== self { if await other.stepAside() { stopped.append(other.backend.name) } }
        if !stopped.isEmpty {
            tell("Disconnected \(stopped.joined(separator: ", ")) first: one VPN at a time.")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    /// The other built-in service is about to connect: this one ends its scan and its connection (true when it had either).
    func stepAside() async -> Bool {
        let had = scanning || connected || connectTask != nil
        if scanning { stopScan() }
        connectTask?.cancel()
        // Wait until the scan or the connect has really ended and taken its connection down: returning at once let the
        // other service start while this one was still connecting or disconnecting. Not while this one is itself only
        // waiting for the other to step aside (both clicked at once): each would wait for the other for ever.
        if !clearing {
            await scanTask?.value
            await connectTask?.value
        }
        if connected { await letGo(); Log.shared.write("\(backend.title): disconnected, another built-in VPN is starting (one VPN at a time)") }
        return had
    }

    /// Connects to `target` over `proto` and `port`, waiting for the answer. "Scanned locations" tries
    /// the routes that passed the scan one after the other, best score first, until one comes up.
    func connect() {
        guard busy == nil, !scanning else { return }
        var list = [(place: target, proto: proto, port: port)]
        notice = nil
        if target == Self.scanned {
            list = best.map { (place: $0.city, proto: $0.proto, port: $0.port) }
            if list.isEmpty {
                list = [(place: "best", proto: "", port: 0)]
                tell("Nothing has been scanned yet, so \(backend.name) picks its best location. Run a scan to find the locations that work on this network.")
            }
        }
        let routes = list
        busy = "Connecting…"
        connectingHere = true
        connectTask = Task {
            defer { busy = nil; connectingHere = false; connectTask = nil }
            await clearTheWay()
            // Never asked yet (a click in the menu right after launch): ask now, or the firewall a failed attempt
            // leaves on could not be put back, and the Mac would stay without internet.
            if status == nil { await refresh() }
            if firewallBefore == nil { firewallBefore = status?.firewallOn }
            var why = ""
            for (i, r) in routes.enumerated() {
                if Task.isCancelled { break }
                busy = routes.count > 1 ? "Trying \(r.place) · \(backend.hasPorts ? "\(r.proto):\(r.port)" : backend.protocolName(r.proto)) (\(i + 1) of \(routes.count))…" : "Connecting to \(targetLabel(r.place))…"
                if status?.isConnected == true || status?.isConnecting == true {
                    await backend.disconnect()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                let what = [r.place, r.proto.isEmpty ? "" : r.port > 0 ? "\(r.proto):\(r.port)" : r.proto].filter { !$0.isEmpty }.joined(separator: " ")
                // A scanned route came up within the scan's timeout, so a longer wait only delays the next one.
                let wait = routes.count > 1 ? Double(settings.timeout) + 15 : 70
                let out = await backend.connect(place: r.place, proto: r.proto, port: r.port, wait: true, timeout: wait)
                if Task.isCancelled { break }
                await refresh()
                if status?.isConnected == true {
                    connectedByMax = true
                    Log.shared.write("\(backend.title): connected (\(what))")
                    return
                }
                why = out.timedOut ? "\(backend.name) did not answer in time." : out.lines.last ?? "\(backend.name) did not connect."
                Log.shared.write("\(backend.title): \(what) did not connect: \(why)")
                if i < routes.count - 1 {   // Windscribe leaves its firewall on after an attempt, as in a scan
                    await backend.disconnect()
                    await backend.firewall(on: false)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            if Task.isCancelled {
                await letGoAfterCancel()
                tell("Stopped. \(backend.name) is not connected.")
            } else {
                await letGo()
                let failure = routes.count > 1 ? "None of the \(routes.count) scanned routes came up (last answer: \(why)). The network may have changed: scan again."
                                               : why + (backend.hasPorts ? " Try another protocol or port." : " Try another location or protocol.")
                tell(failure, error: true)
                VPNManager.shared.report("\(backend.name): " + failure)   // also in the menu, for a click there
            }
        }
    }

    /// Ends a Connect that is still trying routes.
    func stopConnect() { connectTask?.cancel() }

    /// Connect, the way the panel does it with its chosen place and protocol, and return when it is up (true) or has
    /// failed or been stopped (false). Smart Connect uses it.
    func connectAndWait() async -> Bool {
        connect()
        await connectTask?.value
        return connected
    }

    /// `letGo` for a cancelled task: its own commands would be cut short, so they run detached.
    private func letGoAfterCancel() async {
        let restoreFirewall = firewallBefore == false
        await Task.detached { @MainActor [backend] in
            await backend.disconnect()
            if restoreFirewall { await backend.firewall(on: false) }
        }.value
        await Task.detached { @MainActor [backend] in await backend.idle() }.value   // detached: this task may be the cancelled one
        connectedByMax = false
        firewallBefore = nil
        Task { await refresh() }   // an unstructured task: this one is cancelled and would get no answer
    }

    /// Ends Windscribe's connection (or attempt) and puts its firewall back as it was.
    private func letGo() async {
        await backend.disconnect()
        connectedByMax = false
        if firewallBefore == false { await backend.firewall(on: false) }
        firewallBefore = nil
        await Task.detached { @MainActor [backend] in await backend.idle() }.value   // detached: this task may be the cancelled one
        await refresh()
    }

    func disconnect() {
        guard busy == nil else { return }
        busy = "Disconnecting…"
        notice = nil
        Task {
            defer { busy = nil }
            if scanning { stopScan() }
            await letGo()
            if status?.isConnected == true { tell("\(backend.name) is still connected.", error: true) }
        }
    }

    /// Connects to a tested route (a click in Results).
    func connect(_ r: WindscribeResult) {
        target = r.city; proto = r.proto; port = r.port
        connect()
    }

    /// A FiveT VPN is starting: Windscribe (if FiveT started it) and any scan make way.
    func yieldToFiveT() {
        if scanning { stopScan() }
        connectTask?.cancel()
        guard connectedByMax else { return }
        Task {
            await letGo()
            Log.shared.write("\(backend.title): disconnected \(backend.name), a FiveT VPN is starting (one VPN at a time)")
        }
    }

    // MARK: Scan (AutoScribe's way)

    struct Step: Equatable { var country: WindscribeCountry; var city: String; var proto: String; var port: Int }

    /// Cities, then protocols, then ports: the order AutoScribe tests in.
    var plan: [Step] {
        let wanted = settings.cities
        var out: [Step] = []
        for c in countries {
            for city in c.cities where wanted.isEmpty || wanted.contains(city) {
                for p in backend.protocols where settings.protocols.contains(p) {
                    for port in settings.ports[p] ?? [] { out.append(Step(country: c, city: city, proto: p, port: port)) }
                }
            }
        }
        return out
    }

    /// Steps still to do, and about how long they take.
    var planned: (steps: Int, seconds: TimeInterval) {
        let all = plan
        let have = Set(results.map(\.id))
        let todo = settings.resume ? all.filter { !have.contains(WindscribeResult.key($0.city, $0.proto, $0.port)) } : all
        let known = results.filter { $0.outcome != .unavailable }
        let each = known.isEmpty ? 22 : known.map(\.seconds).reduce(0, +) / Double(known.count)
        return (todo.count, each * Double(todo.count))
    }

    func startScan() {
        guard !scanning, busy == nil else { return }
        let steps = plan
        guard !steps.isEmpty else { return }
        let cfg = settings
        scan = Scan(total: steps.count, step: "Starting…")
        notice = nil
        scanTask = Task { await run(steps, cfg) }
    }

    func stopScan() {
        guard scanning else { return }
        scan?.step = "Stopping…"
        scanTask?.cancel()
    }

    /// Ends a scan before FiveT quits, so the service is not left on a test route. A connection the
    /// user made stays: it is the service's own tunnel, not one FiveT runs.
    func stopForQuit() {
        guard scanning else { return }
        scanTask?.cancel()
        backend.disconnectSync()
    }

    private func step(_ text: String) { scan?.step = text }
    /// Why the scan ended by itself, when it did.
    private var scanProblem: String?

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private func run(_ steps: [Step], _ cfg: WindscribeScanSettings) async {
        // The firewall as the person had it, to put it back at the end. Windscribe misses an answer now and then: a
        // missed one must not read as "off", or the scan would end by switching their firewall off.
        var before = (await backend.poll()).status
        for _ in 0..<3 where !before.known { await pause(1); before = (await backend.poll()).status }
        let firewallWasOn = before.known ? before.firewallOn : status?.firewallOn ?? false
        step("Making room")
        var stopped = VPNManager.shared.stopOtherVPNs(withForti: true)   // the scan tests the bare network
        clearing = true   // two scans started at once must not each wait for the other to step aside
        for other in Self.all where other !== self { if await other.stepAside() { stopped.append(other.backend.name) } }
        clearing = false
        if !stopped.isEmpty {
            Log.shared.write("\(backend.title): scan started, disconnected \(stopped.joined(separator: ", "))")
            // The scan begins once they are really down (a Forti tunnel takes a few seconds), not after a guess.
            var waited = 0.0
            while waited < 15, VPNManager.shared.sessions.contains(where: { $0.connectionID != nil }) { await pause(0.5); waited += 0.5 }
            await pause(1)
        }
        Log.shared.write("\(backend.title): scan of \(steps.count) routes started")
        scanProblem = nil
        var kept = false
        var have = Set(results.map(\.id))
        for s in steps {
            if Task.isCancelled { break }
            if cfg.resume, have.contains(WindscribeResult.key(s.city, s.proto, s.port)) {
                scan?.done += 1
                continue
            }
            scan?.current = "\(s.city), \(s.country.name) · \(backend.hasPorts ? "\(s.proto):\(s.port)" : backend.protocolName(s.proto))"
            guard let r = await test(s, cfg) else { break }   // nil: stopped in the middle of a test
            record(r)
            have.insert(r.id)
            scan?.done += 1
            if r.outcome != .unavailable { scan?.spent += r.seconds; scan?.tested += 1 }
            if r.works {
                scan?.worked += 1
                if cfg.stopOnFirst { kept = true; break }
            }
            step("Disconnecting")
            await backend.disconnect()
            await backend.firewall(on: false)   // Windscribe leaves it on after an attempt
            await pause(2)
        }
        let finished = scan
        // Detached: Stop cancelled this task, and a cancelled one would not get these commands through.
        if kept {
            firewallBefore = firewallWasOn
        } else {
            await Task.detached { @MainActor [backend] in await backend.disconnect() }.value
            await Task.detached { @MainActor [backend] in await backend.firewall(on: firewallWasOn) }.value
            await Task.detached { @MainActor [backend] in await backend.idle() }.value   // detached: this task may be the cancelled one
        }
        connectedByMax = kept
        scan = nil
        scanTask = nil
        let moved = pendingNet
        if let moved { adopt(moved) }   // the Wi-Fi changed during the scan: its results are saved, now the new network's come in
        await refresh()
        let cancelled = steps.count != (finished?.done ?? 0) && !kept
        if kept {
            tell("Found a route that works and stayed connected: \(finished?.current ?? "").")
        } else if let problem = scanProblem {
            tell(problem, error: true)
        } else if moved != nil {
            tell("The Wi-Fi changed, so the scan stopped after \(finished?.done ?? 0) of \(steps.count). Its \(finished?.worked ?? 0) working routes stay with the old network.")
        } else if cancelled {
            tell("Scan stopped after \(finished?.done ?? 0) of \(steps.count). \(finished?.worked ?? 0) routes worked.")
        } else {
            tell("Scan finished: \(finished?.worked ?? 0) of \(steps.count) routes work on this network.")
        }
        Log.shared.write("\(backend.title): scan ended after \(finished?.done ?? 0) of \(steps.count) routes, \(finished?.worked ?? 0) worked")
    }

    func record(_ r: WindscribeResult) {
        results.removeAll { $0.id == r.id }
        results.append(r)
        save()
    }

    /// One route: disconnect, connect, wait for it to come up, let it settle, ping through it.
    /// nil when Stop ended it before there was an answer.
    private func test(_ s: Step, _ cfg: WindscribeScanSettings) async -> WindscribeResult? {
        let begin = Date()
        func result(_ o: WindscribeResult.Outcome, _ ping: WindscribeCLI.Ping? = nil, web: Double? = nil, speed: Double? = nil) -> WindscribeResult {
            WindscribeResult(code: s.country.code, country: s.country.name, city: s.city, proto: s.proto, port: s.port, outcome: o,
                             avg: ping?.avg, loss: ping?.loss, seconds: Date().timeIntervalSince(begin), date: Date(),
                             jitter: ping?.stddev, web: web, speed: speed)
        }
        step("Disconnecting")
        for _ in 0..<5 {
            let now = (await backend.poll()).status
            if now.firewallOn { await backend.firewall(on: false) }
            if !now.isConnected && !now.isConnecting { break }
            await backend.disconnect()
            await pause(1.5)
        }
        if Task.isCancelled { return nil }
        step("Connecting")
        let started = Date()
        let out = await backend.connect(place: s.city, proto: s.proto, port: s.port, wait: false, timeout: Double(cfg.timeout) + 15)
        if Task.isCancelled { return nil }
        if backend.refusesLocation(out.text) { return result(.unavailable) }
        // The command itself could not run: the scan stops here. Going on would file every route as "Failed",
        // and the next scan would skip them all as already tested.
        if backend.couldNotRun(out) {
            scanProblem = "The scan stopped: \(backend.name) could not be started (\(out.lines.last ?? "no answer")). Open the \(backend.name) app, then scan again; the routes tested so far are kept."
            return nil
        }
        if out.status != 0 && !out.timedOut && !backend.hasPorts { return result(.failed) }   // a command line that says no at once
        await pause(1)
        var sawConnecting = false, idle = 0
        while Date().timeIntervalSince(started) < Double(cfg.timeout) {
            if Task.isCancelled { return nil }
            let (now, text) = await backend.poll()
            Log.shared.write("\(backend.title): \(s.city) \(s.proto):\(s.port) status: \(now.connect.isEmpty ? "no answer: " + text : now.connect)", level: .debug)
            if backend.refusesLocation(text) { return result(.unavailable) }
            if now.isError { return result(.failed) }   // Windscribe 2.25+ says so as soon as the attempt fails
            if now.isConnected { break }
            if now.isConnecting { sawConnecting = true; idle = 0 } else { idle += 1 }
            // It gave up by itself: back to Disconnected after trying (or never started to try).
            if idle >= (sawConnecting ? 6 : 10) { return result(.failed) }
            await pause(1)
        }
        let up = (await backend.poll()).status.isConnected
        if Task.isCancelled { return nil }
        guard up else { return result(.failed) }
        if cfg.settle > 0 { step("Settling"); await pause(Double(cfg.settle)) }
        if Task.isCancelled { return nil }
        // An empty field means the usual address; a host that starts with "-" would be read by ping as an option.
        let typed = cfg.pingHost.trimmingCharacters(in: .whitespaces)
        let host = typed.isEmpty || typed.hasPrefix("-") ? "1.1.1.1" : typed
        step("Pinging \(host)")
        let ping = await WindscribeCLI.ping(host: host, count: cfg.pingCount)
        if Task.isCancelled { return nil }
        guard ping.answered else { return result(.noTraffic, ping) }
        // It works: how good is it? A web page's first byte, then (if wanted) a short download.
        step("Timing a web page")
        let web = await WindscribeCLI.webResponse()
        if Task.isCancelled { return nil }
        var speed: Double?
        if cfg.speedTest {
            step("Measuring download speed")
            speed = await WindscribeCLI.downloadSpeed()
            if Task.isCancelled { return nil }
        }
        return result(.works, ping, web: web, speed: speed)
    }

    // MARK: Results

    /// Working routes, best score first; the same score: ping, then loss, then how long it took to come up.
    var best: [WindscribeResult] {
        results.filter { $0.score != nil }.sorted { a, b in
            if a.score != b.score { return (a.score ?? 0) > (b.score ?? 0) }
            return (a.pingSort, a.lossSort, a.seconds) < (b.pingSort, b.lossSort, b.seconds)
        }
    }

    /// Per protocol: (worked, tested). A protocol that fails nearly everywhere is worth leaving out.
    var protocolStats: [(proto: String, ok: Int, total: Int)] {
        backend.protocols.compactMap { p in
            let rs = results.filter { $0.proto == p && $0.outcome != .unavailable }
            return rs.isEmpty ? nil : (p, rs.filter(\.works).count, rs.count)
        }
    }
}
