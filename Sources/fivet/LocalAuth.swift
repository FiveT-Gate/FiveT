import AppKit
import LocalAuthentication
import OpenDirectory

/// Touch ID, or the Mac password, before a secret is shown.
///
/// macOS is asked first (LocalAuthentication). On a Mac without Touch ID, or with the lid closed,
/// that is the system password sheet, and on some Macs the system drops that sheet the instant a
/// menu bar app opens it (LAError -4 "cancelled by the system"). FiveT then asks for the Mac
/// password itself and checks it with OpenDirectory, the same service the login window uses.
enum LocalAuth {
    /// `reason` completes the sentence "FiveT is trying to …". `done` runs on the main thread with
    /// success and, for a failure other than the user cancelling, a message.
    private static var current: LAContext?   // kept alive for the whole prompt; non-nil while one is open

    static func confirm(_ reason: String, _ done: @escaping (Bool, String?) -> Void) {
        guard current == nil else {
            // A second click while the prompt is up; replacing the context would cancel the prompt.
            Log.shared.write("local authentication to \(reason): a prompt is already open", level: .debug)
            return
        }
        // The prompt belongs to another process; when it goes away macOS hands focus to whatever
        // app was active before FiveT, and this menu bar app's window sinks behind it. Coming to
        // the front first also spares the password sheet a "not the frontmost app" cancel.
        let window = NSApp.keyWindow
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        let touchID = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            Log.shared.write("local authentication to \(reason): macOS cannot ask (\(err?.localizedDescription ?? "unknown")); asking for the Mac password instead", level: .debug)
            askMacPassword(reason, window: window, done: done)
            return
        }
        current = ctx
        let started = Date()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, e in
            DispatchQueue.main.async {
                current = nil
                NSApp.activate(ignoringOtherApps: true)
                // Not a window that was closed while the prompt was up: a closed Settings window has let go
                // of its content, and bringing it back would show an empty shell.
                if let window, window.isVisible { window.makeKeyAndOrderFront(nil) }
                let elapsed = Date().timeIntervalSince(started)
                let code = (e as? LAError)?.code
                Log.shared.write("local authentication to \(reason): \(ok ? "ok" : describe(code, e) + String(format: " after %.1fs", elapsed)) (Touch ID \(touchID ? "available" : "not available"))", level: .debug)
                if ok { done(true, nil); return }
                // A cancel that comes back within a second is not the user's doing: the prompt was
                // gone before anyone could see it. Every other failure gets FiveT's own sheet too.
                if code == .userCancel && elapsed >= 1 { done(false, nil); return }
                askMacPassword(reason, window: window, done: done)
            }
        }
    }

    private static func describe(_ code: LAError.Code?, _ error: Error?) -> String {
        let word: String
        switch code {
        case .userCancel: word = "cancelled by the user"
        case .systemCancel: word = "cancelled by the system"
        case .appCancel: word = "cancelled by the app"
        case .userFallback: word = "user chose the password"
        case .authenticationFailed: word = "failed"
        case .passcodeNotSet: word = "no Mac password set"
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout: word = "Touch ID not usable"
        case .none: word = error?.localizedDescription ?? "failed"
        default: word = error?.localizedDescription ?? "failed"
        }
        return code.map { "\(word) (LAError \($0.rawValue))" } ?? word
    }

    /// FiveT's own sheet: the password of the Mac account, checked with OpenDirectory.
    private static func askMacPassword(_ reason: String, window: NSWindow?, wrongBefore: Bool = false,
                                       done: @escaping (Bool, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "FiveT is trying to \(reason)."
        alert.informativeText = (wrongBefore ? "That password is not correct. " : "")
            + "Enter the password of your Mac account “\(NSFullUserName())” to allow this."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Mac password"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                Log.shared.write("local authentication to \(reason): Mac password sheet cancelled", level: .debug)
                done(false, nil)
                return
            }
            switch MacPassword.verify(field.stringValue) {
            case .ok:
                Log.shared.write("local authentication to \(reason): ok (Mac password)", level: .debug)
                done(true, nil)
            case .wrong:
                Log.shared.write("local authentication to \(reason): wrong Mac password", level: .debug)
                DispatchQueue.main.async { askMacPassword(reason, window: window, wrongBefore: true, done: done) }
            case .unavailable(let why):
                Log.shared.write("local authentication to \(reason): cannot check the Mac password: \(why)", level: .error)
                done(false, "FiveT could not check your Mac password: \(why)")
            }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Checks a password against the account FiveT is running as, through OpenDirectory.
enum MacPassword {
    enum Outcome { case ok, wrong, unavailable(String) }

    static func verify(_ password: String) -> Outcome {
        guard !password.isEmpty else { return .wrong }
        do {
            // The search node covers local accounts and, on a Mac bound to a directory, network ones.
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            do {
                try record.verifyPassword(password)
                return .ok
            } catch {
                let e = error as NSError
                return e.code == 5000 /* kODErrorCredentialsInvalid */ ? .wrong : .unavailable(e.localizedDescription)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
