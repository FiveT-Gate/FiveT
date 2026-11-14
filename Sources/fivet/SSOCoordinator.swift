import AppKit
import Combine

/// Keeps the system-wide shortcuts of the SSO tab registered, and does what a shortcut asks: type the
/// entry's current one-time code into the app in front. Main thread only.
final class SSOCoordinator: ObservableObject {
    static let shared = SSOCoordinator()

    /// Per entry: why its shortcut does not work (macOS or another app owns it), for the Settings row.
    @Published private(set) var problems: [UUID: String] = [:]
    /// FiveT may type: it is allowed under Privacy & Security → Accessibility.
    @Published private(set) var typingAllowed = CodeTyper.isAllowed

    /// A code with less than this left is not typed: it could run out before the page checks it, and
    /// a rejected code counts as a failed login. The next one comes at most this long after.
    static let minimumSecondsLeft: TimeInterval = 2

    /// The "Try a shortcut" box of the SSO tab has the keyboard (the tab says so). The only place in
    /// FiveT's own windows where a code may be typed.
    var tryBoxHasKeyboard = false

    private let store = SSOStore.shared
    private var registered: [UUID: (token: UInt32, shortcut: KeyShortcut)] = [:]
    private var suspended = false
    private var busy = false
    private var askedForPermission = false
    private var cancellables = Set<AnyCancellable>()

    /// At launch: registers the shortcuts of the saved entries and follows every change to them.
    func start() {
        // objectWillChange-style: the hop through the main queue lands after the change.
        store.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        // Back from System Settings, where the permission is given.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermission() }
            .store(in: &cancellables)
        sync()
        let n = store.entries.filter { $0.shortcut != nil }.count
        Log.shared.write("SSO: \(store.entries.count) code(s), \(registered.count) of \(n) shortcut(s) active, typing \(typingAllowed ? "allowed" : "not allowed yet")")
    }

    func refreshPermission() {
        let allowed = CodeTyper.isAllowed
        if allowed != typingAllowed { typingAllowed = allowed }
    }

    /// While a shortcut is being recorded none may fire: pressing ⌥2 again to choose it must not type a code.
    func setSuspended(_ on: Bool) {
        guard suspended != on else { return }
        suspended = on
        sync()
    }

    /// Makes the registered shortcuts the ones the entries ask for.
    private func sync() {
        let hotKeys = GlobalHotKeys.shared
        let wanted: [UUID: KeyShortcut] = suspended ? [:]
            : Dictionary(store.entries.compactMap { e in e.shortcut.map { (e.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for (id, reg) in registered where wanted[id] != reg.shortcut {
            hotKeys.unregister(reg.token)
            registered[id] = nil
        }
        var failures: [UUID: String] = [:]
        for (id, shortcut) in wanted where registered[id] == nil {
            switch hotKeys.register(shortcut, action: { [weak self] in self?.fire(id) }) {
            case .success(let token):
                registered[id] = (token, shortcut)
            case .failure(let refused):
                // -9878 (eventHotKeyExistsErr): taken, by another entry or by macOS.
                let status = refused.status
                failures[id] = status == -9878 ? "Another app already uses \(shortcut.display)." : "macOS did not accept \(shortcut.display) (error \(status))."
                Log.shared.write("SSO: shortcut \(shortcut.display) was refused (status \(status))", level: .error)
            }
        }
        if failures != problems { problems = failures }
    }

    // MARK: A shortcut was pressed

    private func fire(_ id: UUID) {
        guard !busy, let entry = store.entry(id: id) else { return }
        guard TOTP.code(secret: entry.secret) != nil else {
            HUD.show("“\(displayName(entry))” has no usable secret", detail: "Open Settings → SSO and add it again.",
                     symbol: "exclamationmark.triangle.fill", tint: .systemOrange, seconds: 3)
            return
        }
        busy = true
        let left = TOTP.period - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: TOTP.period)
        guard left < Self.minimumSecondsLeft else { deliver(id); return }
        HUD.show(displayName(entry), detail: "Waiting for the next code…", symbol: "clock", tint: .secondaryLabelColor, seconds: left + 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.15) { [weak self] in self?.deliver(id) }
    }

    private func displayName(_ entry: SSOEntry) -> String { entry.name.trimmed.isEmpty ? "One-time code" : entry.name.trimmed }

    private func finish() {
        // Holding the shortcut repeats it; a short pause keeps one press from typing twice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.busy = false }
    }

    private func deliver(_ id: UUID) {
        // The entry as it is now: it may have been edited, or removed, while waiting for the next code.
        guard let entry = store.entry(id: id), let code = TOTP.code(secret: entry.secret) else { busy = false; return }
        let name = displayName(entry)
        // With FiveT itself in front, a code would land wherever its keyboard focus happens to be: in
        // the name of an entry, say. Only the Try box of the SSO tab is a place for one.
        let ownFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if ownFront && !(tryBoxHasKeyboard && SettingsRouter.shared.tab == .sso) {
            HUD.show("FiveT is in front", detail: "Switch to the app where you need the code, or click the Try box at the bottom of the SSO tab.",
                     symbol: "arrow.uturn.left.circle", tint: .secondaryLabelColor, seconds: 4)
            finish()
            return
        }
        guard CodeTyper.isAllowed else {
            refreshPermission()
            copyInstead(code, name: name)
            finish()
            return
        }
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front"
        DispatchQueue.global(qos: .userInteractive).async {
            CodeTyper.type(code)
            DispatchQueue.main.async {
                // The log never holds the code, or the secret: only that one was typed, and where.
                Log.shared.write("SSO: typed the code for “\(name)” into \(target)")
                HUD.show("\(name): code typed")
                self.finish()
            }
        }
    }

    /// Without the permission to type, the code goes to the clipboard for ⌘V (see SecretClipboard).
    private func copyInstead(_ code: String, name: String) {
        SecretClipboard.copy(code)
        Log.shared.write("SSO: copied the code for “\(name)” (FiveT is not allowed to type yet)")
        HUD.show("\(name): code copied", detail: "Press ⌘V to paste it. To have FiveT type it for you, allow FiveT under Privacy & Security → Accessibility.",
                 symbol: "doc.on.clipboard", tint: .systemOrange, seconds: 5)
        if !askedForPermission {
            askedForPermission = true
            CodeTyper.askForPermission()
        }
    }
}

/// Puts a code on the clipboard the careful way: marked so clipboard managers that follow
/// nspasteboard.org leave it out, and taken off again after the code's 30 seconds unless something
/// else was copied since (the clipboard is shared with the iPhone, other Macs and history tools).
enum SecretClipboard {
    static func copy(_ text: String, clearAfter seconds: TimeInterval = TOTP.period) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
