import SwiftUI
import AppKit
import Combine

/// One line of feedback above the list, with an optional next step (Record Shortcut after an import).
struct SSONotice: Equatable {
    let id = UUID()
    var text: String
    var failed = false
    /// An entry whose shortcut the notice offers to record.
    var recordFor: UUID? = nil
}

/// The SSO tab: the one-time codes, each with a name and a shortcut, and what it takes to use them.
///
/// Laid out so nothing you need scrolls away: the header (with Add), the permission notice and the
/// footer (permission state, the box for trying a shortcut) stay put, and only the list scrolls.
struct SSOTab: View {
    @ObservedObject private var store = SSOStore.shared
    @ObservedObject private var center = SSOCoordinator.shared
    @ViewState private var showingAdd = false
    @ViewState private var notice: SSONotice?
    @ViewState private var pendingRemoval: SSOEntry?
    @ViewState private var tryText = ""
    @FocusState private var tryFocused: Bool
    @FocusState private var nameFocus: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !center.typingAllowed { SSOPermissionBanner() }
            if let notice {
                SSONoticeBanner(notice: notice) { self.notice = nil }
            }
            if store.entries.isEmpty { emptyState } else { list }
            Divider()
            footer
        }
        .sheet(isPresented: $showingAdd) {
            SSOAddSheet { accounts, name, clipboard in adopt(accounts, name: name, clipboard: clipboard) }
        }
        .alert("Remove “\(pendingRemoval.map { $0.name.trimmed.isEmpty ? "One-time code" : $0.name } ?? "")”?",
               isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { entry in
            Button("Remove", role: .destructive) {
                store.remove(id: entry.id)
                Log.shared.write("SSO: removed “\(entry.name)”")
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its secret is deleted from this Mac and FiveT cannot get it back. Make sure you can still sign in to the service another way (a recovery code, or another device) first.")
        }
        // A picture of the QR code dropped anywhere on the tab.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            QRImport.fromDrop(providers) { result in
                switch result {
                case .success(let r): adopt(r.accounts, name: nil, clipboard: nil)
                case .failure(let e): report(e)
                }
            }
        }
        // The page is kept between visits, so onAppear would run once: look again on every visit, and
        // while the tab is up (the switch is flipped in another window).
        .onReceive(SettingsRouter.shared.$tab) { tab in
            if tab == .sso {
                center.refreshPermission()
                // The window hands the keyboard to the first field, the name of the first code: a key
                // pressed then would rename it.
                DispatchQueue.main.async { nameFocus = nil }
            }
            // A code left in the box, or the box still "having the keyboard", must not outlive the tab.
            else { tryText = ""; tryFocused = false; SSOCoordinator.shared.tryBoxHasKeyboard = false }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if SettingsRouter.shared.tab == .sso { center.refreshPermission() }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("One-time codes").font(.title3.weight(.semibold))
                Text("Press a code's shortcut in any app and FiveT types its current code. Works while FiveT is running.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // With no codes yet the empty state carries the one big button.
            if !store.entries.isEmpty {
                Button { showingAdd = true } label: { Label("Add Code…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var list: some View {
        Form {
            Section {
                ForEach(store.entries) { entry in
                    SSOEntryRow(id: entry.id, nameFocus: $nameFocus, onRemove: { pendingRemoval = entry })
                }
            } footer: {
                if store.entries.contains(where: { $0.shortcut.map { !$0.worksInPasswordFields } ?? false }) {
                    Label("Shortcuts with only ⌥ or ⇧ do not work while the cursor is in a password field (macOS blocks them there). Add ⌃ or ⌘ for those.",
                          systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "lock.rotation")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Sign in faster with your one-time codes").font(.title3.weight(.semibold))
            Text("Add the secret key or QR code your service gave you for two-step login. Give it a shortcut, and FiveT types the current code wherever you press it.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button { showingAdd = true } label: { Label("Add Your First Code…", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("You can also drop a picture of the QR code anywhere on this tab.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if center.typingAllowed {
                Label { Text("FiveT can type your codes").foregroundStyle(.secondary) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
            }
            Spacer(minLength: 8)
            if !store.entries.isEmpty {
                // The one place in FiveT's own windows that takes a code: anywhere else a code would land
                // in the name of an entry.
                TextField("Try a shortcut", text: $tryText, prompt: Text("Try it here: click, then press a shortcut"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .focused($tryFocused)
                    .onChange(of: tryFocused) { focused in SSOCoordinator.shared.tryBoxHasKeyboard = focused }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Adding

    /// Adds what an import found. Several accounts in one code: the user ticks the ones wanted.
    private func adopt(_ accounts: [OTPAuthImport.Account], name: String?, clipboard: Int?) {
        if accounts.count > 1 {
            // From the Add sheet, the key window is that sheet on its way out: a question attached to it
            // would go with it. Ask over the Settings window, once the sheet is gone.
            let key = NSApp.keyWindow
            let host = key?.sheetParent ?? key
            DispatchQueue.main.asyncAfter(deadline: .now() + (key?.sheetParent == nil ? 0 : 0.4)) {
                AccountPicker.choose(from: accounts, over: host) { chosen in save(chosen, name: nil, clipboard: clipboard) }
            }
        } else {
            save(accounts, name: name, clipboard: clipboard)
        }
    }

    private func save(_ accounts: [OTPAuthImport.Account], name: String?, clipboard: Int?) {
        let outcome = store.add(accounts, name: name)
        var text = ""
        if !outcome.added.isEmpty {
            let names = outcome.added.map { "“\($0.name)”" }.joined(separator: ", ")
            text = outcome.added.count == 1
                ? "Added \(names). Compare its code with your authenticator app, then give it a shortcut."
                : "Added \(names). Compare their codes with your authenticator app, then give each a shortcut."
            Log.shared.write("SSO: added \(outcome.added.count) code(s) from a pasted secret, a link or a QR code")
        }
        if !outcome.duplicates.isEmpty {
            text += (text.isEmpty ? "" : " ") + "Already here, not added again: \(outcome.duplicates.joined(separator: ", "))."
        }
        // The clipboard held the secret, and clipboard managers and Universal Clipboard keep what it holds.
        if !outcome.added.isEmpty, let clipboard, NSPasteboard.general.changeCount == clipboard {
            NSPasteboard.general.clearContents()
            text += " The clipboard was emptied, since it held the secret."
        }
        guard !text.isEmpty else { return }
        // A single new code: put the cursor in its name, and offer the next step.
        let only = outcome.added.count == 1 ? outcome.added[0] : nil
        show(SSONotice(text: text, recordFor: only?.id))
        if let only {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { nameFocus = only.id }
        }
    }

    private func report(_ error: Error) {
        show(SSONotice(text: (error as? OTPAuthImport.Failure)?.message ?? error.localizedDescription, failed: true), seconds: 20)
    }

    /// Shows a notice and takes it away again after a while (unless a newer one has replaced it).
    private func show(_ new: SSONotice, seconds: Double = 14) {
        notice = new
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if notice?.id == new.id { notice = nil }
        }
    }
}

// MARK: - Banners

/// The permission FiveT needs to type, as a notice that cannot be missed while it is missing.
struct SSOPermissionBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow FiveT to type your codes").font(.headline)
                Text("macOS asks you once, under Privacy & Security → Accessibility. Until then a shortcut copies the code and you paste it yourself with ⌘V.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Allow…") { CodeTyper.askForPermission() }
                    .buttonStyle(.borderedProminent)
                Button("Open Privacy Settings") { CodeTyper.openPrivacySettings() }
                    .buttonStyle(.link)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// What just happened, and what to do next.
struct SSONoticeBanner: View {
    let notice: SSONotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.failed ? Color.red : Color.green)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let id = notice.recordFor {
                Button("Record Shortcut") {
                    ShortcutRecording.shared.start(for: id)
                    dismiss()
                }
                .controlSize(.small)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((notice.failed ? Color.red : Color.green).opacity(0.10)))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
