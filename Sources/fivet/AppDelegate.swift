import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var animTimer: Timer?
    private var animFrame = 0
    private var menuTimer: Timer?
    private var termSignal: DispatchSourceSignal?
    private var menuIsOpen = false
    /// fivet:// links that arrived before launch finished (a link can be what starts FiveT).
    private var launched = false
    private var pendingLinks: [URL] = []

    private let store = ConnectionStore.shared
    private let vpn = VPNManager.shared

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A copy that updated to 1.16.0 (when the app was called FiveX) renames itself back first, before anything starts.
        if AppRename.renameIfNeeded() { NSApp.terminate(nil); return }
        AppRename.finish()
        installMainMenu()
        // A new menu bar item goes to the left end of the others, which on a Mac with a notch can
        // be behind the notch, and FiveT starts anew after every update. A VPN's status belongs next
        // to Control Center, among the system icons. macOS keeps a named item's place under this key,
        // as its distance from the screen's right edge (1: as far right as it goes, left of Control
        // Center; 0 counts as no place at all), and saves it again when the user ⌘-drags the icon:
        // this only sets where FiveT starts until then. macOS 27 ignores the place of an unnamed
        // item ("Item-0"); one the user chose under that name before is kept.
        let defaults = UserDefaults.standard
        let placeKey = "NSStatusItem Preferred Position FiveT"
        if defaults.object(forKey: placeKey) == nil {
            defaults.set(defaults.object(forKey: "NSStatusItem Preferred Position Item-0") ?? 1, forKey: placeKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "FiveT"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // objectWillChange fires before the change; the hop through the main queue lands after it.
        vpn.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        store.$showNameInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .windscribeScanChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        // MCP server for AI assistants: follows the switch in Settings → MCP.
        store.$mcpEnabled
            .receive(on: DispatchQueue.main)
            .sink { on in on ? MCPServer.shared.start() : MCPServer.shared.stop() }
            .store(in: &cancellables)

        // SIGTERM (`kill`, `pkill -x FiveT` in build.sh --install) would end the app on the spot,
        // leaving its tunnels running as root and its /etc/resolver files behind. Quit normally instead.
        // A handler that does nothing, not SIG_IGN: an ignored signal stays ignored in every process
        // FiveT starts (sudo, openfortivpn, which is stopped with SIGTERM); a handler ends at exec.
        signal(SIGTERM) { _ in }
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            Log.shared.write("SIGTERM received; quitting")
            NSApp.terminate(nil)
        }
        term.resume()
        termSignal = term

        Log.shared.write("FiveT launched from \(Bundle.main.bundlePath)")
        Log.shared.scrubOldSecrets()
        // A certificate question from a click goes to the person who clicked, at once.
        // Questions run from the run loop, not from a main-queue block: a modal alert inside a block
        // would hold up the main queue (tunnel output, assistants' calls) until it is answered. The
        // default mode also waits until a menu has closed.
        vpn.onReviewNeeded = { [weak self] id in
            RunLoop.main.perform(inModes: [.default]) { CertReview.present(id, over: self?.settingsWindow?.isKeyWindow == true ? self?.settingsWindow : nil) }
        }
        // So does the question whether to log in again after failed logins (LoginGuard).
        vpn.onLoginLimit = { [weak self] id in
            RunLoop.main.perform(inModes: [.default]) { self?.askToLogInAgain(id) }
        }
        vpn.detectExistingSession()
        // FiveT had an SSO tab (one-time codes on keyboard shortcuts) until 1.11.1: its saved codes
        // are deleted once, so their secrets do not stay behind on the Mac.
        Self.removeSSOLeftovers()
        refreshIcon()
        // Links that started FiveT (or came during launch) run once the tunnels already up have been
        // found and the helper check says whether FiveT is set up.
        vpn.whenSetupKnown { [weak self] in
            guard let self else { return }
            self.launched = true
            let early = self.pendingLinks
            self.pendingLinks = []
            early.forEach(self.handleLink)
        }
        // A ready update restarts FiveT only when that interrupts nothing: no tunnel up, starting
        // or reconnecting, and neither the menu, Settings nor a certificate review open.
        Updater.shared.isBusy = { [weak self] in
            guard let self else { return true }
            return !self.vpn.sessions.isEmpty || self.menuIsOpen || (self.settingsWindow?.isVisible ?? false) || CertReview.isOpen
        }
        Updater.shared.startPeriodicChecks()
        // First start on a Mac FiveT was never set up on: Settings opens on General, where "Set Up
        // FiveT" is the first thing, so a new user finds the one step without looking for it. Not
        // with a debug flag (those drive the window themselves).
        if CommandLine.arguments.count == 1 {
            DispatchQueue.global(qos: .userInitiated).async {
                let fresh = Setup.helperState() == .missing
                DispatchQueue.main.async { [weak self] in
                    if fresh { Log.shared.write("first start on this Mac: showing Set Up FiveT"); self?.showSettings(tab: .general) }
                }
            }
        }

        // Debug helpers: `open FiveT.app --args --setup` opens Settings directly.
        let args = CommandLine.arguments
        if args.contains("--setup") { showSettings(tab: .general) }
        else if args.contains("--settings") {
            // `--settings windscribe` (or `expressvpn`) opens the VPN tab on Windscribe Max (with FIVET_WINDSCRIBE_CLI=none in a test copy: its "not installed" screen).
            if args.contains("windscribe") { SettingsRouter.shared.picked[.openvpn] = WindscribeMax.rowID; showSettings(tab: .openvpn) }
            else if args.contains("expressvpn") { SettingsRouter.shared.picked[.openvpn] = WindscribeMax.expressRowID; showSettings(tab: .openvpn) }
            else if args.contains("smart") { SettingsRouter.shared.picked[.openvpn] = SmartConnect.rowID; showSettings(tab: .openvpn) }
            else { showSettings(tab: .connections) }
        }
        // `--self-update` (test hook): check the feed and install whatever newer version it names at once.
        if args.contains("--self-update") {
            Updater.shared.$state.receive(on: DispatchQueue.main).sink { st in
                switch st {
                case .available, .ready: Updater.shared.installNow()
                case .upToDate: Log.shared.write("self-update: already current")
                case .failed(let m): Log.shared.write("self-update: \(m)", level: .error)
                default: break
                }
            }.store(in: &cancellables)
            Updater.shared.check()
        }
        // `--dump-settings [connections|openvpn|smart|windscribe|general|mcp]` renders the Settings window (title bar
        // included) on that tab (General by default) to a PNG and quits; used to check the window
        // layout without Screen Recording permission.
        if let i = args.firstIndex(of: "--dump-settings") {
            let name = args.dropFirst(i + 1).first
            let named: [String: SettingsTab] = ["mcp": .assistants, "connections": .connections, "forti": .connections, "smart": .openvpn, "openvpn": .openvpn, "windscribe": .openvpn, "expressvpn": .openvpn]
            if name == "windscribe" { SettingsRouter.shared.picked[.openvpn] = WindscribeMax.rowID }   // the VPN tab with Windscribe Max picked
            if name == "expressvpn" { SettingsRouter.shared.picked[.openvpn] = WindscribeMax.expressRowID }
            if name == "smart" { SettingsRouter.shared.picked[.openvpn] = SmartConnect.rowID }
            showSettings(tab: name.flatMap { named[$0] } ?? .general)
            // FIVET_DUMP_HEIGHT=1400: a taller window, to see the bottom of a long form in one picture.
            if let h = ProcessInfo.processInfo.environment["FIVET_DUMP_HEIGHT"].flatMap(Double.init), let w = settingsWindow {
                w.setContentSize(NSSize(width: w.contentLayoutRect.width, height: h))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                if let w = settingsWindow, let frame = w.contentView?.superview,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    let path = NSTemporaryDirectory() + "fivet-settings.png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    Log.shared.write("settings window dump → \(path)")
                }
                NSApp.terminate(nil)
            }
        }
        // `--measure-settings` opens Settings, closes it again, logs the memory footprint at the start, with
        // the window open, 2 s after closing it and 30 s after ("settings memory: …"), and quits: what
        // Settings costs and gives back, and how much of that is still coming back a while later. In
        // between it opens the window again after the close, again in the very turn it was closed, and
        // five more times ("settings lifecycle: …"): it must come back whole each time.
        if args.contains("--measure-settings") {
            let start = Self.footprintMB()
            showSettings(tab: .connections)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [self] in
                let open = Self.footprintMB()
                settingsWindow?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                    let closed = Self.footprintMB()
                    let whole = { [self] in settingsWindow?.isVisible == true && settingsWindow?.contentViewController != nil }
                    var results: [String] = []
                    func finish() {
                        let cycled = Self.footprintMB()
                        settingsWindow?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 28.0) {
                            Log.shared.write(String(format: "settings memory: start %.1f MB, open %.1f MB, closed %.1f MB, open after 7 openings %.1f MB, 30 s later %.1f MB",
                                                    start, open, closed, cycled, Self.footprintMB()))
                            Log.shared.write("settings lifecycle: " + results.joined(separator: ", "))
                            NSApp.terminate(nil)
                        }
                    }
                    func cycle(_ n: Int) {
                        guard n > 0 else { results.append("5 more cycles " + (results.contains { $0.contains("BROKEN") } ? "BROKEN" : "ok")); finish(); return }
                        settingsWindow?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                            showSettings(tab: n % 2 == 0 ? .general : .connections)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                if !whole() { results.append("cycle \(n) BROKEN") }
                                cycle(n - 1)
                            }
                        }
                    }
                    showSettings(tab: .general)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
                        results.append("reopen after close " + (whole() ? "ok" : "BROKEN"))
                        settingsWindow?.close()
                        showSettings(tab: .connections)   // closed and opened again in one turn
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            results.append("reopen in the same turn " + (whole() ? "ok" : "BROKEN"))
                            cycle(5)
                        }
                    }
                }
            }
        }
        // `--time-tabs` switches the Settings tabs a few times and logs, per switch, the longest time
        // the main thread did not answer: that is how long the window (and the tab animation) froze.
        if args.contains("--time-tabs") {
            showSettings(tab: .connections)
            let order: [SettingsTab] = [.general, .assistants, .connections, .general, .assistants, .connections,
                                        .general, .assistants, .connections]
            let lock = NSLock()
            var worst = 0.0
            Thread.detachNewThread {
                while true {
                    let sent = CACurrentMediaTime()
                    let answered = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { answered.signal() }
                    answered.wait()
                    let wait = CACurrentMediaTime() - sent
                    lock.lock(); worst = max(worst, wait); lock.unlock()
                    usleep(2000)
                }
            }
            func step(_ i: Int, _ results: [String]) {
                guard i < order.count else {
                    Log.shared.write("tab switch timing: " + results.joined(separator: ", "))
                    NSApp.terminate(nil); return
                }
                lock.lock(); worst = 0; lock.unlock()
                SettingsRouter.shared.tab = order[i]
                // The switch itself, then 1.2 s of doing nothing on that tab (timers, redraws).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    lock.lock(); let w = worst; worst = 0; lock.unlock()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        lock.lock(); let idle = worst; lock.unlock()
                        step(i + 1, results + ["\(order[i]) \(Int(w * 1000))/\(Int(idle * 1000)) ms"])
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { step(0, []) }
        }
        // `--dump-menu` writes the menu-bar menu's lines to the log ("--" a separator, "## " a
        // section title, "(off)" a greyed-out line, "[icon]" a line with a picture) and quits: the menu's layout without a screenshot.
        if args.contains("--dump-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                rebuildMenu()
                let lines = menu.items.map { i -> String in
                    if i.isSeparatorItem { return "--" }
                    if #available(macOS 14, *), i.isSectionHeader { return "## " + i.title }
                    return i.title + (i.isEnabled ? "" : " (off)") + (i.attributedTitle == nil ? "" : " [icon]")
                }
                let appItems = NSApp.mainMenu?.items.first?.submenu?.items ?? []
                let appLines = appItems.map { i -> String in
                    if i.isSeparatorItem { return "--" }
                    let pictured = i.attributedTitle != nil || i.image != nil
                    return i.title + (pictured ? " [icon]" : "")
                }
                Log.shared.write("menu dump:\n" + lines.joined(separator: "\n") + "\napp menu (top of the screen):\n" + appLines.joined(separator: "\n"))
                NSApp.terminate(nil)
            }
        }
        // `--pop-menu` opens the menu-bar menu at a fixed spot on screen after launch (the icon itself may be hidden in a full menu bar), to take a picture of it with screencapture.
        if args.contains("--pop-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                rebuildMenu()
                menu.popUp(positioning: nil, at: NSPoint(x: 300, y: 800), in: nil)
            }
        }
        if args.contains("--dump-statusitem") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard let b = statusItem.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return }
                b.cacheDisplay(in: b.bounds, to: rep)
                let path = NSTemporaryDirectory() + "fivet-statusitem.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                if let cv = b.window?.contentView, let wrep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                    cv.cacheDisplay(in: cv.bounds, to: wrep)
                    try? wrep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "fivet-window.png"))
                    Log.shared.write("statusitem window dump: contentView \(cv.bounds) button frame \(b.frame) superview \(String(describing: b.superview?.frame))")
                }
                Log.shared.write("statusitem dump: bounds \(b.bounds) window \(b.window?.frame ?? .zero) image \(b.image?.size ?? .zero) length \(statusItem.length) alignment \(b.alignment.rawValue) imagePosition \(b.imagePosition.rawValue) → \(path)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServer.shared.stop()   // removes the socket file so a bridge never waits on a dead app
        vpn.shutdownCleanup()     // never leave /etc/resolver files behind
        Updater.shared.installAtQuit()
        store.flush()             // a settings change from the last half second
        MainActor.assumeIsolated { WindscribeMax.all.forEach { $0.stopForQuit() } }   // never leave a built-in VPN on a scan's test route
        MainActor.assumeIsolated { SmartConnect.shared.stopForQuit() }
    }

    /// sso.json, and any sso.unreadable-*.json set aside from it, in FiveT's data folder.
    private static func removeSSOLeftovers() {
        let fm = FileManager.default
        let dir = ConnectionStore.shared.directory
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name == "sso.json" || (name.hasPrefix("sso.unreadable-") && name.hasSuffix(".json")) {
            do {
                try fm.removeItem(at: dir.appendingPathComponent(name))
                Log.shared.write("removed \(name): FiveT no longer has SSO codes")
            } catch {
                Log.shared.write("could not remove \(name): \(error.localizedDescription)", level: .error)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vpn.isRunning else { return .terminateNow }
        Log.shared.write("quit requested while connected; disconnecting all tunnels first")
        vpn.disconnect()
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while vpn.isRunning && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }
        wait(6)
        if vpn.isRunning {
            // Quitting now would leave a root openfortivpn behind with no app to stop it.
            vpn.forceStopAll()
            wait(2)
        }
        return .terminateNow
    }

    // MARK: Menu bar icon

    /// The SF Symbol rendered into a plain template image. Handed a symbol image directly,
    /// macOS 26's status-bar button lays it out on the symbol's font metrics (a 10.5-pt
    /// alignment rect at this size) and clips the glyph to that rect on a 1x display, so the
    /// top and bottom of the shield were cut off on external monitors. A bitmap-backed image
    /// is laid out on its full 17×18 size on every screen; it still draws at 2x on Retina.
    private func symbol(_ name: String) -> NSImage? {
        // The not-connected shield is an outline: at medium weight its hairline stroke is hard
        // to see in the menu bar, so outline shapes get a heavier stroke than the filled ones.
        let outline = name == "shield" || name == "shield.lefthalf.filled"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: outline ? .heavy : .medium)
        guard let src = NSImage(systemSymbolName: name, accessibilityDescription: "FiveT")?
            .withSymbolConfiguration(cfg) else { return nil }
        let img = NSImage(size: src.size, flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "FiveT"
        return img
    }

    /// A solid shield with a magnifying glass cut out of it: the icon while Windscribe Max scans. Cut out
    /// (not drawn over), so it stays a template image that follows the menu bar's colours. It sits on the
    /// 17 × 20 pt canvas of the "off" icon (shield.slash.fill) at the same height. The off icon looks bigger than
    /// its 12.1 × 14.6 pt shield, because its slash reaches out to 14.9 × 14.9 pt, so this shield is drawn
    /// 6% larger than a plain one (15 pt symbols, measured through `symbol()`): about 13 × 15.4 pt. It is
    /// a larger symbol, not a scaled picture: scaling blurred its edges.
    private func scanningSymbol() -> NSImage? {
        let k: CGFloat = 1.06
        guard let reference = NSImage(systemSymbolName: "shield.slash.fill", accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)),
              let shield = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "FiveT")?
                  .withSymbolConfiguration(.init(pointSize: 15 * k, weight: .medium)),
              let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: 8 * k, weight: .heavy)) else { return nil }
        let centre = CGPoint(x: 8.81, y: 9.56 + 0.47 * k)   // the shield's own box is a little off-centre from its ink
        let img = NSImage(size: reference.size, flipped: false) { _ in
            shield.draw(in: NSRect(x: centre.x - shield.size.width / 2, y: centre.y - shield.size.height / 2,
                                   width: shield.size.width, height: shield.size.height))
            let g = glass.size
            glass.draw(in: NSRect(x: centre.x - g.width / 2, y: centre.y - g.height / 2, width: g.width, height: g.height),
                       from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "FiveT"
        return img
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let scanning = MainActor.assumeIsolated { WindscribeMax.scanActive }
        let all = vpn.sessions
        // Waiting for the network can last a whole flight, and the pause before a retry a whole night
        // for a gateway that is down: those hold still (see below), they do not animate.
        let resting: (VPNStatus) -> Bool = { $0.waitingForNetwork || $0.waitingToRetry }
        // A scan has its own icon: the tunnels it ends do not animate over it.
        let busy = scanning ? nil : all.first { ($0.phase == .connecting && !resting($0)) || $0.phase == .disconnecting }
        let offline = all.first(where: resting)
        let up = all.filter { $0.phase == .connected }.compactMap(\.connectionName)
        if busy == nil { animTimer?.invalidate(); animTimer = nil }
        button.contentTintColor = nil
        var title = ""
        var tip = "FiveT — not connected"

        if scanning {
            button.image = scanningSymbol() ?? symbol("shield.fill")
            tip = "FiveT — \(MainActor.assumeIsolated { WindscribeMax.all.first(where: \.scanning)?.backend.title } ?? "a built-in VPN") is scanning for routes that work"
        } else if let busy {
            // One tunnel changing state animates the icon even while another is up. A running
            // animation keeps going: restarting it on every progress line pinned it to frame 0.
            if animTimer == nil {
                animFrame = 0
                let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.tickAnimation() }
                t.tolerance = 0.07   // lets macOS fold the tick into a wake-up it makes anyway
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
                tickAnimation()
            }
            tip = busy.phase == .connecting ? "FiveT — connecting to \(busy.connectionName ?? "VPN")…"
                                            : "FiveT — disconnecting \(busy.connectionName ?? "")…"
            if store.showNameInMenuBar && !up.isEmpty { title = " " + up.joined(separator: " + ") }
        } else if !up.isEmpty {
            button.image = symbol("checkmark.shield.fill")
            let names = up.joined(separator: " + ")
            tip = "FiveT — connected to \(names)"
            if store.showNameInMenuBar { title = " " + names }
        } else if let offline {
            button.image = symbol("shield.lefthalf.filled")
            tip = offline.waitingForNetwork ? "FiveT — \(offline.connectionName ?? "VPN"): waiting for the network to reconnect"
                                            : "FiveT — \(offline.connectionName ?? "VPN"): \(offline.detail ?? "waiting to reconnect")"
        } else if let err = vpn.lastError {
            button.image = symbol("exclamationmark.shield.fill")
            button.contentTintColor = .systemRed
            tip = "FiveT — \(err)"
        } else {
            // Off is a solid shield with a slash: a filled shape reads at menu bar size, an outline does not.
            button.image = symbol("shield.slash.fill")
        }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        // Icon-only: make the slot barely wider than the glyph, like other third-party icons.
        statusItem.length = title.isEmpty ? ((button.image?.size.width ?? 18) + 1) : NSStatusItem.variableLength
        button.toolTip = tip
    }

    private func tickAnimation() {
        let frames = ["shield", "shield.lefthalf.filled", "shield.fill", "shield.lefthalf.filled"]
        statusItem.button?.image = symbol(frames[animFrame % frames.count])
        animFrame += 1
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu !== self.menu {   // the FiveT menu at the top of the screen: only its Smart Connect line changes
            for item in menu.items where item.action == #selector(smartConnect) { showSmartConnectTitle(item, smartConnectTitle()) }
            return
        }
        rebuildMenu()
        menuTimer?.invalidate()
        var ticks = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            ticks += 1
            self?.refreshLiveTitles()
            if ticks % 4 == 0 { self?.askBuiltIn() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        menuTimer = t
        askBuiltIn()
    }

    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { menuIsOpen = true } }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }   // not the FiveT menu at the top of the screen
        menuIsOpen = false
        menuTimer?.invalidate(); menuTimer = nil
        vpn.clearError()
    }

    /// A small template SF Symbol for a menu line, drawn in the menu's text colour.
    /// Bitmap-backed, like the menu bar icon (see `symbol()`): handed a symbol image directly, the menu did not
    /// draw the lightning bolt of Smart Connect on the developer's Mac, while the bitmap dots of the VPN lines show.
    private func menuSymbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let src = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let img = NSImage(size: src.size, flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func title(for c: Connection) -> String {
        guard let st = vpn.status(for: c.id) else { return c.name }
        switch st.phase {
        case .connected:
            return "\(c.name) — Connected \(durationText(st.since))" + (st.health.map { " · \($0)" } ?? "")
        case .connecting:
            return "\(c.name) — \(st.detail ?? "Connecting…")"
        case .disconnecting:
            return "\(c.name) — Disconnecting…"
        case .idle:
            return c.name
        }
    }

    /// A menu line for one saved connection: its state as a coloured dot and in the title.
    private func connectionItem(_ c: Connection) -> NSMenuItem {
        let item = NSMenuItem(title: title(for: c), action: #selector(toggleConnection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = c.id
        item.toolTip = c.username.isEmpty ? c.gatewayDescription : "\(c.gatewayDescription)  ·  \(c.username)"
        let st = vpn.status(for: c.id)
        let color: NSColor
        switch st?.phase {
        case .connected: color = .systemGreen
        case .connecting, .disconnecting: color = .systemOrange
        default: color = .tertiaryLabelColor
        }
        item.isEnabled = st?.phase != .disconnecting
        decorate(item, dot(color))
        return item
    }

    /// A section title in the menu ("Forti", "My VPNs", "Built in"): macOS 14's small grey heading, or on
    /// macOS 13 a greyed-out line.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func durationText(_ since: Date?) -> String {
        guard let since else { return "" }
        return VPNStatus.durationText(Int(Date().timeIntervalSince(since)))
    }

    /// The built-in services' lines in the menu, under "Built in": just the name, whatever the service is doing. A service
    /// has no line at all unless its app and command line are on this Mac and it is not known to be signed out.
    private func builtInItems() -> [NSMenuItem] {
        MainActor.assumeIsolated {
            WindscribeMax.all.compactMap { m -> NSMenuItem? in
                guard m.backend.installState() == .ready, m.status?.isLoggedIn != false else { return nil }
                let item = NSMenuItem(title: m.backend.menuName, action: #selector(toggleBuiltIn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.rowID
                showBuiltInState(item, m)
                return item
            }
        }
    }

    /// The dot (green connected, orange busy, grey off) and whether a click is possible.
    @MainActor private func showBuiltInState(_ item: NSMenuItem, _ m: WindscribeMax) {
        item.isEnabled = !m.scanning && m.busy == nil
        item.title = m.backend.menuName   // the plain title again: this runs every second, and `decorate` builds on the title
        decorate(item, dot(m.connected ? .systemGreen : m.scanning || m.busy != nil || m.status?.isConnecting == true ? .systemOrange : .tertiaryLabelColor))
    }

    private var askingBuiltIn = false

    /// While the menu is open: asks each service for its state, so the dots are right a moment after it opens.
    private func askBuiltIn() {
        guard !askingBuiltIn, menu.items.contains(where: { $0.action == #selector(toggleBuiltIn(_:)) }) else { return }
        askingBuiltIn = true
        Task { @MainActor in
            defer { askingBuiltIn = false }
            for m in WindscribeMax.all where !m.scanning && m.busy == nil && m.backend.installState() == .ready { await m.refresh() }
        }
    }

    @objc private func toggleBuiltIn(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let m = WindscribeMax.service(for: sender.representedObject as? UUID) else { return }
            if m.connected || m.status?.isConnecting == true { m.disconnect() } else { m.connect() }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let conns = store.connections
        let sessions = vpn.sessions

        let builtIn = builtInItems()
        if conns.isEmpty && builtIn.isEmpty {
            let i = NSMenuItem(title: "No connections yet — open Settings", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        // Each connection shows its own state; clicking one connects it (a VPN that was up is
        // disconnected: one VPN at a time, next to Forti), or disconnects it. With an OpenVPN connection
        // saved, the menu has sections, like Settings: Forti, My VPNs, then Built in (Windscribe, ExpressVPN).
        let forti = conns.filter { !$0.isOtherVPN }
        let openvpn = conns.filter(\.isOtherVPN)   // OpenVPN and V2Ray
        let ext = sessions.first(where: { $0.connectionID == nil })   // an openfortivpn started outside FiveT
        if (!openvpn.isEmpty || !builtIn.isEmpty) && (!forti.isEmpty || ext != nil) { menu.addItem(sectionHeader("Forti")) }
        forti.forEach { menu.addItem(connectionItem($0)) }
        if let ext {
            let item = NSMenuItem(title: "Stop: \(ext.connectionName ?? "openfortivpn session")", action: #selector(disconnectAll), keyEquivalent: "")
            item.target = self
            item.isEnabled = ext.phase == .connected
            decorate(item, dot(ext.phase == .connected ? .systemGreen : .systemOrange))
            menu.addItem(item)
        }
        if !openvpn.isEmpty {
            if !forti.isEmpty || ext != nil { menu.addItem(.separator()) }
            menu.addItem(sectionHeader("My VPNs"))
            openvpn.forEach { menu.addItem(connectionItem($0)) }
        }
        if !builtIn.isEmpty {
            if !conns.isEmpty || ext != nil { menu.addItem(.separator()) }
            menu.addItem(sectionHeader("Built in"))
            builtIn.forEach { menu.addItem($0) }
        }

        if ConnectionStore.shared.appsOnly, !ConnectionStore.shared.vpnApps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Open with VPN"))
            for path in ConnectionStore.shared.vpnApps {
                let i = NSMenuItem(title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                   action: #selector(openAppThroughVPN(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = path
                i.isEnabled = vpn.appProxyReady
                decorate(i, NSWorkspace.shared.icon(forFile: path).resized(to: NSSize(width: 16, height: 16)))
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())

        if vpn.killSwitchActive {
            // The kill switch is blocking the Mac's internet: said here, with the way out.
            let i = NSMenuItem(title: "Internet Blocked by Kill Switch: Unblock Internet", action: #selector(unblockInternet), keyEquivalent: "")
            i.target = self
            decorate(i, menuSymbol("lock.shield"))
            i.toolTip = "The VPN is down and nobody switched it off, so FiveT lets nothing leave the Mac. Connecting again, disconnecting, or this line lifts the block."
            menu.addItem(i)
        }
        if let err = vpn.lastError {
            // One short line: the first sentence. The whole message is in the tooltip and, for a
            // connection, under it on its tab in Settings (Forti or VPN), which a click opens.
            // Its own action: with openSettings macOS would draw its Settings gear in front of it.
            let i = NSMenuItem(title: "⚠︎ \(Self.headline(err))", action: #selector(showErrorDetails), keyEquivalent: "")
            i.target = self
            i.toolTip = err
            menu.addItem(i)
        }
        // A gateway certificate that changed and waits for the user's decision (CertReview).
        let changed = conns.filter(\.hasPendingReview)
        for c in changed {
            let i = NSMenuItem(title: c.pendingCertFirst ? "Review Certificate for \(c.name)…" : "Review New Certificate for \(c.name)…",
                               action: #selector(reviewCertificate(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = c.id
            decorate(i, menuSymbol("exclamationmark.shield"))
            menu.addItem(i)
        }
        if vpn.needsSetup {
            let i = NSMenuItem(title: "Set Up FiveT…", action: #selector(setUp), keyEquivalent: "")
            i.target = self
            i.isEnabled = !SetupFlow.shared.working
            menu.addItem(i)
        }
        if vpn.killSwitchActive || vpn.lastError != nil || vpn.needsSetup || !changed.isEmpty { menu.addItem(.separator()) }

        // Smart Connect (the lightning bolt) has a section of its own above Settings, once there is a VPN to choose from.
        if !openvpn.isEmpty || !builtIn.isEmpty {
            let smart = NSMenuItem(title: "Smart Connect", action: #selector(smartConnect), keyEquivalent: "")
            smart.target = self
            showSmartConnectTitle(smart, smartConnectTitle())
            smart.toolTip = "Tests every VPN that is switched on in Settings → Smart Connect and connects the one with the best score."
            menu.addItem(smart)
            menu.addItem(.separator())
        }

        // Settings and Quit share the last section, plain text, no icons.
        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// The first sentence of a message, cut at a word to at most `limit` characters: FiveT's
    /// messages lead with what happened ("Login failed.") and follow with what to do.
    static func headline(_ text: String, limit: Int = 60) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: ". ") { s = String(s[..<r.lowerBound]) + "." }
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// Updates the "Connected 1:23" / TOTP countdown text while the menu is open.
    private func refreshLiveTitles() {
        for item in menu.items where item.action == #selector(toggleConnection(_:)) {
            guard let id = item.representedObject as? UUID, let c = store.connection(id: id) else { continue }
            if item.action == #selector(toggleConnection(_:)) {
                item.title = title(for: c)
                let st = vpn.status(for: id)
                decorate(item, dot(st?.phase == .connected ? .systemGreen : st?.phase == .connecting || st?.phase == .disconnecting ? .systemOrange : .tertiaryLabelColor))
            }
        }
        for item in menu.items where item.action == #selector(toggleBuiltIn(_:)) {
            MainActor.assumeIsolated { if let m = WindscribeMax.service(for: item.representedObject as? UUID) { showBuiltInState(item, m) } }
        }
        for item in menu.items where item.action == #selector(smartConnect) { showSmartConnectTitle(item, smartConnectTitle()) }
    }

    /// Puts `picture` in front of the item's title, as part of the text. macOS 27 on the developer's Mac draws no `image` of a
    /// menu item (only its own, like the gear of Settings): the dots that say which VPN is up, the lightning bolt
    /// of Smart Connect and the warning shields were all invisible. A picture inside the text is drawn. Call it
    /// after the title and `isEnabled` are set.
    private func decorate(_ item: NSMenuItem, _ picture: NSImage?) {
        guard let picture else { item.attributedTitle = nil; return }
        let font = NSFont.menuFont(ofSize: 0)
        let attachment = NSTextAttachment()
        attachment.image = picture
        // Centred on the capital letters of the title.
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - picture.size.height) / 2).rounded(), width: picture.size.width, height: picture.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        var look: [NSAttributedString.Key: Any] = [.font: font]
        if !item.isEnabled { look[.foregroundColor] = NSColor.disabledControlTextColor }
        text.append(NSAttributedString(string: "  " + item.title, attributes: look))
        item.attributedTitle = text
    }

    private func showSmartConnectTitle(_ item: NSMenuItem, _ title: String) {
        item.title = title
        decorate(item, menuSymbol("bolt.fill"))
    }

    /// "Smart Connect", or while a run goes on, what it is doing (a click then stops it).
    private func smartConnectTitle() -> String {
        MainActor.assumeIsolated { SmartConnect.shared.running ? "Stop Smart Connect — \(SmartConnect.shared.step)" : "Smart Connect" }
    }

    @objc private func smartConnect() {
        MainActor.assumeIsolated {
            let smart = SmartConnect.shared
            if smart.running { smart.stop() } else { smart.start() }
        }
    }

    // MARK: Actions

    @objc private func toggleConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let c = store.connection(id: id) else { return }
        // Stopping never waits for a setup. What waits for one is a connect by id: connect() does
        // nothing for a tunnel already starting, so a second click during the password prompt does
        // not undo the first, and it uses the connection as it is by then.
        if let st = vpn.status(for: id), st.phase == .connected || st.phase == .connecting {
            vpn.toggle(c)
        } else {
            whenSetUp { [vpn, store] in if let c = store.connection(id: id) { vpn.connect(c, byUser: true) } }
        }
    }

    @objc private func openAppThroughVPN(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // After the menu has closed: an alert opened from inside a menu action blocks the menu's tracking.
        DispatchQueue.main.async {
            guard let problem = VPNManager.shared.openThroughVPN(path) else { return }
            let a = NSAlert()
            a.messageText = "Could not open the app through the VPN"
            a.informativeText = problem
            a.runModal()
        }
    }

    @objc private func unblockInternet() {
        vpn.releaseKillSwitch()
    }

    @objc private func reviewCertificate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        // After the menu has closed: an alert opened from inside a menu action blocks the menu's tracking.
        RunLoop.main.perform(inModes: [.default]) { CertReview.present(id, over: nil) }
    }

    /// A connect click on a Mac that is not set up yet sets it up first (one password prompt) and
    /// then connects; if the setup fails, Settings shows why.
    private func whenSetUp(_ action: @escaping () -> Void) {
        SetupFlow.shared.whenReady(action, failed: { [weak self] in self?.showSettings(tab: .general) })
    }

    @objc private func disconnectAll() {
        vpn.disconnect()
    }

    // MARK: fivet:// links

    /// When each connection (or "all") was last acted on by a link: repeats within a few seconds
    /// are dropped, so a page cannot flip tunnels on and off in a loop.
    private var lastLinkAction: [String: Date] = [:]

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingLinks += urls; return }
        urls.forEach(handleLink)
    }

    /// Does what the link asks, as the same click in the menu would, within what LinkCommand allows.
    /// Any web page can open a link, so: a connect always asks first, a name must match exactly, a
    /// link never starts FiveT's setup, and nothing from the link is shown in FiveT's menu (a page
    /// could write whatever it likes there).
    private func handleLink(_ url: URL) {
        let command: LinkCommand
        do { command = try LinkCommand.parse(url) } catch {
            Log.shared.write("link refused: \(Self.sanitized(url.absoluteString)) — \((error as? LinkCommand.Failure)?.message ?? "\(error)")", level: .error)
            vpn.report("FiveT could not follow a fivet:// link. Links look like fivet://connect/<name>; see the log.")
            return
        }
        Log.shared.write("link: \(Self.sanitized(url.absoluteString))")
        if case .settings = command { showSettings(tab: .connections); return }

        let conns = store.connections
        func named(_ name: String) -> Connection? {
            if let c = ConnectionStore.findExact(name, in: conns) { return c }
            Log.shared.write("link asked for “\(Self.sanitized(name))”, which is not the exact name of a connection", level: .error)
            vpn.report("A fivet:// link named a connection FiveT does not have. Links need the exact name shown in FiveT's menu.")
            return nil
        }
        func tooSoon(_ key: String) -> Bool {
            let now = Date()
            if let last = lastLinkAction[key], now.timeIntervalSince(last) < 3 {
                Log.shared.write("link ignored: another link acted on the same connection a moment ago", level: .debug)
                return true
            }
            lastLinkAction[key] = now
            return false
        }
        func connect(_ c: Connection) {
            guard !vpn.needsSetup else {
                vpn.report("FiveT is not set up yet. A fivet:// link asked to connect \(c.name): choose Set Up FiveT… in FiveT's menu first.")
                return
            }
            let id = c.id
            confirmLinkConnect(c) { [vpn, store] in if let c = store.connection(id: id) { vpn.connect(c) } }
        }
        switch command {
        case .settings:
            break
        case .connect(let name):
            guard let c = named(name) else { return }
            if let st = vpn.status(for: c.id), st.phase == .connected || st.phase == .connecting {
                Log.shared.write("link: \(c.name) is already \(st.stateName)", level: .debug)   // nothing to ask
                return
            }
            if !tooSoon(c.id.uuidString) { connect(c) }
        case .disconnect(nil):
            if !tooSoon("all") { vpn.disconnect() }
        case .disconnect(let name?):
            if let c = named(name), !tooSoon(c.id.uuidString) { vpn.disconnect(id: c.id) }
        case .toggle(let name):
            guard let c = named(name), !tooSoon(c.id.uuidString) else { return }
            if let st = vpn.status(for: c.id), st.phase == .connected || st.phase == .connecting { vpn.toggle(c) } else { connect(c) }
        }
    }

    /// Gateways whose Try Anyway question is open: one question per gateway at a time, so two
    /// connections to it (Connect All) cannot each get their extra login.
    private var askingAboutGateway = Set<String>()

    /// A click on a connection whose last logins failed (LoginGuard) asks before one more: the next
    /// failure gets this network's internet address banned at the gateway for hours, for everyone on
    /// the network. Open Settings is the default; Try Anyway allows exactly one login, at the count
    /// the question showed.
    private func askToLogInAgain(_ id: UUID) {
        guard let c = store.connection(id: id) else { return }
        let key = c.loginGuardKey
        let failed = LoginGuard.shared.count(for: key)
        guard failed >= LoginGuard.limit else {
            vpn.connect(c, byUser: true)   // a login got through meanwhile: nothing to ask
            return
        }
        guard !askingAboutGateway.contains(key) else {
            Log.shared.write("[\(c.name)] the question about \(key) is already open; not asking twice")
            return
        }
        askingAboutGateway.insert(key)
        defer { askingAboutGateway.remove(key) }

        let sharing = store.connections.filter { $0.loginGuardKey == key }.map(\.name)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The last \(failed) logins to \(c.name)'s gateway failed"
        var info = "One more failed login and the gateway (\(c.endpoint.host)) bans this network's internet address for a few hours: "
            + "nobody on this network can connect to it then, on any computer. "
            + "Check the password and the one-time code in Settings → \(c.isOpenVPN ? "VPN" : "Forti") first."
        if sharing.count > 1 {
            info += "\n\n\(sharing.joined(separator: ", ")) all log in to this gateway: a wrong password or code in any of them counts."
        }
        if let other = vpn.untriedOTPMode(for: c) {
            info += "\n\nThose logins had the one-time code \(VPNManager.describe(c.otpMode)). With Try Anyway it is \(VPNManager.describe(other))."
        }
        if let until = LoginGuard.shared.clearsAt(key) {
            info += "\n\nFiveT stops asking at \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)), "
                + "three hours after the last failure, or after a login that gets through."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Try Anyway")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            showSettings(tab: .of(c))
        case .alertThirdButtonReturn:
            Log.shared.write("[\(c.name)] the user chose Try Anyway after \(failed) failed login(s)")
            // At the count the question showed: if it changed while it was open, launch() asks anew.
            if let latest = store.connection(id: id) { vpn.connect(latest, byUser: true, loginOverrideAt: failed) }
        default:
            Log.shared.write("[\(c.name)] not logging in again after \(failed) failed login(s)")
        }
    }

    /// A link that would connect always asks first, naming the connection: any web page can open a
    /// link. There is no "always allow". Cancel is the default.
    private func confirmLinkConnect(_ c: Connection, _ go: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect to \(c.name)?"
        alert.informativeText = "A fivet:// link from another app or a web page asks FiveT to connect to \(c.name). If you did not just click such a link, choose Cancel."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Connect")
        guard alert.runModal() == .alertSecondButtonReturn else {
            Log.shared.write("link to connect \(c.name) cancelled")
            return
        }
        go()
    }

    /// Link text for the log: one line, printable, short.
    private static func sanitized(_ s: String) -> String {
        let clean = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : Character($0) })
        return clean.count > 80 ? String(clean.prefix(80)) + "…" : clean
    }

    @objc func openSettings() { showSettings(tab: .connections) }
    /// The menu's warning line: the whole message is under the connection in Settings, on its tab.
    @objc private func showErrorDetails() {
        let failed = vpn.lastError.flatMap { e in store.connections.first { $0.lastError == e } }
        showSettings(tab: failed.map(SettingsTab.of) ?? .connections)
    }
    /// "Set Up FiveT…": the password prompt at once, progress and outcome in Settings → General.
    @objc private func setUp() {
        showSettings(tab: .general)
        SetupFlow.shared.run()
    }
    @objc private func checkForUpdates() { showSettings(tab: .general); Updater.shared.check() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The Settings window is closing: after it has gone, let go of its content and the window (see showSettings).
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === settingsWindow else { return }
        w.makeFirstResponder(nil)   // a number typed in a field (the port) is taken now, not lost with the window
        DispatchQueue.main.async { [weak self, weak w] in
            // Not when Settings was opened again in the meantime: that would blank the window.
            guard let self, let w, self.settingsWindow === w, !w.isVisible else { return }
            w.contentViewController = nil
            w.delegate = nil
            self.settingsWindow = nil
        }
    }

    /// This process's physical memory footprint in MB (what Activity Monitor's Memory column and
    /// `footprint` report, unlike `ps` RSS, which counts shared system libraries).
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func showSettings(tab: SettingsTab) {
        SettingsRouter.shared.tab = tab
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "FiveT"
            w.contentViewController = SettingsTabsController()
            SettingsToolbar.shared.install(on: w)   // tabs in the title bar on every macOS version
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("fivet.settings")   // where and how big the user left it
            settingsWindow = w
            // A menu bar app spends nearly all its time with Settings closed, and four live SwiftUI forms
            // that nobody looks at still re-render on every VPN status change (about 0.5 s of CPU per
            // connect and disconnect) and hold about 5-6 MB. Closing the window lets them go; the next
            // Settings builds them again. (The rest of what opening Settings costs, ColorSync tables and
            // allocator leftovers, stays for the life of the process: measured with --measure-settings.)
            // Tab switches in an open window stay instant: its pages are still built once and then kept.
            w.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A minimal main menu so ⌘C/⌘V/⌘W/⌘Q work inside the Settings window.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Smart Connect (the lightning bolt) above Settings, as in the menu bar icon's menu; a click while it runs stops it.
        let smart = appMenu.addItem(withTitle: "Smart Connect", action: #selector(smartConnect), keyEquivalent: "")
        smart.target = self
        showSmartConnectTitle(smart, "Smart Connect")
        appMenu.delegate = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FiveT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

private extension NSImage {
    func resized(to size: NSSize) -> NSImage {
        let i = NSImage(size: size)
        i.lockFocus()
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        i.unlockFocus()
        return i
    }
}
