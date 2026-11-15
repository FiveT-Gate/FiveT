import Foundation

/// Update, Test Ping and Quality of a subscription's servers (Settings → VPN). Kept here, not in the form, so a
/// test goes on and shows its progress after the person looks at another connection and comes back; the form is
/// built anew for every connection it shows.
@MainActor
final class SubscriptionTests: ObservableObject {
    static let shared = SubscriptionTests()

    struct State {
        /// Milliseconds by server (V2RayServer.key), or -1 for no answer.
        var pings: [String: Int] = [:]
        var pinging = false
        var quality: [String: SmartConnect.Measure] = [:]
        var qualityTask: Task<Void, Never>?
        var qualityDone = 0
        var qualityTotal = 0
        /// The server the quality test is on now.
        var qualityNow: String?
        var updating = false
        /// What the last Update said.
        var message: String?
        var failed = false
        var qualityRunning: Bool { qualityTask != nil }
    }

    @Published private(set) var states: [UUID: State] = [:]

    func state(_ id: UUID) -> State { states[id] ?? State() }

    private func change(_ id: UUID, _ edit: (inout State) -> Void) {
        var s = state(id)
        edit(&s)
        states[id] = s
    }

    static func isUDP(_ s: V2RayServer) -> Bool { s.outbound.contains("\"protocol\":\"hysteria\"") }

    func update(_ id: UUID) {
        change(id) { $0.updating = true }
        Task {
            let out = await VPNImport.updateSubscription(id: id)
            change(id) {
                $0.updating = false
                $0.failed = out.lines.first?.hasPrefix("Could not") == true
                // A failed update changed nothing: the results still belong to the servers listed.
                if !$0.failed { $0.pings = [:]; $0.quality = [:] }
                $0.message = out.message
            }
        }
    }

    func ping(_ id: UUID) {
        change(id) { $0.quality = [:] }
        Task { await pingAll(id) }
    }

    private func pingAll(_ id: UUID) async {
        let servers = (ConnectionStore.shared.connection(id: id)?.v2rayServers ?? []).filter { !Self.isUDP($0) }
        change(id) { $0.pinging = true; $0.pings = [:] }
        await withTaskGroup(of: (String, Int).self) { group in
            // 24 at a time: a subscription of hundreds opened that many connections at once, which
            // slowed every answer (the times shown were the crowd's, not the servers').
            var running = 0
            for s in servers {
                if running >= 24, let (key, ms) = await group.next() {
                    change(id) { $0.pings[key] = ms }
                    running -= 1
                }
                group.addTask { (s.key, await V2RayConfig.tcpPing(host: s.host, port: s.port) ?? -1) }
                running += 1
            }
            for await (key, ms) in group { change(id) { $0.pings[key] = ms } }
        }
        change(id) { $0.pinging = false }
    }

    /// Quality: ping, then each server that answered (and the UDP ones, which ping cannot reach) measured one
    /// after the other through a side Xray, as Smart Connect does. Called again while it runs, it stops.
    func quality(_ id: UUID) {
        if let t = state(id).qualityTask {
            t.cancel()
            change(id) { $0.qualityTask = nil; $0.qualityNow = nil }
            return
        }
        guard let base = ConnectionStore.shared.connection(id: id) else { return }
        let task = Task {
            await pingAll(id)
            let pings = state(id).pings
            let list = base.v2rayServers.filter { pings[$0.key] != -1 }
            change(id) { $0.qualityTotal = list.count }
            for s in list {
                // A connection removed meanwhile has nobody to show the rest to.
                if Task.isCancelled || ConnectionStore.shared.connection(id: id) == nil { break }
                var c = base
                c.name = "\(base.name) · \(s.name)"
                V2RayConfig.use(s, in: &c)
                change(id) { $0.qualityNow = s.key }
                let m = await SmartConnect.shared.probe(c)
                if Task.isCancelled { break }   // a stopped check measured nothing
                change(id) { $0.quality[s.key] = m; $0.qualityDone += 1 }
            }
            if !Task.isCancelled { change(id) { $0.qualityNow = nil; $0.qualityTask = nil } }
        }
        change(id) { $0.quality = [:]; $0.qualityDone = 0; $0.qualityTotal = 0; $0.qualityTask = task }
    }
}
