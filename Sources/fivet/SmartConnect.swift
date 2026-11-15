import Foundation
import Combine
import CryptoKit

/// Smart Connect: tries every VPN the person left switched on (My VPNs and the built-in services), one after the
/// other, each the way it is set to connect (a saved connection as it is; a built-in service with the place and
/// protocol of its panel). Through each tunnel that comes up it times a web page and a download, scores it like the
/// scans of Windscribe do, and leaves the best one connected. Forti is not part of it: that is the company's network.
@MainActor
final class SmartConnect: ObservableObject {
    static let shared = SmartConnect()
    /// The tag of its row in the VPN tab's list (never a saved connection).
    static let rowID = UUID(uuidString: "57D1B5C0-0000-4000-8000-00000000AAA3")!

    /// One VPN in the list: a saved connection or a built-in service, by the id the rest of the app knows it by.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let builtIn: Bool
        /// Why it cannot take part ("Not installed"); nil when it can.
        let unavailable: String?
    }

    /// What one VPN did in the last run.
    struct Measure: Equatable, Codable {
        var score: Int?
        /// Mbit/s of the download.
        var speed: Double?
        /// ms until a web page began to answer.
        var web: Double?
        var failure: String?
        /// Where the score comes from when it was not measured just now ("From its scan").
        var note: String?
    }

    @Published private(set) var running = false
    @Published private(set) var step = ""
    /// The VPN being tried now.
    @Published private(set) var testing: UUID?
    @Published private(set) var results: [UUID: Measure] = [:]
    @Published private(set) var winner: UUID?
    /// The outcome of the last run, or why one did not start.
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    /// The VPN the notice says is connected; the header stops saying so once it is down (disconnected by hand).
    @Published private(set) var noticeConnection: UUID?

    private var task: Task<Void, Never>?
    /// This run has started connecting something: from then on the VPN from before may be down, or going down.
    private var changed = false
    /// The kill switch was already blocking the internet when this run began: it still does when the run finds nothing.
    private var blockedAtStart = false
    /// The side Xrays of the background checks that run now (Smart Connect's, and a subscription's Quality tests).
    private var probing: Set<Process> = []

    /// FiveT quits: a side Xray must not be left running behind it.
    func stopForQuit() { probing.forEach { $0.terminate() } }
    private var store: ConnectionStore { .shared }
    private var vpn: VPNManager { .shared }

    // MARK: The list

    /// My VPNs (OpenVPN, V2Ray, Outline), then the built-in services.
    var entries: [Entry] {
        let saved = store.connections.filter(\.isOtherVPN).map { Entry(id: $0.id, name: $0.name, builtIn: false, unavailable: nil) }
        let built = WindscribeMax.all.map { m -> Entry in
            let why: String?
            switch m.backend.installState() {
            case .notInstalled: why = "Not installed"
            case .noCLI: why = "Needs its command line"
            case .ready: why = m.status?.isLoggedIn == false ? "Signed out" : nil
            }
            return Entry(id: m.rowID, name: m.backend.title, builtIn: true, unavailable: why)
        }
        return saved + built
    }

    func isOn(_ e: Entry) -> Bool { e.unavailable == nil && !store.smartOff.contains(e.id) }

    func setOn(_ on: Bool, _ e: Entry) {
        if on { store.smartOff.remove(e.id) } else { store.smartOff.insert(e.id) }
        objectWillChange.send()
    }

    // MARK: Running

    /// Starts a run (after the helper is set up, on a Mac that is not yet).
    func start() {
        guard !running else { return }
        guard !WindscribeMax.scanActive else { return tell("A scan of Windscribe or Express is running. Stop it first.", error: true) }
        guard entries.contains(where: isOn) else { return tell("Switch on at least one VPN.", error: true) }
        SetupFlow.shared.whenReady({ [weak self] in self?.begin() },
                                   failed: { [weak self] in self?.tell("FiveT is not set up yet. Open Settings → General.", error: true) })
    }

    func stop() {
        guard running else { return }
        step = "Stopping…"
        task?.cancel()
    }

    /// Asks the built-in services for their state now. What FiveT last heard may be old: they are only asked
    /// while their panel is in front, and their own apps connect and disconnect them too.
    private func refreshBuiltIn() async {
        for m in WindscribeMax.all { await m.refresh() }
    }

    private func begin() {
        guard !running, entries.contains(where: isOn) else { return }
        running = true
        results = [:]
        winner = nil
        notice = nil
        noticeConnection = nil
        changed = false
        blockedAtStart = vpn.killSwitchActive
        task = Task {
            await self.refreshBuiltIn()
            let list = self.entries.filter(self.isOn)
            let before = self.upNow()
            let outcome = await self.run(list)
            let cancelled = Task.isCancelled
            // A cancelled task's own commands are cut short, so putting things back runs in a task of its own.
            await Task { @MainActor in
                switch outcome {
                case .connected(let name, let m):
                    self.tell("Connected to \(name)" + (m.score.map { ": score \($0)" } ?? "") + (m.speed.map { String(format: " · %.0f Mbit/s", $0) } ?? "") + ".", connection: self.winner)
                case .kept(let name):
                    self.tell("\(name) is already the best one. Nothing changed.", connection: self.winner)
                case .untouched:
                    self.tell("Stopped. Nothing changed.")
                case .nothing:
                    await self.putBack(before)
                    // Said only when it is true: the VPN from before may not have come back up.
                    let back = before.map { self.isUp($0) ? " Back to \($0.name)." : " \($0.name) did not come back up either." } ?? ""
                    // Said too: a block that stays (see putBack) is why nothing loads, and the menu's Unblock Internet ends it.
                    let blocked = self.vpn.killSwitchActive ? " The kill switch is blocking the internet." : ""
                    let none = list.isEmpty ? "Switch on at least one VPN." : "None of the \(list.count) VPNs could be connected."
                    self.tell((cancelled ? "Stopped." : none) + back + blocked, error: !cancelled)
                }
            }.value
            self.running = false
            self.testing = nil
            self.step = ""
            self.task = nil
        }
    }

    /// `untouched`: stopped during the check, before anything was connected or disconnected.
    private enum Outcome { case connected(String, Measure), kept(String), untouched, nothing }

    /// First the check, in the background: every VPN gets a score while the Mac's connection stays as it is. Only
    /// then the one change: the best VPN is connected (the next best if it does not come up, and so on).
    private func run(_ list: [Entry]) async -> Outcome {
        for (i, e) in list.enumerated() {
            if Task.isCancelled { return .untouched }
            step = "Checking \(e.name) (\(i + 1) of \(list.count))…"
            testing = e.id
            results[e.id] = await check(e)
        }
        testing = nil
        if Task.isCancelled { return .untouched }
        // Best score first; then the ones nothing is known about yet, in the list's order. A VPN whose check failed is out.
        var order: [Entry] = []
        var scored = results.filter { $0.value.failure == nil }.map { (id: $0.key, score: $0.value.score, speed: $0.value.speed, web: $0.value.web) }
        while let best = Self.pick(scored), let e = list.first(where: { $0.id == best }) {
            order.append(e)
            scored.removeAll { $0.id == best }
        }
        order += list.filter { e in results[e.id]?.failure == nil && !order.contains(e) }
        await refreshBuiltIn()   // the check took a while: "already the best" must be true now
        for e in order {
            if Task.isCancelled { return .nothing }
            winner = e.id
            if isUp(e) { return .kept(e.name) }
            step = "Connecting to \(e.name)…"
            changed = true
            var (ok, failure) = await connect(e)
            // Up is not enough: a tunnel that carries no web page is a no, and the next one gets its turn. It is
            // left as it is: the next connect switches away from it (blocked in between, with the kill switch on).
            if ok, !Task.isCancelled {
                step = "Checking \(e.name)…"
                if splitOnly(e.id) { (ok, failure) = (false, "Carries only its own network, not the internet") }
                else if !(await carries(e)) { (ok, failure) = (false, "Connected, but no traffic comes through") }
            }
            if Task.isCancelled { return .nothing }
            if ok {
                Task { await self.learn(e) }   // its score as it is now, for the next time (an old one may be of another day)
                return .connected(e.name, results[e.id] ?? Measure())
            }
            results[e.id] = Measure(failure: failure ?? "Did not connect")
        }
        winner = nil
        return .nothing
    }

    /// The best score; the same score: the faster download, then the quicker web page. nil: no VPN has a score.
    nonisolated static func pick(_ all: [(id: UUID, score: Int?, speed: Double?, web: Double?)]) -> UUID? {
        all.filter { $0.score != nil }.min { a, b in
            if a.score != b.score { return a.score! > b.score! }
            if (a.speed ?? 0) != (b.speed ?? 0) { return (a.speed ?? 0) > (b.speed ?? 0) }
            return (a.web ?? .infinity) < (b.web ?? .infinity)
        }?.id
    }

    // MARK: One VPN, checked in the background

    /// A score for `e` without changing the Mac's connection:
    /// - the VPN that is up now: measured through its tunnel;
    /// - V2Ray and Outline: a second Xray, a local proxy only, straight to the server over the Wi-Fi or Ethernet;
    /// - Windscribe and Express: the best route of their last scan on this network;
    /// - OpenVPN: what Smart Connect measured the last time it was up on this network (it cannot be tried without its tunnel).
    private func check(_ e: Entry) async -> Measure {
        let k = key(e)   // now: a measurement belongs to the network it began on
        if isUp(e), e.builtIn || vpn.appProxyPort(for: e.id) == nil {
            // Its traffic to the internet does not go through it: the measurement would be of the bare network.
            if splitOnly(e.id) { return Measure(failure: "Carries only its own network, not the internet") }
            let m = await measure(socksPort: nil)
            if !e.builtIn { remember(m, for: e, key: k) }
            return m
        }
        if e.builtIn {
            guard let s = WindscribeMax.service(for: e.id) else { return Measure(failure: "Not found") }
            // The score of the route Connect will take: the best scanned one, or the place and protocol chosen in its panel.
            let chosen = s.target == WindscribeMax.scanned ? s.best.first
                : s.best.first { $0.city == s.target && (s.proto.isEmpty || ($0.proto == s.proto && (s.port == 0 || $0.port == s.port))) }
            guard let r = chosen else { return Measure(note: s.target == WindscribeMax.scanned ? "Not scanned yet" : "Its chosen place was not scanned") }
            // The same formula as the others (web page and speed, no ping), when the scan measured them.
            let score = r.web == nil && r.speed == nil ? r.score : WindscribeResult.score(ping: nil, loss: nil, jitter: nil, web: r.web, speed: r.speed)
            return Measure(score: score, speed: r.speed, web: r.web, note: "From its scan")
        }
        guard let c = store.connection(id: e.id) else { return Measure(failure: "Not found") }
        guard c.isV2Ray else { return remembered[k] ?? Measure(note: "Not tested yet") }
        // The block lets only the VPN from before through: a good server would look dead. It is tried by connecting.
        if vpn.killSwitchActive { return Measure(note: "Not tested: the kill switch is blocking") }
        let m = await probe(c)
        remember(m, for: e, key: k)
        return m
    }

    /// The check alone, for `--check-windscribe smart`: every VPN that is on, nothing connected.
    func checkAll() async -> [(name: String, result: Measure)] {
        var out: [(String, Measure)] = []
        for e in entries.filter(isOn) { out.append((e.name, await check(e))) }
        return out
    }

    /// Times a web page, then a download, through the Mac's route or a local proxy.
    private func measure(socksPort: Int?) async -> Measure {
        let web = await WindscribeCLI.webResponse(socksPort: socksPort)
        if web >= WindscribeCLI.webFailedMs { return Measure(failure: "No traffic comes through") }   // no page: no need to wait for a download
        if Task.isCancelled { return Measure() }
        let speed = await WindscribeCLI.downloadSpeed(socksPort: socksPort)
        // Ping is left out: some tunnels (V2Ray, Outline) do not carry it, and one formula has to fit them all.
        return Measure(score: WindscribeResult.score(ping: nil, loss: nil, jitter: nil, web: web, speed: speed), speed: speed, web: web)
    }

    /// A V2Ray or Outline server measured through a side Xray (a local proxy only). Also the Quality test of a
    /// subscription's servers in Settings.
    func probe(_ c: Connection) async -> Measure {
        let port = V2RayConfig.freePort()
        guard let config = try? V2RayConfig.forProbe(c, port: port, interface: NetworkIdentity.physicalInterface()) else {
            return Measure(failure: "Its server settings are missing")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Setup.bundledXrayPath)
        p.arguments = ["run", "-c", "stdin:"]
        p.environment = ["PATH": "/usr/bin:/bin", "XRAY_LOCATION_ASSET": (Setup.bundledXrayGeoPath as NSString).deletingLastPathComponent]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Measure(failure: "Xray could not start") }
        probing.insert(p)
        defer { p.terminate(); probing.remove(p) }
        // An Xray that ended at once must not take FiveT down with it (SIGPIPE, or an exception from the write).
        let w = input.fileHandleForWriting
        _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? w.write(contentsOf: Data(config.utf8))
        try? w.close()
        // Xray needs a moment to listen; the proxy has to be this Xray, not another program on the port.
        var listening = false
        for _ in 0..<20 where !listening && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let pid = p.processIdentifier
            listening = await Task.detached { VPNManager.listenerPID(port: port) == pid }.value
        }
        guard listening else { return Measure(failure: "Xray did not start") }
        var m = await measure(socksPort: port)
        // One more try before a server is written off: a single missed page would take a good VPN out of the choice.
        if m.failure != nil, !Task.isCancelled { m = await measure(socksPort: port) }
        Log.shared.write("Smart Connect: \(c.name) checked in the background: " + (m.failure ?? "score \(m.score ?? 0), web \(Int(m.web ?? 0)) ms, \(String(format: "%.1f", m.speed ?? 0)) Mbit/s"))
        return m.failure == nil ? m : Measure(failure: "Its server does not answer")
    }

    /// Measures a VPN that Smart Connect has just connected without a score, so the next run knows it.
    private func learn(_ e: Entry) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // a fresh tunnel is slow for a moment
        guard isUp(e), e.builtIn || vpn.appProxyPort(for: e.id) == nil, !splitOnly(e.id) else { return }
        let k = key(e)
        let m = await measure(socksPort: nil)
        guard m.failure == nil, isUp(e) else { return }
        if !running { results[e.id] = m }   // a new run has its own results
        if !e.builtIn { remember(m, for: e, key: k) }
    }

    /// Does a web page come through the VPN that has just come up? Twice: a fresh tunnel is slow for a moment.
    private func carries(_ e: Entry) async -> Bool {
        for i in 0..<2 {
            if i > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            if Task.isCancelled { return false }
            if await WindscribeCLI.webResponse(socksPort: vpn.appProxyPort(for: e.id)) < WindscribeCLI.webFailedMs { return true }
        }
        return false
    }

    /// An OpenVPN that is up and carries only its own network: nothing measured over the internet says anything about it.
    private func splitOnly(_ id: UUID) -> Bool {
        guard store.connection(id: id)?.isOpenVPN == true, let n = vpn.status(for: id)?.network else { return false }
        return !n.fullTunnel
    }

    // MARK: What was measured before

    /// The last measurement of each saved VPN on each network ("network key|VPN id"), kept in FiveT's folder.
    private lazy var remembered: [String: Measure] = (try? JSONDecoder().decode([String: Measure].self, from: Data(contentsOf: rememberedURL))) ?? [:]
    private var rememberedURL: URL { store.directory.appendingPathComponent("smart-connect.json") }
    /// An OpenVPN's key ends in a mark of its profile: an edited profile is another server, and the old score is not its.
    private func key(_ e: Entry) -> String {
        let profile = store.connection(id: e.id)?.ovpnProfile ?? ""
        let mark = profile.isEmpty ? "" : "|" + SHA256.hash(data: Data(profile.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(NetworkIdentity.shared.current?.key ?? "")|\(e.id.uuidString)\(mark)"
    }

    /// `key`: the key from before the measurement. Another one now (the Mac changed network meanwhile, or the
    /// profile was edited): the measurement is of neither, and is not kept.
    private func remember(_ m: Measure, for e: Entry, key k: String) {
        guard m.score != nil, key(e) == k else { return }
        var kept = m
        kept.note = "Measured earlier"
        let unmarked = k.components(separatedBy: "|").prefix(2).joined(separator: "|")
        remembered = remembered.filter { !$0.key.hasPrefix(unmarked) }   // the scores of its earlier profiles
        remembered[k] = kept
        if let data = try? JSONEncoder().encode(remembered) { try? data.write(to: rememberedURL, options: .atomic) }
    }

    /// Connects `e` the way it is set to connect and waits until it is up or has failed.
    private func connect(_ e: Entry) async -> (ok: Bool, failure: String?) {
        if e.builtIn {
            guard let m = WindscribeMax.service(for: e.id) else { return (false, "Not found") }
            // shortcut: the kill switch covers FiveT's own VPNs; its block knows no address of this service, which
            // could never connect through it. So it is lifted here, and only here. Upgrade: let the service's servers through.
            vpn.releaseKillSwitch()
            let up = await withTaskCancellationHandler { await m.connectAndWait() } onCancel: { Task { @MainActor in m.stopConnect() } }
            return (up, up ? nil : (m.notice?.text ?? "Did not connect"))
        }
        guard let c = store.connection(id: e.id) else { return (false, "Not found") }
        vpn.connect(c, byUser: true)
        let began = Date()
        while Date().timeIntervalSince(began) < 60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return (false, nil) }
            guard let s = vpn.status(for: c.id) else {
                if Date().timeIntervalSince(began) > 5 { return (false, "Did not connect") }   // it gave up and left
                continue
            }
            if s.phase == .connected { return (true, nil) }
            // The tunnel failed and is only waiting to try again: that is a no here, not a reason to wait.
            // keepBlock: nobody asked for this stop, so a kill switch that is blocking goes on blocking.
            if s.waitingToRetry || s.waitingForNetwork { vpn.disconnect(id: c.id, keepBlock: true); return (false, s.detail ?? "Did not connect") }
        }
        vpn.disconnect(id: c.id, keepBlock: true)
        return (false, "Did not connect in time")
    }

    private func isUp(_ e: Entry) -> Bool { isUp(e.id) }

    func isUp(_ id: UUID) -> Bool {
        WindscribeMax.service(for: id).map { $0.connected } ?? (vpn.status(for: id)?.phase == .connected)
    }

    // MARK: Putting things back

    /// The VPN (not Forti) that is up now: it is the one to come back to when a run finds nothing better.
    private func upNow() -> Entry? { entries.first(where: isUp) }

    private func putBack(_ before: Entry?) async {
        // Nothing was connected (every check failed, or stopped before the first try): leave things as they are.
        // Not judged by "is it still up": a built-in service that is stepping aside still says connected for a moment.
        guard changed else { return }
        // The block stays while a saved VPN is on its way back, and when it was there before the run. Otherwise the
        // run began on an open internet, or goes back to a built-in service, and must not end blocked.
        vpn.stopOtherVPNs(keepBlock: blockedAtStart || before?.builtIn == false)
        for m in WindscribeMax.all { _ = await m.stepAside() }
        guard let before else { return }
        step = "Back to \(before.name)…"
        _ = await connect(before)
    }

    private func tell(_ text: String, error: Bool = false, connection: UUID? = nil) {
        notice = text
        noticeIsError = error
        noticeConnection = connection
        if error { vpn.report("Smart Connect: " + text) }   // the menu shows it too, for a run started there
    }
}
