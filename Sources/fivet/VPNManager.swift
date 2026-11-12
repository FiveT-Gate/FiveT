import AppKit
import Combine
import Network

enum VPNPhase: Equatable { case idle, connecting, connected, disconnecting }

/// What the tunnel produced, captured once "Tunnel is up and running" is seen.
struct NetworkInfo: Equatable {
    var interface: String = ""          // ppp0
    var tunnelIP: String = ""           // our address on the tunnel
    var peerIP: String = ""             // pppd peer
    var dnsServers: [String] = []       // pushed by the gateway
    var searchDomains: [String] = []    // pushed by the gateway (rare on FortiGate)
    var routes: [String] = []           // destinations routed via the tunnel, "a.b.c.d/nn"
    /// OpenVPN: all traffic goes through the tunnel (redirect-gateway), so its DNS is the Mac's too.
    var fullTunnel = false
    /// The network the tunnel itself runs over: the Mac's interface and address that its
    /// connection to the gateway leaves from (en0 192.168.1.20). Empty when unknown.
    var outerInterface: String = ""
    var outerIP: String = ""
}

/// State of the /etc/resolver files for the connection's "DNS domains".
struct SplitDNSInfo: Equatable {
    var domains: [String]
    var state: String       // active | partial | helper_needed | failed | pending
    var detail: String = ""
}

/// The state of one tunnel (or, when nothing is up, of the manager as a whole).
struct VPNStatus: Equatable {
    var phase: VPNPhase = .idle
    var connectionID: UUID? = nil
    var connectionName: String? = nil
    var since: Date? = nil
    /// Progress text while connecting ("Logging in…").
    var detail: String? = nil
    /// Last failure, shown in the menu until it is opened once.
    var lastError: String? = nil
    /// True when the failure was "sudo needs a password" (helper missing).
    var needsSetup: Bool = false
    var network: NetworkInfo? = nil
    var splitDNS: SplitDNSInfo? = nil
    /// Watchdog verdict while connected: nil when the tunnel answers, else "not answering for 40s".
    var health: String? = nil
    /// Connecting, but only waiting for the Mac to have a network again (the icon holds still).
    var waitingForNetwork: Bool = false
    /// Connecting, but only waiting out the pause before the next try (up to a minute, for as long as
    /// the gateway stays away): the icon holds still then too. An animation timer firing three times
    /// a second all night for a gateway that is down cost about 2% of a core.
    var waitingToRetry: Bool = false

    var stateName: String {
        switch phase {
        case .idle: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        }
    }

    var uptimeSeconds: Int? { since.map { Int(Date().timeIntervalSince($0)) } }

    static func durationText(_ s: Int) -> String {
        let s = max(s, 0)   // the Mac's clock was set back since the tunnel came up
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// One readable line, e.g. "connected to Office since 2026-09-05 19:25:38 (up 0:42)".
    var summary: String {
        var s = stateName
        if let n = connectionName { s += " " + (phase == .idle ? "(\(n))" : "to \(n)") }
        if let since { s += " since \(Log.formatter.string(from: since)) (up \(Self.durationText(uptimeSeconds ?? 0)))" }
        if let d = detail { s += " — \(d)" }
        if let h = health { s += " — \(h)" }
        if let e = lastError { s += " — last error: \(e)" }
        if needsSetup { s += " — setup needed" }
        return s
    }
}

/// What FiveT believes of openfortivpn's report on a certificate it would not accept: only the
/// digest on the first "--trusted-cert <64 hex>" line. The subject and issuer lines after it are
/// text from the certificate itself, which whoever made the certificate chose; a '/' in a name
/// even splits it into lines that look like openfortivpn's own ("Tunnel is up and running",
/// another "--trusted-cert …"). So nothing after the refusal is read as state; the details the
/// review shows come from CertCheck, only for a certificate with this very digest.
struct CertReport: Equatable {
    var digest: String
}

/// One openfortivpn, OpenVPN or Xray process and everything that belongs to it. One VPN (OpenVPN,
/// V2Ray, Outline) is up at a time, next to any Forti connections; a second VPN session only lives
/// while the first is still stopping (a switch).
private final class TunnelSession {
    var connection: Connection
    /// An openfortivpn FiveT did not start (found at launch). It has no process handle and can
    /// only be stopped by name.
    let external: Bool
    var status: VPNStatus { didSet { onChange() } }
    var onChange: () -> Void = {}
    var process: Process?
    var pipe: Pipe?
    var lineBuffer = Data()   // bytes, not text: a read can end in the middle of a UTF-8 character
    var certRefused = false           // openfortivpn said it does not accept the certificate: stop reading state
    var certReport: CertReport?       // …and the digest it gave (see processEnded)
    var checkingCert = false          // CertCheck is judging that certificate for this tunnel
    var resolving = false             // V2Ray: the server's name is being looked up; nothing starts a second run meanwhile
    var autoRenewed = false           // a renewal was trusted without asking during this attempt (one only)
    /// Someone clicked Connect (menu, Settings, a review): a certificate question may be put to them
    /// right away. Assistants, links, the CLI and automatic reconnects never trust one by themselves.
    var byUser = false
    var relaunch: Connection?         // connect() arrived while this one was stopping
    var retriedLogin = false          // the one automatic login retry has been used
    var loginPending = false          // the password went out ("Connected to gateway") and no answer yet (LoginGuard)
    var authenticated = false         // this openfortivpn's login got through
    var loginFailedThisRun = false    // this openfortivpn's login was counted as failed
    var sentCredentials = false       // this run sends a password (an OpenVPN profile may use a certificate only)
    var dnsTag: String?               // OpenVPN full tunnel: its DNS is the Mac's (helper dns-set) while up
    var loginOverrideAt: Int?         // Try Anyway: one more login, while the failures on record are still this many
    var waitingForOtherLogin = false  // held back while another login to the same gateway is under way
    var otpModeTrial: OTPMode?        // that retry sends the one-time code the other way; kept if it logs in
    var restartRequested = false      // the watchdog is tearing this tunnel down to bring it back
    var restartWhy: String?           // …and the reason the menu gives until it is back (nil: "Connection lost")
    var probing = false               // a watchdog probe is in flight
    var probeFailures = 0             // consecutive watchdog misses
    var wakeCheck = false             // the Mac woke since this tunnel came up: the next probe decides alone
    var resumeAfterWake = false       // a reconnect came due while the Mac was going to sleep: it starts after the wake
    var resumeAsWait = false          // …and it was a wait (a fresh code, another login), not a retry: it stays one
    var watchdogSkipLogged = false    // "nothing inside this tunnel to probe" was logged once
    var watchdogAnnounced = false     // "watching via …" was logged once for this tunnel
    var stopRequested = false         // the user asked for the stop: never reconnect on its own
    var lastErrorLine: String?
    var currentCode: String?
    var stopTimer: Timer?
    var waitTimer: Timer?
    var reconnectTimer: Timer?
    var reconnectAttempt = 0
    var waitingForNetwork = false     // a reconnect is due, but the Mac has no network: retry when it is back
    var lastNetworkLaunch: Date?      // the last reconnect a network change started (at most one per 10 s)
    var pendingNetwork = NetworkInfo()      // filled from openfortivpn lines while connecting
    var installedResolverDomains: [String] = []
    var serverIPs: [String] = []      // OpenVPN, V2Ray: the server's addresses, looked up before the tunnel (kill switch)
    var localDNS: [String] = []       // …and the Mac's own DNS servers from before the tunnel took over
    /// Kill switch: what `ks-on` gets if this program ends by itself; nil when a stop is wanted or the
    /// switch does not apply. Behind a lock: the termination handler reads it off the main thread.
    var blockOnExit: [String]? {
        get { exitLock.lock(); defer { exitLock.unlock() }; return exitArgs }
        set { exitLock.lock(); exitArgs = newValue; exitLock.unlock() }
    }
    private let exitLock = NSLock()
    private var exitArgs: [String]?

    init(connection: Connection, external: Bool = false, status: VPNStatus) {
        self.connection = connection
        self.external = external
        self.status = status
    }

    var name: String { connection.name }
    var isRunning: Bool { process?.isRunning ?? false }

    func invalidateTimers() {
        stopTimer?.invalidate(); stopTimer = nil
        waitTimer?.invalidate(); waitTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
    }
}

/// Owns the VPN process of the one active connection. All state changes happen on the main thread.
///
/// Flow: connect() stops whatever else is up, runs `sudo -n <helper> run` and writes the
/// config (password included) into its stdin, so it never touches the disk; the helper checks it
/// and starts FiveT's root-owned copy of openfortivpn. Its log lines move the session through
/// connecting -> connected.
/// disconnect(id:) asks the root helper to SIGTERM that one openfortivpn (by the pid of the sudo
/// that started it), which tears its tunnel down cleanly (routes + DNS restored) and exits.
/// disconnect() stops everything, including a session started outside FiveT.
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    /// The live tunnels (connecting, connected or disconnecting), oldest first. Empty when nothing is up.
    @Published private(set) var sessions: [VPNStatus] = []
    /// The last failure, shown in the menu until it has been opened once.
    @Published private(set) var lastError: String?
    /// True when the last failure was "sudo needs a password" or an outdated helper.
    @Published private(set) var needsSetup = false
    /// The kill switch is blocking the Mac's internet now (a VPN that carried all traffic is down
    /// and nobody switched it off).
    @Published private(set) var killSwitchActive = false

    /// A one-time code this close to the end of its 30 s window is not sent; the next one is used.
    static let totpBoundarySeconds = 4
    /// Watchdog: one DNS question per tunnel every `watchdogInterval` s; `watchdogFailures`
    /// misses in a row (about a minute) mean the tunnel is dead and gets reconnected.
    static let watchdogInterval: TimeInterval = 20
    static let watchdogFailures = 3

    /// After a wake, the probe waits this long for Wi-Fi to come back.
    static let wakeProbeDelay: TimeInterval = 8
    /// After the network comes back or changes, this long for DHCP and DNS before reconnecting.
    static let networkSettleDelay: TimeInterval = 2
    /// While there is no network, a reconnect is still tried this often, in case the Mac's network
    /// report is wrong (some VPN and filter products confuse it).
    static let offlineRetryInterval: TimeInterval = 120
    /// A network change starts a session's reconnect at most this often (a flapping Wi-Fi would
    /// otherwise bypass the back-off).
    static let networkLaunchSpacing: TimeInterval = 10

    /// Set by AppDelegate: shows Review New Certificate… for a connection whose certificate question
    /// came from a click, so the person who clicked gets it at once.
    var onReviewNeeded: ((UUID) -> Void)?
    /// Set by AppDelegate: asks the person who clicked Connect whether to log in although the last
    /// logins to that gateway failed (LoginGuard). Try Anyway calls connect(_:byUser:loginOverrideAt:).
    var onLoginLimit: ((UUID) -> Void)?

    private var live: [TunnelSession] = []
    private var lastCodeUsed: [UUID: String] = [:]
    private var watchdogTimer: Timer?
    private var wakeTimer: Timer?
    /// Between willSleep and didWake. A retry timer armed then would fire the instant the Mac
    /// wakes, before Wi-Fi is back, and its attempt would hang until the TCP connect timed out.
    private var asleep = false
    private var sleepCount = 0              // which sleep a watchdog probe was sent before
    /// Watches the Mac's network, so a reconnect waits while there is none and goes the moment
    /// there is one again (or Wi-Fi changes to another network) instead of on its next timer.
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true           // until the monitor's first report
    private var networkSignature: String?  // nil until the monitor's first report
    private var networkTimer: Timer?
    private var moveCheckTimer: Timer?      // checks, once a network report settles, whether tunnels lost their network
    private var lastPathProbe: Date?        // network changes probe the tunnels at most once per watchdog interval
    /// The first helper check has finished, so `needsSetup` is known (fivet:// links wait for it).
    private var setupKnown = false
    private var afterSetupKnown: [() -> Void] = []
    private var pendingAfterExternal: [(connection: Connection, byUser: Bool)] = []   // connect these once the external session has stopped
    private var pendingRemovals = Set<String>()           // resolver files a background removal is still deleting
    /// Every split-DNS and full-tunnel-DNS helper call (add/remove/dns-set/dns-clear) runs on this one
    /// serial queue, in the order it was dispatched: on the global concurrent queue a quick connect
    /// then disconnect could run the clear before the set finished, leaving a resolver pointed at a
    /// tunnel that is already gone.
    private let dnsQueue = DispatchQueue(label: "fivet.dns", qos: .utility)

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.willSleep() }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.didWake() }
        // The screens come on at every full wake (never in a dark wake), sometimes before didWake
        // arrives: whichever comes first ends the sleep, so held reconnects never wait for a
        // notification that is late or never comes. The second finds nothing left to do.
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.asleep else { return }
            Log.shared.write("the screens woke; ending the sleep")
            self.didWake()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        pathMonitor.start(queue: .main)
    }

    // MARK: Read-only views

    /// One status for the whole manager: a tunnel that is changing state first, otherwise the most
    /// recently connected one, otherwise idle with the last error.
    var status: VPNStatus {
        if let s = sessions.first(where: { $0.phase == .connecting || $0.phase == .disconnecting }) { return s }
        if let s = sessions.last(where: { $0.phase == .connected }) { return s }
        return VPNStatus(lastError: lastError, needsSetup: needsSetup)
    }

    /// The status of one connection's tunnel, nil when it is not active.
    func status(for id: UUID) -> VPNStatus? { sessions.first { $0.connectionID == id } }

    var connected: [VPNStatus] { sessions.filter { $0.phase == .connected } }
    var isRunning: Bool { live.contains { $0.isRunning } }
    var isBusy: Bool { sessions.contains { $0.phase == .connecting || $0.phase == .disconnecting } }

    // MARK: Public actions

    /// Called at launch: adopt an openfortivpn that is already running (e.g. app crashed earlier).
    func detectExistingSession() {
        // Before helper v3, configs (password included) went through files in run/; a crash
        // could leave one behind.
        try? FileManager.default.removeItem(at: ConnectionStore.shared.directory.appendingPathComponent("run", isDirectory: true))
        recheckSetup()
        let others = Self.otherFiveTs()
        cleanupLeftoverOpenVPN(others: others)
        let r = Setup.run("/usr/bin/pgrep", ["-x", "openfortivpn"])
        if r.status == 0 {
            var c = Connection()
            c.name = "openfortivpn (started outside FiveT)"
            let s = add(TunnelSession(connection: c, external: true,
                                      status: VPNStatus(phase: .connected, connectionName: c.name)))
            let pids = r.output.trimmed.replacingOccurrences(of: "\n", with: ", ")
            Log.shared.write("found an openfortivpn process already running (pid \(pids))")
            captureNetwork(for: s)
        } else if others.isEmpty {
            // Not next to another FiveT: with an OpenVPN tunnel of its own up, these files are in use.
            cleanupStaleResolvers()
        }
    }

    func toggle(_ c: Connection, byUser: Bool = false) {
        if let st = status(for: c.id), st.phase == .connected || st.phase == .connecting {
            disconnect(id: c.id)
        } else {
            connect(c, byUser: byUser)
        }
    }

    /// Runs `action` once the first helper check has finished (at once after that).
    func whenSetupKnown(_ action: @escaping () -> Void) {
        if setupKnown { action() } else { afterSetupKnown.append(action) }
    }

    /// Starts a tunnel for `c`; another VPN that is up is disconnected first (one VPN at a
    /// time; Forti connections are left alone). Does nothing while `c` is already connecting or connected. `byUser`: a person clicked Connect (see TunnelSession.byUser).
    /// `loginOverrideAt`: that person chose Try Anyway after this many failed logins (LoginGuard);
    /// it allows one login, and only while the count is still that.
    func connect(_ c: Connection, byUser: Bool = false, loginOverrideAt: Int? = nil) {
        if let s = session(for: c.id) {
            switch s.status.phase {
            case .connected:
                return
            case .connecting where s.checkingCert:
                if byUser { s.byUser = true }   // a question that comes up goes to this person
                if let n = loginOverrideAt { s.loginOverrideAt = n }
                return   // CertCheck decides in a moment whether to go on
            case .connecting where s.resolving:
                if byUser { s.byUser = true }
                return   // the server's address is being looked up; Xray starts in a moment
            case .connecting where s.process == nil:
                // Waiting for a retry timer or the network: go now.
                if byUser { s.byUser = true; s.autoRenewed = false }
                if let n = loginOverrideAt { s.loginOverrideAt = n }
                launch(c, in: s)
            case .connecting:
                if byUser { s.byUser = true }
                return
            case .disconnecting, .idle:
                s.relaunch = c   // start again once it has stopped
                if byUser { s.byUser = true }
                if let n = loginOverrideAt { s.loginOverrideAt = n }
            }
            return
        }
        if let ext = live.first(where: { $0.external }) {
            // A session we did not start can only be stopped by name, which takes every
            // openfortivpn with it: stop it first, then start the requested one(s).
            if let i = pendingAfterExternal.firstIndex(where: { $0.connection.id == c.id }) {
                pendingAfterExternal[i].byUser = pendingAfterExternal[i].byUser || byUser
            } else {
                pendingAfterExternal.append((c, byUser))
            }
            if ext.status.phase != .disconnecting { stop(ext) }
            return
        }
        launch(c, byUser: byUser, loginOverrideAt: loginOverrideAt)
    }

    /// Stops one tunnel, as its user asked: the kill switch lets go too.
    func disconnect(id: UUID) {
        guard let s = session(for: id) else { return }
        if s.connection.isOtherVPN { releaseKillSwitch() }   // the block is the VPN's; a Forti stop leaves it
        halt(s)
    }

    /// Stops every tunnel, including one started outside FiveT.
    func disconnect() {
        pendingAfterExternal = []
        releaseKillSwitch()
        guard !live.isEmpty else {
            lastError = nil
            needsSetup = false
            return
        }
        for s in live { halt(s) }
    }

    /// Stops `s` for good: no relaunch, no reconnect, and no kill switch when its program ends.
    private func halt(_ s: TunnelSession) {
        s.relaunch = nil
        s.restartRequested = false
        s.blockOnExit = nil
        stop(s)
    }

    /// Clears a shown error once the user has seen it (menu closed).
    func clearError() {
        if lastError != nil { lastError = nil }
    }

    /// A failure that belongs to no tunnel (a fivet:// link naming no connection), shown the way a
    /// failed connect is: red shield, and the message in the menu until it has been opened.
    func report(_ message: String) {
        Log.shared.write(message, level: .error)
        lastError = message
    }

    /// Checks the helper in the background (at launch and after a setup run). A missing or
    /// outdated one puts "Set Up FiveT…" in the menu before a connect fails on it.
    func recheckSetup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var state = Setup.helperState()
            // An update brings new programs or a new helper: a helper that can replace itself does it now
            // (it checks that this app is FiveT's), so the update asks for nothing.
            // The cheap tests first: canRefreshHelper() starts sudo, and most launches need no refresh at all.
            if state != .missing, state == .outdated || !Setup.copiesMatchBundle() || Setup.copiesCouldShareStorage(), Setup.canRefreshHelper() {
                if let problem = Setup.refreshHelper() {
                    Log.shared.write("helper could not update itself (\(problem)); Install Helper… is needed", level: .error)
                }
                state = Setup.helperState()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if state != .current { Log.shared.write("helper is \(state == .missing ? "not installed" : "outdated"); Set Up FiveT… is needed") }
                self.needsSetup = state != .current
                if !self.setupKnown {
                    self.setupKnown = true
                    let waiting = self.afterSetupKnown
                    self.afterSetupKnown = []
                    waiting.forEach { $0() }
                }
            }
        }
    }

    /// Called from applicationWillTerminate: remove resolver files synchronously, including those
    /// a background removal from stop() has not finished (it may not before the process exits).
    /// With no openfortivpn left at all, every file the helper wrote goes; with one still running
    /// (another copy of FiveT, or one started by hand) those may be its, so only this app's go.
    func shutdownCleanup() {
        var domains = pendingRemovals
        for s in live {
            domains.formUnion(s.installedResolverDomains)
            s.installedResolverDomains = []
        }
        if Setup.run("/usr/bin/pgrep", ["-x", "openfortivpn"]).status != 0, Self.otherFiveTs().isEmpty {
            domains.formUnion(Setup.managedResolverDomains())
        }
        for d in domains.sorted() { _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "remove", d]) }
        // A full tunnel's DNS, so the Mac does not keep asking a tunnel that is gone.
        for s in live { if let tag = s.dnsTag { _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "dns-clear", tag]) } }
        // Never a Mac left without internet and without the app that could unblock it.
        if killSwitchActive { Self.killSwitchHelper(["ks-off"]) }
    }

    /// Quit fallback: SIGKILL every openfortivpn that ignored the TERM, so none is left
    /// running as root with no app to stop it.
    func forceStopAll() {
        for s in live { forceStop(s) }
    }

    // MARK: Session bookkeeping

    private func session(for id: UUID) -> TunnelSession? {
        live.first { !$0.external && $0.connection.id == id }
    }

    @discardableResult
    private func add(_ s: TunnelSession) -> TunnelSession {
        s.onChange = { [weak self] in self?.publish() }
        live.append(s)
        publish()
        updateWatchdog()
        return s
    }

    private func remove(_ s: TunnelSession) {
        s.invalidateTimers()
        s.onChange = {}
        live.removeAll { $0 === s }
        publish()
        updateWatchdog()
    }

    private func publish() {
        sessions = live.map(\.status)
    }

    // MARK: Stopping

    private func stop(_ s: TunnelSession) {
        s.invalidateTimers()
        s.stopRequested = true
        removeSplitDNS(s)
        clearTunnelDNS(s)

        guard let p = s.process else {
            if s.external {
                // A session we did not start: stop it by name.
                s.status.phase = .disconnecting
                Log.shared.write("stopping external openfortivpn session")
                let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "stopall", "TERM"])
                if r.status != 0 { Log.shared.write("helper stopall failed (\(r.status)): \(r.output.trimmed)", level: .error) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    remove(s)
                    let next = pendingAfterExternal
                    pendingAfterExternal = []
                    for item in next { launch(item.connection, byUser: item.byUser) }
                }
            } else {
                // Nothing running: it was waiting for a retry timer.
                Log.shared.write("[\(s.name)] disconnected (was waiting to retry)")
                remove(s)
            }
            return
        }

        if s.loginPending {
            // Its password is at the gateway already: counted now, since a quit does not wait for
            // processEnded. A login that gets through before the stop clears it again.
            s.loginPending = false
            loginFailed(s)
        }
        s.status.phase = .disconnecting
        s.status.detail = nil
        Log.shared.write("[\(s.name)] disconnecting")
        signal(s, p, "TERM")
        let t = Timer(timeInterval: 8, repeats: false) { [weak self, weak s] _ in
            if let s { self?.forceStop(s) }
        }
        RunLoop.main.add(t, forMode: .common)
        s.stopTimer = t
    }

    private func forceStop(_ s: TunnelSession) {
        guard let p = s.process, p.isRunning else { return }
        Log.shared.write("[\(s.name)] openfortivpn did not exit after SIGTERM; sending SIGKILL", level: .error)
        signal(s, p, "KILL")
    }

    /// Sends TERM or KILL to this session's openfortivpn through the root helper, which resolves the
    /// pid of the sudo we started to its openfortivpn child and signals only that one. When the
    /// helper cannot, the signal goes to that sudo, which passes it on to its openfortivpn.
    private func signal(_ s: TunnelSession, _ p: Process, _ sig: String) {
        let pid = String(p.processIdentifier)
        let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "stop", pid, sig])
        if r.status == 0 { return }
        if r.status == Setup.helperNotFoundStatus {
            // The process is already gone; its termination handler is about to run.
            Log.shared.write("[\(s.name)] helper found no openfortivpn under pid \(pid); it has exited already", level: .debug)
            return
        }
        Log.shared.write("[\(s.name)] helper stop failed (\(r.status)): \(r.output.trimmed); signalling sudo instead", level: .error)
        if p.isRunning { sig == "KILL" ? p.interrupt() : p.terminate() }
    }

    private func fail(_ s: TunnelSession, _ message: String, needsSetup: Bool = false) {
        let message = killSwitchActive
            ? message + " The kill switch keeps the Mac's internet blocked: connect again, or choose Unblock Internet in FiveT's menu." : message
        Log.shared.write("[\(s.name)] FAILED: \(message)", level: .error)
        ConnectionStore.shared.mutate(id: s.connection.id) { $0.lastError = message }
        remove(s)
        lastError = message
        self.needsSetup = needsSetup
    }

    // MARK: Launching

    private func launch(_ c: Connection, in existing: TunnelSession? = nil, byUser: Bool = false, loginOverrideAt: Int? = nil) {
        let s: TunnelSession
        if let existing {
            // One openfortivpn per session: a second would be untracked, running as root.
            guard !existing.isRunning else {
                Log.shared.write("[\(c.name)] already starting; not starting a second openfortivpn", level: .debug)
                return
            }
            s = existing
        } else {
            s = add(TunnelSession(connection: c, status: VPNStatus(phase: .connecting, connectionID: c.id,
                                                                   connectionName: c.name, detail: "Starting…")))
            s.byUser = byUser
            s.loginOverrideAt = loginOverrideAt
        }
        // A trial of the other way of sending the one-time code survives every relaunch: retry
        // timers, the network and the wake load the connection as it is saved.
        var c = c
        if let mode = s.otpModeTrial, c.usesTOTP { c.otpMode = mode }
        s.connection = c
        // Whatever was going to start this session later (a retry, a fresh code, the network) is
        // superseded by this start.
        s.waitTimer?.invalidate(); s.waitTimer = nil
        s.reconnectTimer?.invalidate(); s.reconnectTimer = nil
        s.lastErrorLine = nil
        s.currentCode = nil
        s.stopRequested = false
        s.waitingForNetwork = false
        s.resumeAfterWake = false
        s.wakeCheck = false   // a new openfortivpn: nothing it carries slept
        s.loginPending = false
        s.authenticated = false
        s.loginFailedThisRun = false
        s.certRefused = false
        s.certReport = nil
        if c.isOtherVPN {
            // The Mac's own DNS servers, read while no tunnel of this session answers for them: the
            // kill switch leaves them reachable, so a blocked Mac can still look up its VPN server.
            let tunnelDNS = s.pendingNetwork.dnsServers
            let dns = Self.systemDNSServers().filter { Self.isIPAddress($0) && !$0.hasPrefix("198.18.") && !tunnelDNS.contains($0) }
            if !dns.isEmpty { s.localDNS = dns }
        }
        s.pendingNetwork = NetworkInfo()
        let detail = s.reconnectAttempt > 0 ? "Reconnecting (try \(s.reconnectAttempt))…" : "Starting…"
        s.status = VPNStatus(phase: .connecting, connectionID: c.id, connectionName: c.name, detail: detail)
        lastError = nil
        needsSetup = false

        // One VPN (OpenVPN, V2Ray, Outline) at a time: another one that is up or starting stops first,
        // and this one starts once the other has let go of its routes (they would clash). A Forti
        // connection runs next to a VPN and to other Forti connections, and neither stops the other.
        // With the kill switch on, a switch from one VPN to another stays blocked in between.
        let guarded = c.isOtherVPN && ConnectionStore.shared.killSwitch
        let otherVPNs = c.isOtherVPN ? live.filter { $0 !== s && !$0.external && $0.connection.isOtherVPN } : []
        for o in otherVPNs where o.status.phase != .disconnecting {
            Log.shared.write("[\(c.name)] switching from \(o.name): one VPN at a time")
            if guarded, o.blockOnExit != nil { blockInternet(for: o) }
            halt(o)
        }
        if let other = otherVPNs.first {
            s.status.detail = "Switching from \(other.name)…"
            let t = Timer(timeInterval: 0.5, repeats: false) { [weak self, weak s] _ in
                guard let self, let s, self.live.contains(where: { $0 === s }) else { return }
                self.launch(s.connection, in: s)
            }
            RunLoop.main.add(t, forMode: .common)
            s.waitTimer = t
            return
        }
        // Still blocked from the VPN before: a VPN keeps it so (with this network's DNS servers let
        // through). A Forti connection leaves the block alone: it belongs to the VPN, and only that
        // VPN coming back, or the user, lifts it. shortcut: the block also stops this Forti gateway
        // from being reached until then; let its address through if that ever matters.
        if killSwitchActive && guarded { blockInternet(for: s) }

        switch Setup.helperState() {
        case .current: break
        case .outdated:
            // A helper that can replace itself does it from this app, with no password; then this starts again.
            if Setup.canRefreshHelper() {
                s.status.detail = "Updating FiveT's helper…"
                publish()
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak s] in
                    let problem = Setup.refreshHelper()
                    DispatchQueue.main.async {
                        guard let self, let s, self.live.contains(where: { $0 === s }), s.status.phase == .connecting, !s.stopRequested else { return }
                        if problem == nil {
                            self.launch(s.connection, in: s)
                        } else {
                            self.fail(s, "FiveT's helper needs a one-time security update, and could not do it by itself (\(problem ?? "")). Click Set Up FiveT… in FiveT's menu (asks for your Mac password once).", needsSetup: true)
                        }
                    }
                }
                return
            }
            fail(s, "FiveT's helper needs a one-time security update. Click Set Up FiveT… in FiveT's menu (asks for your Mac password once).", needsSetup: true)
            return
        case .missing:
            fail(s, "FiveT is not set up on this Mac yet. Click Set Up FiveT… in FiveT's menu (asks for your Mac password once).", needsSetup: true)
            return
        }
        // Each value is one config line: a line break would end it early, and openfortivpn repeats a
        // line it cannot read in its log, password and all.
        let fields = [("gateway", c.host), ("realm", c.realm), ("username", c.username), ("password", c.password), ("TOTP secret", c.totpSecret)]
        if let bad = fields.first(where: { $0.1.contains(where: \.isNewline) }) {
            fail(s, "The \(bad.0) of \(c.name) contains a line break. Retype it in Settings → \(c.isOpenVPN ? "VPN" : "Forti").")
            return
        }
        if c.isV2Ray {
            launchV2Ray(c, in: s)
            return
        }
        // The helper refuses options it does not allow, and names them in its error, which would
        // then reach the log and assistants: an "option" can be a secret pasted in the wrong place
        // ("JBSWY3DP…======" looks like key = value). Refused here, without naming them.
        if c.isOpenVPN {
            if c.ovpnProfile.trimmed.isEmpty {
                fail(s, "\(c.name) has no OpenVPN profile. Import one in Settings → VPN.")
                return
            }
            let bad = OpenVPNProfile.problems(c.ovpnProfile)
            if !bad.isEmpty {
                fail(s, "\(c.name)'s OpenVPN profile uses options FiveT does not allow: \(bad.joined(separator: ", ")). Import it again in Settings → VPN.")
                return
            }
        }
        let unknown = c.isOpenVPN ? [] : Connection.optionLines(c.extraConfig).map(\.key).filter { !Setup.allowedOptions.contains($0) }
        if !unknown.isEmpty {
            fail(s, unknown.count == 1
                 ? "\(c.name) has an openfortivpn option FiveT does not allow. It is not shown: it may hold a password. Check Settings → Forti → Advanced."
                 : "\(c.name) has \(unknown.count) openfortivpn options FiveT does not allow. They are not shown: they may hold a password. Check Settings → Forti → Advanced.")
            return
        }
        // Never the failed login that gets the Mac's address banned (LoginGuard). When only the
        // saved way of sending the one-time code has failed, the other way goes first.
        if s.otpModeTrial == nil, let other = untriedOTPMode(for: c) {
            Log.shared.write("[\(c.name)] the failed login(s) on record had the one-time code \(Self.describe(c.otpMode)); this time it is \(Self.describe(other))")
            c.otpMode = other
            s.otpModeTrial = other
            s.retriedLogin = true   // the one switch of mode is this one
            s.connection = c
        }
        let key = c.loginGuardKey
        let failed = LoginGuard.shared.count(for: key)
        let tryAnyway = s.loginOverrideAt == failed   // agreed to at exactly this count
        if failed >= LoginGuard.limit && !tryAnyway {
            s.loginOverrideAt = nil
            if s.byUser {
                // A click asks first; everything else (reconnects, assistants, the CLI, links) stops.
                Log.shared.write("[\(c.name)] \(failed) logins to \(key) failed in a row; asking before logging in again")
                remove(s)
                onLoginLimit?(c.id)
            } else {
                fail(s, loginLimitMessage(c))
            }
            return
        }
        let inFlight = loginsInFlight(to: key, besides: s)
        if inFlight > 0 && (tryAnyway || failed + inFlight >= LoginGuard.limit) {
            // Another login to this gateway may still fail: one at a time, then decide again.
            waitForOtherLogin(s)
            return
        }
        s.waitingForOtherLogin = false
        guard c.isOpenVPN else { start(c, in: s); return }
        // The addresses of the profile's servers, for the kill switch (OpenVPN looks the names up
        // again itself). Before the one-time code is made: a slow lookup must not let it expire.
        let hosts = OpenVPNProfile.serverHosts(c.ovpnProfile)
        resolve(hosts.filter { !Self.isIPAddress($0) }, for: s) { [weak self, weak s] found in
            guard let self, let s else { return }
            s.serverIPs = hosts.filter(Self.isIPAddress) + found.values.flatMap { $0 }
            if self.killSwitchActive { self.blockInternet(for: s) }
            self.start(c, in: s)
        }
    }

    /// The last step of launch() for openfortivpn and OpenVPN: the login as it goes out now.
    private func start(_ c: Connection, in s: TunnelSession) {
        var password = c.password
        var otp: String?
        if c.usesTOTP {
            guard let code = TOTP.code(secret: c.totpSecret) else {
                fail(s, "The TOTP secret for \(c.name) is not valid Base32.")
                return
            }
            let remaining = TOTP.secondsRemaining()
            if lastCodeUsed[c.id] == code || remaining <= Self.totpBoundarySeconds {
                // Servers reject a reused code, and a code sent in the last seconds of its window
                // can expire before the gateway checks it (clock skew): wait for the next window.
                let wait = remaining + 1
                s.status.detail = "Waiting \(wait)s for a fresh code…"
                let why = lastCodeUsed[c.id] == code ? "current code was already used" : "current code expires in \(remaining)s"
                Log.shared.write("[\(c.name)] \(why); waiting \(wait)s")
                let t = Timer(timeInterval: Double(wait), repeats: false) { [weak self, weak s] _ in
                    if let s { self?.launch(c, in: s) }
                }
                RunLoop.main.add(t, forMode: .common)
                s.waitTimer = t
                return
            }
            s.currentCode = code
            if c.otpMode == .appendToPassword { password += code } else { otp = code }
        }

        let command: String
        let config: String
        if c.isOpenVPN {
            command = "ovpn-run"
            config = OpenVPNProfile.forLaunch(c, code: s.currentCode)
            // The helper truncates stdin at this many bytes; checked on the text actually going to it
            // (certificates inlined, the login appended), not the raw imported file, which can be
            // smaller. A silent mid-block cut gets a confusing "unclosed" error from the helper and
            // can lose the appended password.
            guard config.utf8.count <= Setup.ovpnMaxConfigBytes else {
                fail(s, "\(c.name)'s OpenVPN profile, with its login added, is \(config.utf8.count) bytes: more than FiveT's helper allows (\(Setup.ovpnMaxConfigBytes)). Use a smaller certificate or key, or ask your VPN administrator for a shorter profile.")
                return
            }
            s.sentCredentials = OpenVPNProfile.needsLogin(c.ovpnProfile)
        } else {
            command = "run"
            config = Self.openfortivpnConfig(c, password: password, otp: otp)
            s.sentCredentials = true
        }
        startHelper(s, command: command, input: config, verbose: ConnectionStore.shared.verboseLogging)
    }

    /// Runs the helper's `command` for `s` (openfortivpn, OpenVPN or Xray as root), with `input` on
    /// its stdin; its output comes back line by line through handle(line:in:).
    private func startHelper(_ s: TunnelSession, command: String, input config: String, verbose: Bool) {
        let c = s.connection
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Setup.resolverHelperPath, command] + (verbose ? ["-v"] : [])
        let pipe = Pipe()
        let input = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = input
        s.lineBuffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak s] h in
            let read = h.availableData
            // Empty means EOF; left installed, the handler keeps firing on the closed pipe.
            guard !read.isEmpty else { h.readabilityHandler = nil; return }
            // A copy of exactly the bytes read: a read comes in a 16 KB buffer for a line of 65 bytes, and
            // a burst of lines (Xray or openfortivpn with the detailed log) queues one buffer per line on
            // the main thread, until it catches up.
            let d = read.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: read.count) }
            DispatchQueue.main.async { if let s { self?.consume(d, in: s) } }
        }
        p.terminationHandler = { [weak self, weak s] proc in
            // Kill switch: the program ended by itself and its routes went with it. Blocked here, on
            // this thread, before anything else: every moment until then, traffic leaves unprotected.
            var blocked = false
            if let s, let args = s.blockOnExit {
                s.blockOnExit = nil
                blocked = Self.killSwitchHelper(["ks-on"] + args)
            }
            // Small delay so log lines already read get processed first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [blocked] in if let s { self?.processEnded(proc, s, blocked: blocked) } }
        }
        do {
            try p.run()
        } catch {
            fail(s, "Could not start sudo: \(error.localizedDescription)")
            return
        }
        // The config reaches the helper through the pipe and is never written to disk. A helper
        // that already exited must not take FiveT down with SIGPIPE: the write just fails then.
        let w = input.fileHandleForWriting
        _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? w.write(contentsOf: Data(config.utf8))
        try? w.close()
        s.process = p
        s.pipe = pipe
        // How the one-time code goes out is not in openfortivpn's own log when it is part of the password.
        let codeNote = c.usesTOTP ? ", one-time code \(Self.describe(c.otpMode))" : ""
        Log.shared.write("[\(c.name)] launched sudo -n <helper> \(command)\(verbose ? " -v" : "") (pid \(p.processIdentifier)) → \(c.gatewayDescription)\(codeNote)")
    }

    /// openfortivpn's config: one "key = value" line each, the password (and code) included.
    private static func openfortivpnConfig(_ c: Connection, password: String, otp: String?) -> String {
        var lines = [
            "host = \(c.host.trimmed)",
            "port = \(c.port)",
            "username = \(c.username.trimmed)",
            "password = \(password)",
            // macOS: let Apple's pppd publish DNS; do not rewrite /etc/resolv.conf.
            "set-dns = 0",
            "pppd-use-peerdns = 1",
            "set-routes = 1",
        ]
        if !c.realm.trimmed.isEmpty { lines.append("realm = \(c.realm.trimmed)") }
        if let otp { lines.append("otp = \(otp)") }
        if c.hasPinForGateway { lines.append("trusted-cert = \(c.trustedCert)") }
        let extra = c.extraConfigForOpenfortivpn
        if !extra.isEmpty { lines.append(extra) }   // later lines override earlier ones
        // Never openfortivpn's own `persistent` reconnects: it would log in again by itself, past
        // the failed-login limit and with a one-time code already used. FiveT reconnects itself.
        lines.append("persistent = 0")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: openfortivpn output

    private func consume(_ data: Data, in s: TunnelSession) {
        s.lineBuffer.append(data)
        while let nl = s.lineBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: s.lineBuffer[s.lineBuffer.startIndex..<nl], as: UTF8.self)
            s.lineBuffer.removeSubrange(s.lineBuffer.startIndex...nl)
            handle(line: line, in: s)
        }
    }

    /// Splits an openfortivpn line into (level, text without the "INFO:   " style prefix).
    private static func classify(_ line: String) -> (LogLevel, String) {
        for (prefix, level) in [("ERROR:", LogLevel.error), ("WARN:", .info), ("INFO:", .info), ("DEBUG:", .debug), ("sudo:", .error)] {
            if line.hasPrefix(prefix) {
                let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return (level, prefix == "WARN:" ? "warning: " + body : (prefix == "sudo:" ? line : body))
            }
        }
        // Lines without a prefix come from pppd / route ("add net 10.0.0.0: gateway ppp0").
        return (.debug, line)
    }

    private static func isPacketTrace(_ text: String) -> Bool {
        text.contains("pppd ---> gateway") || text.contains("gateway ---> pppd")
    }

    /// Secrets openfortivpn writes into its own log lines, hidden before FiveT logs them: the session
    /// cookie (a live login, with Detailed log on), the one-time code, and a config line it could
    /// not read (which could be a password pasted into the extra options).
    /// What masked() keeps after a marker, in the order it looks for them. maskedMarkers is built from
    /// this table, so Log.scrubOldSecrets, which looks for the markers in a file's raw bytes before it
    /// goes through the lines, cannot miss one that masked() reacts to.
    private static let maskedAfterMarker = [("SVPNCOOKIE=", "<hidden>"), ("Cookie:", " <hidden>"), ("One-time password =", " <hidden>")]
    static let maskedMarkers = ["Bad line in configuration file"] + maskedAfterMarker.map(\.0)

    static func masked(_ line: String) -> String {
        if let r = line.range(of: "Bad line in configuration file") {
            return String(line[..<r.lowerBound]) + "a config line could not be read and was skipped (not shown: it may hold a password)"
        }
        for (marker, rest) in maskedAfterMarker {
            if let r = line.range(of: marker) { return String(line[..<r.upperBound]) + rest }
        }
        return line
    }

    /// The digest on openfortivpn's "ERROR:      --trusted-cert <digest>" line: exactly 64 lower-case hex digits.
    static func trustedCertDigest(in line: String) -> String? {
        let pattern = #"^ERROR:\s+--trusted-cert ([0-9a-f]{64})$"#
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[r].suffix(64))
    }

    private func handle(line raw: String, in s: TunnelSession) {
        let line = raw.trimmed
        guard !line.isEmpty else { return }
        let c = s.connection
        if c.isOpenVPN { handleOpenVPN(line, in: s); return }
        if c.isV2Ray { handleV2Ray(line, in: s); return }

        // openfortivpn has refused the certificate: what follows describes the certificate, in text
        // its maker chose (see CertReport). Only the first digest line counts; nothing is read as
        // state, and the lines go to the debug log, away from the events assistants read.
        if s.certRefused {
            if s.certReport == nil, let digest = Self.trustedCertDigest(in: line) {
                s.certReport = CertReport(digest: digest)
                Log.shared.write("[\(c.name)] the gateway's certificate is \(digest)")
                stopAfterRefusal(s)
            } else {
                Log.shared.write("[\(c.name)] \(Self.classify(Self.masked(line)).1)", level: .debug)
            }
            return
        }

        let (level, text) = Self.classify(Self.masked(line))
        if Self.isPacketTrace(text) && !ConnectionStore.shared.verbosePackets { return }
        Log.shared.write("[\(c.name)] \(text)", level: level)

        if line.hasPrefix("ERROR:") && line.contains("not in the local whitelist") {
            // "Gateway certificate validation failed, and the certificate digest is not in the local
            // whitelist": the same words for a gateway met for the first time and for a changed
            // certificate; processEnded tells them apart.
            s.certRefused = true
            s.lastErrorLine = line
            return
        }

        if line.contains("Connected to gateway") {
            // openfortivpn accepted the certificate (the pin, or a public certificate authority
            // for the host name): from now on another certificate from this gateway is a change.
            s.status.detail = "Logging in…"
            // The password goes out right after this line (auth_log_in): from here a login counts.
            s.loginPending = true
            if s.loginOverrideAt != nil {
                s.loginOverrideAt = nil   // Try Anyway was for this one login
                Log.shared.write("[\(c.name)] logging in although the last logins to \(c.loginGuardKey) failed (Try Anyway)")
            }
            if let code = s.currentCode { lastCodeUsed[c.id] = code }
            // The certificate is the trusted one (or one a CA vouches for): a question about another
            // certificate from this gateway is moot. Only if the gateway was not edited meanwhile.
            let ran = c.gatewayKey
            ConnectionStore.shared.mutate(id: c.id) {
                guard $0.gatewayKey == ran else { return }
                $0.markGatewayVerified()
                $0.clearPendingReview()
            }
        } else if line.contains("Authenticated") {
            s.status.detail = "Authenticated, building tunnel…"
            s.retriedLogin = false
            loginSucceeded(s)
        } else if line.contains("Got addresses:") {
            // "Got addresses: [10.0.1.5], ns [10.0.0.53, 10.0.0.54], ns_suffix [corp.example;intranet.example]"
            let lists = Self.bracketLists(in: line)
            if let ip = lists.first?.first { s.pendingNetwork.tunnelIP = ip }
            if lists.count > 1 { s.pendingNetwork.dnsServers = lists[1] }
            if lists.count > 2 { s.pendingNetwork.searchDomains = Connection.cleanDomains(lists[2]) }
            s.status.detail = "Got address \(s.pendingNetwork.tunnelIP), bringing interface up…"
        } else if line.contains("Got search domain") {
            s.pendingNetwork.searchDomains += Self.bracketLists(in: line).flatMap { $0 }
        } else if let iface = Self.interfaceUp(in: line) {
            s.pendingNetwork.interface = iface
        } else if line.contains("Tunnel is up and running") {
            tunnelUp(s)
            recordCertificateNames(for: c)
        } else if line.hasPrefix("ERROR:") || line.hasPrefix("sudo:") {
            s.lastErrorLine = line
            if line.hasPrefix("ERROR:") && s.loginPending {
                // "Could not authenticate to gateway…" and the like: counted at once, before anything
                // else can decide on a count that is behind.
                s.loginPending = false
                loginFailed(s)
            }
            if line.contains("a password is required") || line.contains("not allowed") || line.contains("not in the sudoers")
                || line.contains("Install Helper") {
                s.status.needsSetup = true
            }
        }
    }

    /// The gateway let this login in: the failed-login count starts over, and a trial of the other
    /// way of sending the one-time code becomes the saved way.
    private func loginSucceeded(_ s: TunnelSession) {
        let c = s.connection
        s.loginPending = false
        s.authenticated = true
        let cleared = LoginGuard.shared.recordSuccess(c.loginGuardKey)
        if cleared > 0 { Log.shared.write("[\(c.name)] logged in; the \(cleared) failed login(s) before no longer count") }
        if let mode = s.otpModeTrial {
            s.otpModeTrial = nil
            // The other way of sending the code is the one this gateway wants: keep it (only if
            // this login really sent it that way).
            if c.otpMode == mode {
                ConnectionStore.shared.mutate(id: c.id) { $0.otpMode = mode }
                Log.shared.write("[\(c.name)] the gateway wants the one-time code \(Self.describe(mode)); saved that under One-time code")
            }
        }
        // What this login went out with (not what Settings says by now): a later refusal of the same
        // way is not blamed on it (untriedOTPMode).
        if c.usesTOTP && !c.otpModeAccepted {
            let key = c.otpAcceptedKey
            ConnectionStore.shared.mutate(id: c.id) { $0.acceptedOTP = key }
        }
    }

    /// The tunnel is up: connected, with what was learned while connecting.
    private func tunnelUp(_ s: TunnelSession) {
        let c = s.connection
        if s.reconnectAttempt > 0 { Log.shared.write("[\(c.name)] reconnected after \(s.reconnectAttempt) attempt(s)") }
        s.reconnectAttempt = 0
        s.probeFailures = 0
        s.watchdogSkipLogged = false
        s.watchdogAnnounced = false
        s.status = VPNStatus(phase: .connected, connectionID: c.id, connectionName: c.name, since: Date(),
                             network: s.pendingNetwork)
        s.byUser = false
        s.autoRenewed = false
        if c.isOtherVPN { releaseKillSwitch() }   // the tunnel's routes carry everything again (a Forti tunnel's do not)
        arm(s)
        ConnectionStore.shared.mutate(id: c.id) {
            $0.lastConnectedAt = Date(); $0.lastError = nil
            // Logged in with the trusted certificate: a question about another one is moot.
            $0.clearPendingReview()
        }
        captureNetwork(for: s)
    }

    // MARK: V2Ray

    /// lastErrorLine of a run whose server carried no traffic (see friendly()).
    static let v2rayNoTraffic = "V2RAY_NO_TRAFFIC"

    /// A V2Ray connection: FiveT's copy of Xray with the config V2RayConfig.forLaunch builds. There
    /// is no login, so no failed-login count.
    private func launchV2Ray(_ c: Connection, in s: TunnelSession) {
        // A server given by name is looked up now, with the Mac's own DNS, before FiveT's tunnel and DNS
        // exist: once they do, Xray can only ask through the server, and cannot reach the server without
        // the answer (an Outline key that names its server never connected).
        let names = V2RayConfig.serverNames(of: c.v2rayOutbound)
        resolve(names, for: s) { [weak self, weak s] found in
            guard let self, let s else { return }
            if let missing = names.first(where: { found[$0]?.isEmpty ?? true }) {
                if s.reconnectAttempt > 0 {
                    // An automatic reconnect (the Wi-Fi changed, the Mac woke): the new network's DNS may
                    // not answer yet. Keep trying like for a run that failed to start; giving up here
                    // would leave the connection down for good although Reconnect is on.
                    Log.shared.write("[\(c.name)] reconnect attempt \(s.reconnectAttempt) failed: could not look up \(missing)", level: .error)
                    self.scheduleReconnect(s, attempt: s.reconnectAttempt + 1, why: "Could not look up the server")
                    return
                }
                self.fail(s, "FiveT could not find \(missing), the address of \(c.name)'s server, with this Mac's DNS. Check the internet connection (another VPN or a filter can block the lookup), then try again.")
                return
            }
            for (name, ips) in found.sorted(by: { $0.key < $1.key }) {
                Log.shared.write("[\(c.name)] \(name) is \(ips.joined(separator: ", ")) (looked up before the tunnel starts)", level: .debug)
                if ips.allSatisfy(Self.isPrivateOrLocal) {
                    Log.shared.write("[\(c.name)] \(name) resolves to a private address: a network that blocks the server often answers with one; the connection will probably not work")
                }
            }
            s.serverIPs = V2RayConfig.serverAddresses(of: c.v2rayOutbound).filter(Self.isIPAddress) + found.values.flatMap { $0 }
            self.startV2Ray(c, in: s, serverIPs: found)
        }
    }

    /// Looks `names` up with the Mac's own DNS, off the main thread, then goes on with `then` on it
    /// (at once when there is none to look up), unless the session was stopped meanwhile.
    private func resolve(_ names: [String], for s: TunnelSession, then: @escaping ([String: [String]]) -> Void) {
        guard !names.isEmpty else { then([:]); return }
        s.resolving = true
        s.status.detail = "Looking up the server…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak s] in
            let found = Self.lookUp(names)
            DispatchQueue.main.async {
                guard let self, let s else { return }
                s.resolving = false
                guard self.live.contains(where: { $0 === s }), s.status.phase == .connecting, !s.stopRequested else { return }
                then(found)
            }
        }
    }

    /// The second half of launchV2Ray: the server's addresses are known, so Xray can start.
    private func startV2Ray(_ c: Connection, in s: TunnelSession, serverIPs: [String: [String]]) {
        guard let tun = Self.freeTunName() else {
            fail(s, "macOS has no free tunnel interface for \(c.name). Restart the Mac, then try again.")
            return
        }
        // .ir names are asked of the DNS server the Mac uses now, as they would be without the VPN.
        let localDNS = Self.systemDNSServers().filter { Self.isIPv4($0) && !$0.hasPrefix("198.18.") }
        // Forti gateways given by address stay off the V2Ray server (openfortivpn routes its own,
        // but one that starts first, or a host route that is gone, would otherwise go through it).
        let direct = ConnectionStore.shared.connections.filter { $0.kind == .fortinet }
            .map { $0.endpoint.host }.filter(Self.isIPv4).map { $0 + "/32" }
        let config: String
        do {
            config = try V2RayConfig.forLaunch(c, tun: tun, localDNS: localDNS, direct: Array(Set(direct)).sorted(),
                                               serverIPs: serverIPs, verbose: ConnectionStore.shared.verboseLogging)
        } catch {
            fail(s, "\(c.name) cannot be used: \(error.localizedDescription). Import it again in Settings → VPN.")
            return
        }
        // Still blocked by the kill switch: this server and this tunnel are what may pass now.
        if killSwitchActive { blockInternet(for: s, tun: tun) }
        s.sentCredentials = false
        s.pendingNetwork.interface = tun
        s.pendingNetwork.tunnelIP = V2RayConfig.tunAddress
        s.pendingNetwork.peerIP = V2RayConfig.tunGateway
        s.pendingNetwork.dnsServers = [V2RayConfig.tunGateway]
        s.pendingNetwork.fullTunnel = true
        startHelper(s, command: "xray-run", input: config, verbose: false)   // its log level is in the config
    }

    /// One line of Xray's log ("2026/10/12 22:35:20.885412 [Warning] core: Xray 26.10.10 started").
    /// Started is not connected: the Mac's DNS goes into the tunnel, then checkV2Ray() makes sure
    /// the server really carries traffic.
    private func handleV2Ray(_ line: String, in s: TunnelSession) {
        let c = s.connection
        var text = line
        if let r = line.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? "#, options: .regularExpression) {
            text = String(line[r.upperBound...])
        }
        let error = text.hasPrefix("[Error]") || text.hasPrefix("Failed to start") || text.hasPrefix("ERROR:") || text.hasPrefix("sudo:")
        Log.shared.write("[\(c.name)] \(text)", level: error ? .error : text.hasPrefix("[Warning]") ? .info : .debug)
        if text.contains("core: Xray") && text.contains(" started") {
            guard s.status.phase == .connecting else { return }
            s.status.detail = "Checking the server…"
            publish()
            applyTunnelDNS(for: s, network: s.pendingNetwork)
            checkV2Ray(s, attempt: 1)
        } else if error {
            if s.lastErrorLine == nil { s.lastErrorLine = text }
            if text.contains("a password is required") || text.contains("not in the sudoers") || text.contains("Install Helper") {
                s.status.needsSetup = true
            }
        }
    }

    /// Up once a web request gets through the server (three tries, about 20 s); otherwise the run
    /// ends as a failure, which processEnded reports (or retries, for a reconnect).
    private func checkV2Ray(_ s: TunnelSession, attempt: Int) {
        let run = s.process
        // A moment for the routes and the DNS setting to take effect.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (attempt == 1 ? 0.7 : 0)) { [weak self, weak s] in
            let ok = Self.v2rayCarriesTraffic(timeout: 6)
            DispatchQueue.main.async {
                guard let self, let s, s.process != nil, s.process === run, s.status.phase == .connecting, !s.stopRequested else { return }
                if ok {
                    Log.shared.write("[\(s.name)] the server carries traffic")
                    self.tunnelUp(s)
                } else if attempt < 3 {
                    Log.shared.write("[\(s.name)] no answer through the server yet (try \(attempt)/3)", level: .debug)
                    s.status.detail = "Checking the server (try \(attempt + 1))…"
                    self.publish()
                    self.checkV2Ray(s, attempt: attempt + 1)
                } else {
                    Log.shared.write("[\(s.name)] no web request got through the server", level: .error)
                    s.lastErrorLine = Self.v2rayNoTraffic
                    self.endRun(s)
                }
            }
        }
    }

    /// Ends the running program as a failed attempt, not a disconnect: processEnded then says why,
    /// or tries again when this was a reconnect.
    private func endRun(_ s: TunnelSession) {
        guard let p = s.process else { return }
        let pid = String(p.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "stop", pid, "TERM"])
        }
    }

    /// A small web request through whatever carries the Mac's traffic: any HTTP answer counts.
    /// Plain HTTP to two well-known "generate_204" addresses, so no certificate gets in the way.
    static func v2rayCarriesTraffic(timeout: TimeInterval) -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        for address in ["http://cp.cloudflare.com/generate_204", "http://www.gstatic.com/generate_204"] {
            guard let url = URL(string: address) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            let done = DispatchSemaphore(value: 0)
            var answered = false
            session.dataTask(with: req) { _, response, _ in
                answered = response is HTTPURLResponse
                done.signal()
            }.resume()
            if done.wait(timeout: .now() + timeout + 1) == .success, answered { return true }
        }
        return false
    }

    /// A utun name no interface has now, for Xray's TUN ("utun100" and up).
    static func freeTunName() -> String? {
        (100..<200).lazy.map { "utun\($0)" }.first { if_nametoindex($0) == 0 }
    }

    /// The DNS servers the Mac uses now (State:/Network/Global/DNS).
    static func systemDNSServers() -> [String] {
        let out = Setup.run("/bin/sh", ["-c", "echo 'show State:/Network/Global/DNS' | /usr/sbin/scutil"]).output
        return out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    static func isIPAddress(_ s: String) -> Bool {
        var a = in6_addr()
        return isIPv4(s) || inet_pton(AF_INET6, s, &a) == 1
    }

    /// The addresses the Mac's own DNS gives each name now, IPv4 first; a name it cannot answer is
    /// missing or empty. getaddrinfo can wait many seconds on a dead network, so every name gets its
    /// own thread and the wait is capped: call this off the main thread.
    static func lookUp(_ names: [String]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for name in names {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let ips = addresses(of: name)
                lock.lock(); found[name] = ips; lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 12)
        lock.lock(); defer { lock.unlock() }
        return found
    }

    private static func addresses(of name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var v4: [String] = [], v6: [String] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                // A scoped (link-local) address means nothing to Xray.
                if !ip.contains("%") {
                    if entry.pointee.ai_family == AF_INET { if !v4.contains(ip) { v4.append(ip) } }
                    else if entry.pointee.ai_family == AF_INET6, !v6.contains(ip) { v6.append(ip) }
                }
            }
            next = entry.pointee.ai_next
        }
        return v4 + v6
    }

    /// Private, loopback, link-local or unspecified: not where a server on the internet lives.
    static func isPrivateOrLocal(_ ip: String) -> Bool {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else {
            let low = ip.lowercased()
            return low == "::1" || low == "::" || low.hasPrefix("fe80") || low.hasPrefix("fc") || low.hasPrefix("fd")
        }
        let v = UInt32(bigEndian: a.s_addr)
        let b1 = v >> 24, b2 = (v >> 16) & 0xff
        return b1 == 0 || b1 == 10 || b1 == 127 || (b1 == 172 && (16...31).contains(b2)) || (b1 == 192 && b2 == 168) || (b1 == 169 && b2 == 254)
    }

    // MARK: OpenVPN output

    /// One line of OpenVPN's log (the helper runs it at verb 3, without timestamps). The login goes
    /// out with the key exchange ("Peer Connection Initiated"); the server answers AUTH_FAILED, or
    /// sends the tunnel's settings (PUSH_REPLY), and "Initialization Sequence Completed" means up.
    private func handleOpenVPN(_ line: String, in s: TunnelSession) {
        let c = s.connection
        let error = Self.isOpenVPNError(line)
        Log.shared.write("[\(c.name)] \(line)", level: error ? .error : Self.isOpenVPNChatter(line) ? .debug : .info)

        if line.contains("Peer Connection Initiated") {
            if s.sentCredentials && !s.authenticated {
                // From here the login counts (LoginGuard), and its one-time code is used.
                s.loginPending = true
                if let code = s.currentCode { lastCodeUsed[c.id] = code }
                if s.loginOverrideAt != nil {
                    s.loginOverrideAt = nil   // Try Anyway was for this one login
                    Log.shared.write("[\(c.name)] logging in although the last logins to \(c.loginGuardKey) failed (Try Anyway)")
                }
                s.status.detail = "Logging in…"
            } else if !s.sentCredentials {
                s.status.detail = "Connected to the server, setting up…"
            }
            // else: already authenticated this run (a TLS renegotiation can print this line again on
            // a connection that is still fine) — nothing to redo, and never a fresh "login" to count.
        } else if line.contains("AUTH_FAILED") {
            s.lastErrorLine = line
            if s.loginPending {
                s.loginPending = false
                loginFailed(s)
            }
        } else if let r = line.range(of: "PUSH_REPLY,") {
            if s.sentCredentials && !s.authenticated { loginSucceeded(s) } else { s.authenticated = true }
            // "PUSH_REPLY,route 10.99.0.0 255.255.255.0,dhcp-option DNS 10.8.0.1,dhcp-option DOMAIN corp,
            //  redirect-gateway def1,ifconfig 10.8.0.2 255.255.255.0,…'" (a long reply comes in parts)
            var body = String(line[r.upperBound...])
            if body.hasSuffix("'") { body.removeLast() }
            for option in body.split(separator: ",") {
                let w = option.split(separator: " ").map(String.init)
                guard let key = w.first else { continue }
                switch key {
                case "ifconfig" where w.count > 1: s.pendingNetwork.tunnelIP = w[1]
                case "route-gateway" where w.count > 1: s.pendingNetwork.peerIP = w[1]
                case "redirect-gateway": s.pendingNetwork.fullTunnel = true
                case "dhcp-option" where w.count > 2:
                    switch w[1].uppercased() {
                    case "DNS", "DNS6": if !s.pendingNetwork.dnsServers.contains(w[2]) { s.pendingNetwork.dnsServers.append(w[2]) }
                    case "DOMAIN", "DOMAIN-SEARCH", "ADAPTER_DOMAIN_SUFFIX":
                        s.pendingNetwork.searchDomains = Connection.cleanDomains(s.pendingNetwork.searchDomains + [w[2]])
                    default: break
                    }
                default: break
                }
            }
            s.status.detail = "Setting up the tunnel…"
        } else if let iface = Self.openVPNInterface(in: line) {
            s.pendingNetwork.interface = iface
        } else if line.contains("Initialization Sequence Completed") {
            if OpenVPNProfile.redirectsGateway(c.ovpnProfile) { s.pendingNetwork.fullTunnel = true }
            tunnelUp(s)
        } else if error {
            // The first specific error explains the exit; a rejected login always does.
            if s.lastErrorLine == nil || (!isAuthFailure(s.lastErrorLine) && !line.contains("Exiting due to fatal error")) {
                s.lastErrorLine = line
            }
            if line.contains("a password is required") || line.contains("not in the sudoers") || line.contains("Install Helper") {
                s.status.needsSetup = true
            }
        }
    }

    /// "Opened utun device utun7" (OpenVPN 2.6 on macOS), or "TUN/TAP device utun7 opened" (older).
    static func openVPNInterface(in line: String) -> String? {
        for pattern in [#"Opened utun device (utun[0-9]+)"#, #"TUN/TAP device (utun[0-9]+) opened"#] {
            if let r = line.range(of: pattern, options: .regularExpression),
               let i = line[r].range(of: "utun[0-9]+", options: .regularExpression) {
                return String(line[r][i])
            }
        }
        return nil
    }

    private static func isOpenVPNError(_ line: String) -> Bool {
        let markers = ["ERROR:", "sudo:", "AUTH_FAILED", "Options error", "Exiting due to fatal error", "TLS Error",
                       "TLS handshake failed", "VERIFY ERROR", "Cannot resolve host", "RESOLVE: Cannot", "Connection refused",
                       "Connection timed out", "Operation timed out", "Network is unreachable", "Cannot open TUN/TAP",
                       "Cannot allocate TUN/TAP", "Unrecognized option", "No route to host"]
        return markers.contains { line.contains($0) }
    }

    /// OpenVPN's routine detail: kept at debug level, out of the events assistants read.
    private static func isOpenVPNChatter(_ line: String) -> Bool {
        let prefixes = ["/sbin/", "net_", "OPTIONS IMPORT", "Outgoing Data Channel", "Incoming Data Channel", "TLS: ",
                        "VERIFY OK", "Socket Buffers", "TCPv4_CLIENT", "TCPv6_CLIENT", "UDPv4", "UDPv6", "TCP/UDP:",
                        "Data Channel MTU", "ROUTE_GATEWAY", "ROUTE6_GATEWAY", "SENT CONTROL", "library versions", "Note:",
                        "DCO", "Originally developed by", "Control Channel MTU", "Timers:", "MTU:", "Using peer cipher",
                        "Preserving recently used", "WARNING: this configuration may cache passwords",
                        "ifconfig: ioctl", "NOTE: Tried to delete pre-existing", "add net ", "delete net ",
                        "Protocol options:", "++ Certificate has EKU", "Validating certificate"]
        return prefixes.contains { line.hasPrefix($0) }
    }

    /// All "[a, b, c]" groups in a line, split into items.
    private static func bracketLists(in line: String) -> [[String]] {
        var out: [[String]] = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let inner = rest[rest.index(after: open)..<close]
            out.append(inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// "Interface ppp0 is UP." → "ppp0"
    private static func interfaceUp(in line: String) -> String? {
        guard line.contains(" is UP"), let r = line.range(of: "Interface ") else { return nil }
        let name = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    private func processEnded(_ proc: Process, _ s: TunnelSession, blocked: Bool = false) {
        if blocked {
            killSwitchActive = true
            // A stop the user asked for just as the program ended by itself is still their stop.
            if s.stopRequested && !s.restartRequested { releaseKillSwitch() }
            else { Log.shared.write("[\(s.name)] kill switch: the VPN ended, so the Mac's internet is blocked until it is back") }
        }
        s.pipe?.fileHandleForReading.readabilityHandler = nil
        if !s.lineBuffer.isEmpty { handle(line: String(decoding: s.lineBuffer, as: UTF8.self), in: s); s.lineBuffer = Data() }
        removeSplitDNS(s)
        clearTunnelDNS(s)
        s.stopTimer?.invalidate(); s.stopTimer = nil
        s.process = nil
        s.pipe = nil
        let code = proc.terminationStatus
        Log.shared.write("[\(s.name)] \(s.connection.isV2Ray ? "xray" : s.connection.isOpenVPN ? "openvpn" : "openfortivpn") exited (status \(code))")
        if s.loginPending {
            // It ended between sending the password and getting in: a failed login, also when it
            // was stopped meanwhile (the gateway has the password by then and judges it anyway).
            s.loginPending = false
            loginFailed(s)
        }

        let previous = s.status
        if let report = s.certReport {
            s.certReport = nil
            if !s.stopRequested && s.relaunch == nil {
                if previous.phase == .connected {
                    // openfortivpn reconnected by itself (the `persistent` option) and met another
                    // certificate: the tunnel is gone, as after any drop.
                    s.status = VPNStatus(phase: .connecting, connectionID: s.connection.id, connectionName: s.name, detail: "Connection lost…")
                    s.reconnectAttempt = max(s.reconnectAttempt, 1)
                }
                if handleRefusedCertificate(report, in: s) { return }
            }
        }
        if let next = s.relaunch {
            s.relaunch = nil
            s.reconnectAttempt = 0
            launch(next, in: s)
            return
        }
        if s.restartRequested {
            // The watchdog or a network change tore it down: treat it like a drop and bring it back.
            let why = s.restartWhy ?? "Connection lost"
            s.restartRequested = false
            s.restartWhy = nil
            s.stopRequested = false
            s.status.health = nil
            if ConnectionStore.shared.autoReconnect {
                scheduleReconnect(s, attempt: 1, why: why)
            } else {
                let latest = ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection
                launch(latest, in: s)
            }
            return
        }
        if s.stopRequested || previous.phase == .disconnecting || previous.phase == .idle {
            remove(s)
            return
        }
        switch previous.phase {
        case .connected:
            // Dropped while in use (not a manual disconnect).
            let why = friendly(s.lastErrorLine).map { " " + $0 } ?? ""
            if ConnectionStore.shared.autoReconnect {
                Log.shared.write("[\(s.name)] connection dropped.\(why)", level: .error)
                scheduleReconnect(s, attempt: 1)
            } else {
                fail(s, "\(s.name) disconnected unexpectedly.\(why)")
            }
        case .connecting:
            if !previous.needsSetup, LoginGuard.shared.isLimited(s.connection.loginGuardKey) {
                // Any retry from here (the other one-time-code mode, a reconnect) would be a login
                // that can get the Mac's address banned: only the user goes on, after a check.
                // A run that never sent its password says what really went wrong first.
                s.reconnectAttempt = 0
                s.otpModeTrial = nil
                let limit = loginLimitMessage(s.connection)
                fail(s, s.loginFailedThisRun ? limit
                        : (friendly(s.lastErrorLine).map { $0 + " " } ?? "") + "No password was sent this time. " + limit)
                return
            }
            var msg = friendly(s.lastErrorLine) ?? "\(s.name): connection failed (exit \(code)). See the log."
            if s.connection.usesTOTP && !s.connection.otpModeAccepted && isAuthFailure(s.lastErrorLine)
                && !s.retriedLogin && s.reconnectAttempt == 0 {
                // FortiGate gateways take the one-time code one of two ways: typed right after the
                // password (Office) or as a second step after it. A login rejected in one mode is
                // retried once in the other, with a fresh code (launch() waits for a new window when
                // needed); if that logs in, the mode is saved. A wrong password fails both times and
                // is reported then. One retry only, so a bad password can never lock the account.
                // Not for a mode the gateway has taken before: that one is not the cause.
                s.retriedLogin = true
                var latest = ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection
                if let other = Self.otherOTPMode(latest.otpMode) {
                    latest.otpMode = other
                    s.otpModeTrial = other
                    Log.shared.write("[\(s.name)] login rejected; retrying once with the one-time code \(Self.describe(other))")
                } else {
                    Log.shared.write("[\(s.name)] login rejected; retrying once with a fresh one-time code")
                }
                launch(latest, in: s)
                return
            }
            if s.otpModeTrial != nil {
                s.otpModeTrial = nil
                if isAuthFailure(s.lastErrorLine) {
                    msg += " The one-time code was tried both appended to the password and as a second step."
                }
            }
            if isAuthFailure(s.lastErrorLine) { msg += lastConnectedNote(s.connection) }
            let retryable = s.reconnectAttempt > 0 && !previous.needsSetup && !isAuthFailure(s.lastErrorLine)
            if retryable {
                Log.shared.write("[\(s.name)] reconnect attempt \(s.reconnectAttempt) failed: \(msg)", level: .error)
                scheduleReconnect(s, attempt: s.reconnectAttempt + 1)
            } else {
                let prefix = s.reconnectAttempt > 0 ? "Could not reconnect \(s.name): " : ""
                s.reconnectAttempt = 0
                fail(s, prefix + msg, needsSetup: previous.needsSetup)
            }
        case .disconnecting, .idle:
            remove(s)
        }
    }

    // MARK: Gateway certificate

    /// openfortivpn refused the gateway's certificate, before any password or code was sent (it
    /// checks the certificate first). CertCheck gets macOS's opinion:
    /// - A gateway FiveT has never logged in to (or whose host or port was edited): trusted without
    ///   asking only when macOS vouches for the certificate for the very host name FiveT connects
    ///   to, as a browser would. Otherwise the user confirms it once, with its details: the step
    ///   FortiClient calls "accept this certificate".
    /// - A known gateway showing another certificate: a renewal or someone in the middle, and
    ///   openfortivpn cannot tell which. One macOS vouches for that carries the old certificate's
    ///   name is a renewal (once per attempt); anything else is a question for the user.
    /// Only a person answers it: asked at once after a click; from an assistant, a link or the CLI
    /// it waits in the menu (Review New Certificate…); an automatic reconnect keeps retrying (a
    /// hotel Wi-Fi sign-in page that intercepts the connection goes away by itself) with the
    /// question in the menu meanwhile. Returns false when there is nothing to decide.
    private func handleRefusedCertificate(_ report: CertReport, in s: TunnelSession) -> Bool {
        // What this attempt ran with (the store may have been edited since), and what is saved now.
        let ran = s.connection
        let c = ConnectionStore.shared.connection(id: ran.id) ?? ran
        if c.gatewayKey == ran.gatewayKey && c.hasPinForGateway && c.trustedCert == report.digest {
            // Trusted meanwhile (the user reviewed it while this attempt ran): go again with it.
            // Not when this very attempt already had it: then openfortivpn refused its own pin.
            guard ran.trustedCert != report.digest else { return false }
            Log.shared.write("[\(c.name)] the certificate was trusted meanwhile; connecting with it")
            launch(c, in: s)
            return true
        }
        let first = !ran.knowsGateway
        let again = !first && s.autoRenewed
        Log.shared.write(first
            ? "[\(c.name)] first connection to \(ran.gatewayKey): checking its certificate \(report.digest.prefix(12))… before logging in"
            : "[\(c.name)] the gateway's certificate has changed (trusted \(ran.trustedCert.isEmpty ? "one verified by a certificate authority" : String(ran.trustedCert.prefix(12)) + "…"), now \(report.digest.prefix(12))…); not logging in until it is checked",
            level: first ? .info : .error)
        s.checkingCert = true
        s.status.detail = first ? "Checking the gateway's certificate…" : "The gateway's certificate changed; checking it…"
        let e = ran.endpoint, pinned = ran.trustedCertNames
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak s] in
            let verdict: CertCheck.Verdict = again
                ? .unverified(nil, reason: "it changed again right after a renewal")
                : (first ? CertCheck.judgeFirstMeeting(host: e.host, port: e.port, sni: e.sni, digest: report.digest)
                         : CertCheck.judge(host: e.host, port: e.port, sni: e.sni, digest: report.digest, pinnedNames: pinned))
            DispatchQueue.main.async {
                guard let self, let s else { return }
                s.checkingCert = false
                // Disconnected meanwhile (stop() has removed the session): nothing to continue.
                guard self.live.contains(where: { $0 === s }), !s.stopRequested, s.process == nil else { return }
                var latest = ConnectionStore.shared.connection(id: c.id) ?? c
                // The one-time-code mode this attempt was trying (the login retry) goes on being tried.
                if let mode = s.otpModeTrial { latest.otpMode = mode }
                guard latest.gatewayKey == ran.gatewayKey else {
                    // The host or port was edited meanwhile: the answer is about another gateway.
                    Log.shared.write("[\(c.name)] the gateway was changed in Settings meanwhile; starting over with it")
                    self.launch(latest, in: s)
                    return
                }
                if latest.hasPinForGateway && latest.trustedCert == report.digest {
                    self.launch(latest, in: s)   // trusted meanwhile, by the user
                    return
                }
                switch verdict {
                case .renewal(let leaf):
                    ConnectionStore.shared.mutate(id: c.id) { $0.trust(leaf.sha256, names: leaf.names) }
                    latest.trust(leaf.sha256, names: leaf.names)
                    s.autoRenewed = true
                    Log.shared.write(first
                        ? "[\(c.name)] macOS vouches for the certificate (\(leaf.summary)) for \(e.host); trusting it"
                        : "[\(c.name)] the new certificate is \(leaf.summary), and macOS vouches for it with the old one's name: a renewal; trusting it")
                    self.launch(latest, in: s)
                case .unverified(let leaf, let reason):
                    let info = Self.describe(digest: report.digest, leaf: leaf, old: first ? nil : ran, reason: reason)
                    ConnectionStore.shared.mutate(id: c.id) { $0.setPendingReview(report.digest, first: first, info: info) }
                    // `reason` holds no text from an untrusted certificate (CertCheck cleans and replaces it).
                    Log.shared.write("[\(c.name)] not trusting the \(first ? "" : "new ")certificate without asking: \(reason)", level: .error)
                    self.certificateQuestion(s, latest, first: first)
                }
            }
        }
        return true
    }

    /// A certificate question is open for `c` (its review is saved on the connection).
    private func certificateQuestion(_ s: TunnelSession, _ c: Connection, first: Bool) {
        let what = first ? "Confirm the certificate of \(c.name)'s gateway. FiveT has not connected to it before"
                         : "The certificate of \(c.name)'s gateway has changed"
        let safe = "FiveT did not log in and did not send your password."
        if s.byUser {
            s.reconnectAttempt = 0
            fail(s, "\(what). \(safe)")
            onReviewNeeded?(c.id)
        } else if s.reconnectAttempt > 0 && !first {
            Log.shared.write("[\(c.name)] keeps retrying meanwhile (no password is sent to an untrusted certificate)")
            scheduleReconnect(s, attempt: s.reconnectAttempt + 1, why: "the gateway shows another certificate")
        } else {
            s.reconnectAttempt = 0
            fail(s, "\(what). \(safe) Choose \(first ? "Review Certificate" : "Review New Certificate") for \(c.name)… in FiveT's menu.")
        }
    }

    /// The text of the review (menu and Settings → Review…). Details only from the certificate
    /// FiveT fetched itself, and only when it is the one openfortivpn refused.
    private static func describe(digest: String, leaf: CertCheck.Leaf?, old: Connection?, reason: String) -> String {
        var lines: [String] = []
        if let leaf, leaf.sha256 == digest {
            lines.append("The certificate says it is \(leaf.summary).")
        } else {
            lines.append("FiveT could not read the certificate's details.")
        }
        lines.append("Its fingerprint (SHA-256): \(groupedHex(digest))")
        if let old {
            lines.append(old.trustedCert.isEmpty
                ? "Until now, a certificate from a certificate authority, for this gateway's name."
                : "Trusted until now: \(groupedHex(old.trustedCert))" + (old.trustedCertNames.isEmpty ? "" : " (\(old.trustedCertNames.joined(separator: ", ")))"))
        }
        lines.append("Why FiveT did not accept it by itself: \(reason).")
        return lines.joined(separator: "\n")
    }

    static func groupedHex(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a..<(hex.index(a, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex)])
        }.joined(separator: " ")
    }

    /// Connections trusted before FiveT kept certificate names have none on record, so a renewal
    /// could not be recognised. After a login, read the names off the certificate the gateway
    /// shows, if it is the trusted one (the pin, or one macOS vouches for for this host name).
    private func recordCertificateNames(for c: Connection) {
        guard c.knowsGateway, c.trustedCertNames.isEmpty else { return }
        let e = c.endpoint, pin = c.trustedCert
        DispatchQueue.global(qos: .utility).async {
            guard let leaf = CertCheck.fetch(host: e.host, port: e.port, sni: e.sni), !leaf.names.isEmpty,
                  pin.isEmpty ? leaf.trustedForHost : leaf.sha256 == pin else { return }
            DispatchQueue.main.async {
                ConnectionStore.shared.mutate(id: c.id) { conn in
                    if conn.trustedCert == pin && conn.trustedCertNames.isEmpty { conn.trustedCertNames = leaf.names }
                }
                Log.shared.write("[\(c.name)] noted the names on the gateway's certificate: \(leaf.names.joined(separator: ", "))")
            }
        }
    }

    /// openfortivpn exits after refusing a certificate, unless the extra options say `persistent`:
    /// then it tries again and again by itself, and FiveT would wait for an exit forever. What
    /// happens next is FiveT's decision, so it ends that run.
    private func stopAfterRefusal(_ s: TunnelSession) {
        guard let p = s.process else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak s] in
            guard let self, let s, s.process === p, p.isRunning else { return }
            Log.shared.write("[\(s.name)] openfortivpn kept running after refusing the certificate; stopping it", level: .debug)
            self.signal(s, p, "TERM")
        }
    }

    // MARK: Auto-reconnect

    /// Retries in the background after an unexpected drop: 2 s, then 10, 20, … up to 60 s apart,
    /// indefinitely, until it succeeds or the user disconnects. Login failures stop the loop
    /// so a wrong password can never lock the account through repeated attempts. `why` replaces
    /// "Connection lost" in the menu line; `delay` replaces the back-off.
    private func scheduleReconnect(_ s: TunnelSession, attempt: Int, why: String = "Connection lost", delay: Double? = nil) {
        s.reconnectTimer?.invalidate()
        s.reconnectAttempt = attempt
        s.byUser = false   // what happens from here on is automatic
        s.loginOverrideAt = nil
        let c = s.connection
        if asleep {
            // Often the drop itself is the sleep (Wi-Fi going down): didWake starts it.
            s.resumeAfterWake = true
            s.status = VPNStatus(phase: .connecting, connectionID: c.id, connectionName: c.name,
                                 detail: "\(why), reconnecting after the Mac wakes…")
            Log.shared.write("[\(c.name)] reconnect attempt \(attempt) waits until the Mac wakes")
            return
        }
        guard networkUp else { waitForNetwork(s); return }
        let delay = delay ?? (attempt == 1 ? 2 : min(Double(attempt - 1) * 10, 60))
        s.status = VPNStatus(phase: .connecting, connectionID: c.id, connectionName: c.name,
                             detail: "\(why), retrying in \(Int(delay))s (try \(attempt))…", waitingToRetry: true)
        Log.shared.write("[\(c.name)] reconnect attempt \(attempt) scheduled in \(Int(delay))s")
        let t = Timer(timeInterval: delay, repeats: false) { [weak self, weak s] _ in
            guard let self, let s, s.process == nil, !s.stopRequested, !s.checkingCert, self.live.contains(where: { $0 === s }) else { return }
            s.reconnectTimer = nil
            guard self.networkUp else { self.waitForNetwork(s); return }
            let latest = ConnectionStore.shared.connection(id: c.id) ?? c   // pick up edited settings
            self.launch(latest, in: s)
        }
        RunLoop.main.add(t, forMode: .common)
        s.reconnectTimer = t
    }

    /// A reconnect that is due while the Mac has no network: nothing to try until there is one
    /// (networkSettled starts it then). A slow timer still tries now and then, in case the Mac's
    /// report of "no network" is wrong.
    private func waitForNetwork(_ s: TunnelSession) {
        s.reconnectTimer?.invalidate(); s.reconnectTimer = nil
        s.loginOverrideAt = nil
        let c = s.connection
        if !s.waitingForNetwork { Log.shared.write("[\(c.name)] no network; reconnecting once it is back") }
        s.waitingForNetwork = true
        s.status = VPNStatus(phase: .connecting, connectionID: c.id, connectionName: c.name,
                             detail: "Connection lost, waiting for the network…", waitingForNetwork: true)
        let t = Timer(timeInterval: Self.offlineRetryInterval, repeats: false) { [weak self, weak s] _ in
            guard let self, let s, s.waitingForNetwork, s.process == nil, !s.stopRequested, !s.checkingCert,
                  self.live.contains(where: { $0 === s }) else { return }
            s.reconnectTimer = nil
            Log.shared.write("[\(s.name)] still no network after \(Int(Self.offlineRetryInterval))s; trying anyway")
            self.launch(ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection, in: s)
        }
        RunLoop.main.add(t, forMode: .common)
        s.reconnectTimer = t
    }

    // MARK: Network changes

    /// The Wi-Fi, Ethernet and cellular interfaces the Mac could use. FiveT's own ppp tunnels and
    /// other VPNs' utun interfaces are of type "other" and left out: a tunnel coming up or going
    /// down is never a network change, and a full-tunnel VPN still "up" after Wi-Fi is gone
    /// does not count as a network.
    private static func physicalInterfaces(_ path: NWPath) -> [String] {
        let physical: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        return path.availableInterfaces.filter { physical.contains($0.type) }.map(\.name).sorted()
    }

    /// Online (a physical interface, and a path that is not unsatisfied: "requires connection",
    /// an on-demand VPN waiting to start, counts as online) and through which interfaces and routers.
    /// The routers tell one Wi-Fi network from the next on the same interface.
    private static func signature(_ path: NWPath) -> (up: Bool, text: String) {
        let interfaces = physicalInterfaces(path)
        guard path.status != .unsatisfied, !interfaces.isEmpty else { return (false, "offline") }
        let routers = path.gateways.map { "\($0)" }.sorted()
        return (true, "online " + interfaces.joined(separator: ",") + " via " + routers.joined(separator: ","))
    }

    private func pathChanged(_ path: NWPath) {
        let (up, sig) = Self.signature(path)
        // The Mac's address can change while its interfaces and routers stay the same (two Wi-Fi
        // networks whose routers share an address), so every report checks the tunnels' networks.
        if up && networkSignature != nil { scheduleMoveCheck() }
        guard sig != networkSignature else { return }
        let first = networkSignature == nil
        let wasUp = networkUp
        networkSignature = sig
        networkUp = up
        if first { return }   // the monitor's first report describes the network FiveT started on
        // Every change restarts the settle timer: a burst of changes (roaming, DHCP) acts once.
        networkTimer?.invalidate(); networkTimer = nil
        guard up else {
            Log.shared.write("network is gone")
            // Reconnects waiting on a timer would only fail: wait for the network instead.
            for s in live where !s.external && s.process == nil && !s.stopRequested && !s.checkingCert && s.reconnectTimer != nil
                                && !s.waitingForNetwork {
                waitForNetwork(s)
            }
            return
        }
        Log.shared.write(wasUp ? "network changed (\(sig))" : "network is back (\(sig))")
        let t = Timer(timeInterval: Self.networkSettleDelay, repeats: false) { [weak self] _ in self?.networkSettled() }
        RunLoop.main.add(t, forMode: .common)
        networkTimer = t
    }

    /// The network is back or different: reconnect what was waiting for a retry or for the network
    /// now instead of on its timer (never one waiting for a fresh one-time code or a certificate
    /// check, and each at most once per `networkLaunchSpacing`), reconnect the tunnels that ran over
    /// a network the Mac has left, and probe the other tunnels that are up: on the same address
    /// behind another router, a probe's packet meets a gateway that no longer knows the
    /// connection, its reset ends openfortivpn at once, and auto-reconnect takes over.
    private func networkSettled() {
        networkTimer = nil
        guard networkUp, !asleep else { return }   // asleep: didWake starts what is waiting
        checkTunnelsMoved()
        let now = Date()
        for s in live where !s.external && s.process == nil && !s.stopRequested && !s.checkingCert && s.status.phase == .connecting
                            && (s.waitingForNetwork || s.reconnectTimer != nil) {
            if let last = s.lastNetworkLaunch, now.timeIntervalSince(last) < Self.networkLaunchSpacing {
                // Started by a network change a moment ago: the usual back-off, not the offline wait.
                if s.waitingForNetwork {
                    s.waitingForNetwork = false
                    scheduleReconnect(s, attempt: max(s.reconnectAttempt, 1))
                }
                continue
            }
            s.lastNetworkLaunch = now
            Log.shared.write("[\(s.name)] network is up; reconnecting now")
            launch(ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection, in: s)
        }
        if ConnectionStore.shared.watchdog, live.contains(where: { !$0.external && $0.status.phase == .connected }) {
            if let last = lastPathProbe, now.timeIntervalSince(last) < Self.watchdogInterval { return }
            lastPathProbe = now
            probeTunnels()
        }
    }

    /// Checks the tunnels' networks once a report has had `networkSettleDelay` for DHCP. Armed by
    /// the first report of a burst and not pushed back by later ones, so a stream of reports
    /// cannot put the check off.
    private func scheduleMoveCheck() {
        guard moveCheckTimer == nil, live.contains(where: { !$0.external && $0.status.phase == .connected }) else { return }
        let t = Timer(timeInterval: Self.networkSettleDelay, repeats: false) { [weak self] _ in self?.checkTunnelsMoved() }
        RunLoop.main.add(t, forMode: .common)
        moveCheckTimer = t
    }

    /// A tunnel whose outer address is gone ran over a network the Mac has left: another Wi-Fi
    /// network, a pulled cable, a personal VPN switched off. Its connection to the gateway cannot
    /// come back (openfortivpn pinned its route to the gateway through the old network's router),
    /// yet openfortivpn goes on saying "connected" for minutes. A tunnel whose address is still
    /// there (a short Wi-Fi drop, a roam to another access point) is left alone.
    private func checkTunnelsMoved() {
        moveCheckTimer?.invalidate(); moveCheckTimer = nil
        guard networkUp, let present = Self.localIPv4Addresses() else { return }
        for s in live where !s.external && s.status.phase == .connected {
            guard let n = s.status.network, !n.outerIP.isEmpty, present[n.outerIP] != n.outerInterface else { continue }
            let address = "\(n.outerInterface) \(n.outerIP)"
            Log.shared.write("[\(s.name)] the Mac has left the network this tunnel ran over (\(address) is gone)")
            tunnelLostItsNetwork(s, address: address)
        }
    }

    /// The Mac has left the network `s` ran over (`address`, e.g. "en0 192.168.1.20", is gone): the
    /// tunnel is dead although openfortivpn still reports it up, and cannot recover by itself. It
    /// comes back on the network the Mac has now, the way a drop does (after 2 s, then with
    /// retries). With Settings → General → "Reconnect when the connection drops" off, it is
    /// disconnected instead and the menu says why: no zombie "connected" line.
    private func tunnelLostItsNetwork(_ s: TunnelSession, address: String) {
        if ConnectionStore.shared.autoReconnect {
            restart(s, reason: "network changed", why: "Network changed", level: .info)
        } else {
            stop(s, telling: "\(s.name) disconnected: the Mac moved to another network. Click it to connect again.")
        }
    }

    /// Disconnects a tunnel for good and says why in the menu, as a failed connect does.
    private func stop(_ s: TunnelSession, telling message: String) {
        s.relaunch = nil
        s.restartRequested = false
        if s.blockOnExit != nil { blockInternet(for: s) }   // nobody asked for this stop
        stop(s)
        let message = killSwitchActive
            ? message + " The kill switch keeps the Mac's internet blocked until you connect again or choose Unblock Internet in FiveT's menu." : message
        Log.shared.write("[\(s.name)] \(message)", level: .error)
        ConnectionStore.shared.mutate(id: s.connection.id) { $0.lastError = message }
        lastError = message
    }

    // MARK: Failed-login limit

    /// Logins other tunnels have under way to this gateway: started and not through yet. Each may
    /// still fail, so they count against the limit as if they had.
    func loginsInFlight(to key: String, besides s: AnyObject? = nil) -> Int {
        live.filter { $0 !== s && !$0.external && $0.isRunning && !$0.authenticated && $0.connection.loginGuardKey == key }.count
    }

    /// The other way of sending `c`'s one-time code when every login on record that the gateway
    /// refused for `c` sent it the saved way: the next login then tries the other way rather than one
    /// the gateway refused. Nil without a code, without refusals, or once both ways were refused.
    /// (A login that only timed out says nothing about the way.) Also nil when the gateway has taken
    /// the saved way before: a login it turns down after that is the password, the account or the
    /// gateway, and a login in the other way is one more failure that counts toward the ban.
    func untriedOTPMode(for c: Connection) -> OTPMode? {
        guard c.usesTOTP, !c.otpModeAccepted, let other = Self.otherOTPMode(c.otpMode) else { return nil }
        let mine = LoginGuard.shared.failures(for: c.loginGuardKey).filter { $0.connection == c.id && $0.rejected == true }
        guard mine.contains(where: { $0.otpMode == c.otpMode }), !mine.contains(where: { $0.otpMode == other }) else { return nil }
        return other
    }

    /// Why FiveT does not log in to `c`'s gateway by itself, for the menu, the log and assistants.
    /// The first sentence is the headline the menu shows; the rest is in Settings and the tooltip.
    private func loginLimitMessage(_ c: Connection) -> String {
        let failed = LoginGuard.shared.count(for: c.loginGuardKey)
        var text = "\(c.name) stopped after \(failed) failed logins. One more failed login to its gateway gets this network's internet address banned there for hours."
        if let other = untriedOTPMode(for: c) {
            text += " Those logins had the one-time code \(Self.describe(c.otpMode)); in the next one it is \(Self.describe(other))."
        }
        return text + " Check the password and the one-time code in Settings → \(c.isOpenVPN ? "VPN" : "Forti") (and that the Mac's clock is right), then click \(c.name) in FiveT's menu."
            + lastConnectedNote(c)
    }

    /// For a login the gateway refused on a connection that has connected before: when that was. It
    /// worked then, so the cause may be the gateway or the account rather than anything saved here.
    private func lastConnectedNote(_ c: Connection) -> String {
        guard let last = (ConnectionStore.shared.connection(id: c.id) ?? c).lastConnectedAt else { return "" }
        let today = Calendar.current.isDateInToday(last)
        let f = DateFormatter()
        f.dateStyle = today ? .none : .medium
        f.timeStyle = .short
        return " It last connected \(today ? "at" : "on") \(f.string(from: last)); if the password and the code are right, "
            + "the gateway or the account may have changed, and its administrator can say."
    }

    /// openfortivpn sent the password and did not get in.
    private func loginFailed(_ s: TunnelSession) {
        let c = s.connection
        s.loginFailedThisRun = true
        let n = LoginGuard.shared.recordFailure(c.loginGuardKey, connection: c.id, otpMode: c.usesTOTP ? c.otpMode : nil,
                                                rejected: isAuthFailure(s.lastErrorLine))
        Log.shared.write("[\(s.name)] login to \(c.loginGuardKey) failed (\(n) in a row; FiveT stops at \(LoginGuard.limit))", level: .error)
    }

    /// Another login to the same gateway is under way and may still fail: `s` waits for it rather
    /// than risk the failure that gets the address banned, then decides again.
    private func waitForOtherLogin(_ s: TunnelSession) {
        if !s.waitingForOtherLogin {
            s.waitingForOtherLogin = true
            Log.shared.write("[\(s.name)] another login to \(s.connection.loginGuardKey) is under way; waiting for it")
        }
        s.status.detail = "Waiting for another login to the same gateway…"
        let t = Timer(timeInterval: 2, repeats: false) { [weak self, weak s] _ in
            guard let self, let s, s.process == nil, !s.stopRequested, !s.checkingCert, self.live.contains(where: { $0 === s }) else { return }
            self.launch(ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection, in: s)
        }
        RunLoop.main.add(t, forMode: .common)
        s.waitTimer = t
    }

    /// The other way of sending a one-time code, or nil when the connection uses none.
    static func otherOTPMode(_ mode: OTPMode) -> OTPMode? {
        switch mode {
        case .appendToPassword: return .separate
        case .separate: return .appendToPassword
        case .none: return nil
        }
    }

    static func describe(_ mode: OTPMode) -> String {
        mode == .appendToPassword ? "appended to the password" : "sent as a second step"
    }

    private func isAuthFailure(_ line: String?) -> Bool {
        guard let l = line else { return false }
        return l.contains("Could not authenticate") || l.localizedCaseInsensitiveContains("authentication") || l.contains("AUTH_FAILED")
    }

    // MARK: Watchdog

    /// Runs while any FiveT-started tunnel exists.
    private func updateWatchdog() {
        let wanted = live.contains { !$0.external }
        if wanted && watchdogTimer == nil && !asleep {   // asleep: didWake starts it
            let t = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in self?.probeTunnels() }
            t.tolerance = Self.watchdogInterval / 5   // a probe a few seconds late is as good, and shares a wake-up
            RunLoop.main.add(t, forMode: .common)
            watchdogTimer = t
        } else if !wanted, let t = watchdogTimer {
            t.invalidate()
            watchdogTimer = nil
        }
    }

    /// Asks each connected tunnel's DNS server one question through the tunnel. pppd only notices
    /// a dead tunnel when the gateway says goodbye; after a network change or a sleep it can sit
    /// "connected" for many minutes carrying nothing. Three silent probes in a row tear the tunnel
    /// down and bring it back. Off in Settings → General.
    private func probeTunnels() {
        // Without a network no tunnel can answer: counting that as misses would tear down tunnels
        // that may well survive a short Wi-Fi drop. The first probe after it is back decides.
        guard ConnectionStore.shared.watchdog, networkUp, !asleep else { return }
        let epoch = sleepCount
        for s in live where !s.external && s.status.phase == .connected && !s.probing {
            let server: String, name: String
            let check: () -> Bool
            if s.connection.isV2Ray {
                // Xray answers DNS and pings itself, server or no server: only a real request says.
                server = "the V2Ray server"
                name = "a web request"
                check = { Self.v2rayCarriesTraffic(timeout: 5) }
            } else {
                guard let n = s.status.network,
                      let dns = n.dnsServers.first(where: { Self.ipv4($0, isCoveredBy: n.routes) }) else {
                    if !s.watchdogSkipLogged {
                        s.watchdogSkipLogged = true
                        Log.shared.write("[\(s.name)] watchdog: no DNS server inside the tunnel to probe; not watching this tunnel", level: .debug)
                    }
                    continue
                }
                let question = Connection.cleanDomains([s.connection.dnsDomains] + n.searchDomains).first ?? "."
                server = dns
                name = question
                check = { Self.dnsAnswers(server: dns, name: question) }
            }
            s.probing = true
            DispatchQueue.global(qos: .utility).async { [weak self, weak s] in
                let alive = check()
                DispatchQueue.main.async {
                    guard let self, let s else { return }
                    s.probing = false
                    // Sent before a sleep: its answer (or its silence) says nothing about the tunnel now.
                    guard epoch == self.sleepCount, !self.asleep else { return }
                    guard s.status.phase == .connected, self.live.contains(where: { $0 === s }) else { return }
                    if alive {
                        if s.probeFailures > 0 { Log.shared.write("[\(s.name)] watchdog: \(server) answers again") }
                        else if !s.watchdogAnnounced { Log.shared.write("[\(s.name)] watchdog: watching the tunnel via \(server) (\(name))") }
                        s.watchdogAnnounced = true
                        s.probeFailures = 0
                        s.wakeCheck = false
                        if s.status.health != nil { s.status.health = nil }
                        return
                    }
                    if s.wakeCheck {
                        // After a sleep, silence almost always means the gateway has dropped the
                        // session, and a firewall on the way discards the packets rather than
                        // refusing them, so openfortivpn does not notice. Two more rounds would leave
                        // the tunnel dead for another 40 s, long enough for people to click it off.
                        s.wakeCheck = false
                        Log.shared.write("[\(s.name)] watchdog: \(server) did not answer after the wake", level: .error)
                        self.restart(s, reason: "tunnel did not survive the sleep", why: "Woke from sleep")
                        return
                    }
                    s.probeFailures += 1
                    let silent = Int(Double(s.probeFailures) * Self.watchdogInterval)
                    s.status.health = "not answering for \(silent)s"
                    Log.shared.write("[\(s.name)] watchdog: \(server) did not answer (\(s.probeFailures)/\(Self.watchdogFailures))", level: .error)
                    if s.probeFailures >= Self.watchdogFailures {
                        self.restart(s, reason: "tunnel stopped answering (\(server) silent for \(silent)s)")
                    }
                }
            }
        }
    }

    /// True when packets flow through the tunnel: its DNS server answered at all (NXDOMAIN and
    /// REFUSED count), or, when DNS got no answer, the same server answers a ping. Some Macs filter
    /// every DNS question (DNS-protection products, some VPNs): there a DNS server that is never
    /// reached says nothing about the tunnel, and counting it would restart a working tunnel.
    private static func dnsAnswers(server: String, name: String) -> Bool {
        if Setup.run("/usr/bin/dig", ["+time=2", "+tries=1", "@" + server, name, "A"]).status == 0 { return true }
        // IPv4 only: macOS's IPv6 ping has no time limit, and VPN DNS servers on IPv6 are rare.
        guard !server.contains(":") else { return false }
        return Setup.run("/sbin/ping", ["-c", "1", "-t", "2", server]).status == 0
    }

    /// Tears the tunnel down and brings it back. `why` heads the menu line until it is up
    /// ("Network changed, reconnecting…"); without one the line reads as after a drop.
    private func restart(_ s: TunnelSession, reason: String, why: String? = nil, level: LogLevel = .error) {
        Log.shared.write("[\(s.name)] \(reason); reconnecting", level: level)
        s.restartRequested = true
        s.restartWhy = why
        s.probeFailures = 0
        if s.blockOnExit != nil { blockInternet(for: s) }   // before its routes go, so nothing slips out
        stop(s)
        s.status.detail = why.map { "\($0), reconnecting…" } ?? "Not answering, reconnecting…"
    }

    // MARK: Kill switch

    /// The kill switch (Settings → General) covers a VPN that carries all of the Mac's traffic: V2Ray,
    /// Outline, and OpenVPN when it redirects the gateway. While such a tunnel is up, its routes take
    /// everything and nothing is filtered. When it goes down without the user having switched it off
    /// (a drop, a dead tunnel, a network change), the helper's `ks-on` blocks all traffic that leaves
    /// the Mac except to the local network, the VPN's server and the Mac's DNS servers, so FiveT can
    /// reconnect; `ks-off` lifts it when the tunnel is back or the user disconnects. A Forti
    /// connection only carries its office's addresses, so there is nothing to guard.
    /// shortcut: a program that ends by itself is blocked a moment (about 0.1 s) after its routes
    /// went; filtering all the time would close that, but would also stop Xray's own direct
    /// connections ("Iranian sites go direct"). Upgrade if that moment ever matters.
    private func arm(_ s: TunnelSession) {
        let wanted = ConnectionStore.shared.killSwitch && s.connection.isOtherVPN && s.pendingNetwork.fullTunnel
        s.blockOnExit = wanted ? killSwitchAddresses(s) : nil
    }

    /// What stays reachable while blocked: the VPN's server and the Mac's own DNS servers.
    private func killSwitchAddresses(_ s: TunnelSession) -> [String] {
        Array(Set(s.serverIPs + s.localDNS).filter(Self.isIPAddress)).sorted()
    }

    /// Blocks the Mac's internet for `s` now, or updates what the block lets through (`tun`: the
    /// tunnel a V2Ray run is about to open, so its check that the server carries traffic gets out).
    private func blockInternet(for s: TunnelSession, tun: String? = nil) {
        s.blockOnExit = nil
        guard Self.killSwitchHelper(["ks-on"] + (tun.map { [$0] } ?? []) + killSwitchAddresses(s)) else { return }
        if !killSwitchActive { Log.shared.write("[\(s.name)] kill switch: the Mac's internet is blocked until the VPN is back") }
        killSwitchActive = true
    }

    /// Lifts the block (the tunnel is back, the user disconnected or chose Unblock Internet), and
    /// keeps a program that is stopping from setting it.
    func releaseKillSwitch() {
        for s in live { s.blockOnExit = nil }
        guard killSwitchActive, Self.killSwitchHelper(["ks-off"]) else { return }
        killSwitchActive = false
        Log.shared.write("kill switch: the Mac's internet is open again")
    }

    /// Settings → General → Kill switch was switched: off lifts a block; on covers the tunnel that is up.
    func killSwitchChanged() {
        guard ConnectionStore.shared.killSwitch else { releaseKillSwitch(); return }
        for s in live where s.status.phase == .connected { arm(s) }
    }

    /// Runs the helper's ks-on or ks-off; false, with a line in the log, when it could not. Safe off
    /// the main thread.
    @discardableResult
    private static func killSwitchHelper(_ args: [String]) -> Bool {
        let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath] + args)
        if r.status != 0 {
            Log.shared.write("kill switch: the helper could not \(args[0] == "ks-on" ? "block" : "unblock") the internet (\(r.status)): \(r.output.trimmed)", level: .error)
        }
        return r.status == 0
    }

    // MARK: Sleep and wake

    /// The watchdog and the retry timers pause while the Mac sleeps. Left running, an overdue timer
    /// fires the instant the Mac wakes, before Wi-Fi is back: a probe counts a miss that says
    /// nothing about the tunnel, and a reconnect hangs until its TCP connect times out (20 s).
    private func willSleep() {
        asleep = true
        sleepCount += 1
        watchdogTimer?.invalidate(); watchdogTimer = nil
        wakeTimer?.invalidate(); wakeTimer = nil
        for s in live where !s.external && s.process == nil && (s.reconnectTimer != nil || s.waitTimer != nil) {
            // A wait (for a fresh code, for another login) is the same attempt, with its byUser and
            // its one-time-code trial: it resumes as a wait, not as a reconnect.
            s.resumeAsWait = s.waitTimer != nil && s.reconnectTimer == nil
            s.reconnectTimer?.invalidate(); s.reconnectTimer = nil
            s.waitTimer?.invalidate(); s.waitTimer = nil
            s.resumeAfterWake = true
            Log.shared.write("[\(s.name)] the Mac is going to sleep; going on after the wake")
        }
    }

    /// After a sleep the gateway has often dropped the session while pppd still shows the tunnel
    /// up. Tunnels that look connected get one probe once Wi-Fi is back, and one miss reconnects
    /// them (see probeTunnels). Reconnects that came due during the sleep start then too, or as soon
    /// as the network monitor reports the network (networkSettled), whichever is first.
    private func didWake() {
        asleep = false
        for s in live { s.probeFailures = 0 }
        // A fresh round: the first probe after the wake is wakeTimer's, never an old tick due now.
        watchdogTimer?.invalidate(); watchdogTimer = nil
        updateWatchdog()
        for s in live where s.resumeAfterWake {
            s.resumeAfterWake = false
            let asWait = s.resumeAsWait
            s.resumeAsWait = false
            guard s.process == nil, !s.stopRequested, !s.checkingCert else { continue }
            if asWait && networkUp {
                let t = Timer(timeInterval: Self.wakeProbeDelay, repeats: false) { [weak self, weak s] _ in
                    guard let self, let s, s.process == nil, !s.stopRequested, !s.checkingCert,
                          self.live.contains(where: { $0 === s }) else { return }
                    self.launch(ConnectionStore.shared.connection(id: s.connection.id) ?? s.connection, in: s)
                }
                RunLoop.main.add(t, forMode: .common)
                s.waitTimer = t
                continue
            }
            s.waitingForNetwork = false   // scheduleReconnect waits for it again if there is still none
            scheduleReconnect(s, attempt: max(s.reconnectAttempt, 1), delay: Self.wakeProbeDelay)
        }
        let connected = live.filter { !$0.external && $0.status.phase == .connected }
        guard ConnectionStore.shared.watchdog, !connected.isEmpty else { return }
        for s in connected { s.wakeCheck = true }
        Log.shared.write("woke from sleep; checking the tunnels in \(Int(Self.wakeProbeDelay))s")
        wakeTimer?.invalidate()
        let t = Timer(timeInterval: Self.wakeProbeDelay, repeats: false) { [weak self] _ in self?.probeTunnels() }
        RunLoop.main.add(t, forMode: .common)
        wakeTimer = t
    }

    // MARK: Network facts

    /// A second after the tunnel is up, read what pppd published: the scoped DNS resolver,
    /// the routes over the interface and the interface addresses. Fills the session's
    /// `status.network`, logs one compact summary, then applies split DNS for the connection.
    private func captureNetwork(for s: TunnelSession) {
        let seed = s.status.network ?? s.pendingNetwork
        // Interfaces the other tunnels own, so the fallback scan never picks one of theirs.
        let taken = Set(live.filter { $0 !== s }.compactMap { $0.status.network?.interface }.filter { !$0.isEmpty })
        let gateway = s.external ? nil : s.connection.endpoint
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self, weak s] in
            var n = seed
            if n.interface.isEmpty { n.interface = Self.findPPPInterface(excluding: taken) ?? "" }
            if !n.interface.isEmpty {
                let (ip, peer) = Self.interfaceAddresses(n.interface)
                if n.tunnelIP.isEmpty { n.tunnelIP = ip }
                n.peerIP = peer
                let (dns, search) = Self.scopedDNS(interface: n.interface)
                if !dns.isEmpty { n.dnsServers = dns }
                if !search.isEmpty { n.searchDomains = search }
                n.routes = Self.routes(via: n.interface, excluding: peer)
            }
            // Through the tunnel itself would be a routing loop, not a network to watch.
            if let g = gateway, let outer = Self.outerAddress(toward: g.host, port: g.port), outer.interface != n.interface {
                n.outerInterface = outer.interface
                n.outerIP = outer.ip
            }
            DispatchQueue.main.async {
                guard let self, let s, s.status.phase == .connected, self.live.contains(where: { $0 === s }) else { return }
                s.status.network = n
                let tag = s.external ? "external" : s.name
                Log.shared.write("[\(tag)] tunnel \(n.interface) \(n.tunnelIP) → \(n.peerIP), dns [\(n.dnsServers.joined(separator: ", "))]"
                                 + (n.searchDomains.isEmpty ? "" : ", search [\(n.searchDomains.joined(separator: ", "))]")
                                 + ", \(n.routes.count) routes via tunnel"
                                 + (n.outerIP.isEmpty ? "" : ", over \(n.outerInterface) \(n.outerIP)"))
                Log.shared.write("[\(tag)] routes: \(n.routes.joined(separator: " "))", level: .debug)
                // V2Ray: every name already goes to its DNS (set before the check that it carries traffic).
                if !s.external && !s.connection.isV2Ray { self.applySplitDNS(for: s, servers: n.dnsServers) }
                if !s.external && s.connection.isOpenVPN && n.fullTunnel { self.applyTunnelDNS(for: s, network: n) }
            }
        }
    }

    private static func findPPPInterface(excluding taken: Set<String>) -> String? {
        Setup.run("/sbin/ifconfig", ["-l"]).output.split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("ppp") && !taken.contains($0) }
    }

    /// "inet 10.0.1.5 --> 169.254.2.1 netmask ..." → (10.0.1.5, 169.254.2.1)
    private static func interfaceAddresses(_ iface: String) -> (String, String) {
        for line in Setup.run("/sbin/ifconfig", [iface]).output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            if parts.count >= 4, parts[0] == "inet", parts[2] == "-->" { return (parts[1], parts[3]) }
            if parts.count >= 2, parts[0] == "inet" { return (parts[1], "") }
        }
        return ("", "")
    }

    /// The Mac's own interface and address that packets to `host` leave from: what a UDP socket
    /// connected to it is given (connecting one sends nothing; the kernel only picks the route).
    /// Right after openfortivpn is up that is the route it pinned to its gateway, so this is the
    /// address its connection runs over. IPv4 only, as openfortivpn is.
    static func outerAddress(toward host: String, port: Int) -> (interface: String, ip: String)? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard !host.isEmpty, getaddrinfo(host, String(port), &hints, &found) == 0, let ai = found else { return nil }
        defer { freeaddrinfo(found) }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        // Only an address the Mac's interfaces list: one they never list would look gone at every
        // check and reconnect the tunnel over and over.
        guard named, let ip = ipv4String(local.sin_addr), let iface = localIPv4Addresses()?[ip] else { return nil }
        return (iface, ip)
    }

    /// The Mac's IPv4 addresses on interfaces that are up, each with its interface
    /// ("192.168.1.20" → "en0"); nil when they cannot be read.
    static func localIPv4Addresses() -> [String: String]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var out: [String: String] = [:]
        var next = list
        while let ifa = next {
            next = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { ipv4String($0.pointee.sin_addr) })
            else { continue }
            out[ip] = String(cString: ifa.pointee.ifa_name)
        }
        return out
    }

    private static func ipv4String(_ address: in_addr) -> String? {
        var a = address
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    /// The scoped resolver that pppd registered for the interface, from `scutil --dns`.
    private static func scopedDNS(interface: String) -> ([String], [String]) {
        var servers: [String] = [], search: [String] = []
        var block: [String] = []
        var blocks: [[String]] = []
        for raw in Setup.run("/usr/sbin/scutil", ["--dns"]).output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") { if !block.isEmpty { blocks.append(block) }; block = [] }
            else if !line.isEmpty { block.append(line) }
        }
        if !block.isEmpty { blocks.append(block) }
        for b in blocks where b.contains(where: { $0.hasPrefix("if_index") && $0.hasSuffix("(\(interface))") }) {
            for l in b {
                let value = l.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if l.hasPrefix("nameserver["), !servers.contains(value) { servers.append(value) }
                if l.hasPrefix("search domain["), !search.contains(value) { search.append(value) }
            }
            if !servers.isEmpty { break }
        }
        return (servers, search)
    }

    /// Destinations routed over the interface, normalised to "a.b.c.d/nn" (netstat abbreviates
    /// "172.16.101/24"). The default route and the peer host route are left out.
    private static func routes(via iface: String, excluding peer: String) -> [String] {
        var out: [String] = []
        for line in Setup.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4, cols[3] == iface || cols.count >= 5 && cols[4] == iface else { continue }
            let dest = cols[0]
            // Skip the default route, link-local, multicast, the broadcast address and the link-local peer.
            guard dest != "default", !dest.hasPrefix("127."), !dest.hasPrefix("169.254."),
                  !dest.hasPrefix("224"), !dest.hasPrefix("239"), dest != "255.255.255.255",
                  !dest.hasSuffix(".255") else { continue }
            guard let norm = normalizeCIDR(dest), !norm.hasPrefix(peer + "/") else { continue }
            if !out.contains(norm) { out.append(norm) }
        }
        return out
    }

    /// netstat abbreviates classful networks: "192.168.22" means 192.168.22.0/24 and "10" means
    /// 10.0.0.0/8; "172.16.101/24" carries its prefix; "10.1.2.3" is a host → /32.
    static func normalizeCIDR(_ s: String) -> String? {
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        var octets = parts[0].split(separator: ".").map(String.init)
        guard (1...4).contains(octets.count), octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        let implied = octets.count * 8
        while octets.count < 4 { octets.append("0") }
        let prefix = parts.count > 1 ? Int(parts[1]) ?? implied : implied
        return octets.joined(separator: ".") + "/\(min(max(prefix, 0), 32))"
    }

    /// True when `ip` falls inside one of `cidrs`.
    static func ipv4(_ ip: String, isCoveredBy cidrs: [String]) -> Bool {
        func toInt(_ s: String) -> UInt32? {
            let o = s.split(separator: ".").compactMap { UInt32($0) }
            guard o.count == 4 else { return nil }
            return (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]
        }
        guard let v = toInt(ip) else { return false }
        for c in cidrs {
            let parts = c.split(separator: "/").map(String.init)
            guard let net = toInt(parts[0]), let bits = parts.count > 1 ? Int(parts[1]) : 32 else { continue }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            if (v & mask) == (net & mask) { return true }
        }
        return false
    }

    // MARK: Split DNS

    /// Writes /etc/resolver/<domain> (via the root helper) for the connection's "DNS domains" plus
    /// the DNS suffixes the gateway pushed, pointing at the DNS servers the gateway pushed. macOS
    /// then sends lookups for those domains to this tunnel's DNS even when another VPN, or a
    /// second tunnel that came up later, owns the Mac's primary resolver.
    private func applySplitDNS(for s: TunnelSession, servers: [String]) {
        let c = s.connection
        let pushed = s.status.network?.searchDomains ?? s.pendingNetwork.searchDomains
        let domains = Connection.cleanDomains([c.dnsDomains] + pushed)
        guard !domains.isEmpty else { s.status.splitDNS = nil; return }
        guard !servers.isEmpty else {
            s.status.splitDNS = SplitDNSInfo(domains: domains, state: "failed", detail: "the gateway pushed no DNS servers")
            return
        }
        s.status.splitDNS = SplitDNSInfo(domains: domains, state: "pending")
        dnsQueue.async { [weak self, weak s] in
            var ok: [String] = [], failed: [String] = []
            var helperNeeded = false
            for d in domains {
                let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "add", d] + servers)
                if r.status == 0 { ok.append(d); continue }
                failed.append(d)
                let out = r.output.trimmed
                if out.contains("a password is required") || out.contains("not allowed") || out.contains("No such file") || out.contains("command not found") {
                    helperNeeded = true
                    break
                }
                Log.shared.write("[\(c.name)] split dns: could not add \(d): \(out)", level: .error)
            }
            DispatchQueue.main.async {
                guard let self, let s else { return }
                s.installedResolverDomains += ok
                guard s.status.phase == .connected, self.live.contains(where: { $0 === s }) else { self.removeSplitDNS(s); return }
                let info: SplitDNSInfo
                if helperNeeded {
                    info = SplitDNSInfo(domains: domains, state: "helper_needed",
                                        detail: "Click Set Up FiveT… in FiveT's menu (one-time admin prompt) to enable split DNS.")
                } else if failed.isEmpty {
                    info = SplitDNSInfo(domains: domains, state: "active", detail: "/etc/resolver/<domain> → \(servers.joined(separator: ", "))")
                } else if ok.isEmpty {
                    info = SplitDNSInfo(domains: domains, state: "failed", detail: "could not write /etc/resolver files; see the log")
                } else {
                    info = SplitDNSInfo(domains: domains, state: "partial", detail: "failed: \(failed.joined(separator: ", "))")
                }
                s.status.splitDNS = info
                Log.shared.write("[\(c.name)] split dns \(info.state) for [\(domains.joined(separator: ", "))]\(info.detail.isEmpty ? "" : " — " + info.detail)",
                                 level: info.state == "active" ? .info : .error)
            }
        }
    }

    private func removeSplitDNS(_ s: TunnelSession) {
        let ds = s.installedResolverDomains
        s.installedResolverDomains = []
        if s.status.splitDNS != nil { s.status.splitDNS = nil }
        guard !ds.isEmpty else { return }
        let tag = s.name
        pendingRemovals.formUnion(ds)
        dnsQueue.async { [weak self] in
            for d in ds {
                let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "remove", d])
                if r.status != 0 { Log.shared.write("[\(tag)] split dns: could not remove \(d): \(r.output.trimmed)", level: .error) }
            }
            Log.shared.write("[\(tag)] split dns removed for [\(ds.joined(separator: ", "))]")
            DispatchQueue.main.async { self?.pendingRemovals.subtract(ds) }
        }
    }

    /// At launch with no tunnel: remove resolver files a crashed earlier run may have left,
    /// including those for gateway-pushed domains, which no saved connection lists.
    /// An OpenVPN full tunnel: its DNS servers answer every name while it is up (helper dns-set makes
    /// the tunnel the Mac's primary network service, as pppd does for a VPN), so names are not looked
    /// up by the local network's resolver, which may answer differently (or be filtered).
    private func applyTunnelDNS(for s: TunnelSession, network n: NetworkInfo) {
        let servers = n.dnsServers.filter { $0.range(of: "^[0-9A-Fa-f.:]+$", options: .regularExpression) != nil }
        guard !servers.isEmpty, n.interface.hasPrefix("utun"), !n.tunnelIP.isEmpty else {
            Log.shared.write("[\(s.name)] all traffic goes through the tunnel, but the server sent no DNS server: the Mac keeps its own DNS")
            return
        }
        let tag = (s.connection.isV2Ray ? "v2ray-" : "ovpn-") + s.connection.id.uuidString.prefix(8).lowercased()
        s.dnsTag = tag
        let name = s.name
        dnsQueue.async {
            let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "dns-set", tag, n.interface, n.tunnelIP] + servers)
            DispatchQueue.main.async {
                if r.status == 0 {
                    Log.shared.write("[\(name)] DNS: every name now goes to \(servers.joined(separator: ", ")) through the tunnel")
                } else {
                    Log.shared.write("[\(name)] could not make the tunnel's DNS the Mac's (\(r.status)): \(r.output.trimmed)", level: .error)
                }
            }
        }
    }

    private func clearTunnelDNS(_ s: TunnelSession) {
        guard let tag = s.dnsTag else { return }
        s.dnsTag = nil
        let name = s.name
        dnsQueue.async {
            let r = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "dns-clear", tag])
            DispatchQueue.main.async {
                Log.shared.write(r.status == 0 ? "[\(name)] DNS: back to the Mac's own"
                                 : "[\(name)] could not restore the Mac's DNS (\(r.status)): \(r.output.trimmed)",
                                 level: r.status == 0 ? .info : .error)
            }
        }
    }

    /// After a crash: FiveT's own OpenVPN or Xray still running with no app to stop it, and a full tunnel's
    /// DNS still set. Both are FiveT's alone (another app's openvpn runs from elsewhere), so they go
    /// — but only when no other copy of FiveT is running to own them right now: unlike the openfortivpn
    /// case above (adopted as external, never killed), a second launch of FiveT (a test copy, or the
    /// app started twice) must not tear down a live OpenVPN or V2Ray tunnel, or clear DNS, that another
    /// running copy still manages.
    private func cleanupLeftoverOpenVPN(others: [Int32]) {
        guard others.isEmpty else {
            Log.shared.write("another FiveT is already running (pid \(Set(others).sorted().map(String.init).joined(separator: ", "))); leaving its OpenVPN, Xray and DNS alone", level: .debug)
            return
        }
        for (program, label) in [(Setup.openvpnCopyDir + "/openvpn", "OpenVPN"), (Setup.xrayCopyDir + "/xray", "Xray")] {
            let r = Setup.run("/usr/bin/pgrep", ["-f", "^\(program) "])
            guard r.status == 0 else { continue }
            for pid in r.output.split(separator: "\n").map(String.init) where Int(pid) != nil {
                Log.shared.write("stopping FiveT's \(label) left running by an earlier FiveT (pid \(pid))")
                _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "stop", pid, "TERM"])
            }
        }
        let list = Setup.run("/bin/sh", ["-c", "echo 'list State:/Network/Service/app.fivet.[^/]+/DNS' | /usr/sbin/scutil"])
        let tags = list.output.components(separatedBy: "\n").compactMap { line -> String? in
            guard let r = line.range(of: #"app\.fivet\.[a-z0-9-]+/"#, options: .regularExpression) else { return nil }
            return String(line[r].dropFirst("app.fivet.".count).dropLast())
        }
        for tag in Set(tags) {
            Log.shared.write("removing a full tunnel's DNS left by an earlier FiveT (\(tag))")
            _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "dns-clear", tag])
        }
        if FileManager.default.fileExists(atPath: Setup.killSwitchTokenFile) {
            Log.shared.write("lifting a kill switch block left by an earlier FiveT")
            Self.killSwitchHelper(["ks-off"])
        }
    }

    /// Other copies of FiveT running now (a test copy, or the app started twice): what they manage is theirs.
    /// Asked of macOS, not pgrep: `FiveT --mcp` bridges and CLI calls carry the name too and own nothing.
    private static func otherFiveTs() -> [Int32] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "app.fivet" || ["FiveT", "fivet"].contains($0.localizedName ?? "") }
            .map(\.processIdentifier).filter { $0 != myPID }
    }

    private func cleanupStaleResolvers() {
        let stale = Setup.managedResolverDomains()
        guard !stale.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for d in stale { _ = Setup.run("/usr/bin/sudo", ["-n", Setup.resolverHelperPath, "remove", d]) }
            Log.shared.write("removed stale split-dns files for [\(stale.joined(separator: ", "))]")
        }
    }

    private func friendly(_ line: String?) -> String? {
        guard let l = line else { return nil }
        if l == Self.v2rayNoTraffic {
            return "The V2Ray server did not answer: it may be down or blocked, or the config is out of date. Try another server, or refresh the subscription in Settings → VPN."
        }
        if l.contains("does not allow this in a V2Ray config") {
            return l.replacingOccurrences(of: "ERROR:", with: "").trimmed
        }
        if l.contains("Failed to start") || l.contains("infra/conf") || l.contains("proxy/tun") {
            if l.contains("file exists") || l.contains("File exists") {
                return "Another VPN already takes all of this Mac's traffic (NordVPN, or an OpenVPN that does): turn it off, then connect again."
            }
            if l.contains("is prohibited") {
                return "Xray refuses this config: it would send the traffic unencrypted. Ask your provider for a config with TLS or Reality."
            }
            let detail = l.components(separatedBy: " > ").last?.trimmed ?? l
            return "Xray could not start with this config: \(detail)"
        }
        if l.contains("a password is required") || l.contains("not allowed") || l.contains("not in the sudoers") {
            return "FiveT is not set up on this Mac yet. Click Set Up FiveT… in FiveT's menu."
        }
        if l.contains("Could not authenticate") || l.localizedCaseInsensitiveContains("authentication") || l.contains("AUTH_FAILED") {
            return "Login failed. Check the password and the TOTP secret, and that the Mac's clock is correct."
        }
        // OpenVPN's own words.
        if let r = l.range(of: "Options error: ") {
            return "The OpenVPN profile has a setting OpenVPN cannot use: \(l[r.upperBound...])"
        }
        if l.contains("VERIFY ERROR") {
            return "The server's certificate does not match the OpenVPN profile. Ask your VPN administrator for a current profile."
        }
        if l.contains("TLS key negotiation failed") || l.contains("TLS handshake failed") || l.contains("TLS Error") {
            return "The OpenVPN server did not answer in time. Check the network, and whether another VPN or a firewall blocks it."
        }
        if l.contains("Cannot open TUN/TAP") || l.contains("Cannot allocate TUN/TAP") {
            return "macOS did not give OpenVPN a tunnel interface. Try again; if it keeps failing, restart the Mac."
        }
        if l.contains("Connection refused") {
            return "The VPN server refused the connection. Check the server address and port, or ask your VPN administrator."
        }
        if l.contains("Could not connect") || l.contains("connect:") || l.contains("resolve")
            || l.contains("unreachable") || l.contains("timed out") {
            return "Could not reach the gateway. Is another VPN switched on?"
        }
        return l.replacingOccurrences(of: "ERROR:", with: "").trimmed
    }
}
