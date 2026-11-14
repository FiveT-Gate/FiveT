import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func minutes(_ seconds: TimeInterval) -> String {
    let m = Int((seconds / 60).rounded())
    return m < 1 ? "under a minute" : m < 90 ? "\(m) min" : String(format: "%.1f h", seconds / 3600)
}

// MARK: - Pieces

/// A rounded panel that groups related controls, laid out like a section of the grouped forms in the other
/// Settings tabs: the title (13 pt semibold) above the panel, not inside it.
private struct Card<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline).padding(.leading, 12) }
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))   // close to the grouped forms' own fill, on macOS 13 too
        }
    }
}

/// One row of a settings card, laid out like a row of the grouped forms in the other tabs: the title (13 pt, with a
/// 11 pt secondary line under it when there is something to explain) on the leading side, its control on the trailing side.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    let control: Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) { self.title = title; self.detail = detail; self.control = control() }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// A number with a stepper (Apple HIG: a stepper does not show its value, so it sits next to a field that does, and the
/// field can be typed in for big changes). A typed value is held to the range.
private struct NumberRow: View {
    let title: String
    var detail: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: String?
    init(_ title: String, detail: String? = nil, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil) {
        self.title = title; self.detail = detail; self._value = value; self.range = range; self.step = step; self.unit = unit
    }
    var body: some View {
        SettingRow(title, detail: detail) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 56)
                    .onChange(of: value) { v in
                        let held = min(max(v, range.lowerBound), range.upperBound)
                        if held != v { value = held }
                    }
                if let unit { Text(unit).foregroundStyle(.secondary).frame(width: 12, alignment: .leading) }
                Stepper("", value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// Wraps its children onto new lines, for the port chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    private func place(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { place(proposal.width ?? 400, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, f) in zip(subviews, place(bounds.width, subviews).frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified)
        }
    }
}

private struct Chip: View {
    let text: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.monospacedDigit())
                .padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A tick box that can also show "some".
private struct TickBox: View {
    enum State { case none, some, all }
    let state: State
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The logo

/// A service's own logo: the icon of its app (Resources/windscribe-logo.png, expressvpn-logo.png). A bolt when the file is not in the app.
private func serviceLogo(_ resource: String?) -> NSImage? {
    resource.flatMap { Bundle.main.url(forResource: $0, withExtension: "png") }.flatMap { NSImage(contentsOf: $0) }
}

struct WindscribeMark: View {
    let size: CGFloat
    let resource: String?
    var body: some View {
        if let logo = serviceLogo(resource) {
            Image(nsImage: logo).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.27))
        }
    }
}

// MARK: - The list row

/// A built-in service's row in the VPN tab: always there, never saved as a connection, so no remove.
struct WindscribeMaxRow: View {
    @ObservedObject var m: WindscribeMax
    var body: some View {
        HStack(spacing: 8) {
            WindscribeMark(size: 16, resource: m.backend.logoResource)
            Text(m.backend.title).lineLimit(1)
            Spacer(minLength: 0)
            Circle().fill(m.scanning ? Color.orange : m.connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
        .padding(.vertical, 3)   // the same air as the rows of My VPNs
        .help("Built in: drives the \(m.backend.name) app and finds the servers that work on this network. It cannot be removed.")
    }
}

// MARK: - The panel

struct WindscribeMaxPanel: View {
    @ObservedObject var m: WindscribeMax
    @ViewState private var page = WindscribeMaxPanel.firstPage

    enum Page: String, CaseIterable, Identifiable {
        case control = "Control", scan = "Scan", results = "Results"
        var id: String { rawValue }
    }

    private static var firstPage: Page {
        #if !DISTRIBUTION
        // Test copies: FIVET_WINDSCRIBE_PAGE=scan|results opens that page (for pictures of the window).
        if let name = ProcessInfo.processInfo.environment["FIVET_WINDSCRIBE_PAGE"], let p = Page(rawValue: name.capitalized) { return p }
        #endif
        return .control
    }

    private var headline: (text: String, color: Color) {
        if m.scanning { return ("Scanning \(m.scan?.done ?? 0)/\(m.scan?.total ?? 0)", .orange) }
        switch m.install {
        case .notInstalled: return ("Not installed", .secondary)
        case .noCLI: return ("No command line", .orange)
        case .ready:
            guard let s = m.status else { return (m.asked ? "Not answering" : "Checking…", .secondary) }
            if !s.isLoggedIn { return ("Sign in needed", .orange) }
            if s.isConnected { return (s.place.map { "Connected · \($0)" } ?? "Connected", .green) }
            return (s.isConnecting ? "Connecting…" : "Not connected", s.isConnecting ? .orange : .secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            WindscribeMark(size: 44, resource: m.backend.logoResource)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.backend.title).font(.title2.weight(.semibold))
                // What the Status card said: the state under the title, or what FiveT is doing right now.
                HStack(spacing: 6) {
                    if let busy = m.busy {
                        ProgressView().controlSize(.mini)
                        Text(busy).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Circle().fill(headline.color).frame(width: 8, height: 8)
                        Text(headline.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if m.scanning {
                // The Connect button turns into this while a scan runs.
                // A real button with Connect's own style, so the corners match on every macOS; a click stops the scan.
                Button { m.stopScan() } label: { Label("Scanning", systemImage: "magnifyingglass").foregroundStyle(.black).frame(minWidth: 90) }
                    .buttonStyle(.borderedProminent).tint(.yellow).controlSize(.large)
                    .help("Click to stop the scan")
            } else if m.install == .ready && m.status?.isLoggedIn == true { connectButtons }
        }
    }

    /// Connect (Reconnect and Disconnect while it is up).
    @ViewBuilder private var connectButtons: some View {
        if m.connectingHere {
            // Connect turned into this while it tries (one route, or several scanned ones): a click stops it.
            Button { m.stopConnect() } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).environment(\.colorScheme, .dark)   // light spinner on the blue
                    Text("Connecting…")
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Click to stop connecting")
        } else {
            let up = m.connected || m.status?.isConnecting == true
            Button { m.connect() } label: { Label(m.connected ? "Reconnect" : "Connect", systemImage: "power").frame(minWidth: 110) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.busy != nil)
            if up {
                Button { m.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    .controlSize(.large).disabled(m.busy != nil)
            }
        }
    }

    private var noticeBar: some View {
        Group {
            if let n = m.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: n.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(n.isError ? Color.orange : Color.accentColor)
                    Text(n.text).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { m.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(10)
                .background((n.isError ? Color.orange : Color.accentColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.install != .notInstalled { header }   // not installed: the screen below says it all, with its own picture
            noticeBar
            switch m.install {
            case .notInstalled, .noCLI:
                InstallCard(m: m)
            case .ready:
                if !m.asked {
                    HStack { ProgressView().controlSize(.small); Text("Asking \(m.backend.name)…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if m.status == nil {
                    NotAnsweringCard(m: m)
                } else if m.status?.isLoggedIn != true {
                    SignInCard(m: m)
                } else {
                    Picker("", selection: $page) {
                        ForEach(Page.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                    NetworkBar(m: m)
                    switch page {
                    case .control: ControlPage(m: m)
                    case .scan: ScanPage(m: m, showResults: { page = .results })
                    case .results: ResultsPage(m: m)
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)   // the same margins as the Forti and VPN forms
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: m.rowID) { await m.watch() }
    }
}

/// The Wi-Fi the scan results and settings below belong to. Each network keeps its own, and they change by themselves
/// when the Mac joins another one.
private struct NetworkBar: View {
    @ObservedObject var m: WindscribeMax
    @ObservedObject private var net = NetworkIdentity.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            Text(m.networkName ?? "No network").font(.subheadline.weight(.medium)).lineLimit(1)
            Button { rename() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Rename this network")
            Text("· \(m.results.filter(\.works).count) of \(m.results.count) routes work here").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if net.canAskForName {
                Button(net.locationStatus == .notDetermined ? "Show Wi-Fi Name" : "Allow Wi-Fi Name…") { net.askForWiFiName() }
                    .buttonStyle(.link).font(.subheadline)
                    .help("macOS hides the Wi-Fi name until you allow Location for FiveT. FiveT uses it only to label the saved results; it never leaves this Mac.")
            }
            if !m.otherNetworks.isEmpty {
                Menu("Other Networks") {
                    ForEach(m.otherNetworks, id: \.key) { n in
                        Menu("\(m.displayName(n.key)) · \(n.profile.results.filter(\.works).count) of \(n.profile.results.count)") {
                            Button("Forget This Network", role: .destructive) { m.forgetNetwork(n.key) }
                                .help("Deletes its name and its saved results and settings, in Windscribe Max and in Express Max.")
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        // Its own group (HIG: group related items with negative space): room above and below, and the left edge of the section titles.
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Results and scan settings are saved per network, and switch by themselves when the Wi-Fi changes.")
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Name this network"
        alert.informativeText = "Its scan results and settings are kept under this name, and come back when the Mac joins this network again. Empty: the automatic name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = m.networkName ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { m.renameNetwork(field.stringValue) } }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

// MARK: - Not installed, not answering, not signed in

/// FiveT's mascot peering through a magnifying glass at the dotted ghost of the Windscribe logo (the picture Omid
/// chose and accepted: Resources/windscribe-missing.png, 640 px, made from Resources/art/windscribe-missing-accepted.png
/// with the black background cut out, the brass hook above the logo removed, and its right and bottom edges faded, because the picture cuts the mascot off there).
/// Nothing is shown when the file is not in the app.
private let missingPicture: NSImage? = Bundle.main.url(forResource: "windscribe-missing", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

private struct InstallCard: View {
    @ObservedObject var m: WindscribeMax
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let missingApp = m.install == .notInstalled
        let name = m.backend.name
        ScrollView {
        VStack(spacing: 14) {
            if missingApp, m.backend.logoResource == "windscribe-logo", let picture = missingPicture {
                Image(nsImage: picture)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 320)
                    // The logo's white dots would vanish on a light window: a thin dark edge keeps them there.
                    .shadow(color: scheme == .light ? .black.opacity(0.5) : .clear, radius: 0.7)
                    .accessibilityLabel("FiveT's mascot looking through a magnifying glass for the missing \(name) logo")
            } else {
                Image(systemName: missingApp ? "arrow.down.app" : "terminal")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary).padding(.top, 24)
            }
            Text(missingApp ? "\(name) is not installed" : "\(name)'s command line is missing")
                .font(.title3.weight(.semibold))
            Text(missingApp
                 ? "\(m.backend.title) drives the \(name) app and its command line tool, which you install yourself: FiveT does not include them."
                 : "The \(name) app is on this Mac, but its command line tool (\(m.backend.hasPorts ? "windscribe-cli" : "expressvpnctl")) was not found. Install the latest \(name) over it: current versions include the tool.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 6) {
                Label("Download and install the \(name) app", systemImage: "1.circle")
                Label("Open it and sign in to your account", systemImage: "2.circle")
                Label("Come back here: FiveT notices by itself", systemImage: "3.circle")
            }
            .font(.body).foregroundStyle(.secondary)
            HStack {
                Button { NSWorkspace.shared.open(m.backend.downloadURL) } label: { Label("Download \(name)…", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if !missingApp { Button("Open \(name)…") { m.openApp() }.controlSize(.large) }
            }
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking for \(name)…").font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        }
    }
}

private struct NotAnsweringCard: View {
    @ObservedObject var m: WindscribeMax
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "bolt.slash").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("\(m.backend.name) is not answering").font(.title3.weight(.semibold))
            Text("The command line is there, but the \(m.backend.name) app did not reply. Open the app and try again.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            if !m.rawStatus.isEmpty {
                Text(m.rawStatus).font(.subheadline.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: 420, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Open \(m.backend.name)…") { m.openApp() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SignInCard: View {
    @ObservedObject var m: WindscribeMax
    var body: some View {
        let state = m.status?.login ?? ""
        let busy = state.lowercased().contains("logging")
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            if busy { ProgressView() } else { Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary) }
            Text(busy ? "\(m.backend.name) is signing in…" : "Sign in to \(m.backend.name)").font(.title3.weight(.semibold))
            Text(busy ? "This panel opens up once it is done."
                      : "Open the \(m.backend.name) app and sign in with your account. \(m.backend.title) can then connect it and scan for routes that work here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            if !state.isEmpty { Text("\(m.backend.name) says: \(state)").font(.subheadline).foregroundStyle(.secondary) }
            Button("Open \(m.backend.name)…") { m.openApp() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Control

private struct ControlPage: View {
    @ObservedObject var m: WindscribeMax
    @ViewState private var picking = false

    private var s: WindscribeCLI.Status { m.status ?? WindscribeCLI.Status() }
    private var scannedTarget: Bool { m.target == WindscribeMax.scanned }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {   // the gap between sections of the grouped forms
                if let scan = m.scan { ScanBanner(scan: scan, m: m) }
                Card("Connect to") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Location").foregroundStyle(.secondary)
                            Button { picking = true } label: {
                                HStack { Text(m.targetLabel(m.target)).lineLimit(1); Spacer(minLength: 4); Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary) }
                                    .frame(maxWidth: .infinity)
                            }
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                TargetLocationList(m: m) { picking = false }.frame(width: 320, height: 420)
                            }
                        }
                        GridRow {
                            Text("Protocol").foregroundStyle(.secondary)
                            Picker("", selection: $m.proto) {
                                Text("Automatic").tag("")
                                ForEach(m.backend.protocols, id: \.self) { Text(m.backend.protocolName($0)).tag($0) }
                            }
                            .labelsHidden().fixedSize().frame(maxWidth: .infinity, alignment: .leading).disabled(scannedTarget)
                            // A port the new protocol does not have goes back to Automatic. One it has stays: a click on a
                            // result sets protocol and port together, and this ran after it and wiped the port.
                            .onChange(of: m.proto) { p in if !(m.ports[p] ?? []).contains(m.port) { m.port = 0 } }
                        }
                        if m.backend.hasPorts {
                            GridRow {
                                Text("Port").foregroundStyle(.secondary)
                                Picker("", selection: $m.port) {
                                    Text("Automatic").tag(0)
                                    ForEach(m.ports[m.proto] ?? [], id: \.self) { Text(String($0)).tag($0) }
                                }
                                .labelsHidden().fixedSize().frame(maxWidth: .infinity, alignment: .leading).disabled(m.proto.isEmpty || scannedTarget)
                            }
                        }
                    }
                }
                if !m.scanning { StartScanCard(m: m) }
                Card(m.backend.name) {
                    HStack {
                        let about = m.backend.aboutRow(s)
                        Text(about.label).foregroundStyle(.secondary)
                        Text(about.value)
                        Spacer()
                        if !s.update.isEmpty { Text("Update available: \(s.update)").font(.subheadline).foregroundStyle(.secondary) }
                        Button("Open \(m.backend.name)…") { m.openApp() }
                    }
                }
            }
        }
    }
}

/// Pick one place to connect to: the scanned ones, Windscribe's best, a whole country, or a city.
/// Laid out by hand (not a DisclosureGroup) so every row shares one left edge: a 18 pt column for the
/// arrow or icon, a 10 pt gap, then the name.
private struct TargetLocationList: View {
    @ObservedObject var m: WindscribeMax
    let done: () -> Void
    @ViewState private var query = ""
    @ViewState private var open = Set<String>()

    private let column: CGFloat = 18, gap: CGFloat = 10

    private func pick(_ t: String) { m.target = t; done() }

    private var q: String { query.trimmed.lowercased() }

    private func countries() -> [WindscribeCountry] {
        q.isEmpty ? m.countries : m.countries.filter { $0.name.lowercased().contains(q) || $0.code.lowercased() == q || $0.cities.contains { $0.lowercased().contains(q) } }
    }

    /// While searching, the cities that match (all of them when the country itself matched).
    private func cities(_ c: WindscribeCountry) -> [String] {
        guard !q.isEmpty, !c.name.lowercased().contains(q), c.code.lowercased() != q else { return c.cities }
        return c.cities.filter { $0.lowercased().contains(q) }
    }

    private func isOpen(_ c: WindscribeCountry) -> Bool { !q.isEmpty || open.contains(c.id) }

    private func check(_ on: Bool) -> some View { Image(systemName: "checkmark").opacity(on ? 1 : 0) }

    /// A top row (Scanned locations, Best location): its icon sits in the arrow column of the country rows.
    private func topRow(_ title: String, icon: String, target: String) -> some View {
        Button { pick(target) } label: {
            HStack(spacing: gap) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: column)   // both filled, one size
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if m.target == target { check(true) }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func countryRow(_ c: WindscribeCountry) -> some View {
        let target = m.target(of: c)
        return HStack(spacing: gap) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { if open.contains(c.id) { open.remove(c.id) } else { open.insert(c.id) } }
            } label: {
                Image(systemName: "chevron.right")   // turns a quarter when the country opens, like Advanced in the Forti form
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen(c) ? 90 : 0))
                    .frame(width: column, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!q.isEmpty)   // a search shows its matches open
            Button { pick(target) } label: {
                HStack {
                    Text(c.name).lineLimit(1)
                    Text(c.continent).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if m.target == target { check(true) }
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func cityRow(_ city: String) -> some View {
        Button { pick(city) } label: {
            HStack {
                Text(city).lineLimit(1)
                Spacer(minLength: 8)
                if m.target == city { check(true) }
            }
            .padding(.leading, column + gap).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search countries and cities", text: $query).textFieldStyle(.roundedBorder).padding(10)
            List {
                topRow(m.targetLabel(WindscribeMax.scanned), icon: "checkmark.seal.fill", target: WindscribeMax.scanned)
                topRow("Best location", icon: "star.fill", target: "best")
                ForEach(countries()) { c in
                    countryRow(c)
                    if isOpen(c) { ForEach(cities(c), id: \.self) { cityRow($0) } }
                }
            }
        }
    }
}

// MARK: - Scan

private struct ScanBanner: View {
    let scan: WindscribeMax.Scan
    @ObservedObject var m: WindscribeMax
    var body: some View {
        Card("Scan progress") {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning: \(scan.done) of \(scan.total) tested · \(scan.worked) work").font(.title3.weight(.semibold))
                Spacer()
                Button(role: .destructive) { m.stopScan() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1)))
            Text(scan.current.isEmpty ? scan.step : "\(scan.current) — \(scan.step)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let left = scan.left { Text("About \(minutes(left)) left").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

private struct ScanPage: View {
    @ObservedObject var m: WindscribeMax
    let showResults: () -> Void
    @ViewState private var picking = false

    private var cityCount: Int { m.countries.reduce(0) { $0 + $1.cities.count } }
    private var scopeText: String {
        let chosen = m.settings.cities
        if chosen.isEmpty { return "Every city: \(cityCount) in \(m.countries.count) countries" }
        let countries = m.countries.filter { $0.cities.contains { chosen.contains($0) } }.count
        return "\(chosen.count) \(chosen.count == 1 ? "city" : "cities") in \(countries) \(countries == 1 ? "country" : "countries")"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {   // the gap between sections of the grouped forms
                if let scan = m.scan { ScanBanner(scan: scan, m: m) }
                if !m.scanning { StartScanCard(m: m) }
                Card("Where") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scopeText).font(.body)
                            Text(!m.backend.canUpdateList ? "Locations read from \(m.backend.name)"
                                 : m.serversDownloaded ? "Server list downloaded from \(m.backend.name)" : "Server list built into FiveT")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if m.backend.canUpdateList {
                            Button { m.updateServers() } label: { m.updatingServers ? AnyView(ProgressView().controlSize(.small)) : AnyView(Text("Update List")) }
                                .disabled(m.updatingServers)
                        }
                        Button("Choose…") { picking = true }
                            .popover(isPresented: $picking, arrowEdge: .bottom) { ScanLocationList(m: m).frame(width: 340, height: 440) }
                    }
                }
                .disabled(m.scanning)
                Card(m.backend.hasPorts ? "Protocols and ports" : "Protocols") {
                    ForEach(m.backend.protocols, id: \.self) { p in
                        protocolRow(p)
                        if p != m.backend.protocols.last { Divider() }
                    }
                }
                .disabled(m.scanning)
                Card("Test") {
                    SettingRow("Ping Host", detail: "The address pinged through each route.") {
                        TextField("1.1.1.1", text: $m.settings.pingHost)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 150)
                    }
                    Divider()
                    NumberRow("Pings per Test", detail: "More pings give a steadier average and loss figure.", value: $m.settings.pingCount, range: 1...20)
                    Divider()
                    NumberRow("Connect Timeout", detail: "A route that has not connected by then counts as failed.", value: $m.settings.timeout, range: 3...300, step: 5, unit: "s")
                    Divider()
                    NumberRow("Settle Delay", detail: "A pause after a route connects, before it is measured.", value: $m.settings.settle, range: 0...60, unit: "s")
                    Divider()
                    SettingRow("Stop at the First Route That Works", detail: "FiveT stays connected to it.") {
                        Toggle("", isOn: $m.settings.stopOnFirst).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    Divider()
                    SettingRow("Skip Routes Already Tested", detail: "Carries on from an earlier scan instead of starting over.") {
                        Toggle("", isOn: $m.settings.resume).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    Divider()
                    SettingRow("Measure Download Speed", detail: "Downloads for up to 4 s (25 MB at most) per route that works. Turn it off to scan faster and use no data; the score then rests on the ping and the web page time.") {
                        Toggle("", isOn: $m.settings.speedTest).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                .disabled(m.scanning)
            }
        }
    }

    private func protocolRow(_ p: String) -> some View {
        let on = m.settings.protocols.contains(p)
        let stat = m.protocolStats.first { $0.proto == p }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { on }, set: { v in
                    if v {
                        m.settings.protocols.append(p)
                        // With no port ticked the protocol would add no test at all: it gets its first port back.
                        if (m.settings.ports[p] ?? []).isEmpty { m.settings.ports[p] = [m.ports[p]?.first ?? 0] }
                    } else { m.settings.protocols.removeAll { $0 == p } }
                })) { Text(m.backend.protocolName(p)).font(.body.weight(.medium)) }
                Spacer()
                if let stat { Text("worked \(stat.ok) of \(stat.total)").font(.subheadline).foregroundStyle(stat.total >= 4 && Double(stat.ok) / Double(stat.total) < 0.4 ? Color.orange : Color.secondary) }
            }
            if m.backend.hasPorts { FlowLayout {
                ForEach(m.ports[p] ?? [], id: \.self) { port in
                    Chip(text: String(port), on: on && (m.settings.ports[p] ?? []).contains(port)) {
                        var list = m.settings.ports[p] ?? []
                        if let i = list.firstIndex(of: port) { list.remove(at: i) } else { list.append(port) }
                        m.settings.ports[p] = list
                        if !on && !list.isEmpty { m.settings.protocols.append(p) }
                    }
                }
            }
            .opacity(on ? 1 : 0.5) }
        }
    }
}

/// "N tests · about X min" and the Start scan button: on the Control page and on the Scan page.
private struct StartScanCard: View {
    @ObservedObject var m: WindscribeMax

    var body: some View {
        let plan = m.planned
        return Card("Scan") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.steps == 0 ? "Nothing to test" : "\(plan.steps) tests · about \(minutes(plan.seconds))").font(.title3.weight(.semibold))
                    Text(plan.steps == 0 ? "Pick locations and at least one \(m.backend.hasPorts ? "port" : "protocol"), or turn off \"Skip routes already tested\"."
                         : "\(m.backend.name) connects and disconnects for each one: the Mac's internet changes while it runs.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { askAndStart() } label: { Label("Start Scan", systemImage: "play.fill").frame(minWidth: 110) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(plan.steps == 0 || m.busy != nil)
            }
        }
    }

    /// A scan ends FiveT's own VPNs, so that is asked first.
    private func askAndStart() {
        let up = VPNManager.shared.connected.compactMap(\.connectionName)
        guard !up.isEmpty else { m.startScan(); return }
        let alert = NSAlert()
        alert.messageText = "Disconnect \(up.joined(separator: ", ")) to scan?"
        alert.informativeText = "The scan connects \(m.backend.name) over and over and tests the network itself, so every VPN and Forti connection of FiveT is disconnected first. Start them again afterwards from the menu."
        alert.addButton(withTitle: "Disconnect and Scan")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { m.startScan() } }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

/// The cities to test, by country; nothing ticked means all of them.
private struct ScanLocationList: View {
    @ObservedObject var m: WindscribeMax
    @ViewState private var query = ""

    private struct Entry: Identifiable {
        let country: WindscribeCountry
        let cities: [String]
        var id: String { country.id }
    }

    private func shown() -> [Entry] {
        let q = query.trimmed.lowercased()
        return m.countries.compactMap { c in
            guard !q.isEmpty else { return Entry(country: c, cities: c.cities) }
            if c.name.lowercased().contains(q) || c.code.lowercased() == q { return Entry(country: c, cities: c.cities) }
            let hit = c.cities.filter { $0.lowercased().contains(q) }
            return hit.isEmpty ? nil : Entry(country: c, cities: hit)
        }
    }

    private func state(_ cities: [String]) -> TickBox.State {
        let n = cities.filter { m.settings.cities.contains($0) }.count
        return n == 0 ? .none : n == cities.count ? .all : .some
    }

    private func toggle(_ cities: [String], on: Bool) {
        if on { m.settings.cities.formUnion(cities) } else { m.settings.cities.subtract(cities) }
    }

    var body: some View {
        let list = shown()
        VStack(spacing: 0) {
            TextField("Search countries and cities", text: $query).textFieldStyle(.roundedBorder).padding(10)
            List {
                ForEach(list) { entry in
                    let c = entry.country
                    DisclosureGroup {
                        ForEach(entry.cities, id: \.self) { city in
                            HStack {
                                TickBox(state: m.settings.cities.contains(city) ? .all : .none) { toggle([city], on: !m.settings.cities.contains(city)) }
                                Text(city)
                                Spacer()
                            }
                        }
                    } label: {
                        HStack {
                            TickBox(state: state(c.cities)) { toggle(c.cities, on: state(c.cities) != .all) }
                            Text(c.name)
                            Text(c.continent).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(c.cities.filter { m.settings.cities.contains($0) }.count)/\(c.cities.count)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(m.settings.cities.isEmpty ? "Nothing ticked: every city is tested" : "\(m.settings.cities.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { m.settings.cities = [] }.disabled(m.settings.cities.isEmpty)
            }
            .padding(10)
        }
    }
}

// MARK: - Results

private struct ResultsPage: View {
    @ObservedObject var m: WindscribeMax
    @ViewState private var order = [KeyPathComparator(\WindscribeResult.scoreSort, order: .reverse)]
    @ViewState private var onlyWorking = true
    @ViewState private var selection = Set<String>()

    private var rows: [WindscribeResult] {
        m.results.filter { !onlyWorking || $0.works }.sorted(using: order)
    }

    private func scoreColor(_ score: Int) -> Color { score >= 75 ? .green : score >= 50 ? .yellow : .orange }

    /// The numbers behind a score, for the tooltip.
    private func details(_ r: WindscribeResult) -> String {
        var parts = [r.avg.map { String(format: "ping %.0f ms", $0) } ?? "", r.jitter.map { String(format: "jitter %.0f ms", $0) } ?? "",
                     r.loss.map { String(format: "loss %.0f%%", $0) } ?? ""]
        if let web = r.web { parts.append(web >= WindscribeCLI.webFailedMs ? "web page failed" : String(format: "web page %.0f ms", web)) }
        if let speed = r.speed { parts.append(String(format: "download %.0f Mb/s", speed)) }
        return "Score \(r.score ?? 0): " + parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Delete all \(m.results.count) results?"
        alert.informativeText = "The next scan starts from nothing."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { m.clearResults() } }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    var body: some View {
        if m.results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("No results yet").font(.headline)
                Text("Run a scan: the routes that work on this network, best score first, appear here.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                if let scan = m.scan { ScanBanner(scan: scan, m: m) }
                best
                HStack {
                    Toggle("Only routes that work", isOn: $onlyWorking).toggleStyle(.checkbox)
                    Spacer()
                    Button("Clear…", role: .destructive) { confirmClear() }.disabled(m.scanning)
                }
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Location", value: \.city) { r in
                        Text("\(r.city) · \(r.code)").lineLimit(1)
                    }
                    TableColumn("Route", value: \.proto) { r in Text(m.backend.hasPorts ? r.route : m.backend.protocolName(r.proto)).lineLimit(1) }
                        .width(min: 84, ideal: 96)
                    TableColumn("Score", value: \.scoreSort) { r in
                        if let score = r.score {
                            Text("\(score)").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(scoreColor(score))
                                .help(details(r))
                        } else {
                            Text(r.outcome.label).font(.subheadline).foregroundStyle(r.outcome == .noTraffic ? Color.orange : Color.secondary).lineLimit(1)
                        }
                    }
                    .width(min: 52, ideal: 64)
                    TableColumn("Speed", value: \.speedSort) { r in
                        Text(r.speed.map { $0 > 0 ? String(format: "%.0f Mb/s", $0) : "none" } ?? "—").monospacedDigit()
                    }
                    .width(min: 54, ideal: 60)
                    TableColumn("Web", value: \.webSort) { r in
                        Text(r.web.map { $0 >= WindscribeCLI.webFailedMs ? "failed" : String(format: "%.0f ms", $0) } ?? "—").monospacedDigit()
                    }
                    .width(min: 48, ideal: 56)
                    TableColumn("Ping", value: \.pingSort) { r in
                        Text(r.avg.map { String(format: "%.0f ms", $0) } ?? "—").monospacedDigit()
                    }
                    .width(min: 46, ideal: 54)
                    TableColumn("Loss", value: \.lossSort) { r in
                        Text(r.loss.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                    }
                    .width(min: 34, ideal: 40)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let r = m.results.first(where: { ids.contains($0.id) }) {
                        Button("Connect to \(r.city) · \(r.route)") { m.connect(r) }
                        Button("Copy Route") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(r.place) \(r.route)", forType: .string)
                        }
                    }
                } primaryAction: { ids in
                    if let r = m.results.first(where: { ids.contains($0.id) }) { m.connect(r) }
                }
                .frame(minHeight: 180)
                Text("\(m.results.filter(\.works).count) of \(m.results.count) work").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var best: some View {
        let top = Array(m.best.prefix(3))
        return Group {
            if !top.isEmpty {
                Card("Best routes") {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(i == 0 ? Color.green : Color.secondary, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.place).font(.body.weight(.medium))
                                Text(m.backend.hasPorts ? "\(m.backend.protocolName(r.proto)) · port \(r.port)" : m.backend.protocolName(r.proto)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text([r.speed.map { String(format: "%.0f Mb/s", $0) }, r.avg.map { String(format: "%.0f ms", $0) }].compactMap { $0 }.joined(separator: " · "))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text("\(r.score ?? 0)").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(scoreColor(r.score ?? 0)).help(details(r))
                            Button("Connect") { m.connect(r) }.disabled(m.busy != nil || m.scanning)
                        }
                    }
                }
            }
        }
    }
}
