import Foundation
import AppKit

/// What differs between the built-in services of the VPN tab ("Windscribe Max", "Express Max"): the command line they
/// drive, the places and protocols it offers, and a few words. The model (`WindscribeMax`, one instance per service),
/// the scan, the scoring and the panel are the same for both.
@MainActor
protocol MaxBackend: AnyObject {
    /// "Windscribe": what the service is called in sentences.
    var name: String { get }
    /// "Windscribe Max": the panel's title.
    var title: String { get }
    /// The service's line in the menu bar menu.
    var menuName: String { get }
    var rowID: UUID { get }
    /// The file in FiveT's folder that keeps the scan results and settings.
    var fileName: String { get }
    /// The logo in Resources (a PNG without its extension); nil: a symbol.
    var logoResource: String? { get }
    var protocols: [String] { get }
    /// The protocols a first scan tests (each one multiplies the number of tests).
    var defaultProtocols: [String] { get }
    /// The ports to offer per protocol; `[0]` for a service that has none (a route is then just place and protocol).
    var defaultPorts: [String: [Int]] { get }
    var hasPorts: Bool { get }
    /// The Scan page can download a fresher location list.
    var canUpdateList: Bool { get }
    var downloadURL: URL { get }
    /// Country codes never listed, scanned or connected to.
    var leftOut: Set<String> { get }

    func protocolName(_ p: String) -> String
    func installState() -> WindscribeMax.Install
    /// The locations, and whether they came from a download rather than the list built into FiveT.
    func catalog() async -> (countries: [WindscribeCountry], downloaded: Bool)
    func downloadCatalog() async throws -> [WindscribeCountry]
    /// The ports of each protocol, when the service can say; nil when it cannot.
    func readPorts() async -> [String: [Int]]?

    /// The state for the panel (may take several commands), and the quick one the scan polls once a second.
    func status() async -> (status: WindscribeCLI.Status, text: String)
    func poll() async -> (status: WindscribeCLI.Status, text: String)
    /// Another command of this service is running, so the one just run was not run: not an answer about the service.
    func isBusyAnswer(_ text: String) -> Bool

    /// Starts a connection to a place (a city name, a country, or "best") over a protocol and port ("" and 0: its own choice).
    /// `wait`: return when it is up or has failed (the Connect button); otherwise as soon as it is started (a scan polls).
    func connect(place: String, proto: String, port: Int, wait: Bool, timeout: Double) async -> WindscribeCLI.Output
    func disconnect() async
    /// Windscribe's firewall, which it leaves ON after a failed attempt. Other services have none.
    func firewall(on: Bool) async
    func refusesLocation(_ text: String) -> Bool
    /// The connect command could not run at all (the service's app is missing or did not start): no answer about the route.
    func couldNotRun(_ out: WindscribeCLI.Output) -> Bool
    func openApp()
    /// Ends a connection from a thread that is quitting.
    func disconnectSync()
    /// FiveT lets go of the service (nothing connected through it): what it changed in the service's own settings is put back, and its helper app closed.
    func idle() async

    /// The row of the card named after the service (Windscribe: "Account  Logged in").
    func aboutRow(_ s: WindscribeCLI.Status) -> (label: String, value: String)
}

// MARK: - Windscribe

@MainActor
final class WindscribeBackend: MaxBackend {
    let name = "Windscribe"
    let title = "Windscribe Max"
    let menuName = "Windscribe"
    let rowID = WindscribeMax.rowID
    let fileName = "windscribe-max.json"
    let logoResource: String? = "windscribe-logo"
    let protocols = WindscribeCLI.protocols
    let defaultProtocols = WindscribeCLI.protocols
    let defaultPorts = WindscribeCLI.defaultPorts
    let hasPorts = true
    let canUpdateList = true
    let downloadURL = WindscribeCLI.downloadURL
    let leftOut = WindscribeCatalog.leftOut

    func protocolName(_ p: String) -> String {
        switch p {
        case "wireguard": return "WireGuard"
        case "ikev2": return "IKEv2"
        case "udp": return "UDP (OpenVPN)"
        case "tcp": return "TCP (OpenVPN)"
        case "stealth": return "Stealth"
        case "wstunnel": return "WStunnel"
        default: return p
        }
    }

    func installState() -> WindscribeMax.Install {
        WindscribeCLI.path != nil ? .ready : (WindscribeCLI.appInstalled ? .noCLI : .notInstalled)
    }

    func catalog() async -> (countries: [WindscribeCountry], downloaded: Bool) { WindscribeCatalog.load() }
    func downloadCatalog() async throws -> [WindscribeCountry] { try await WindscribeCatalog.download() }

    func readPorts() async -> [String: [Int]]? {
        var found: [String: [Int]] = [:]
        for p in WindscribeCLI.protocols { found[p] = await WindscribeCLI.ports(for: p) }
        return found
    }

    func status() async -> (status: WindscribeCLI.Status, text: String) { await WindscribeCLI.status() }
    func poll() async -> (status: WindscribeCLI.Status, text: String) { await WindscribeCLI.status() }
    func isBusyAnswer(_ text: String) -> Bool { WindscribeCLI.isBusyAnswer(text) }

    func connect(place: String, proto: String, port: Int, wait: Bool, timeout: Double) async -> WindscribeCLI.Output {
        var args = ["connect"]
        if !wait { args.append("-n") }
        args.append(place)
        if !proto.isEmpty { args.append(port > 0 ? "\(proto):\(port)" : proto) }
        return await WindscribeCLI.cli(args, timeout: timeout)
    }

    func disconnect() async { _ = await WindscribeCLI.cli(["disconnect"], timeout: 30) }
    func firewall(on: Bool) async { _ = await WindscribeCLI.cli(["firewall", on ? "on" : "off"], timeout: 20) }
    func refusesLocation(_ text: String) -> Bool { WindscribeCLI.refusesLocation(text) }
    func couldNotRun(_ out: WindscribeCLI.Output) -> Bool { out.status == 127 }

    func openApp() {
        let apps = ["/Applications", NSHomeDirectory() + "/Applications"].map { $0 + "/Windscribe.app" }
        if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
    }

    func disconnectSync() {
        guard let path = WindscribeCLI.path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["disconnect"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func idle() async {}

    func aboutRow(_ s: WindscribeCLI.Status) -> (label: String, value: String) { ("Account", s.login) }
}

// MARK: - ExpressVPN

@MainActor
final class ExpressBackend: MaxBackend {
    let name = "ExpressVPN"
    let title = "Express Max"
    let menuName = "Express"
    let rowID = WindscribeMax.expressRowID
    let fileName = "expressvpn-max.json"
    let logoResource: String? = "expressvpn-logo"
    let protocols = ExpressVPNCLI.protocols
    let defaultProtocols = ["lightwayudp"]   // 214 locations times five protocols would be hours: Lightway UDP is ExpressVPN's own first choice
    let defaultPorts: [String: [Int]] = Dictionary(uniqueKeysWithValues: ExpressVPNCLI.protocols.map { ($0, [0]) })   // no ports: one route per protocol
    let hasPorts = false
    let canUpdateList = false
    let downloadURL = ExpressVPNCLI.downloadURL
    let leftOut = ExpressCatalog.leftOut

    func protocolName(_ p: String) -> String {
        switch p {
        case "auto", "": return "Automatic"
        case "lightwayudp": return "Lightway UDP"
        case "lightwaytcp": return "Lightway TCP"
        case "wireguard": return "WireGuard"
        case "openvpnudp": return "OpenVPN UDP"
        case "openvpntcp": return "OpenVPN TCP"
        default: return p
        }
    }

    func installState() -> WindscribeMax.Install {
        ExpressVPNCLI.path != nil ? .ready : (ExpressVPNCLI.appInstalled ? .noCLI : .notInstalled)
    }

    func catalog() async -> (countries: [WindscribeCountry], downloaded: Bool) { (await ExpressCatalog.read(), false) }
    func downloadCatalog() async throws -> [WindscribeCountry] { await ExpressCatalog.read() }
    func readPorts() async -> [String: [Int]]? { nil }

    func status() async -> (status: WindscribeCLI.Status, text: String) { await ExpressVPNCLI.fullStatus() }
    func poll() async -> (status: WindscribeCLI.Status, text: String) { await ExpressVPNCLI.status() }
    func isBusyAnswer(_ text: String) -> Bool { false }

    func connect(place: String, proto: String, port: Int, wait: Bool, timeout: Double) async -> WindscribeCLI.Output {
        var out = await ExpressVPNCLI.connect(slug: ExpressCatalog.slug(for: place), proto: proto)
        guard wait, out.status == 0 else { return out }
        // The command line only starts the attempt: wait here for the state it reaches.
        let began = Date()
        while Date().timeIntervalSince(began) < timeout && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state = ExpressVPNCLI.parseState(await ExpressVPNCLI.get("connectionstate").text)
            if state == "Connected" { return out }
            if state == "Disconnected" && Date().timeIntervalSince(began) > 4 { out.text = "ExpressVPN did not connect."; out.status = 1; return out }
        }
        out.timedOut = true
        return out
    }

    func disconnect() async { await ExpressVPNCLI.disconnect() }
    func firewall(on: Bool) async {}
    func refusesLocation(_ text: String) -> Bool { ExpressVPNCLI.refusesLocation(text) }
    func couldNotRun(_ out: WindscribeCLI.Output) -> Bool { out.status == 127 || out.status == 4 }   // 4: its window app is not running

    func openApp() {
        if let app = ExpressVPNCLI.appPath { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
    }

    func disconnectSync() {
        guard let path = ExpressVPNCLI.path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["disconnect"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        ExpressVPNCLI.closeAppIfOurs()
    }

    func idle() async {
        await ExpressVPNCLI.restoreSettings()
        ExpressVPNCLI.closeAppIfOurs()
    }

    func aboutRow(_ s: WindscribeCLI.Status) -> (label: String, value: String) { ("Version", ExpressVPNCLI.version ?? "") }
}
