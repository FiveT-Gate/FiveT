import Foundation

/// Counts failed logins per gateway so FiveT never makes the one that gets the Mac's internet
/// address banned. FortiGates block an address after a few failed logins in a row (Office's
/// gateway: after 3, for a couple of hours), and that address is often shared by a whole office.
///
/// A failure is a login the gateway saw and did not accept: openfortivpn said "Connected to
/// gateway" (the password goes out right after) and never "Authenticated". An attempt that never
/// reaches the gateway (no network, a timeout, a refused certificate) cannot count against the
/// address and does not count here. Failures are counted per gateway (Connection.gatewayKey), since
/// two connections can log in to the same one. A login that gets through clears them; otherwise
/// they are forgotten `window` after the last one.
///
/// The count lives in one file for every copy of FiveT on this Mac (a test copy with its own
/// connections included), re-read before each decision: two copies must not each allow two.
///
/// At `limit` VPNManager stops: reconnects, assistants, the CLI and links are refused, and a click
/// asks first (Try Anyway allows one more login).
final class LoginGuard {
    static let shared = LoginGuard()

    /// Failed logins in a row after which FiveT stops: one fewer than the gateway's ban threshold.
    static let limit = 2
    /// How long failures are remembered after the last one: longer than the gateway's ban.
    static let window: TimeInterval = 3 * 3600

    /// One failed login: when, which connection, how it sent the one-time code (nil without one) and
    /// whether the gateway said no (rather than going quiet), so the next try can send the code the
    /// way that has not been refused yet.
    struct Failure: Codable, Equatable {
        var at: Date
        var connection: UUID?
        var otpMode: OTPMode?
        var rejected: Bool?
    }

    private var failed: [String: [Failure]] = [:]   // gateway key → failures since the last login that got through
    private let fileURL: URL
    private let lockURL: URL

    private init() {
        // Always the real app's folder, also for a copy started with FIVET_DATA_DIR: the gateway
        // counts the Mac's logins, whichever copy made them.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("fivet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = dir.appendingPathComponent("login-failures.json")
        lockURL = dir.appendingPathComponent(".login-failures.lock")
        locked { }
    }

    /// The failures that still count for this gateway, oldest first (none once `window` has passed
    /// since the last one).
    func failures(for key: String) -> [Failure] {
        locked { current(key) }
    }

    func count(for key: String) -> Int { failures(for: key).count }

    func isLimited(_ key: String) -> Bool { count(for: key) >= Self.limit }

    /// When the warning lifts by itself: `window` after the last failure.
    func clearsAt(_ key: String) -> Date? { failures(for: key).last?.at.addingTimeInterval(Self.window) }

    /// Records one failed login and returns how many in a row there are now.
    @discardableResult
    func recordFailure(_ key: String, connection: UUID, otpMode: OTPMode?, rejected: Bool) -> Int {
        locked {
            let list = current(key) + [Failure(at: Date(), connection: connection, otpMode: otpMode, rejected: rejected)]
            failed[key] = list
            save()
            return list.count
        }
    }

    /// A login got through: the gateway starts counting from zero again. Returns how many failures
    /// that cleared.
    @discardableResult
    func recordSuccess(_ key: String) -> Int {
        locked {
            let n = current(key).count
            if failed.removeValue(forKey: key) != nil { save() }
            return n
        }
    }

    // MARK: File

    private func current(_ key: String) -> [Failure] {
        guard let list = failed[key], let last = list.last, Date().timeIntervalSince(last.at) < Self.window else { return [] }
        return list
    }

    /// Runs `body` holding an exclusive lock on the file, after reading what other copies wrote.
    private func locked<T>(_ body: () -> T) -> T {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        load()
        return body()
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { failed = [:]; return }
        if let saved = try? dec.decode([String: [Failure]].self, from: data) {
            failed = saved
        } else {
            // Unreadable: keep what this copy knows rather than forget failures.
            Log.shared.write("the failed-login count file could not be read; keeping the count in memory", level: .error)
        }
    }

    private func save() {
        // Gateways whose failures no longer count are left out.
        failed = failed.filter { !current($0.key).isEmpty }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(failed) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.shared.write("could not save the failed-login count: \(error.localizedDescription)", level: .error)
        }
    }
}

extension Connection {
    /// The gateway as LoginGuard counts it: its address alone. A FortiGate counts failed logins per
    /// client address, whichever of its ports they went to. (A host name and the address it stands
    /// for still count apart.)
    var loginGuardKey: String { endpoint.host.lowercased() }
}
