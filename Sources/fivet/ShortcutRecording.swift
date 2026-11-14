import AppKit
import Combine
import Carbon.HIToolbox

/// The shortcut being recorded, if any. While one is, FiveT's own shortcuts are switched off and
/// every key goes here, so a combination that is already taken can be seen (and refused) instead of
/// running its entry.
final class ShortcutRecording: ObservableObject {
    static let shared = ShortcutRecording()

    @Published private(set) var activeID: UUID?
    /// The modifier keys held right now while recording, as keycap symbols ("⌥"): the button shows
    /// them as they go down, so the user sees the keys register before the last one is pressed.
    @Published private(set) var held: [String] = []
    /// What was wrong with the last combination tried, per entry.
    @Published var messages: [UUID: String] = [:]

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var tabWatch: AnyCancellable?
    /// True while the event monitor's own callback is running.
    private var insideMonitor = false
    /// A shortcut was taken (or recording was cancelled) from inside the monitor: stop() runs on the
    /// next turn of the run loop, and until then every key is still swallowed.
    private var finishing = false

    func start(for id: UUID) {
        stop()
        messages[id] = nil
        activeID = id
        SSOCoordinator.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.insideMonitor = true
            defer { self.insideMonitor = false }
            return self.handle(event)
        }
        // Whatever takes the keyboard away ends the recording: another app, another window, another tab.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() },
        ]
        tabWatch = SettingsRouter.shared.$tab.dropFirst().sink { [weak self] _ in self?.stop() }
    }

    func stop() {
        // Not from inside the monitor's own callback: AppKit is still going through its monitors, and
        // taking this one out then lets the key it returned nil for reach the field that has the
        // keyboard (the recorded key was typed into the name of the code). One turn later is safe.
        if insideMonitor {
            finishing = true
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        finishing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        tabWatch = nil
        held = []
        if activeID != nil {
            activeID = nil
            SSOCoordinator.shared.setSuspended(false)
        }
    }

    /// nil swallows the key: nothing the user presses while recording reaches the window.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let id = activeID else { return event }
        if finishing { return event.type == .keyDown ? nil : event }
        if event.type == .flagsChanged {
            held = KeyShortcut.symbols(for: KeyShortcut.modifiers(from: event.modifierFlags))
            return event
        }
        if event.isARepeat { return nil }
        let modifiers = KeyShortcut.modifiers(from: event.modifierFlags)
        let code = Int(event.keyCode)
        if modifiers == 0 {
            if code == kVK_Escape { stop(); return nil }
            if code == kVK_Delete || code == kVK_ForwardDelete {
                SSOStore.shared.mutate(id: id) { $0.shortcut = nil }
                stop()
                return nil
            }
        }
        let shortcut = KeyShortcut(keyCode: UInt32(code), modifiers: modifiers)
        if let problem = shortcut.problem(among: SSOStore.shared.entries.filter { $0.id != id }) {
            messages[id] = problem
            return nil
        }
        SSOStore.shared.mutate(id: id) { $0.shortcut = shortcut }
        stop()
        return nil
    }
}
