import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which is what lets a shortcut work in
/// every app. Compared with an event tap it needs no privacy permission at all, and it takes the key
/// away from the app in front (⌥2 does not also type ™).
///
/// Tested on macOS 27 with a focused window that has Secure Input on, as a password field does:
/// shortcuts with ⌥ or ⌥⇧ as the only modifiers do not arrive then (the key is typed instead), while
/// anything with ⌃ or ⌘ in it does (KeyShortcut.worksInPasswordFields). Apple documents Secure Input
/// as hiding keystrokes from every other app, so an event tap would not do better.
///
/// Main thread only: Carbon delivers the shortcut on the application's event queue.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private static let signature: OSType = 0x46_76_54_31   // 'FvT1'

    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    /// Carbon's reason for refusing a shortcut: eventHotKeyExistsErr (-9878) when it is already taken.
    struct Refused: Error { let status: OSStatus }

    /// Registers `shortcut`. The token to `unregister` it with, or why it was refused.
    func register(_ shortcut: KeyShortcut, action: @escaping () -> Void) -> Result<UInt32, Refused> {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = nextID
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return .failure(Refused(status: status == noErr ? OSStatus(paramErr) : status)) }
        nextID += 1
        refs[id] = ref
        actions[id] = action
        return .success(id)
    }

    func unregister(_ token: UInt32) {
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        actions[token] = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeys.signature,
                  let action = GlobalHotKeys.shared.actions[id.id] else { return OSStatus(eventNotHandledErr) }
            action()
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
