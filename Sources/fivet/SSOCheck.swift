import AppKit

#if !DISTRIBUTION
/// `FiveT --check-sso [qr.png…]`: the SSO store against a throwaway FIVET_DATA_DIR. Prints PASS/FAIL lines.
enum SSOCheck {
    static func run(pictures: [String]) -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["FIVET_DATA_DIR"], !dir.isEmpty else {
            print("FAIL: set FIVET_DATA_DIR to an empty throwaway folder first"); return 2
        }
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failed += 1 } }
        let store = SSOStore.shared
        let conns = ConnectionStore.shared

        store.entries = []
        let a = SSOEntry(name: "Office", account: "x: a", secret: "JBSWY3DPEHPK3PXPJBSWY3DP", shortcut: KeyShortcut(keyCode: 19, modifiers: KeyShortcut.control | KeyShortcut.command))
        let b = SSOEntry(name: "Bank", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        store.entries = [a, b]
        let backup: Data
        do { backup = try conns.backupData() } catch { print("FAIL backupData: \(error)"); return 1 }
        check(!backup.isEmpty && backup.prefix(8) == Data("FIVETBK1".utf8), "backup is a sealed .fivet file")
        check(!String(decoding: backup, as: UTF8.self).contains(a.secret), "the secret is not readable in the backup file")

        // Restore on a "new Mac": no codes yet.
        store.entries = []
        do { let msg = try conns.restore(from: backup); check(msg.contains("2 SSO code(s) added"), "restore says 2 SSO codes added (\(msg))") }
        catch { check(false, "restore threw \(error)") }
        check(store.entries.count == 2, "2 codes back after restore (\(store.entries.count))")
        let back = store.entries.first { $0.secret == a.secret }
        check(back?.name == "Office" && back?.account == "x: a" && back?.shortcut == a.shortcut, "name, account and shortcut survived")
        check(store.entries.first { $0.secret == b.secret }?.shortcut == nil, "a code with no shortcut stays without one")

        // Restoring again must not duplicate anything.
        _ = try? conns.restore(from: backup)
        check(store.entries.count == 2, "a second restore adds nothing (\(store.entries.count))")

        // A code already here with a different shortcut, and an incoming code whose shortcut is taken.
        store.entries = [SSOEntry(name: "Mine", secret: "MFRGGZDFMZTWQ2LKMFRGGZDFMZTWQ2LK", shortcut: a.shortcut)]
        _ = try? conns.restore(from: backup)
        check(store.entries.count == 3, "merge keeps the existing code and adds the 2 new (\(store.entries.count))")
        check(store.entries.first { $0.secret == a.secret }?.shortcut == nil, "an incoming shortcut already in use is dropped")
        check(store.entries.first { $0.name == "Mine" }?.shortcut == a.shortcut, "the existing code keeps its shortcut")
        let data = try? Data(contentsOf: store.fileURL)
        check(data.map { String(decoding: $0, as: UTF8.self).contains("Mine") } == true, "sso.json was written at once")

        // A backup with no SSO codes (older FiveT) restores without touching the codes.
        store.entries = []
        let empty = try? conns.backupData()
        store.entries = [b]
        if let empty { _ = try? conns.restore(from: empty) }
        check(store.entries.count == 1, "a backup with no SSO codes leaves the codes alone")

        for path in pictures {
            guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { check(false, "\(path) is not a picture"); continue }
            do {
                let accounts = try OTPAuthImport.accounts(in: image)
                print("INFO \(path): \(accounts.count) account(s): " + accounts.map(\.label).joined(separator: " | "))
                for acc in accounts { print("INFO   \(acc.label) code now \(TOTP.code(secret: acc.secret) ?? "?")") }
            } catch { check(false, "\(path): \((error as? OTPAuthImport.Failure)?.message ?? "\(error)")") }
        }
        store.entries = []
        store.flush()
        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        return failed == 0 ? 0 : 1
    }
}
#endif
