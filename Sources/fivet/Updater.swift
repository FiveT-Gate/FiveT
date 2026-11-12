import AppKit
import Combine
import CryptoKit
import Foundation

/// Self-update. Reads `<feed>/latest.json` (published by release.sh), checks that the release is
/// signed with FiveT's release key (UpdateSignature), downloads the DMG it names in the background,
/// verifies the SHA-256 and unpacks the new app; once no tunnel is in use (or at quit) it swaps the
/// app bundle for the new one and relaunches. No dialogs.
/// Nothing runs with elevated rights: /Applications is writable by the user who installed FiveT.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    struct Release: Codable, Equatable {
        var version: String
        var build: Int?
        var url: URL
        var sha256: String
        var notes: String?
        /// Ed25519 signature over version, build and sha256 by FiveT's release key (UpdateSignature).
        var signature: String?

        var isSigned: Bool { UpdateSignature.isValid(signature, version: version, build: build, sha256: sha256) }
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case available(Release)
        /// Downloaded, verified and unpacked; swapped in at the next quiet moment or at quit.
        case ready(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// Set by AppDelegate: true while a restart would get in someone's way. A ready update
    /// waits until this has been false twice in a row.
    var isBusy: () -> Bool = { false }

    /// Where to look: FIVET_UPDATE_URL in the environment (testing) or the FiveTUpdateFeed
    /// key in Info.plist (what release.sh publishes to).
    static var feedURL: URL? {
        if let s = ProcessInfo.processInfo.environment["FIVET_UPDATE_URL"], let u = URL(string: s) { return u }
        if let s = Bundle.main.object(forInfoDictionaryKey: "FiveTUpdateFeed") as? String, let u = URL(string: s) { return u }
        return nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static let checkInterval: TimeInterval = 24 * 3600
    /// After a failed check or download, one more try this much later; then back to `checkInterval`.
    static let retryInterval: TimeInterval = 5 * 3600
    /// How often a ready update looks for a quiet moment.
    static let quietCheckInterval: TimeInterval = 180

    /// The unpacked new FiveT.app waits here: ~/Library/Caches is on the same volume as
    /// /Applications, so putting it in place is a rename, not a copy.
    static let stagingDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("fivet/update", isDirectory: true)

    /// Silent downloads go out as background traffic, so they never slow a tunnel or a call down;
    /// ephemeral keeps the DMG out of the URL cache.
    private static let quietSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.networkServiceType = .background
        return URLSession(configuration: c)
    }()

    /// For the feed check and a download somebody asked for. Not URLSession.shared: that one keeps
    /// cookies and a URL cache on disk (3.6 MB in ~/Library/HTTPStorages and ~/Library/Caches), and
    /// the feed and the download need neither.
    private static let session = URLSession(configuration: .ephemeral)

    private var timer: Timer?
    private var nextCheck = Date.distantFuture
    private var retrying = false   // the running check is the one retry after a failure
    private var quietTimer: Timer?
    private var quietTicks = 0
    private var staged: URL?

    /// One check a minute after launch, then once a day; a failure is retried once after five
    /// hours. Nothing is ever shown: updates download and install on their own (Settings → General
    /// can turn that off), and the log is the only trace.
    func startPeriodicChecks() {
        try? FileManager.default.removeItem(at: Self.stagingDir)   // unpacked by an earlier run, never installed
        schedule(in: 60)
        // Timers stand still while the Mac sleeps. Off during sleep, and after a wake the check that
        // came due waits a minute for Wi-Fi instead of firing into a network that is not back yet.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.timer?.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.schedule(in: max(60, self.nextCheck.timeIntervalSinceNow))
        }
    }

    private func schedule(in seconds: TimeInterval) {
        timer?.invalidate()
        nextCheck = Date().addingTimeInterval(seconds)
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.check() }
        t.tolerance = min(seconds / 10, 30 * 60)   // lets macOS fold the wake-up into one it makes anyway
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A failed check or download: one retry after five hours. If the retry fails too, the next
    /// try is the regular one a day later (check() booked it when it started).
    private func retryLater() {
        if retrying {
            retrying = false
            Log.shared.write("update retry failed; next check in 24 h")
            return
        }
        retrying = true
        schedule(in: Self.retryInterval)
        Log.shared.write("update failed; trying again in 5 h")
    }

    func check() {
        guard let feed = Self.feedURL else {
            state = .failed("This copy of FiveT has no update address built in."); return
        }
        schedule(in: Self.checkInterval)   // the next regular check; a failure brings it forward once
        switch state {
        case .checking, .downloading, .installing, .ready: return
        default: break
        }
        state = .checking
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        req.setValue("FiveT/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        Self.session.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.lastChecked = Date()
                if let err {
                    self.checkFailed("Could not reach the update server: \(err.localizedDescription)"); return
                }
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                    self.checkFailed("The update server answered with an error."); return
                }
                guard let rel = try? JSONDecoder().decode(Release.self, from: data) else {
                    self.checkFailed("The update information could not be read."); return
                }
                if Self.isNewer(rel) {
                    // Checked before anything is downloaded: the checksum only proves the file is the
                    // one the feed names, the signature that the release is FiveT's.
                    guard rel.isSigned else {
                        // Nothing from an unsigned feed is shown as it is: its text is whatever the
                        // server says, and could be instructions. A plain version number at most.
                        let shown = rel.version.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#, options: .regularExpression) != nil
                            ? rel.version : "(not a version number)"
                        Log.shared.write("update \(shown) is not signed with FiveT's release key (\(rel.signature == nil ? "no signature" : "signature does not match")); not installing it", level: .error)
                        self.checkFailed("The update on the server is not signed with FiveT's key, so it was not installed.")
                        return
                    }
                    Log.shared.write("update available: \(rel.version) (running \(Self.currentVersion))")
                    self.state = .available(rel)
                    if ConnectionStore.shared.autoUpdate { self.download(rel, thenInstall: false); return }
                } else {
                    self.state = .upToDate
                }
                self.retrying = false
            }
        }.resume()
    }

    private func checkFailed(_ message: String) {
        state = .failed(message)
        retryLater()
    }

    static func isNewer(_ r: Release) -> Bool {
        switch compare(r.version, currentVersion) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return (r.build ?? 0) > currentBuild
        }
    }

    /// Numeric, part by part: 1.2.10 > 1.2.9, and 1.2 equals 1.2.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Install

    /// Install Update / Restart Now in Settings (and the --self-update hook): no waiting for a quiet moment.
    func installNow() {
        switch state {
        case .available(let rel): download(rel, thenInstall: true)
        case .ready(let rel): install(rel)
        default: break
        }
    }

    /// At quit (the menu's Quit, logout, shutdown) a ready update takes the old copy's place
    /// without a relaunch, so a Mac that always has a tunnel up still gets it: the next start is
    /// the new version. A rename, so it is done before the quit is.
    func installAtQuit() {
        guard ConnectionStore.shared.autoUpdate, case .ready(let rel) = state, let app = staged else { return }
        swap(in: app, release: rel, relaunch: false)
    }

    private func download(_ rel: Release, thenInstall: Bool) {
        // A copy that cannot replace itself (run from the DMG, or /Applications not writable)
        // would otherwise download the update every six hours for nothing.
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            fail("FiveT cannot replace itself at \(target.path). Move it to Applications and try again."); return
        }
        state = .downloading
        Log.shared.write("downloading update \(rel.version) from \(rel.url)")
        let session = thenInstall ? Self.session : Self.quietSession
        let task = session.downloadTask(with: rel.url) { tmp, resp, err in
            if let err { self.fail("Download failed: \(err.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), let tmp else {
                self.fail("Download failed (server error)."); return
            }
            // The temporary file is deleted when this handler returns, so move it first.
            let dmg = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FiveT-\(rel.version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            do { try FileManager.default.moveItem(at: tmp, to: dmg) } catch {
                self.fail("Could not save the download: \(error.localizedDescription)"); return
            }
            DispatchQueue.global(qos: thenInstall ? .userInitiated : .utility).async {
                guard let app = self.unpack(dmg: dmg, release: rel) else { return }
                DispatchQueue.main.async {
                    self.staged = app
                    self.state = .ready(rel)
                    self.retrying = false
                    Log.shared.write("update \(rel.version) ready")
                    if thenInstall { self.install(rel) } else { self.waitForQuietMoment() }
                }
            }
        }
        task.priority = thenInstall ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        task.resume()
    }

    private func fail(_ message: String) {
        Log.shared.write("update failed: \(message)", level: .error)
        DispatchQueue.main.async {
            self.state = .failed(message)
            self.retryLater()
        }
    }

    /// Checks the DMG and copies the new app out of it into `stagingDir`. Off the main thread.
    private func unpack(dmg: URL, release: Release) -> URL? {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dmg) }

        // 1. Integrity: the file must be exactly the one release.sh published and signed (the
        //    signature covers this checksum). Mapped rather than read, so its pages come from the
        //    file and are not held as app memory.
        guard release.isSigned else { fail("This update is not signed with FiveT's key."); return nil }
        guard let data = try? Data(contentsOf: dmg, options: .alwaysMapped) else { fail("Could not read the download."); return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            fail("The download is damaged (checksum mismatch). Try again later."); return nil
        }

        // 2. Open the image (-nobrowse: it never shows up in Finder) and find the new app inside.
        let mount = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fivet-update-\(release.version)")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        // -noverify: the whole file was just checked against its signed SHA-256; hdiutil's own checksum
        // pass over it again is two seconds of CPU for nothing.
        let attach = Setup.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-noverify",
                                                    "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else { fail("Could not open the downloaded disk image."); return nil }
        defer {
            _ = Setup.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? fm.removeItem(at: mount)   // the empty mount point
        }
        let newApp = mount.appendingPathComponent("FiveT.app")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/FiveT").path) else {
            fail("The disk image does not contain FiveT.app."); return nil
        }

        // 3. Copy it out now, while nothing is waiting on it, so the install itself is a rename. The
        //    copy comes from the image (another file system), where ditto can compress what it writes
        //    (APFS transparent compression: the code signature never sees it): about 20 MB on disk
        //    instead of 44. A copy that does not pass codesign is made again without it.
        let app = Self.stagingDir.appendingPathComponent("FiveT.app")
        try? fm.removeItem(at: Self.stagingDir)
        try? fm.createDirectory(at: Self.stagingDir, withIntermediateDirectories: true)
        var copy = Setup.run("/usr/bin/ditto", ["--hfsCompression", newApp.path, app.path])
        if copy.status != 0 || Setup.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path]).status != 0 {
            Log.shared.write("update \(release.version): the compressed copy did not check out; unpacking it uncompressed", level: .error)
            try? fm.removeItem(at: app)
            copy = Setup.run("/usr/bin/ditto", [newApp.path, app.path])
        }
        guard copy.status == 0 else { fail("Could not unpack the new version: \(copy.output)"); return nil }
        _ = Setup.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Installing restarts FiveT, and quitting takes every tunnel down, so a ready update waits
    /// until nobody is using the app: `isBusy` must be false on two checks in a row (3 to 6
    /// minutes), so a restart never lands between a disconnect and the next connect.
    private func waitForQuietMoment() {
        quietTimer?.invalidate()
        quietTicks = 0
        let t = Timer(timeInterval: Self.quietCheckInterval, repeats: true) { [weak self] _ in
            guard let self, case .ready(let rel) = self.state else { self?.quietTimer?.invalidate(); return }
            guard ConnectionStore.shared.autoUpdate else { self.quietTicks = 0; return }
            self.quietTicks = self.isBusy() ? 0 : self.quietTicks + 1
            if self.quietTicks >= 2 {
                Log.shared.write("no tunnel in use; installing update \(rel.version)")
                self.install(rel)
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        quietTimer = t
    }

    private func install(_ rel: Release) {
        quietTimer?.invalidate(); quietTimer = nil
        guard let app = staged,
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/FiveT").path) else {
            staged = nil
            state = .idle   // the unpacked copy is gone; the next check downloads it again
            return
        }
        state = .installing
        DispatchQueue.global(qos: .userInitiated).async { self.swap(in: app, release: rel, relaunch: true) }
    }

    /// Puts the unpacked app where this one is. RENAME_SWAP exchanges the two in one step, so there
    /// is never a moment without a FiveT.app, not even if the Mac shuts down right then.
    private func swap(in app: URL, release: Release, relaunch: Bool) {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        if renamex_np(app.path, target.path, UInt32(RENAME_SWAP)) != 0 {
            // Another volume or a file system without swap: move the old copy aside, then the new one in.
            let old = Self.stagingDir.appendingPathComponent("FiveT-old.app")
            try? fm.removeItem(at: old)
            do { try fm.moveItem(at: target, to: old) } catch {
                fail("Could not replace the app: \(error.localizedDescription)"); return
            }
            do { try fm.moveItem(at: app, to: target) } catch {
                try? fm.moveItem(at: old, to: target)   // put the old version back
                fail("Could not move the new version in: \(error.localizedDescription)"); return
            }
        }
        try? fm.removeItem(at: Self.stagingDir)   // holds the old version now
        Log.shared.write("update \(release.version) installed at \(target.path); "
                         + (relaunch ? "relaunching" : "it starts next time"))
        guard relaunch else { return }

        // Relaunch once this process has gone (quitting disconnects the VPN cleanly first).
        // FIVET_SOCKET / FIVET_UPDATE_URL / FIVET_DATA_DIR are passed along so a test copy stays a
        // test copy (and never opens the real app's connections).
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open ${FIVET_SOCKET:+--env FIVET_SOCKET=\"$FIVET_SOCKET\"} "
            + "${FIVET_UPDATE_URL:+--env FIVET_UPDATE_URL=\"$FIVET_UPDATE_URL\"} "
            + "${FIVET_DATA_DIR:+--env FIVET_DATA_DIR=\"$FIVET_DATA_DIR\"} \"\(target.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
