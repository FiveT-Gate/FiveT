import AppKit
import ApplicationServices

/// Types a one-time code into whatever has the keyboard focus, in any app.
///
/// It sends key events, so macOS wants FiveT allowed under Privacy & Security → Accessibility. The
/// code is typed, not pasted: the clipboard (and every clipboard manager watching it) never sees it,
/// and a code field made of six boxes gets its digits one key at a time, as if from a keyboard.
enum CodeTyper {
    /// FiveT is allowed to control the keyboard. Cheap enough to ask whenever it is needed.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// macOS's own question, which offers to open the Accessibility list.
    static func askForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The keys of the digit row, by position: key codes do not depend on the layout in use.
    private static let digitKeys: [Character: CGKeyCode] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]

    /// Waits (up to `timeout`) until no ⌘ ⌥ ⌃ ⇧ key is held. The shortcut that asked for the code is
    /// usually still down: typed with ⌥ held, a digit would come out as a symbol.
    static func waitForModifiersToBeReleased(timeout: TimeInterval = 1.5) {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            usleep(10_000)
        }
    }

    /// Types `text` at the keyboard focus. Takes a moment (it waits for the modifier keys to come
    /// up): not on the main thread.
    ///
    /// Every key event carries its character explicitly. With only a key code, the Persian layout
    /// typed ۱۲۳ for 123, and any layout would type its own idea of that key. The key code is set as
    /// well (apps that read the physical key, such as remote desktops and virtual machines, use it),
    /// and no modifiers, whatever is held.
    static func type(_ text: String) {
        waitForModifiersToBeReleased()
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: digitKeys[character] ?? 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            usleep(8_000)   // events sent all at once can arrive out of step in some apps
        }
    }
}
