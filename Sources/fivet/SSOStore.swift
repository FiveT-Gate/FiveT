import Foundation
import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox

/// A keyboard shortcut for one SSO code: the physical key (a virtual key code, so "2" is the key
/// printed 2 whichever layout is on, the Persian one included) and Carbon modifier bits.
struct KeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= command }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        return m
    }

    /// The modifier keys as keycap symbols, in the order macOS shows them: ⌃ ⌥ ⇧ ⌘.
    static func symbols(for modifiers: UInt32) -> [String] {
        var s: [String] = []
        if modifiers & control != 0 { s.append("⌃") }
        if modifiers & option != 0 { s.append("⌥") }
        if modifiers & shift != 0 { s.append("⇧") }
        if modifiers & command != 0 { s.append("⌘") }
        return s
    }

    /// The keycaps to draw: the modifiers, then the key ("⌥", "2").
    var parts: [String] { Self.symbols(for: modifiers) + [Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)"] }

    /// "⌥2".
    var display: String { parts.joined() }

    /// For VoiceOver: "Option 2".
    var spoken: String {
        let words = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
        return parts.map { words[$0] ?? $0 }.joined(separator: " ")
    }

    /// Shortcuts with ⌥ or ⇧ as their only modifiers do not work while a password field has the
    /// keyboard: macOS blocks them there (they could be used to read what is typed). ⌃ or ⌘ in the
    /// shortcut works everywhere. Tested on macOS 27: ⌥, ⌥⇧ blocked; ⌃⌥, ⌘⌥, ⌃⌥⇧, ⌘⇧, ⌃ not.
    var worksInPasswordFields: Bool { modifiers & (Self.command | Self.control) != 0 }

    /// Why FiveT will not take this shortcut, or nil when it can. `others`: the other entries.
    func problem(among others: [SSOEntry]) -> String? {
        // A key that takes ⌘, ⌥ or ⌃ with it is one the user does not type text with. Function keys are
        // left out on purpose: a real F-key press carries the Fn flag and a registered shortcut
        // without it does not match, which cannot be tried without the keys.
        guard modifiers & (Self.command | Self.option | Self.control) != 0 else {
            return "Hold ⌘, ⌥ or ⌃ as well, or the key would stop working for normal typing."
        }
        // Command alone belongs to every app's own shortcuts: ⌘C, ⌘W, ⌘Q… would stop working everywhere.
        if modifiers & (Self.option | Self.control) == 0 {
            return "Apps use \(display) for their own commands, such as copy and quit. Add ⌥ or ⌃ to it."
        }
        if let other = others.first(where: { $0.shortcut == self }) {
            return "\(display) is already used for “\(other.name.isEmpty ? "Untitled" : other.name)”."
        }
        if SystemShortcuts.uses(self) {
            return "macOS already uses \(display) (System Settings → Keyboard → Keyboard Shortcuts)."
        }
        return nil
    }

    // The keys of a US keyboard by their position, as they are labelled on the keycap.
    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
        kVK_ANSI_Keypad0: "Num 0", kVK_ANSI_Keypad1: "Num 1", kVK_ANSI_Keypad2: "Num 2", kVK_ANSI_Keypad3: "Num 3",
        kVK_ANSI_Keypad4: "Num 4", kVK_ANSI_Keypad5: "Num 5", kVK_ANSI_Keypad6: "Num 6", kVK_ANSI_Keypad7: "Num 7",
        kVK_ANSI_Keypad8: "Num 8", kVK_ANSI_Keypad9: "Num 9", kVK_ANSI_KeypadDecimal: "Num .",
        kVK_ANSI_KeypadMultiply: "Num *", kVK_ANSI_KeypadPlus: "Num +", kVK_ANSI_KeypadMinus: "Num -",
        kVK_ANSI_KeypadDivide: "Num /", kVK_ANSI_KeypadEquals: "Num =", kVK_ANSI_KeypadEnter: "Num ↩",
        kVK_ANSI_KeypadClear: "Num Clear",
    ]
}

/// The shortcuts macOS itself has switched on (Spotlight, screenshots, Mission Control…).
enum SystemShortcuts {
    static func uses(_ s: KeyShortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        for hotKey in list {
            guard (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = hotKey[kHISymbolicHotKeyCode as String] as? Int, code != 65535,
                  let mods = hotKey[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            // A system shortcut that needs the Fn key carries 0x20000, which none of ours have.
            if UInt32(truncatingIfNeeded: code) == s.keyCode && UInt32(truncatingIfNeeded: mods) == s.modifiers { return true }
        }
        return false
    }
}

/// One one-time-code secret with the name and the shortcut the user gave it.
struct SSOEntry: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    /// What the QR code or link called the account ("Issuer: name"), shown under the name.
    var account = ""
    /// Base32, upper case, no spaces or padding (OTPAuthImport.normalized).
    var secret = ""
    var shortcut: KeyShortcut?
}

extension SSOEntry: Codable {
    enum CodingKeys: String, CodingKey { case id, name, account, secret, shortcut }

    // Tolerant decoding so older files keep loading when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        shortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
    }
}

/// The SSO tab's codes, in ~/Library/Application Support/fivet/sso.json (mode 0600), next to
/// connections.json and kept the same way: secrets in the file, hidden in the UI.
final class SSOStore: ObservableObject {
    static let shared = SSOStore()

    @Published var entries: [SSOEntry] { didSet { persist() } }

    let fileURL: URL
    private var isLoading = true
    private var pendingSave: DispatchWorkItem?

    private struct FileFormat: Codable {
        var version: Int = 1
        var entries: [SSOEntry] = []
    }

    private init() {
        // The same folder as the connections (and the same test override, FIVET_DATA_DIR).
        fileURL = ConnectionStore.shared.directory.appendingPathComponent("sso.json")
        var loaded: [SSOEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            if let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
                loaded = file.entries
            } else {
                // The only copy of a secret may be in there: never write over a file that cannot be
                // read. It is put aside for a person to look at.
                let aside = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("sso.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                Log.shared.write("SSO: sso.json could not be read; it was kept as \(aside.lastPathComponent)", level: .error)
            }
        }
        entries = loaded
        isLoading = false
    }

    /// Saves shortly after the last change (typing a name changes `entries` with every key).
    func persist() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a change that is still waiting (at quit).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        save()
    }

    private func save() {
        pendingSave = nil
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(FileFormat(entries: entries))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.shared.write("ERROR saving sso.json: \(error)", level: .error)
        }
    }

    func entry(id: UUID) -> SSOEntry? { entries.first { $0.id == id } }

    func binding(for id: UUID) -> Binding<SSOEntry> {
        Binding(
            get: { self.entries.first { $0.id == id } ?? SSOEntry() },
            set: { new in
                if let i = self.entries.firstIndex(where: { $0.id == id }) { self.entries[i] = new }
            }
        )
    }

    /// Changes one field of the stored entry without clobbering others with a stale snapshot.
    func mutate(id: UUID, _ change: (inout SSOEntry) -> Void) {
        if let i = entries.firstIndex(where: { $0.id == id }) { change(&entries[i]) }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        flush()
    }

    /// Adds the codes of a .fivet backup. A secret that is already here is left alone, and a
    /// shortcut another code already has is not taken over. Returns how many were added.
    @discardableResult
    func merge(_ incoming: [SSOEntry]) -> Int {
        var list = entries
        var added = 0
        for var e in incoming where !e.secret.isEmpty && !list.contains(where: { $0.secret == e.secret }) {
            if list.contains(where: { $0.id == e.id }) { e.id = UUID() }
            if let s = e.shortcut, list.contains(where: { $0.shortcut == s }) { e.shortcut = nil }
            list.append(e)
            added += 1
        }
        guard added > 0 else { return 0 }
        entries = list
        pendingSave?.cancel()
        save()
        return added
    }

    /// What a name should be when the user typed none: the service from the QR code, else the account.
    static func suggestedName(for a: OTPAuthImport.Account) -> String {
        let issuer = a.issuer.trimmed
        if !issuer.isEmpty { return issuer }
        let name = a.name.trimmed
        return name.isEmpty ? "One-time code" : name
    }

    struct AddOutcome {
        var added: [SSOEntry] = []
        /// The labels of accounts whose secret was already here.
        var duplicates: [String] = []
    }

    /// Adds the accounts as new entries (a secret that is already here is not added twice). `name`
    /// only for a single account: what the user typed.
    @discardableResult
    func add(_ accounts: [OTPAuthImport.Account], name: String? = nil) -> AddOutcome {
        var outcome = AddOutcome()
        for a in accounts {
            if entries.contains(where: { $0.secret == a.secret }) || outcome.added.contains(where: { $0.secret == a.secret }) {
                outcome.duplicates.append(a.label)
                continue
            }
            let typed = accounts.count == 1 ? (name ?? "").trimmed : ""
            // The caption under the name: what the QR code or link called the account, when it said anything.
            let caption = a.issuer.trimmed.isEmpty && a.name.trimmed.isEmpty ? "" : a.label
            outcome.added.append(SSOEntry(name: typed.isEmpty ? Self.suggestedName(for: a) : typed,
                                          account: caption, secret: a.secret))
        }
        if !outcome.added.isEmpty {
            entries.append(contentsOf: outcome.added)
            // A secret may have been shown only once, so it is saved now, not half a second from now.
            pendingSave?.cancel()
            save()
        }
        return outcome
    }
}
