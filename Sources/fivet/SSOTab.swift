import SwiftUI
import AppKit
import Combine

/// One line above the list for something that did NOT work (a picture without a QR code, a code that is
/// already there). Adding and changing codes shows nothing.
struct SSONotice: Equatable {
    let id = UUID()
    var text: String
}

/// The SSO tab: the one-time codes, each with a name and a shortcut, and what it takes to use them.
///
/// Laid out so nothing you need scrolls away: the header (with Add) and the permission notice stay
/// put, and only the list scrolls.
struct SSOTab: View {
    @ObservedObject private var store = SSOStore.shared
    @ObservedObject private var center = SSOCoordinator.shared
    @ViewState private var showingAdd = false
    @ViewState private var notice: SSONotice?
    @ViewState private var pendingRemoval: SSOEntry?
    @FocusState private var nameFocus: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !center.typingAllowed { SSOPermissionBanner() }
            if let notice {
                SSONoticeBanner(notice: notice) { self.notice = nil }
            }
            if store.entries.isEmpty { emptyState } else { list }
        }
        // A click on empty space finishes a name being edited (macOS leaves the cursor in a text field
        // otherwise; the buttons and fields in the tab take their own clicks first).
        .contentShape(Rectangle())
        .onTapGesture { nameFocus = nil }
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
            // A notice only lasts for the visit (it has no timer: apps should not take away what people
            // may still be reading), and a name being edited is finished.
            else { notice = nil; nameFocus = nil }
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
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if !outcome.added.isEmpty {
            Log.shared.write("SSO: added \(outcome.added.count) code(s) from a pasted secret, a link or a QR code")
            // The clipboard held the secret, and clipboard managers and Universal Clipboard keep what it holds.
            if let clipboard, NSPasteboard.general.changeCount == clipboard { NSPasteboard.general.clearContents() }
        }
        // Success is silent (the new row is the answer, and the name field is not given the cursor: that
        // left it "stuck" in edit mode). A code that was not added is not: nothing would seem to happen.
        if !outcome.duplicates.isEmpty {
            notice = SSONotice(text: "Already here, not added again: \(outcome.duplicates.joined(separator: ", ")).")
        }
    }

    private func report(_ error: Error) {
        notice = SSONotice(text: (error as? OTPAuthImport.Failure)?.message ?? error.localizedDescription)
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

/// What did not work.
struct SSONoticeBanner: View {
    let notice: SSONotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.red)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.red.opacity(0.10)))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
