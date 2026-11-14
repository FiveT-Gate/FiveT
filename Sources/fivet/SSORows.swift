import SwiftUI
import AppKit

// MARK: - One code

struct SSOEntryRow: View {
    let id: UUID
    var nameFocus: FocusState<UUID?>.Binding
    let onRemove: () -> Void
    @ObservedObject private var store = SSOStore.shared
    @ObservedObject private var center = SSOCoordinator.shared
    @ObservedObject private var recording = ShortcutRecording.shared
    @ViewState private var revealError: String?

    private var nameBinding: Binding<String> {
        Binding(get: { store.entry(id: id)?.name ?? "" }, set: { new in store.mutate(id: id) { $0.name = new } })
    }

    var body: some View {
        if let entry = store.entry(id: id) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        InlineNameField(text: nameBinding, focus: nameFocus, id: id)
                        if !entry.account.isEmpty && entry.account != entry.name {
                            Text(entry.account).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.leading, 7)
                        }
                    }
                    .frame(width: 200, alignment: .leading)
                    ShortcutChip(id: id)
                        .frame(width: 190, alignment: .leading)
                    Spacer(minLength: 4)
                    CodeReadout(secret: entry.secret)
                    Menu {
                        Button("Copy Code") { copyCode(entry) }
                        Button("Rename") { nameFocus.wrappedValue = id }
                        Button("Show Secret…") { showSecret(entry) }
                        Divider()
                        Button("Remove…", role: .destructive) { onRemove() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                            .accessibilityLabel("More actions for \(entry.name)")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if let message = recording.messages[id] ?? center.problems[id] ?? revealError {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if recording.activeID == id {
                    Text("Press the keys you want. Esc cancels, Delete removes the shortcut.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
        }
    }

    private func copyCode(_ entry: SSOEntry) {
        guard let code = TOTP.code(secret: entry.secret) else { return }
        SecretClipboard.copy(code)
        HUD.show("\(entry.name.isEmpty ? "Code" : entry.name): code copied", symbol: "doc.on.clipboard")
    }

    /// After Touch ID or the Mac password, like the secrets of a connection.
    private func showSecret(_ entry: SSOEntry) {
        revealError = nil
        LocalAuth.confirm("show the secret for “\(entry.name)”") { ok, why in
            guard ok else { revealError = why; return }
            let grouped = stride(from: 0, to: entry.secret.count, by: 4).map { i -> String in
                let start = entry.secret.index(entry.secret.startIndex, offsetBy: i)
                return String(entry.secret[start..<(entry.secret.index(start, offsetBy: 4, limitedBy: entry.secret.endIndex) ?? entry.secret.endIndex)])
            }.joined(separator: " ")
            let alert = NSAlert()
            alert.messageText = "Secret for “\(entry.name)”"
            alert.informativeText = "Anyone who has this can make your codes. Keep it private."
            let field = NSTextField(wrappingLabelWithString: grouped)
            field.isSelectable = true
            field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 44)
            alert.accessoryView = field
            alert.addButton(withTitle: "Done")
            if let w = NSApp.keyWindow { alert.beginSheetModal(for: w) } else { alert.runModal() }
        }
    }
}

/// The name of a code, written in place: it looks like a label until the pointer is over it or it has
/// the keyboard, so a list of codes reads as a list and not as a form.
struct InlineNameField: View {
    @Binding var text: String
    var focus: FocusState<UUID?>.Binding
    let id: UUID
    @ViewState private var hovering = false

    var body: some View {
        let focused = focus.wrappedValue == id
        TextField("Name this code", text: $text, prompt: Text("Name this code").foregroundColor(.secondary))   // in a Form the title alone is a label, not a placeholder
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.plain)
            .font(.headline)
            .focused(focus, equals: id)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.10 : (hovering ? 0.06 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
            .onHover { hovering = $0 }
            .help("Click to rename")
    }
}

// MARK: - The shortcut

/// A shortcut drawn as keycaps. Click it to record another; hover to remove it.
struct ShortcutChip: View {
    let id: UUID
    @ObservedObject private var store = SSOStore.shared
    @ObservedObject private var recording = ShortcutRecording.shared
    @ViewState private var hovering = false

    var body: some View {
        let isRecording = recording.activeID == id
        let shortcut = store.entry(id: id)?.shortcut
        let canClear = shortcut != nil && !isRecording
        HStack(spacing: 6) {
            Button {
                if isRecording { recording.stop() } else { recording.start(for: id) }
            } label: {
                label(isRecording: isRecording, shortcut: shortcut)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the keys you want. Esc cancels, Delete removes the shortcut."
                              : (shortcut == nil ? "Click, then press the keys that should type this code in any app."
                                                 : "Click to record a different shortcut."))
            .accessibilityLabel(isRecording ? "Recording a shortcut" : (shortcut.map { "Shortcut: \($0.spoken)" } ?? "No shortcut"))
            .accessibilityHint(isRecording ? "Press the keys you want" : "Activate to record a shortcut")

            // Kept in place (just hidden) so the row does not shift when the pointer comes and goes.
            Button { store.mutate(id: id) { $0.shortcut = nil } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(canClear && hovering ? 1 : 0)
            .allowsHitTesting(canClear && hovering)
            .accessibilityHidden(!canClear)
            .accessibilityLabel("Remove the shortcut")
            .help("Remove the shortcut")

            if let s = shortcut, !isRecording, !s.worksInPasswordFields {
                // Tested: macOS does not let ⌥ or ⌥⇧ shortcuts through while a password field has the keyboard.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("\(s.display) does not work while the cursor is in a password field: macOS blocks ⌥ shortcuts there. Add ⌃ or ⌘ to the shortcut if you need that.")
                    .accessibilityLabel("Does not work in password fields")
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func label(isRecording: Bool, shortcut: KeyShortcut?) -> some View {
        if isRecording {
            HStack(spacing: 6) {
                if recording.held.isEmpty {
                    Text("Press the keys…")
                } else {
                    KeyCaps(parts: recording.held, tint: .accentColor)
                    Text("…")
                }
            }
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .frame(minWidth: 124, minHeight: 28)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
        } else if let shortcut {
            KeyCaps(parts: shortcut.parts)
                .padding(.horizontal, 6)
                .frame(minHeight: 28)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Capsule())
        } else {
            Text("Add Shortcut")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(minWidth: 124, minHeight: 28)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(hovering ? 0.8 : 0.45),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Capsule())
        }
    }
}

/// The keys of a shortcut, each drawn as a small key.
struct KeyCaps: View {
    let parts: [String]
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, part.count > 1 ? 6 : 0)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.20)))
            }
        }
    }
}

// MARK: - The code

/// The code now with the time it has left, like an authenticator app. Click the code to copy it.
struct CodeReadout: View {
    let secret: String
    @ViewState private var copied = false

    var body: some View {
        // Ticks on whole seconds of the clock, which is where a code changes.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { ctx in
            if let code = TOTP.code(secret: secret, at: ctx.date) {
                HStack(spacing: 10) {
                    Button {
                        SecretClipboard.copy(code)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                    } label: {
                        Text(copied ? "Copied" : String(code.prefix(3)) + " " + String(code.suffix(3)))
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                            .frame(minWidth: 108, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy the current code")
                    .accessibilityLabel("Current code \(code.map(String.init).joined(separator: " "))")
                    .accessibilityHint("Activate to copy it")
                    CountdownRing(seconds: max(1, TOTP.secondsRemaining(at: ctx.date)))
                }
            } else {
                Text("Invalid secret").foregroundStyle(.red)
            }
        }
    }
}

/// Time left in the code's 30 seconds: a ring that runs down, orange in the last 10 seconds, red in the last 5.
struct CountdownRing: View {
    let seconds: Int

    var body: some View {
        let tint: Color = seconds <= 5 ? .red : (seconds <= 10 ? .orange : .secondary)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(seconds) / CGFloat(TOTP.period))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Runs down smoothly, and jumps back to full with the new code instead of sweeping back.
                .animation(seconds >= 29 ? nil : .linear(duration: 1), value: seconds)
            Text("\(seconds)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seconds) seconds left")
    }
}
