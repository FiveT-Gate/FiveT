import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Where a secret can come from

/// Where a one-time-code secret can come from besides typing it: a link or a picture of a QR code on
/// the clipboard, a picture in a file, or a picture dropped on the tab. The reading itself is
/// OTPAuthImport's.
enum QRImport {
    struct Result { var accounts: [OTPAuthImport.Account]; var clipboardChange: Int? = nil }

    /// An otpauth link copied as text, or a screenshot of the QR code (⌃⇧⌘4 copies one).
    static func fromClipboard() throws -> Result {
        let pb = NSPasteboard.general
        let copied = pb.changeCount
        if let text = pb.string(forType: .string), OTPAuthImport.looksLikeLink(text) {
            return Result(accounts: try OTPAuthImport.accounts(in: text), clipboardChange: copied)
        }
        guard let image = NSImage(pasteboard: pb) else {
            throw OTPAuthImport.Failure(message: "The clipboard holds no picture or link. Take a screenshot of the QR code with ⌃⇧⌘4 (Control-Shift-Command-4 copies it), then try again.")
        }
        return Result(accounts: try OTPAuthImport.accounts(in: image), clipboardChange: copied)
    }

    static func chooseFile(_ done: @escaping (Swift.Result<Result, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose a picture of the QR code: a screenshot, a photo, or a PDF page."
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url) else {
                done(.failure(OTPAuthImport.Failure(message: "\(url.lastPathComponent) is not a picture FiveT can read.")))
                return
            }
            done(Swift.Result { Result(accounts: try OTPAuthImport.accounts(in: image)) })
        }
    }

    /// A picture or an image file dropped on the tab. False when the drop holds neither.
    static func fromDrop(_ providers: [NSItemProvider], _ done: @escaping (Swift.Result<Result, Error>) -> Void) -> Bool {
        guard let p = providers.first else { return false }
        let deliver: (NSImage?) -> Void = { image in
            DispatchQueue.main.async {
                guard let image else {
                    done(.failure(OTPAuthImport.Failure(message: "That is not a picture FiveT can read. Drop a screenshot or photo of the QR code.")))
                    return
                }
                done(Swift.Result { Result(accounts: try OTPAuthImport.accounts(in: image)) })
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
}

/// A QR code (or export) with several accounts in it: tick the ones to add.
enum AccountPicker {
    private final class Ticks: NSObject {
        var boxes: [NSButton] = []
        weak var add: NSButton?
        @objc func changed() { add?.isEnabled = boxes.contains { $0.state == .on } }
    }

    static func choose(from accounts: [OTPAuthImport.Account], over window: NSWindow?,
                       _ done: @escaping ([OTPAuthImport.Account]) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Which accounts do you want to add?"
        alert.informativeText = "This QR code holds \(accounts.count) accounts."
            + (accounts.first?.exportPart.map { " It is \($0) of a Google Authenticator export: if an account you need is not listed, cancel and import the next one." } ?? "")
        let ticks = Ticks()
        ticks.boxes = accounts.map { NSButton(checkboxWithTitle: $0.label, target: ticks, action: #selector(Ticks.changed)) }
        let list = NSStackView(views: ticks.boxes)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        let rows = CGFloat(accounts.count)
        list.frame = NSRect(x: 0, y: 0, width: 330, height: rows * 26 + 8)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: min(rows * 26 + 12, 230)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        alert.accessoryView = scroll
        let add = alert.addButton(withTitle: "Add Selected")
        add.isEnabled = false
        ticks.add = add
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            done(zip(accounts, ticks.boxes).filter { $0.1.state == .on }.map(\.0))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

// MARK: - The Add sheet

/// Paste a secret or an otpauth:// link, or import a QR code.
struct SSOAddSheet: View {
    /// accounts, the name the user typed, and the clipboard change count when it held the secret.
    let onAdd: ([OTPAuthImport.Account], String?, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var secretText = ""
    @ViewState private var name = ""
    @ViewState private var parsed: [OTPAuthImport.Account] = []
    @ViewState private var problem: String?
    @ViewState private var pasteChange: Int?
    @FocusState private var secretFocused: Bool

    private func parse(_ text: String) {
        let t = text.trimmed
        problem = nil
        parsed = []
        guard !t.isEmpty else { return }
        if OTPAuthImport.looksLikeLink(t) {
            do { parsed = try OTPAuthImport.accounts(in: t) } catch { problem = (error as? OTPAuthImport.Failure)?.message ?? error.localizedDescription }
            return
        }
        // A page address pasted by mistake (the page that shows the secret, not the secret).
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
            problem = "That is a web address. Paste the secret key itself, or the otpauth:// link the page gives you."
            return
        }
        guard let secret = OTPAuthImport.normalized(t) else {
            problem = "That is not a secret key. A secret key is made of the letters A–Z and the digits 2–7; spaces are fine."
            return
        }
        guard secret.count >= 16 else {
            problem = "That is too short for a secret key; they are usually 16 to 32 letters and digits."
            return
        }
        parsed = [OTPAuthImport.Account(secret: secret, issuer: "", name: "")]
    }

    private func finish(_ result: Swift.Result<QRImport.Result, Error>) {
        switch result {
        case .success(let r):
            onAdd(r.accounts, name, r.clipboardChange)
            dismiss()
        case .failure(let e):
            problem = (e as? OTPAuthImport.Failure)?.message ?? e.localizedDescription
        }
    }

    private func add() {
        guard !parsed.isEmpty else { return }
        // Pasted with ⌘V instead of the Paste button: the clipboard holds the secret just the same.
        let pb = NSPasteboard.general
        let stillThere = pb.string(forType: .string)?.trimmed == secretText.trimmed
        onAdd(parsed, name, pasteChange ?? (stillThere ? pb.changeCount : nil))
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a one-time code").font(.title3.weight(.semibold))
            Text("Paste the secret key or the otpauth:// link your service showed when you set up two-step login, or import its QR code.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Secret key or link").font(.subheadline.weight(.medium))
                HStack {
                    SecureField("Paste it here", text: $secretText)
                        .focused($secretFocused)
                        .onSubmit(add)
                        .onChange(of: secretText) { text in parse(text) }
                    Button("Paste") {
                        let pb = NSPasteboard.general
                        pasteChange = pb.changeCount
                        secretText = pb.string(forType: .string) ?? ""
                    }
                }
                if let first = parsed.first, parsed.count == 1, let code = TOTP.code(secret: first.secret) {
                    TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { ctx in
                        let now = TOTP.code(secret: first.secret, at: ctx.date) ?? code
                        Text("Looks right. Its code now is \(String(now.prefix(3))) \(String(now.suffix(3))): check it against your authenticator app.")
                            .font(.caption).foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if parsed.count > 1 {
                    Text("This link holds \(parsed.count) accounts. You choose which to add next.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField(parsed.count == 1 ? SSOStore.suggestedName(for: parsed[0]) : "For example: Office", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Or import a QR code").font(.subheadline.weight(.medium))
                HStack {
                    Button("Paste Screenshot") { finish(Swift.Result { try QRImport.fromClipboard() }) }
                    Button("Choose Image…") { QRImport.chooseFile(finish) }
                }
                Text("⌃⇧⌘4 copies a screenshot of the part of the screen you select. You can also drop the picture on the tab.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Ready to paste the moment the sheet opens.
        .onAppear { DispatchQueue.main.async { secretFocused = true } }
    }
}
