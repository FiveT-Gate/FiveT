import AppKit

/// Review New Certificate…: the user's decision about a gateway certificate macOS could not vouch
/// for (VPNManager.handleRefusedCertificate): a changed one, or the first one of a gateway reached by
/// IP address. Only a person can make it: assistants (MCP), the command line and fivet:// links have
/// no way to trust a certificate.
enum CertReview {
    /// A review is on screen (the updater does not restart FiveT under it).
    private(set) static var isOpen = false

    static func present(_ id: UUID, over window: NSWindow?) {
        guard !isOpen, let c = ConnectionStore.shared.connection(id: id), c.hasPendingReview else { return }
        // What the user is shown is what gets trusted: if the question changes while the alert is
        // up (another attempt met yet another certificate), Trust does nothing.
        let pending = c.pendingCert, first = c.pendingCertFirst, oldPin = c.trustedCert, gateway = c.gatewayKey
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if first {
            alert.messageText = "Trust the certificate of \(c.name)'s gateway?"
            alert.informativeText = """
                FiveT has not connected to this gateway before, and macOS cannot confirm the certificate \
                belongs to it. FiveT did not log in, so your password was not sent.

                Trust it if you are on a network you trust and this is the gateway your IT team gave \
                you. After that, FiveT checks the gateway against it every time.
                """
        } else {
            alert.messageText = "The certificate of \(c.name)'s gateway has changed"
            alert.informativeText = """
                FiveT did not log in, so your password was not sent.

                Gateways get a new certificate when the old one is renewed. A different certificate can \
                also mean someone is intercepting the connection, for example on hotel or café Wi-Fi. \
                Trust it only if your IT team confirms the change.

                On hotel, café or airport Wi-Fi, sign in to the Wi-Fi in your browser first, then connect \
                again: if the old certificate comes back, FiveT connects without asking.
                """
        }
        alert.accessoryView = detailsView(c.pendingCertInfo)
        // The safe choice is the default one (Return).
        alert.addButton(withTitle: first ? "Don't Connect" : "Keep Blocked")
        alert.addButton(withTitle: first ? "Trust and Connect" : "Trust New Certificate")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            isOpen = false
            guard response == .alertSecondButtonReturn else {
                Log.shared.write("[\(c.name)] \(first ? "gateway certificate not trusted" : "new gateway certificate kept blocked")")
                return
            }
            guard let now = ConnectionStore.shared.connection(id: id), now.pendingCert == pending, now.gatewayKey == gateway else {
                Log.shared.write("[\(c.name)] the certificate question changed while it was on screen; nothing trusted", level: .error)
                return
            }
            // Other connections to the same gateway that trusted the same certificate follow along.
            for other in ConnectionStore.shared.connections where other.gatewayKey == gateway && (other.id == id || (!first && other.trustedCert == oldPin)) {
                ConnectionStore.shared.mutate(id: other.id) { $0.trust(pending, names: []) }   // names: read after the next login
            }
            Log.shared.write("[\(c.name)] the user trusted the gateway certificate \(pending.prefix(12))…; connecting")
            if let updated = ConnectionStore.shared.connection(id: id) {
                SetupFlow.shared.whenReady({ VPNManager.shared.connect(updated, byUser: true) },
                                           failed: { SettingsRouter.shared.tab = .general })
            }
        }
        isOpen = true
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// The details as selectable text, so the fingerprint can be copied and sent to IT.
    private static func detailsView(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.preferredMaxLayoutWidth = 360
        let size = field.sizeThatFits(NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        field.frame = NSRect(x: 0, y: 0, width: 360, height: max(ceil(size.height), 20))
        return field
    }
}
