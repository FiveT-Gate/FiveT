import AppKit
import Network
import CoreWLAN
import CoreLocation
import SystemConfiguration

/// Which network the Mac is on, for the scan profiles of Windscribe Max and Express Max (what works on one Wi-Fi may
/// not work on another). The key is the router's hardware address: it needs no permission, and tells two networks
/// apart even when both are called "Home" or both use 192.168.1.1. The Wi-Fi name is only the label, because since
/// macOS 14 it is hidden from a program until the person allows Location for it.
@MainActor
final class NetworkIdentity: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NetworkIdentity()

    struct Net: Equatable {
        var key: String
        /// The Wi-Fi name; empty when macOS does not give it.
        var ssid: String
        var routerIP: String
        /// What to show: the Wi-Fi name, else the router's address.
        var name: String { ssid.isEmpty ? "Network \(routerIP)" : ssid }
    }

    /// nil: no network at all (the profile then stays as it was).
    @Published private(set) var current: Net?
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    /// Location Services are switched on for the whole Mac. Off (many people keep it off): the Wi-Fi name can never be read.
    @Published private(set) var servicesOn = false

    /// The names the person gave networks ("Home", "Office"), by network key. One list for every service: a network
    /// is the same network in Windscribe Max and in Express Max, so a name given in one shows in the other.
    @Published private(set) var names: [String: String] = [:]
    private var namesURL: URL { ConnectionStore.shared.directory.appendingPathComponent("network-names.json") }

    private let monitor = NWPathMonitor()
    private let location = CLLocationManager()
    private var reading = false

    private override init() {
        super.init()
        names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: namesURL))) ?? [:]
        location.delegate = self
        locationStatus = location.authorizationStatus
        servicesOn = CLLocationManager.locationServicesEnabled()
        Log.shared.write("network: location permission \(locationStatus.rawValue) (0 not asked, 1 restricted, 2 refused, 3/4 allowed), Location Services \(servicesOn ? "on" : "off")")
        refresh()   // not read right here: waiting for a command spins the main run loop, and this runs inside other objects' setup
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
        monitor.start(queue: .main)
    }

    /// Looks again (in the background: it runs two short commands); a change is published.
    func refresh() {
        guard !reading else { return }
        reading = true
        Task {
            let net = await Task.detached { Self.read() }.value
            reading = false
            if let net, net != current { current = net }   // no network: keep the last one
        }
    }

    /// Names a network. Empty: back to the automatic name. `onlyIfNew`: a name an older FiveT kept inside one service's file never replaces one given since.
    func setName(_ name: String, for key: String, onlyIfNew: Bool = false) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if onlyIfNew, names[key] != nil || name.isEmpty { return }
        if name.isEmpty { names[key] = nil } else { names[key] = name }
        guard let data = try? JSONEncoder().encode(names) else { return }
        do { try data.write(to: namesURL, options: .atomic) } catch { Log.shared.write("network: could not save the network names: \(error)", level: .error) }
    }

    /// Asks macOS once for permission to read the Wi-Fi name. If it was refused, System Settings is the only place left.
    func askForWiFiName() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    /// True when the name could be read if the person allowed it.
    var canAskForName: Bool { servicesOn && current?.ssid.isEmpty != false && locationStatus != .authorizedAlways }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            locationStatus = manager.authorizationStatus
            Log.shared.write("network: location permission is now \(locationStatus.rawValue)")
            refresh()
        }
    }

    // MARK: Reading

    /// The network of the first network card that has a router (the Wi-Fi card first). The system itself keeps each
    /// card's "network signature" (the router's address and hardware address) next to the card's other settings, so no
    /// command is run and no permission is needed. A VPN that is up does not change it: it is a card of its own.
    /// The Wi-Fi or Ethernet card the Mac reaches its router through ("en0"), whatever VPN is up on top of it.
    nonisolated static func physicalInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "FiveT" as CFString, nil, nil),
              let all = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/[^/]+/IPv4"] as CFArray) as? [String: [String: Any]] else { return nil }
        let names = all.values.filter { $0["Router"] is String }.compactMap { $0["InterfaceName"] as? String }.filter { $0.hasPrefix("en") }
        let wifi = CWWiFiClient.shared().interface()?.interfaceName
        return names.first { $0 == wifi } ?? names.sorted().first
    }

    nonisolated static func read() -> Net? {
        guard let store = SCDynamicStoreCreate(nil, "FiveT" as CFString, nil, nil),
              let all = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/[^/]+/IPv4"] as CFArray) as? [String: [String: Any]] else { return nil }
        let wifi = CWWiFiClient.shared().interface()
        let cards = all.values.filter { ($0["InterfaceName"] as? String)?.hasPrefix("en") == true && $0["Router"] is String }
        guard let s = cards.first(where: { $0["InterfaceName"] as? String == wifi?.interfaceName }) ?? cards.first,
              let ip = s["Router"] as? String else { return nil }
        let onWiFi = (s["InterfaceName"] as? String) == wifi?.interfaceName
        return Net(key: (s["NetworkSignature"] as? String) ?? "ip:\(ip)", ssid: onWiFi ? (wifi?.ssid() ?? "") : "", routerIP: ip)
    }
}
