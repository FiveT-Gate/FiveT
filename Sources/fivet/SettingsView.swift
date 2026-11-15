import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

/// SwiftUI's `State` property wrapper under another name; use it instead of `@State`. The macOS 27
/// SDK also declares a `@State` macro, which the compiler prefers, and its plugin ships with Xcode
/// but not with the Command Line Tools. Spelled this way the app builds against the newest SDK,
/// which is what gives it the current macOS design. Same behaviour as `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>

/// A disclosure row, as Apple's HIG describes one: a chevron that turns when it opens, a label that says what
/// is behind it, and the whole row is the click target (DisclosureGroup here opened only from its tiny arrow).
/// Shared by "Advanced" in the Forti form and "Backup" in General.
private struct DisclosureHeader: View {
    let title: String
    let open: Bool
    let help: String
    let toggle: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "expanded" : "collapsed")
        .help(help)
    }
}

/// `connections` is the Forti tab (FortiGate connections); OpenVPN connections have their own, the VPN tab.
enum SettingsTab: Hashable, CaseIterable {
    case connections, openvpn, sso, general

    /// The tab that lists `c`: OpenVPN and V2Ray are on the VPN tab.
    static func of(_ c: Connection) -> SettingsTab { c.isOtherVPN ? .openvpn : .connections }
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .connections
    /// The connection picked on each list tab. The Settings window is released when it closes and its
    /// pages start afresh when it opens again, so the pick has to live here to survive that.
    var picked: [SettingsTab: UUID] = [:]
}

/// The Settings window's content: one page per tab, built the first time its tab is shown and
/// then kept in the window, hidden while another tab is up. Switching tabs only flips `isHidden`.
/// Rebuilding the tab's whole form on every switch held the main thread for 50-120 ms, and so
/// did taking a finished page out of the window and putting it back (SwiftUI redraws it all);
/// either way the tab animation in the title bar stuttered. The tab strip is the window's
/// toolbar (SettingsToolbar); `SettingsRouter.tab` picks the page.
final class SettingsTabsController: NSViewController {
    private var pages: [SettingsTab: NSView] = [:]
    private var subscription: AnyCancellable?

    override func loadView() {
        view = NSView()
        subscription = SettingsRouter.shared.$tab.sink { [weak self] tab in self?.show(tab) }
    }

    private func show(_ tab: SettingsTab) {
        // A text field being edited on the page that goes away keeps its text and lets go of the
        // keyboard, so typing never lands in a hidden page.
        if let window = view.window, let responder = window.firstResponder as? NSView,
           pages.contains(where: { $0.key != tab && responder.isDescendant(of: $0.value) }) {
            window.makeFirstResponder(nil)
        }
        if pages[tab] == nil {
            build(tab)
            // The other pages are built hidden a moment after the window opens, one per run-loop
            // turn, so even the first click on a tab finds its page ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.buildNextHidden() }
        }
        for (t, page) in pages where page.isHidden != (t != tab) { page.isHidden = t != tab }
    }

    private func buildNextHidden() {
        guard let tab = SettingsTab.allCases.first(where: { pages[$0] == nil }) else { return }
        build(tab).isHidden = true
        DispatchQueue.main.async { [weak self] in self?.buildNextHidden() }
    }

    @discardableResult
    private func build(_ tab: SettingsTab) -> NSView {
        let host = NSHostingController(rootView: SettingsPage(tab: tab))
        host.sizingOptions = [.minSize]   // the page fills the window; only its minimum size counts
        addChild(host)
        let page = host.view
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pages[tab] = page
        return page
    }
}

struct SettingsPage: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .connections: ConnectionsTab(kind: .fortinet)
            case .openvpn: ConnectionsTab(kind: .openvpn)
            case .sso: SSOTab()
            case .general: GeneralTab()
            }
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 540)
    }
}

// MARK: - Connections

/// The connections of one tab: Forti (FortiGate) or VPN (OpenVPN and V2Ray).
/// The face of a square button (+, −, import): a symbol, no text. Apple's HIG asks for about 10 pt of padding between an
/// image button's symbol and its edges, because the edges are the click target: 14 pt symbol, 32 × 28 pt target.
/// Lights up under the pointer, and `SquareButtonStyle` darkens it while it is pressed (the HIG wants a press state).
private struct SquareButtonLabel: View {
    let symbol: String
    @ViewState private var hovering = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 28)
            .background(hovering ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct SquareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.35)
            .background(configuration.isPressed ? Color.primary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ConnectionsTab: View {
    /// .fortinet for the Forti tab; anything else for the VPN tab.
    let kind: VPNKind
    @ObservedObject var store = ConnectionStore.shared
    @ObservedObject var vpn = VPNManager.shared
    @ViewState private var selection: UUID?
    @ViewState private var importMessage: String?
    @ViewState private var importTitle = "Import"
    @ViewState private var pendingRemoval: Connection?
    @ViewState private var dropTargeted = false
    // A directory listing (OpenVPN Connect's own folder), so done once when the tab appears rather
    // than on every render: this view re-renders on every VPN status tick (@ObservedObject var vpn).
    @ViewState private var hasOpenVPNConnectProfiles = false
    @ViewState private var hasOutline = false
    @ViewState private var importing = false

    private var isVPNTab: Bool { kind != .fortinet }
    /// The rows that are not saved connections: Smart Connect and the built-in services.
    private static func isBuiltInRow(_ id: UUID) -> Bool { id == SmartConnect.rowID || WindscribeMax.rowIDs.contains(id) }
    private var listTab: SettingsTab { isVPNTab ? .openvpn : .connections }

    private var shown: [Connection] { store.connections.filter { $0.isOtherVPN == isVPNTab } }

    private func remove(_ c: Connection) {
        if vpn.status(for: c.id) != nil { vpn.disconnect(id: c.id) }
        store.remove(id: c.id)
        if selection == c.id { selection = shown.first?.id }
    }

    private func importFortiClient(_ read: () throws -> [FortiClientImport.Profile]) {
        importTitle = "Import from FortiClient"
        do {
            let outcome = FortiClientImport.merge(try read(), into: store)
            importMessage = outcome.summary
            if let first = outcome.imported.first { selection = first.id }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a FortiClient backup (Settings → Backup, saved without a password) or FortiClient's vpn.plist."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importFortiClient { try FortiClientImport.read(url: url) }
        }
    }

    /// Shows what an import added (selecting the first) and what it has to say.
    private func show(_ outcome: VPNImport.Outcome, title: String) {
        importTitle = title
        if let first = outcome.added.first { selection = first.id }
        importMessage = outcome.message
    }

    /// Runs an import that may fetch a subscription, with the + button busy meanwhile.
    private func run(_ title: String, _ work: @escaping @MainActor () async -> VPNImport.Outcome) {
        importing = true
        Task { @MainActor in
            let outcome = await work()
            importing = false
            show(outcome, title: title)
        }
    }

    /// The servers saved in the Outline app. macOS keeps Outline's data from other apps until the user
    /// agrees, so a refusal leads to askForOutlineAccess() instead of a message to go and find
    /// System Settings: `folders` is what the user chose there, `asked` that they already did.
    private func importOutline(folders: [URL]? = nil, asked: Bool = false) {
        importing = true
        Task { @MainActor in
            let outcome = await VPNImport.addOutline(folders: folders)
            importing = false
            if outcome.needsOutlineAccess { askForOutlineAccess(alreadyChose: asked) } else { show(outcome, title: "Import from Outline") }
        }
    }

    private func askForOutlineAccess(alreadyChose: Bool) {
        let alert = NSAlert()
        alert.messageText = alreadyChose ? "macOS still keeps Outline's servers from FiveT" : "Let FiveT read Outline's servers"
        alert.informativeText = alreadyChose
            ? "Open Full Disk Access, switch FiveT on (if it is not in the list, drag FiveT from the Finder window into it), then reopen FiveT and import again."
            : "macOS keeps the servers saved in Outline private. Click Choose Folder, then Allow in the window that opens: FiveT only reads the saved servers and changes nothing in Outline."
        if !alreadyChose { alert.addButton(withTitle: "Choose Folder…") }
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let wantsFolder = !alreadyChose && response == .alertFirstButtonReturn
            let wantsSettings = response == (alreadyChose ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            if wantsFolder {
                chooseOutlineFolder()
            } else if wantsSettings {
                // The Full Disk Access page, and FiveT in Finder to drag into its list.
                if let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(page) }
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// The system's folder dialog, already at Outline's folder: choosing it there is the user's say-so.
    private func chooseOutlineFolder() {
        let panel = NSOpenPanel()
        panel.message = "Click Allow to let FiveT read the servers saved in Outline. FiveT changes nothing in Outline."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = OutlineApp.accessFolder
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importOutline(folders: [url], asked: true)
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.message = "Choose OpenVPN profiles (.ovpn), V2Ray/Xray configs (.json), or text files with V2Ray links or Outline keys."
        panel.allowedContentTypes = ["ovpn", "conf", "json", "txt"].compactMap { UTType(filenameExtension: $0) } + [.plainText, .json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            run("Add VPN") { await VPNImport.addFiles(urls) }
        }
    }

    /// The clipboard: V2Ray links, an Outline key, a subscription address, a JSON config, or copied files.
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            run("Add VPN") { await VPNImport.addFiles(urls) }
        } else if let text = pb.string(forType: .string), !text.trimmed.isEmpty {
            run("Add VPN") { await VPNImport.addText(text, from: "the clipboard") }
        } else {
            show(VPNImport.Outcome(lines: ["The clipboard holds no V2Ray links, Outline key or subscription address. Copy the config or key, and paste again."]), title: "Add VPN")
        }
    }

    /// Files or text dropped on the tab.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let texts = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                                       && $0.canLoadObject(ofClass: NSString.self) }
        guard !files.isEmpty || !texts.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in files {
                if let u = await withCheckedContinuation({ (k: CheckedContinuation<URL?, Never>) in
                    _ = p.loadObject(ofClass: NSURL.self) { obj, _ in k.resume(returning: (obj as? NSURL) as URL?) }
                }) { urls.append(u) }
            }
            var text = ""
            for p in texts {
                if let t = await withCheckedContinuation({ (k: CheckedContinuation<String?, Never>) in
                    _ = p.loadObject(ofClass: NSString.self) { obj, _ in k.resume(returning: (obj as? NSString) as String?) }
                }) { text += t + "\n" }
            }
            run("Add VPN") {
                var out = await VPNImport.addFiles(urls)
                if !text.trimmed.isEmpty { out.merge(await VPNImport.addText(text, from: "a drop")) }
                return out
            }
        }
        return true
    }

    private func dotColor(_ c: Connection) -> Color {
        switch vpn.status(for: c.id)?.phase {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        default: return .secondary.opacity(0.4)
        }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).listRowSeparator(.hidden)
    }

    private func row(_ c: Connection) -> some View {
        HStack {
            Circle().fill(dotColor(c)).frame(width: 8, height: 8)
            Text(c.name.isEmpty ? "Untitled" : c.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if isVPNTab {
                Text(c.isV2Ray ? V2RayConfig.kindLabel(c) : "OpenVPN").font(.subheadline).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.vertical, 3)   // a little air between the rows of the Forti and VPN lists
        .listRowSeparator(.hidden)
        .tag(c.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    if isVPNTab {
                        // Smart Connect heads the list, above My VPNs: a built-in row, never saved, so it cannot be removed.
                        SmartConnectRow().listRowSeparator(.hidden).tag(SmartConnect.rowID)
                        // Headers are plain rows, not Section headers: a List pins the first Section header to the top
                        // and draws a line under it, which "Built in" (further down) never had.
                        if !shown.isEmpty { sidebarHeader("My VPNs").padding(.top, 12); ForEach(shown) { row($0) } }
                        // Built in: not a saved connection, so it is always here and cannot be removed.
                        sidebarHeader("Built in").padding(.top, 12)
                        ForEach(WindscribeMax.all, id: \.rowID) { WindscribeMaxRow(m: $0).listRowSeparator(.hidden).tag($0.rowID) }
                    } else {
                        ForEach(shown) { row($0) }
                    }
                }
                .onPasteCommand(of: [.plainText, .fileURL]) { _ in if isVPNTab { pasteFromClipboard() } }
                .onAppear {
                    guard isVPNTab else { return }   // only the VPN tab's + menu reads these
                    hasOpenVPNConnectProfiles = !OpenVPNProfile.openVPNConnectProfiles().isEmpty
                    hasOutline = OutlineApp.installed
                }
                Divider()
                // Square buttons (Apple HIG): symbols only, one size, in one row under the list they act on (as in Finder
                // and Mail's sidebars): + adds, − removes the selected one, the last one imports.
                HStack(spacing: 0) {
                    if isVPNTab {
                        // A VPN connection is its profile or link: there is nothing to fill in without one.
                        Menu {
                            Button("Add from File…") { chooseFiles() }
                            Button("Paste Links, Keys or Subscription") { pasteFromClipboard() }
                            Divider()
                            Button("From Outline on this Mac") { importOutline() }
                                .disabled(!hasOutline)
                            Button("From OpenVPN Connect on this Mac") {
                                show(VPNImport.addOpenVPN(OpenVPNProfile.openVPNConnectProfiles(), from: "OpenVPN Connect",
                                                          names: OpenVPNProfile.openVPNConnectNames()),
                                     title: "Import OpenVPN Profile")
                            }
                            .disabled(!hasOpenVPNConnectProfiles)
                        } label: { SquareButtonLabel(symbol: importing ? "ellipsis" : "plus") }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(importing)
                        .help("Add a VPN: an OpenVPN profile, V2Ray links, an Outline key or a subscription, or the servers of Outline or OpenVPN Connect. You can also drop files or links on this tab, or paste them with ⌘V.")
                    } else {
                        Button {
                            let c = store.add()
                            selection = c.id
                        } label: { SquareButtonLabel(symbol: "plus") }
                        .help("Add a connection")
                    }
                    Button {
                        if let s = selection { pendingRemoval = store.connection(id: s) }
                    } label: { SquareButtonLabel(symbol: "minus") }
                    .disabled(selection == nil || selection.map(Self.isBuiltInRow) == true)
                    .help(selection.map(Self.isBuiltInRow) == true ? "Built in: it cannot be removed" : "Remove the selected connection")
                    if !isVPNTab {
                        Menu {
                            Button("From FortiClient on this Mac") {
                                importFortiClient { try FortiClientImport.readLocalStore() }
                            }
                            .disabled(!FortiClientImport.localStoreExists)
                            Button("From a FortiClient backup file…") { importFromFile() }
                        } label: { SquareButtonLabel(symbol: "square.and.arrow.down") }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Import connections from FortiClient: names, gateways and user names (passwords are never included)")
                    }
                }
                .buttonStyle(SquareButtonStyle())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 190)
            .alert(importTitle, isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .alert("Remove \"\(pendingRemoval?.name ?? "")\"?",
                   isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                   presenting: pendingRemoval) { c in
                Button("Remove", role: .destructive) { remove(c) }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                let active = vpn.status(for: c.id) != nil
                Text("The connection to \(c.gatewayDescription) and its saved password will be deleted."
                     + (active ? " It is connected right now and will be disconnected first." : ""))
            }

            Divider()

            if isVPNTab, selection == SmartConnect.rowID {
                SmartConnectTab()
            } else if isVPNTab, let service = WindscribeMax.service(for: selection) {
                WindscribeMaxPanel(m: service)
            } else if let id = selection, shown.contains(where: { $0.id == id }) {
                // A fresh form per connection: a password revealed with Touch ID for one connection
                // must not stay revealed for the next one selected.
                ConnectionForm(connection: store.binding(for: id))
                    .id(id)
            } else {
                Text(!shown.isEmpty ? (isVPNTab ? "Select a connection, or drop more VPN configs here." : "Select a connection.")
                     : isVPNTab ? "Press + to add a VPN: an OpenVPN profile (.ovpn), V2Ray links (vless://, vmess://, trojan://, hysteria2://), an Outline key (ss:// or ssconf://) or a subscription, or the servers of Outline or OpenVPN Connect on this Mac.\n\nOr drop files or links here, or paste them with ⌘V."
                     : "Press + to add a connection, or import yours from FortiClient with the import button.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil {
                let kept = SettingsRouter.shared.picked[listTab]
                selection = shown.contains(where: { $0.id == kept }) || (isVPNTab && kept.map(Self.isBuiltInRow) == true) ? kept : shown.first?.id
            }
        }
        .onChange(of: selection) { SettingsRouter.shared.picked[listTab] = $0 }
        .onDrop(of: isVPNTab ? [.fileURL, .plainText, .url] : [], isTargeted: $dropTargeted) { dropped($0) }
        .overlay {
            if dropTargeted && isVPNTab {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(2)
                    .overlay(Text("Drop VPN configs to add them").font(.headline).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)))
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ConnectionForm: View {
    @Binding var connection: Connection
    @ObservedObject var vpn = VPNManager.shared
    @ViewState private var showPassword = false
    @ViewState private var showSecret = false
    @ViewState private var revealError: String?
    @ViewState private var qrMessage: String?
    @ViewState private var qrFailed = false
    /// The Forti form's "Advanced" group (DNS, gateway certificate, extra options) is folded until clicked.
    @ViewState private var advancedOpen = false
    /// The split-DNS fields: their own "DNS" section for OpenVPN, inside "Advanced" for Forti.
    @ViewBuilder private var dnsFields: some View {
        TextField("DNS domains for split DNS", text: $connection.dnsDomains)
        Text("While connected, look-ups for these domains go to this VPN's DNS servers even when another VPN, or a second tunnel, owns the Mac's default DNS (FiveT writes /etc/resolver/<domain> and removes it on disconnect). The DNS suffixes the \(connection.isOpenVPN ? "server" : "gateway") pushes are added automatically; list any other internal domains here. Needs the helper from the General tab.")
            .font(.subheadline).foregroundStyle(.secondary)
        if let sd = mine?.splitDNS {
            LabeledContent("Split DNS") {
                Text("\(sd.state)\(sd.detail.isEmpty ? "" : " — " + sd.detail)")
                    .font(.subheadline).foregroundStyle(sd.state == "active" ? .green : .orange)
            }
        }
        if let n = mine?.network, !n.interface.isEmpty {
            LabeledContent("Tunnel") {
                Text("\(n.interface) \(n.tunnelIP)   DNS \(n.dnsServers.joined(separator: ", "))   \(n.routes.count) routes")
                    .font(.subheadline).textSelection(.enabled)
            }
        }
    }
    /// The secret before a paste, put back when a pasted link cannot be used.
    @ViewState private var lastGoodSecret = ""
    @ViewState private var profileMessage: String?
    @ViewState private var profileFailed = false
    // The profile text this cache was computed from; re-parsed only when it changes, not on every
    // render (a status tick re-renders this form as often as the watchdog probes, every 20s or so,
    // and a profile with inlined certificates can be tens of KB to parse three times over).
    @ViewState private var ovpnCacheProfile = ""
    @ViewState private var ovpnServers: [(host: String, port: Int, proto: String)] = []
    @ViewState private var ovpnFullTunnel = false
    @ViewState private var ovpnNeedsLogin = false

    private func refreshOVPNCacheIfNeeded() {
        guard connection.ovpnProfile != ovpnCacheProfile else { return }
        ovpnCacheProfile = connection.ovpnProfile
        ovpnServers = OpenVPNProfile.remotes(connection.ovpnProfile)
        ovpnFullTunnel = OpenVPNProfile.redirectsGateway(connection.ovpnProfile)
        ovpnNeedsLogin = OpenVPNProfile.needsLogin(connection.ovpnProfile)
    }

    /// This connection's own tunnel.
    private var mine: VPNStatus? { vpn.status(for: connection.id) }
    private var isActive: Bool { mine?.phase == .connected || mine?.phase == .connecting }

    private var statusText: String {
        switch mine?.phase {
        case .connected:
            let others = vpn.connected.filter { $0.connectionID != connection.id }.compactMap(\.connectionName)
            return others.isEmpty ? "Connected" : "Connected, together with \(others.joined(separator: ", "))"
        case .connecting: return mine?.detail ?? "Connecting…"
        case .disconnecting: return "Disconnecting…"
        default: return "Not connected"
        }
    }

    private static let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65535
        return f
    }()

    // MARK: One-time-code secret from a QR code

    /// The clipboard: a screenshot of the QR code, or an otpauth:// link copied as text. Once the
    /// secret is saved, the clipboard is emptied (unless something else was copied meanwhile):
    /// it held the secret, and clipboard managers and Universal Clipboard keep what it holds.
    private func importQRFromClipboard() {
        let pb = NSPasteboard.general
        let copied = pb.changeCount
        if let text = pb.string(forType: .string), OTPAuthImport.looksLikeLink(text) {
            importQR(text: text, clipboard: copied)
            return
        }
        guard let image = NSImage(pasteboard: pb) else {
            qrFailed = true
            qrMessage = "The clipboard holds no picture. Take a screenshot of the QR code with ⌃⇧⌘4 (Control-Shift-Command-4 copies it), then choose Import QR Code → Paste Screenshot."
            return
        }
        importQR(image: image, into: connection.id, clipboard: copied)
    }

    private func importQRFromFile() {
        let id = connection.id
        let panel = NSOpenPanel()
        panel.message = "Choose a picture of the QR code: a screenshot, a photo, or a PDF page."
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // A sheet on Settings, so the selected connection cannot change while the panel is open.
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url) else {
                qrFailed = true
                qrMessage = "\(url.lastPathComponent) is not a picture FiveT can read."
                return
            }
            importQR(image: image, into: id)
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// An image file or a picture dragged onto the secret row.
    private func importQR(dropped providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        let id = connection.id
        let deliver: (NSImage?) -> Void = { image in
            DispatchQueue.main.async {
                guard let image else {
                    qrFailed = true
                    qrMessage = "That is not a picture FiveT can read. Drop a screenshot or photo of the QR code."
                    return
                }
                importQR(image: image, into: id)
            }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                deliver(url.flatMap { NSImage(contentsOf: $0) })
            }
            return true
        }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { object, _ in deliver(object as? NSImage) }
            return true
        }
        return false
    }

    private func importQR(image: NSImage, into id: UUID, clipboard: Int? = nil) {
        do { adopt(try OTPAuthImport.accounts(in: image), into: id, clipboard: clipboard) } catch { reportQR(error) }
    }

    /// `restoring`: what the secret field held before a pasted link, put back at once (the link
    /// itself, with every secret of an export in it, is never saved).
    private func importQR(text: String, restoring before: String? = nil, clipboard: Int? = nil) {
        let id = connection.id
        if let before { connection.totpSecret = before }
        do { adopt(try OTPAuthImport.accounts(in: text), into: id, clipboard: clipboard) } catch { reportQR(error) }
    }

    /// Saves the secret into connection `id` (not through the form: it may show another connection
    /// by the time a panel or a drop delivers). Several accounts in one code: the user picks one.
    private func adopt(_ accounts: [OTPAuthImport.Account], into id: UUID, clipboard: Int? = nil) {
        guard accounts.count > 1 else {
            if let a = accounts.first { save(a, into: id, clipboard: clipboard) }
            return
        }
        let target = ConnectionStore.shared.connection(id: id) ?? connection
        let alert = NSAlert()
        alert.messageText = "Which account is \(target.name)'s?"
        alert.informativeText = "This QR code holds \(accounts.count) accounts. Choose the one whose code you use to log in to this VPN."
            + (accounts.first?.exportPart.map { " It is \($0) of a Google Authenticator export: if the VPN's account is not listed, cancel and import the next one." } ?? "")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        // Menu items one by one: addItems(withTitles:) would merge accounts that share a label.
        for a in accounts { popup.menu?.addItem(NSMenuItem(title: a.label, action: nil, keyEquivalent: "")) }
        let hints = [target.name, target.username].map { $0.lowercased() }.filter { $0.count >= 3 }
        if let i = accounts.firstIndex(where: { a in hints.contains { a.label.lowercased().contains($0) } }) { popup.selectItem(at: i) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use This Account")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, accounts.indices.contains(popup.indexOfSelectedItem) else { return }
            save(accounts[popup.indexOfSelectedItem], into: id, clipboard: clipboard)
        }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private func save(_ a: OTPAuthImport.Account, into id: UUID, clipboard: Int? = nil) {
        if id == connection.id { lastGoodSecret = a.secret }   // a later refused paste puts this one back
        var modeSet = false
        ConnectionStore.shared.mutate(id: id) {
            $0.totpSecret = a.secret
            // A secret means a one-time code: with none chosen yet, append it to the password. A
            // gateway that wants it as a second step gets it that way on the automatic retry.
            if $0.otpMode == .none { $0.otpMode = .appendToPassword; modeSet = true }
        }
        var cleared = false
        if let clipboard, NSPasteboard.general.changeCount == clipboard {
            NSPasteboard.general.clearContents()
            cleared = true
        }
        qrFailed = false
        qrMessage = "Imported the secret for \(a.label). Check that the code below matches the one in your authenticator app."
            + (modeSet ? " One-time code is now set to append the code to the password." : "")
            + (cleared ? " The clipboard was emptied, since it held the secret." : "")
        let name = ConnectionStore.shared.connection(id: id)?.name ?? "?"
        Log.shared.write("[\(name)] one-time-code secret imported from a QR code or otpauth link (\(a.label))")
    }

    private func reportQR(_ error: Error) {
        qrFailed = true
        qrMessage = (error as? OTPAuthImport.Failure)?.message ?? error.localizedDescription
    }

    // MARK: OpenVPN

    /// Replace Profile…: a newer .ovpn for this connection; its name, login and settings stay.
    private func replaceProfile() {
        let id = connection.id
        let panel = NSOpenPanel()
        panel.message = "Choose the new OpenVPN profile (.ovpn) for \(connection.name)."
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data, UTType(filenameExtension: "conf") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let imp = try OpenVPNProfile.importProfile(at: url)
                ConnectionStore.shared.mutate(id: id) { OpenVPNProfile.apply(imp, to: &$0) }
                profileFailed = false
                profileMessage = "Profile replaced (\(imp.host):\(imp.port))."
                    + (imp.dropped.isEmpty ? "" : " Left out: \(imp.dropped.joined(separator: "; ")).")
                    + (vpn.status(for: id) != nil ? " It is used from the next connect." : "")
                Log.shared.write("[\(ConnectionStore.shared.connection(id: id)?.name ?? "?")] OpenVPN profile replaced (\(imp.host):\(imp.port))")
            } catch {
                profileFailed = true
                profileMessage = error.localizedDescription
            }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    @ViewState private var refreshing = false

    @ViewBuilder private var v2raySection: some View {
        Section(V2RayConfig.kindLabel(connection)) {
            TextField("Name", text: $connection.name)
            LabeledContent("Server") { Text("\(connection.host):" + String(connection.port)).textSelection(.enabled) }   // String: a number in Text gets a thousands separator ("8,388")
            LabeledContent("Type") { Text(V2RayConfig.summary(connection.v2rayOutbound)) }
            Text("All of the Mac's traffic goes through this server, and names are looked up through it too. Your local network always goes direct, and so do Iranian sites while Bypass Iranian Websites is on (Settings → General).")
                .font(.subheadline).foregroundStyle(.secondary)
            if !connection.v2raySubscription.isEmpty {
                LabeledContent("Subscription") {
                    HStack {
                        Text(URL(string: connection.v2raySubscription)?.host ?? "?").textSelection(.enabled)
                        Button(refreshing ? "Refreshing…" : "Refresh") {
                            refreshing = true
                            let address = connection.v2raySubscription
                            Task { @MainActor in
                                let out = await VPNImport.refresh(subscription: address)
                                refreshing = false
                                profileFailed = out.added.isEmpty && out.lines.first?.hasPrefix("Could not") == true
                                profileMessage = out.message
                            }
                        }
                        .disabled(refreshing)
                        .help("Fetch the subscription again: new servers are added, ones it no longer lists are removed.")
                    }
                }
            }
            if !connection.v2rayLink.isEmpty {
                HStack {
                    Text("The link holds this server's ID or password: share it only with people who may use the server.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connection.v2rayLink, forType: .string)
                    }
                }
            }
            if let m = profileMessage {
                Text(m).font(.subheadline).foregroundStyle(profileFailed ? Color.red : Color.secondary)
            }
        }
    }

    // MARK: Subscription

    @ObservedObject private var tests = SubscriptionTests.shared
    /// This subscription's Update, Test Ping and Quality, which outlive the form (SubscriptionTests).
    private var test: SubscriptionTests.State { tests.state(connection.id) }

    @ViewBuilder private var subscriptionSection: some View {
        Section("Subscription") {
            TextField("Name", text: $connection.name)
            LabeledContent("Address") { Text(URL(string: connection.v2raySubscription)?.host ?? "?").textSelection(.enabled) }
            if let u = connection.v2raySubscriptionUsage { SubscriptionUsageTiles(usage: u) }
        }
        Section {
            if let m = test.message {
                Text(m).font(.subheadline).foregroundStyle(test.failed ? Color.red : Color.secondary)
            }
            ForEach(Array(shownServers.enumerated()), id: \.offset) { _, server in serverRow(server) }
        } header: {
            HStack {
                Text("Servers (\(connection.v2rayServers.count))")
                Spacer()
                Button { tests.update(connection.id) } label: {
                    Label(test.updating ? "Updating…" : "Update", systemImage: "arrow.clockwise")
                }
                .disabled(test.updating || test.qualityRunning)
                .help("Fetch the subscription again: its servers and the account's data and end date.")
                Button { tests.ping(connection.id) } label: {
                    Label(test.pinging && !test.qualityRunning ? "Testing…" : "Test Ping", systemImage: "gauge.with.dots.needle.33percent")
                }
                .disabled(test.pinging || test.qualityRunning)
                .help("How long each server takes to answer a TCP connection, from this Mac.")
                Button { tests.quality(connection.id) } label: {
                    Label(!test.qualityRunning ? "Quality" : test.pinging ? "Stop (ping…)" : "Stop (\(test.qualityDone)/\(test.qualityTotal))",
                          systemImage: test.qualityRunning ? "stop.circle" : "checkmark.seal")
                }
                .disabled(test.pinging && !test.qualityRunning)
                .help("Ping every server, then load a web page and download for 4 s through each one that answered, and score it (0-100). Takes a few seconds a server; the Mac's connection stays as it is.")
            }
        }
    }

    /// The servers as listed, or after a finished ping test fastest first, then the ones that did not
    /// answer or could not be tested (each group in the subscription's order).
    private var shownServers: [V2RayServer] {
        let all = connection.v2rayServers
        let t = test, pings = t.pings, quality = t.quality
        guard !t.pinging, !t.qualityRunning, !pings.isEmpty || !quality.isEmpty else { return all }
        // Best quality score first (untested and failed last), then fastest ping, then the subscription's order.
        let score = { (s: V2RayServer) -> Int in -(quality[s.key]?.score ?? -1) }
        let ping = { (s: V2RayServer) -> Int in pings[s.key].flatMap { $0 >= 0 ? $0 : nil } ?? .max }
        return all.enumerated().sorted {
            (score($0.element), ping($0.element), $0.offset) < (score($1.element), ping($1.element), $1.offset)
        }.map(\.element)
    }

    private func serverRow(_ s: V2RayServer) -> some View {
        let chosen = s.outbound == connection.v2rayOutbound
        return Button { choose(s) } label: {
            HStack {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).lineLimit(1)
                    Text("\(s.host):" + String(s.port) + " · " + V2RayConfig.summary(s.outbound))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                qualityLabel(s)
                pingLabel(s)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? "In use" : "Use this server" + (isActive ? " (reconnects now)" : ""))
    }

    @ViewBuilder private func pingLabel(_ s: V2RayServer) -> some View {
        if SubscriptionTests.isUDP(s) {
            Text("UDP").font(.caption).foregroundStyle(.secondary).help("Hysteria2 runs over UDP, which the ping test cannot reach.")
        } else if let ms = test.pings[s.key] {
            Text(ms < 0 ? "No answer" : "\(ms) ms").font(.caption.monospacedDigit())
                .foregroundStyle(ms < 0 ? Color.red : ms < 300 ? Color.green : ms < 800 ? Color.orange : Color.red)
        } else if test.pinging {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func qualityLabel(_ s: V2RayServer) -> some View {
        if let m = test.quality[s.key] {
            if let score = m.score {
                HStack(spacing: 4) {
                    if let speed = m.speed { Text(String(format: "%.1f Mbit/s", speed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text("\(score)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(score >= 70 ? Color.green : score >= 40 ? Color.orange : Color.red, in: Capsule())
                }
                .help("Quality \(score) of 100: web page in \(Int(m.web ?? 0)) ms, download \(String(format: "%.1f", m.speed ?? 0)) Mbit/s")
            } else {
                Text("No traffic").font(.caption).foregroundStyle(.red).help(m.failure ?? "")
            }
        } else if test.qualityRunning, test.qualityNow == s.key {
            ProgressView().controlSize(.small)
        }
    }

    /// Makes `s` the server this subscription connects to; while it is up, it reconnects to it at once.
    private func choose(_ s: V2RayServer) {
        guard s.outbound != connection.v2rayOutbound else { return }
        V2RayConfig.use(s, in: &connection)
        Log.shared.write("[\(connection.name)] server chosen: \(s.name)")
        guard isActive else { return }
        let c = connection
        vpn.disconnect(id: c.id)
        vpn.connect(c, byUser: true)   // waits for the stop, then starts on the new server
    }

    @ViewBuilder private var openVPNSection: some View {
        Section("OpenVPN") {
            TextField("Name", text: $connection.name)
            let servers = ovpnServers
            LabeledContent("Server") {
                Text(servers.first.map { "\($0.host):\($0.port) (\($0.proto.uppercased()))" + (servers.count > 1 ? ", and \(servers.count - 1) more" : "") } ?? "None")
                    .textSelection(.enabled)
            }
            LabeledContent("Traffic") {
                if ovpnFullTunnel || mine?.network?.fullTunnel == true {
                    Text("All traffic goes through the VPN, and its DNS answers every name")
                } else if mine?.phase == .connected {
                    Text("Only the VPN's own networks go through it")
                } else {
                    Text("As the server decides when it connects").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Certificates and keys are inside the profile.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Replace Profile…") { replaceProfile() }
            }
            if let m = profileMessage {
                Text(m).font(.subheadline).foregroundStyle(profileFailed ? Color.red : Color.secondary)
            }
        }
    }

    var body: some View {
        refreshOVPNCacheIfNeeded()
        return VStack(spacing: 0) {
            header
            Form {
                if connection.isSubscription {
                    subscriptionSection
                } else if connection.isV2Ray {
                    v2raySection
                } else if connection.isOpenVPN {
                    openVPNSection
                } else {
                    Section("Gateway") {
                        TextField("Name", text: $connection.name)
                        TextField("Remote gateway (IP or host name)", text: $connection.host)
                        TextField("Port", value: $connection.port, formatter: Self.portFormatter)
                        TextField("Realm", text: $connection.realm)
                    }
                }
                if connection.isV2Ray {
                    // No login: the ID or password is part of the server's config.
                } else if connection.isOpenVPN && !ovpnNeedsLogin {
                    Section("Login") {
                        Text("This profile logs in with the certificate inside it: no username or password.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                Section("Login") {
                    TextField("Username", text: $connection.username)
                    HStack {
                        if showPassword {
                            TextField("Password (static part)", text: $connection.password)
                        } else {
                            SecureField("Password (static part)", text: $connection.password)
                        }
                        // Nothing to show in an empty field: the button appears once there is.
                        if !connection.password.isEmpty {
                            Button(showPassword ? "Hide" : "Show…") {
                                if showPassword { showPassword = false; return }
                                LocalAuth.confirm("show the password") { ok, why in showPassword = ok; revealError = why }
                            }
                        }
                    }
                    Picker("One-time code", selection: $connection.otpMode) {
                        ForEach(OTPMode.allCases) { Text($0.label).tag($0) }
                    }
                    if connection.otpMode == .separate {   // no note under "Append TOTP code to password"
                        Text("Gateways differ: some want the 6-digit code typed right after the password, others ask for it in a second step. When a login is rejected, FiveT retries once the other way and keeps the one that works.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if connection.usesTOTP {
                        HStack {
                            if showSecret {
                                TextField("TOTP secret", text: $connection.totpSecret)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField("TOTP secret", text: $connection.totpSecret)
                            }
                            if !connection.totpSecret.isEmpty {
                                Button(showSecret ? "Hide" : "Show…") {
                                    if showSecret { showSecret = false; return }
                                    LocalAuth.confirm("show the TOTP secret") { ok, why in showSecret = ok; revealError = why }
                                }
                            }
                        }
                        // Pasting an otpauth:// link (what a QR code holds) into the field takes the secret
                        // out of it; a link FiveT cannot use puts the previous secret back.
                        .onChange(of: connection.totpSecret) { text in
                            guard text.range(of: "otpauth(-migration)?:", options: [.regularExpression, .caseInsensitive]) != nil else {
                                lastGoodSecret = text
                                return
                            }
                            // Only a link that is the whole field is read. Pasted next to the old secret,
                            // the two run together ("…secret=NEWOLD") and no one could tell where the new
                            // secret ends: then the old one is put back and nothing is guessed.
                            let t = text.trimmed
                            let whole = t.range(of: "^otpauth(-migration)?:", options: [.regularExpression, .caseInsensitive]) != nil
                                && (lastGoodSecret.isEmpty || !t.hasSuffix(lastGoodSecret))
                            guard whole else {
                                connection.totpSecret = lastGoodSecret
                                qrFailed = true
                                qrMessage = "To import a link, paste it into an empty secret field (select what is in it first), or use Import QR Code."
                                return
                            }
                            // The clipboard held the link (and every secret of an export): emptied once it
                            // is imported, as Paste Screenshot does.
                            importQR(text: t, restoring: lastGoodSecret, clipboard: NSPasteboard.general.changeCount)
                        }
                    }
                    // Always here, even before a one-time-code mode is chosen: whoever holds the QR code
                    // their IT team sent should not have to know about modes first.
                    HStack {
                        Text(connection.usesTOTP ? "Secret from a QR code" : "One-time code from a QR code")
                        Spacer()
                        Menu {
                            Button("Paste Screenshot") { importQRFromClipboard() }
                            Button("Choose Image…") { importQRFromFile() }
                        } label: {
                            Label("Import QR Code", systemImage: "qrcode")
                        }
                        .fixedSize()
                    }
                    .help("Reads the one-time-code secret from a QR code: a screenshot of it (⌃⇧⌘4 copies one), an image file, a Google Authenticator export, or an otpauth:// link. You can also drop the picture on this row.")
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in importQR(dropped: providers) }
                    if let m = qrMessage {
                        Text(m).font(.subheadline).foregroundStyle(qrFailed ? Color.red : Color.secondary)
                    } else if connection.usesTOTP && connection.totpSecret.isEmpty {
                        Text("Type or paste the secret, or import it from the setup QR code or a Google Authenticator export.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    // No code (and no "not valid Base32" warning) before a secret is entered.
                    if connection.usesTOTP && !connection.totpSecret.isEmpty { TOTPPreview(secret: connection.totpSecret, tab: .of(connection)) }
                    if let e = revealError {
                        Text(e).font(.subheadline).foregroundStyle(.red)
                    }
                }
                }
                if !connection.isV2Ray && connection.kind != .fortinet {   // Forti has it inside Advanced
                Section("DNS") {
                    dnsFields
                }
                }
                if connection.kind == .fortinet {
                Section {
                    DisclosureHeader(title: "Advanced", open: advancedOpen,
                                     help: advancedOpen ? "Hide the advanced settings" : "Show the advanced settings: DNS, the gateway certificate, extra options") {
                        advancedOpen.toggle()
                    }
                    if advancedOpen {
                        dnsFields
                        LabeledContent("Gateway certificate") {
                            HStack {
                                if connection.hasPendingReview {
                                    Text(connection.pendingCertFirst ? "Unconfirmed" : "Changed").foregroundStyle(.orange)
                                    Button("Review…") { CertReview.present(connection.id, over: NSApp.keyWindow) }
                                } else if !connection.knowsGateway {
                                    Text("Checked on the first connect").foregroundStyle(.secondary)
                                } else if connection.trustedCert.isEmpty {
                                    Text("Verified by a certificate authority").foregroundStyle(.secondary)
                                        .help(connection.trustedCertNames.isEmpty ? "" : "Made out to \(connection.trustedCertNames.joined(separator: ", "))")
                                } else {
                                    Text(String(connection.trustedCert.prefix(16)) + "…")
                                        .font(.system(.body, design: .monospaced))
                                        .help(connection.trustedCertNames.isEmpty ? connection.trustedCert
                                              : "\(connection.trustedCert)\nMade out to \(connection.trustedCertNames.joined(separator: ", "))")
                                }
                                // Not while a review waits: Forget would make the next connect a first
                                // meeting, and the certificate under review would be the one met.
                                if connection.knowsGateway && !connection.hasPendingReview {
                                    Button("Forget") { connection.forgetCertificate() }
                                        .help("The next connect meets the gateway as for the first time and asks about its certificate.")
                                }
                            }
                        }
                        if connection.hasPendingReview {
                            Text(connection.pendingCertFirst
                                 ? "macOS cannot confirm this gateway's certificate belongs to it. FiveT logs in once you have reviewed it."
                                 : "The gateway showed a different certificate than the one FiveT trusts, and macOS could not confirm it is a renewal. FiveT will not log in to it until you review it.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extra openfortivpn options (one per line, e.g. set-dns = 1)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            TextEditor(text: $connection.extraConfig)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 56)
                        }
                    }
                }
                }
                // Connect and the status moved to the header; what is left is a failed last try and a certificate waiting for review.
                if !isActive, connection.lastError != nil || connection.hasPendingReview {
                    Section {
                        if let e = connection.lastError {
                            Text("Last error: \(e)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if connection.hasPendingReview {
                            Button(connection.pendingCertFirst ? "Review Certificate…" : "Review New Certificate…") {
                                CertReview.present(connection.id, over: NSApp.keyWindow)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { lastGoodSecret = connection.totpSecret }
        }
    }

    /// The name of the connection, its state under it, and Connect at the top right: the same header as Windscribe's.
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.trimmed.isEmpty ? "Untitled" : connection.name.trimmed)
                    .font(.title2.weight(.semibold)).lineLimit(1)
                Text(statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            connectButton
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
    }

    @ViewBuilder private var connectButton: some View {
        switch mine?.phase {
        case .connecting:   // a click stops the attempt, like Windscribe's button
            Button { vpn.toggle(connection) } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
                    Text("Connecting…")
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Click to stop connecting")
        case .connected:
            Button { vpn.toggle(connection) } label: { Label("Disconnect", systemImage: "xmark.circle").frame(minWidth: 110) }
                .controlSize(.large)
        case .disconnecting:
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Disconnecting…") }.frame(minWidth: 110)
            }
            .controlSize(.large).disabled(true)
        default:
            Button { connectNow() } label: { Label("Connect", systemImage: "power").frame(minWidth: 110) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func connectNow() {
        // On a Mac that is not set up yet: the password prompt first, then the tunnel
        // (a connect by id, so a second click during the prompt changes nothing).
        let id = connection.id
        SetupFlow.shared.whenReady({ if let c = ConnectionStore.shared.connection(id: id) { vpn.connect(c, byUser: true) } },
                                   failed: { SettingsRouter.shared.tab = .general })
    }
}

/// The live one-time code with a Copy button.
struct TOTPPreview: View {
    let secret: String
    /// The tab this row is on. Its page stays in the window, hidden, while another tab shows, and the
    /// countdown would go on ticking there (0.4% of a core): it stops a moment after the tab changes.
    /// Not at once: redrawing the row in the middle of the tab animation made it stutter (30 ms).
    let tab: SettingsTab
    @ViewState private var ticking = true

    var body: some View {
        // The code changes twice a minute, on the half minute: only then is the row made anew.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / TOTP.period).rounded(.down) * TOTP.period),
                               by: TOTP.period)) { ctx in
            HStack {
                if let code = TOTP.code(secret: secret, at: ctx.date) {
                    Text("Current code")
                    Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    // The countdown is drawn, not laid out: as a Text, each second's new number made
                    // SwiftUI lay the whole form out again (9 ms a second with Settings open, 6 ms even
                    // on a page hidden behind another tab).
                    Group {
                        if ticking {
                            TimelineView(.periodic(from: .now, by: 1)) { tick in
                                Canvas { g, size in
                                    g.draw(Text("(\(TOTP.secondsRemaining(at: tick.date))s left)").foregroundColor(.secondary),
                                           at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
                                }
                            }
                        }
                    }
                    .frame(width: 68, height: 18)
                    .accessibilityLabel("Seconds left for this code")
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(code, forType: .string)
                    }
                } else {
                    Text("The secret is not valid Base32.").foregroundStyle(.red)
                }
            }
        }
        .onReceive(SettingsRouter.shared.$tab.debounce(for: .seconds(0.4), scheduler: RunLoop.main)) { ticking = $0 == tab }
    }
}

// MARK: - Setup

/// The first thing on the General tab while this Mac is not set up: one button, one password
/// prompt. After it worked it says so (and points to Connections) until the tab changes.
struct SetupBanner: View {
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var flow = SetupFlow.shared
    @ObservedObject private var store = ConnectionStore.shared

    var body: some View {
        if vpn.needsSetup || flow.justSetUp {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: flow.justSetUp ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 30))
                        .foregroundStyle(flow.justSetUp ? Color.green : Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(flow.justSetUp ? "FiveT is ready" : "One-time setup").font(.headline)
                        Text(flow.justSetUp
                             ? (store.connections.isEmpty ? "Next, add your VPN." : "You can connect now.")
                             : "macOS asks for your Mac password once.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !flow.justSetUp {
                        Button("Set Up FiveT") { flow.run() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(flow.working)
                    } else if store.connections.isEmpty {
                        Button("Add Your VPN…") { SettingsRouter.shared.tab = .connections }
                            .controlSize(.large)
                    }
                }
                .padding(.vertical, 4)
                if flow.working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(flow.message ?? "").font(.body)
                    }
                } else if flow.failed, let m = flow.message {
                    Text(m).font(.body).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }
}

/// The requirement checks and the troubleshooting tools, as the last two sections of the General tab.
/// Rows show a title and, only when something needs doing, one short hint; Copy Diagnostics has
/// the full details.
struct SetupSections: View {
    @ObservedObject private var store = ConnectionStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var flow = SetupFlow.shared
    @ViewState private var checks: [SetupCheck] = []
    @ViewState private var diagnosticsMessage: String?
    @ViewState private var setupOpen = false   // folded, unless a check fails (see refresh)

    /// The banner at the top reports a setup while it is shown; this section does otherwise
    /// (Install Helper… for a newer openfortivpn).
    private var bannerShown: Bool { vpn.needsSetup || flow.justSetUp }

    /// pppd ships with macOS: its row only shows when it is missing.
    private var shownChecks: [SetupCheck] { checks.filter { $0.id != "pppd" || !$0.ok } }

    var body: some View {
        Group {
            Section {
                DisclosureHeader(title: "Setup", open: setupOpen,
                                 help: setupOpen ? "Hide the setup checks" : "Show the setup checks: what FiveT needs on this Mac") {
                    setupOpen.toggle()
                }
                if setupOpen {
                    ForEach(shownChecks) { c in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title)
                                if let h = c.hint { Text(h).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if c.fix == .installHelper {
                                Button("Install Helper…") { flow.run() }
                                    .disabled(flow.working)
                            }
                        }
                    }
                    if checks.isEmpty || (flow.working && !bannerShown) { ProgressView().controlSize(.small) }
                }
                // Progress and errors stay visible when folded; a success shows in the rows turning green.
                if !bannerShown, flow.working || flow.failed, let m = flow.message { Text(m).font(.body) }
            }
            Section("Troubleshooting") {
                Toggle("Detailed log", isOn: $store.verboseLogging)
                Toggle("Include packet traces", isOn: $store.verbosePackets)
                    .disabled(!store.verboseLogging)
                    .padding(.leading, 20)
                HStack {
                    Button("Open Log…") { NSWorkspace.shared.open(Log.shared.fileURL) }
                    Button("Copy Diagnostics") {
                        diagnosticsMessage = "Collecting…"
                        Diagnostics.copyToClipboard { diagnosticsMessage = "Copied. Paste it into the chat." }
                    }
                    if let m = diagnosticsMessage { Text(m).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
        // The page is kept between visits, so onAppear would run once: check again on every visit,
        // and after every setup run, wherever it was started (banner, menu, a connect click).
        .onReceive(SettingsRouter.shared.$tab) { if $0 == .general { refresh() } }
        .onReceive(flow.$working.dropFirst()) { if !$0 { refresh() } }
    }

    /// The checks start processes (sudo, openfortivpn --version): run them off the main thread.
    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Setup.checks()
            DispatchQueue.main.async {
                if result != checks { checks = result }   // same answers: no redraw
                if result.contains(where: { !$0.ok }) { setupOpen = true }   // a problem is never hidden
            }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var store = ConnectionStore.shared
    @ViewState private var startAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginMessage: String?
    @ViewState private var backupMessage: String?
    @ViewState private var backupOpen = false

    static let repositoryURL = URL(string: "https://github.com/FiveT-Gate/FiveT")!
    private static let fivetType = UTType(filenameExtension: "fivet") ?? .json

    /// Writes every connection and setting to a .fivet file the user picks.
    private func addVPNApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "Choose an app to use the VPN."
        guard panel.runModal() == .OK, let url = panel.url, !store.vpnApps.contains(url.path) else { return }
        store.vpnApps.append(url.path)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.message = "The file is encrypted: only FiveT can open it. It holds your connections with their passwords and one-time-code secrets."
        panel.nameFieldStringValue = BackupFile.defaultName()
        panel.allowedContentTypes = [Self.fivetType]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try store.backupData().write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                backupMessage = "Saved \(url.lastPathComponent)."
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }

    /// Reads a .fivet file made on this or another Mac.
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .fivet file exported from FiveT."
        panel.allowedContentTypes = [Self.fivetType, .json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { backupMessage = try store.restore(from: Data(contentsOf: url)) }
            catch { backupMessage = error.localizedDescription }
        }
    }

    var body: some View {
        Form {
            SetupBanner()   // only while this Mac is not set up
            Section {
                Toggle("Start FiveT at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginMessage = nil
                        } catch {
                            loginMessage = error.localizedDescription
                        }
                    }
                if let m = loginMessage { Text(m).font(.subheadline).foregroundStyle(.red) }
                Toggle("Reconnect when the connection drops", isOn: $store.autoReconnect)
                Toggle("Reconnect when the tunnel stops answering", isOn: $store.watchdog)
                Toggle("Show the connection name in the menu bar", isOn: $store.showNameInMenuBar)
            }
            Section("VPN Settings") {
                Toggle("Kill Switch", isOn: $store.killSwitch)
                    .onChange(of: store.killSwitch) { _ in VPNManager.shared.killSwitchChanged() }
                Text("Blocks internet access if the VPN drops.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("VPN for Chosen Apps", isOn: $store.appsOnly)
                    .onChange(of: store.appsOnly) { _ in VPNManager.shared.appsModeChanged() }
                Text("V2Ray and Outline only. Just the apps below use the VPN. Start them from the menu with Open with VPN. Works for Chrome-based apps (Claude, Slack, VS Code), not Safari.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.appsOnly {
                    ForEach(store.vpnApps, id: \.self) { path in
                        HStack {
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            Spacer()
                            Button("Remove") { store.vpnApps.removeAll { $0 == path } }
                        }
                    }
                    Button("Add App…") { addVPNApp() }
                }
                Toggle("Bypass Iranian Websites", isOn: $store.bypassIran)
                Text("Iranian sites connect directly, without the VPN.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Updates") {
                UpdateRow()
                Toggle("Install updates automatically", isOn: $store.autoUpdate)
            }
            MCPSection()
            Section {
                DisclosureHeader(title: "Backup", open: backupOpen,
                                 help: backupOpen ? "Hide the backup" : "Show the backup: export and import all connections and settings") {
                    backupOpen.toggle()
                }
                if backupOpen {
                    HStack {
                        Button("Export Settings…") { exportSettings() }
                        Button("Import Settings…") { importSettings() }
                        if let m = backupMessage { Text(m).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Text("A .fivet file is an encrypted backup of all connections and settings. Import it on another Mac to copy them.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            SetupSections()
            Section("About") {
                Link("FiveT on GitHub", destination: Self.repositoryURL)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Assistants (MCP): a fold-out in General

struct MCPSection: View {
    @ObservedObject var store = ConnectionStore.shared
    @ObservedObject var mcp = MCPServer.shared
    @ViewState private var message: String?
    @ViewState private var working = false
    @ViewState private var open = false

    private var statusText: String {
        guard store.mcpEnabled else { return "Off" }
        guard mcp.isListening else { return "Not running (see the log)" }
        switch mcp.clientCount {
        case 0: return "Ready, no assistant connected"
        case 1: return "Ready, 1 assistant connected"
        default: return "Ready, \(mcp.clientCount) assistants connected"
        }
    }

    var body: some View {
        Section {
            DisclosureHeader(title: "MCP", open: open,
                             help: open ? "Hide the MCP settings" : "Show the MCP settings: let AI assistants control FiveT") {
                open.toggle()
            }
            if open {
                Toggle("Let AI assistants control FiveT", isOn: $store.mcpEnabled)
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                Text("Assistants never see your passwords or one-time codes.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("Add FiveT to") {
                    HStack {
                        Button("Claude Desktop") {
                            run { MCPClientSetup.add(to: MCPClientSetup.claudeDesktopConfig, appName: "Claude Desktop") }
                        }
                        Button("Claude Code") { run { MCPClientSetup.addToClaudeCode() } }
                        Button("Cursor") {
                            run { MCPClientSetup.add(to: MCPClientSetup.cursorConfig, appName: "Cursor") }
                        }
                        if working { ProgressView().controlSize(.small) }
                        // Any other MCP client: the same entry, to paste into its settings.
                        Button("Copy JSON") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(MCPClientSetup.snippet, forType: .string)
                            message = "Copied. Paste it into the app's MCP settings."
                        }
                        .buttonStyle(.link)
                    }
                    .disabled(working)
                }
                if let m = message { Text(m).font(.body).textSelection(.enabled) }
            }
        }
    }

    private func run(_ action: @escaping () -> String) {
        working = true
        message = nil
        DispatchQueue.global().async {
            let m = action()
            DispatchQueue.main.async { message = m; working = false }
        }
    }
}

// MARK: - Updates

/// One row: what the updater knows, and the single button that makes sense right now.
struct UpdateRow: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject var store = ConnectionStore.shared

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let d = detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            switch updater.state {
            case .checking, .downloading, .installing:
                ProgressView().controlSize(.small)
            case .available:
                Button("Install Update") { updater.installNow() }
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Restart Now") { updater.installNow() }
            default:
                Button("Check for Updates") { updater.check() }
            }
        }
    }

    private var title: String {
        switch updater.state {
        case .idle: return "FiveT \(Updater.currentVersion)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "FiveT \(Updater.currentVersion) is up to date"
        case .available(let r): return "FiveT \(r.version) is available"
        case .ready(let r): return "FiveT \(r.version) is ready to install"
        case .downloading: return "Downloading FiveT…"
        case .installing: return "Installing… FiveT will restart in a moment"
        case .failed: return "Update check failed"
        }
    }

    private var detail: String? {
        switch updater.state {
        case .available:
            return "Installing restarts FiveT and briefly disconnects the VPN."
        case .ready:
            return store.autoUpdate ? "Installs by itself when no VPN is connected." : "Restarting briefly disconnects the VPN."
        case .failed(let m): return m
        default: return nil
        }
    }
}

/// A subscription's account in two cards: the data left (with a bar) and the days left. Either may be
/// unlimited, which the panel says with total=0 or expire=0.
struct SubscriptionUsageTiles: View {
    let usage: SubscriptionUsage

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)   // panels count 1024-based ("20.0 GB")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            tile {
                if usage.unlimitedData {
                    big("Unlimited", symbol: "infinity", color: .green)
                    Text("\(Self.bytes(usage.used)) used").font(.caption).foregroundStyle(.secondary)
                } else {
                    let fraction = min(1, Double(usage.used) / Double(usage.total))
                    let color: Color = fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .green
                    big(usage.left > 0 ? "\(Self.bytes(usage.left)) left" : "Used up", color: usage.left > 0 ? .primary : .red)
                    ProgressView(value: fraction).tint(color)
                    Text("\(Self.bytes(usage.used)) of \(Self.bytes(usage.total)) used").font(.caption).foregroundStyle(.secondary)
                }
            }
            tile {
                if let end = usage.expire {
                    let days = Int((end.timeIntervalSinceNow / 86400).rounded(.up))
                    let color: Color = days <= 3 ? .red : days <= 7 ? .orange : .green
                    big(days > 0 ? "\(days) \(days == 1 ? "day" : "days") left" : "Expired", color: days <= 3 ? .red : days <= 7 ? .orange : .primary)
                    ProgressView(value: Self.timeLeft(daysLeft: days)).tint(color)   // green = time still left
                    Text((days > 0 ? "Ends " : "Ended ") + end.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    big("Unlimited", symbol: "infinity", color: .green)
                    Text("No end date").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // both cards as tall as the taller one
        .padding(.vertical, 2)
    }

    /// How much of the plan is still left. The panel sends only the end date, so the plan is taken as the
    /// shortest usual one (30, 60, 90, 180 or 365 days, else whole years) that still holds the days left.
    /// shortcut: a 45-day plan shows as 60, upgrade if a panel ever sends its start date.
    static func timeLeft(daysLeft: Int) -> Double {
        guard daysLeft > 0 else { return 0 }
        let plan = [30, 60, 90, 180, 365].first { $0 >= daysLeft } ?? Int((Double(daysLeft) / 365).rounded(.up)) * 365
        return Double(daysLeft) / Double(plan)
    }

    private func big(_ text: String, symbol: String? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.title3.weight(.semibold).monospacedDigit())
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
