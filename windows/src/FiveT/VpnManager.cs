using System.Diagnostics;
using System.Text;
using FiveT.Core;

namespace FiveT;

/// <summary>Who asked for a connect. It decides what happens when the gateway's certificate needs a person.</summary>
public enum ConnectOrigin
{
    /// <summary>A click: the menu, Connect All, Settings. A certificate question is asked at once.</summary>
    User,
    /// <summary>An AI assistant, the command line or a fivet:// link: it fails and the review waits in the menu.</summary>
    Automation,
    /// <summary>An automatic reconnect: it keeps retrying on its schedule, never logging in to an untrusted certificate.</summary>
    Background,
}

/// <summary>
/// Owns the openconnect processes. All state changes happen on the UI thread.
///
/// Flow: Connect() runs <c>openconnect.exe --protocol=fortinet --passwd-on-stdin …</c>, writes the
/// password (and the one-time code) to its stdin, and watches its output lines to move through
/// connecting → connected. Disconnect() sends Ctrl+C to openconnect's hidden console, which tears the
/// tunnel down cleanly (routes + DNS restored by vpnc-script-win.js) and exits.
///
/// Several connections can be up at the same time. Each one is a <see cref="VpnSession"/> with its
/// own process, its own Wintun adapter ("FiveT", "FiveT-2", …) and its own NRPT rules; picking a
/// second connection adds a tunnel instead of replacing the first. <see cref="Status"/> is still a
/// single value for the tray icon and for callers that predate this — it summarises all of them —
/// while <see cref="Sessions"/> and <see cref="StatusFor"/> give the per-connection detail.
///
/// Whether two tunnels are useful together depends on the gateways: two split-tunnel FortiGates with
/// different internal subnets and DNS domains coexist, but if both push a default route only one of
/// them can own it. Split DNS is per-domain (NRPT), so that part always works.
/// </summary>
public sealed partial class VpnManager
{
    public static VpnManager Shared { get; } = new();

    /// <summary>Live sessions by connection id. A session is dropped once it is idle with no error.</summary>
    private readonly Dictionary<Guid, VpnSession> _sessions = new();

    private readonly Dictionary<Guid, string> _lastCodeUsed = new();

    private bool _externalSession;
    private int _externalPid;
    private VpnStatus _externalStatus = new();
    /// <summary>Connects asked for while an adopted openconnect was running: started once it has stopped (the Mac's pendingAfterExternal).</summary>
    private readonly List<(Connection Connection, ConnectOrigin Origin)> _pendingAfterExternal = new();
    /// <summary>NRPT rules a background removal is still deleting; the quit-time cleanup finishes them synchronously.</summary>
    private readonly HashSet<string> _pendingRemovals = new();

    private VpnStatus _aggregate = new();

    private VpnManager() { }

    /// <summary>
    /// One line for the tray icon, the diagnostics text and the MCP/CLI callers that predate
    /// multiple tunnels: whichever session is most worth reporting, with the connected names joined
    /// when more than one is up. Use <see cref="Sessions"/> when you need them individually.
    /// </summary>
    public VpnStatus Status => _aggregate;

    public event Action<VpnStatus>? StatusChanged;

    /// <summary>Set by the tray app: shows a balloon notification (title, text, isError).</summary>
    public Action<string, string, bool>? Notifier { get; set; }

    /// <summary>Every session that currently exists, plus an adopted external one last.</summary>
    public IReadOnlyList<VpnStatus> Sessions
    {
        get
        {
            var list = _sessions.Values.Select(s => s.Status).ToList();
            if (_externalSession) list.Add(_externalStatus);
            return list;
        }
    }

    /// <summary>This connection's own state, or an idle status when it has no session.</summary>
    public VpnStatus StatusFor(Guid id) =>
        _sessions.TryGetValue(id, out var s) ? s.Status : new VpnStatus { ConnectionId = id };

    /// <summary>True while any tunnel still has a process (the app waits for this when quitting).</summary>
    public bool IsRunning => _sessions.Values.Any(s => s.IsRunning) || _externalSession;

    public bool IsBusy => _sessions.Values.Any(s => s.IsBusy);

    /// <summary>
    /// The network facts of every connected tunnel merged (DNS, search domains and routes unioned,
    /// interface names joined with "+", first split-DNS), for callers that ask about "the VPN" rather
    /// than one tunnel: resolve and check_reachability. The Mac's <c>mergedStatus</c>.
    /// </summary>
    public VpnStatus MergedStatus()
    {
        var up = Sessions.Where(x => x.Phase == VpnPhase.Connected).ToList();
        if (up.Count == 0) return Status;
        if (up.Count == 1) return up[0];   // not the aggregate: a tunnel still coming up would be reported instead
        var n = new NetworkInfo();
        var names = new List<string>();
        foreach (var x in up.Select(u => u.Network).OfType<NetworkInfo>())
        {
            if (x.Interface.Length > 0) names.Add(x.Interface);
            if (n.TunnelIP.Length == 0) n = n with { TunnelIP = x.TunnelIP, PeerIP = x.PeerIP };
            if (n.InterfaceIndex <= 0) n = n with { InterfaceIndex = x.InterfaceIndex };
            foreach (var d in x.DnsServers) if (!n.DnsServers.Contains(d)) n.DnsServers.Add(d);
            foreach (var d in x.SearchDomains) if (!n.SearchDomains.Contains(d)) n.SearchDomains.Add(d);
            foreach (var r in x.Routes) if (!n.Routes.Contains(r)) n.Routes.Add(r);
        }
        return up[0] with
        {
            Network = n with { Interface = string.Join("+", names) },
            ConnectionName = string.Join(" + ", up.Select(u => u.ConnectionName ?? "VPN")),
            SplitDns = up.Select(u => u.SplitDns).FirstOrDefault(d => d != null),
            Since = up.Min(u => u.Since),
            Detail = null, LastError = null, NeedsSetup = false,
            Health = up.Select(u => u.Health).FirstOrDefault(h => h != null),
        };
    }

    /// <summary>
    /// Kills every openconnect FiveT started (and an adopted external one), whole process trees, without
    /// waiting: Quit uses it after its grace period for a clean exit. Timers are cancelled, and each
    /// session is marked as stopping so its exit is not taken for a drop that auto-reconnect should mend.
    /// </summary>
    public void ForceStopAll()
    {
        _pendingAfterExternal.Clear();
        Ui.Cancel(ref _networkTimer);
        Ui.Cancel(ref _wakeTimer);
        foreach (var s in _sessions.Values.ToList())
        {
            s.CancelTimers();
            CancelReconnect(s);
            s.RelaunchWhenStopped = false;
            s.RestartRequested = false;
            s.BlockOnExit = null;
            s.CheckGeneration++;
            if (s.Process is { HasExited: false } p)
            {
                if (s.Status.Phase != VpnPhase.Disconnecting) Update(s, x => x with { Phase = VpnPhase.Disconnecting, Detail = null });
                Log.Shared.Write($"[{s.Name}] force-stopping openconnect (pid {p.Id})", LogLevel.Error);
                try { p.Kill(true); } catch (Exception e) { Log.Shared.Write($"could not kill openconnect: {e.Message}", LogLevel.Error); }
            }
            else
            {
                SetStatus(s, new VpnStatus { ConnectionId = s.Id });
            }
        }
        if (_externalSession)
        {
            try
            {
                using var p = Process.GetProcessById(_externalPid);
                if (p.ProcessName.Equals("openconnect", StringComparison.OrdinalIgnoreCase)) p.Kill(true);
            }
            catch (Exception) { /* already gone */ }
        }
    }

    /// <summary>How many tunnels are up right now (an adopted external session counts).</summary>
    public int ConnectedCount =>
        _sessions.Values.Count(s => s.Status.Phase == VpnPhase.Connected)
        + (_externalSession && _externalStatus.Phase == VpnPhase.Connected ? 1 : 0);

    // MARK: Status plumbing

    private void SetStatus(VpnSession s, VpnStatus status)
    {
        s.Status = status;
        Recompute();
    }

    private void Update(VpnSession s, Func<VpnStatus, VpnStatus> f) => SetStatus(s, f(s.Status));

    /// <summary>
    /// Rebuilds the one-line summary and tells everyone. Sessions that have finished for good are
    /// dropped here, so the registry only ever holds tunnels that are up, busy or showing an error.
    /// </summary>
    private void Recompute()
    {
        foreach (var id in _sessions.Where(kv => kv.Value.IsFinished).Select(kv => kv.Key).ToList())
            _sessions.Remove(id);

        var all = Sessions;
        // A tunnel that is only waiting for the network does not make the icon spin while another one
        // is really connecting; the summary says "waiting" only when that is all that is going on.
        var busyAll = all.Where(x => x.Phase is VpnPhase.Connecting or VpnPhase.Disconnecting).ToList();
        var busy = busyAll.FirstOrDefault(x => !x.WaitingForNetwork) ?? busyAll.FirstOrDefault();
        var connected = all.Where(x => x.Phase == VpnPhase.Connected).ToList();
        var failed = all.FirstOrDefault(x => x.LastError != null);

        VpnStatus next;
        if (busy != null)
        {
            // A tunnel coming up or going down is what the icon should show, but the tunnels that are
            // already up must not vanish from the tooltip while it happens.
            next = connected.Count == 0
                ? busy
                : busy with
                {
                    ConnectionName = string.Join(" + ", connected.Select(x => x.ConnectionName ?? "VPN")
                        .Prepend(busy.ConnectionName ?? "VPN").Distinct()),
                };
        }
        else if (connected.Count == 1)
        {
            next = connected[0];
        }
        else if (connected.Count > 1)
        {
            // Network and SplitDns describe one tunnel each, so a combined summary leaves them out
            // rather than reporting an arbitrary one; Sessions has them per connection.
            next = new VpnStatus
            {
                Phase = VpnPhase.Connected,
                ConnectionName = string.Join(" + ", connected.Select(x => x.ConnectionName ?? "VPN")),
                Since = connected.Min(x => x.Since),
            };
        }
        else
        {
            next = failed ?? new VpnStatus();
        }

        _aggregate = next;
        StatusChanged?.Invoke(next);
    }

    // MARK: Public actions

    /// <summary>Called at launch: adopt an openconnect that is already running (e.g. app crashed earlier).</summary>
    public void DetectExistingSession()
    {
        if (Paths.IsDev)
        {
            // A developer build runs beside the installed app, which may own a live tunnel. Adopting it
            // would let quitting the test build tear down the real connection, so leave it alone.
            Log.Shared.Write("developer mode: leaving any openconnect session already running alone");
            return;
        }
        StopLeftoverVpnPrograms();
        var others = Process.GetProcessesByName("openconnect");
        if (others.Length > 0)
        {
            _externalSession = true;
            _externalPid = others[0].Id;
            _externalStatus = new VpnStatus { Phase = VpnPhase.Connected, ConnectionName = "openconnect (started outside FiveT)" };
            Recompute();
            Log.Shared.Write($"found an openconnect process already running (pid {_externalPid})");
            CaptureExternalNetwork();
        }
        else
        {
            CleanupStaleResolvers();
            RemoveGhostTunnelAdapters();
        }
        foreach (var p in others) p.Dispose();
    }

    /// <summary>Connects this connection, or disconnects it when it is the one already up.</summary>
    public void Toggle(Connection c)
    {
        if (IsActive(c.Id))
            Disconnect(c.Id);
        else
            Connect(c);
    }

    /// <summary>Up or on its way up (what a second click, or fivet://toggle, turns off).</summary>
    public bool IsActive(Guid id) =>
        _sessions.TryGetValue(id, out var s) && s.Status.Phase is VpnPhase.Connected or VpnPhase.Connecting;

    /// <summary>Set while the app quits: a link or an assistant that asks for a tunnel then would start one nothing stops.</summary>
    public volatile bool Closing;

    /// <summary>The menu's "Connect All": every saved connection that is not already up or on its way.</summary>
    public void ConnectAll()
    {
        // The Forti connections: they run side by side. A VPN is one at a time, so "all" cannot mean those.
        foreach (var c in ConnectionStore.Shared.Connections.Where(c => !c.IsOtherVpn).ToList())
            if (StatusFor(c.Id).Phase == VpnPhase.Idle) Connect(c);
    }

    /// <summary>
    /// Brings this connection up, leaving any other tunnel alone. Asking for one that is already up
    /// does nothing; asking for one that is still shutting down queues a relaunch.
    /// <paramref name="origin"/> is who asked: it decides what a certificate question does (see Start).
    /// </summary>
    public void Connect(Connection c, ConnectOrigin origin = ConnectOrigin.User)
    {
        if (Closing)
        {
            Log.Shared.Write($"[{c.Name}] connect request ignored: FiveT is quitting");
            return;
        }
        if (_sessions.TryGetValue(c.Id, out var existing))
        {
            if (existing.Status.Phase == VpnPhase.Connecting && !existing.IsRunning && existing.ReconnectTimer != null)
            {
                // Only waiting for a retry timer or for the network: go now, as the Mac does. A click
                // makes whatever certificate question comes up this person's (Start sets the origin).
                Log.Shared.Write($"[{c.Name}] was waiting to retry; connecting now");
                Ui.Cancel(ref existing.ReconnectTimer);
                existing.ReconnectDue = null;
                existing.WaitingForNetwork = false;
                Start(c, origin);
                return;
            }
            if (existing.Status.Phase is VpnPhase.Connected or VpnPhase.Connecting)
            {
                // A check or a login already under way: a click only takes over the question it may ask.
                if (origin == ConnectOrigin.User && existing.Status.Phase == VpnPhase.Connecting) existing.Origin = ConnectOrigin.User;
                Log.Shared.Write($"[{c.Name}] already {existing.Status.StateName}; ignoring the connect request");
                return;
            }
            if (existing.Status.Phase == VpnPhase.Disconnecting || existing.IsRunning)
            {
                existing.RelaunchWhenStopped = true;   // start again the moment its process is gone
                existing.RelaunchOrigin = origin;
                existing.Connection = c;
                return;
            }
            CancelReconnect(existing);
            existing.CancelTimers();
        }
        if (_externalSession)
        {
            // An openconnect FiveT did not start may hold the adapter name and the routes: stop it
            // first and connect once it is gone (the Mac does the same).
            var i = _pendingAfterExternal.FindIndex(x => x.Connection.Id == c.Id);
            var wasUser = i >= 0 && _pendingAfterExternal[i].Origin == ConnectOrigin.User;
            var entry = (c, wasUser ? ConnectOrigin.User : origin);
            if (i >= 0) _pendingAfterExternal[i] = entry; else _pendingAfterExternal.Add(entry);
            if (_externalStatus.Phase != VpnPhase.Disconnecting) DisconnectExternal();
            return;
        }
        Start(c, origin);
    }

    /// <summary>Stops one tunnel, as its user asked, and leaves the others running: for a VPN the kill switch lets go too (a Forti stop leaves it).</summary>
    public void Disconnect(Guid id)
    {
        if (_sessions.TryGetValue(id, out var asked) && asked.Connection.IsOtherVpn)
        {
            ReleaseKillSwitch();
            asked.BlockOnExit = null;
        }
        StopSession(id);
    }

    /// <summary>Stops one tunnel: no relaunch, no reconnect.</summary>
    private void StopSession(Guid id)
    {
        // A connect that was only waiting for an adopted openconnect to stop is cancelled too.
        _pendingAfterExternal.RemoveAll(x => x.Connection.Id == id);
        // No session, nothing to stop: an adopted openconnect is not this connection's (the flyout's
        // own row, DisconnectAll and Quit stop it through DisconnectExternal).
        if (!_sessions.TryGetValue(id, out var s)) return;
        // Whatever was queued to start again after the stop is cancelled by the stop (as on the Mac).
        s.RelaunchWhenStopped = false;
        s.RestartRequested = false;
        Ui.Cancel(ref s.StopTimer);
        Ui.Cancel(ref s.WaitTimer);
        CancelReconnect(s);   // a manual disconnect never reconnects on its own
        EndOtpTrial(s);
        s.CheckGeneration++;  // a certificate check or trust prompt still open must not connect afterwards
        RemoveSplitDns(s);

        if (!s.IsRunning)
        {
            SetStatus(s, new VpnStatus { ConnectionId = s.Id });
            return;
        }

        // Its password is at the gateway already: counted now (a quit does not wait for ProcessEnded). A login
        // that gets through before the stop clears it again.
        if (s.LoginPending) LoginFailed(s);
        Update(s, x => x with { Phase = VpnPhase.Disconnecting, Detail = null, Health = null });
        Log.Shared.Write($"[{s.Name}] disconnecting");
        ClearTunnelDns(s);
        var p = s.Process!;
        var ok = false;
        try { ok = !p.HasExited && Native.SendCtrlC(p.Id); }
        catch (Exception e) { Log.Shared.Write($"Ctrl+C failed: {e.Message}", LogLevel.Error); }
        if (!ok) Log.Shared.Write("could not signal the VPN program; it will be killed if it does not exit", LogLevel.Error);
        s.StopTimer = Ui.After(8, () => { s.StopTimer = null; ForceStop(s); });
    }

    /// <summary>Stops every tunnel (quitting, and the "Disconnect all" row in the flyout).</summary>
    public void DisconnectAll()
    {
        _pendingAfterExternal.Clear();
        ReleaseKillSwitch();
        foreach (var id in _sessions.Keys.ToList()) Disconnect(id);
        if (_externalSession) DisconnectExternal();
    }

    /// <summary>Stops an adopted openconnect (the flyout offers this as its own row).</summary>
    public void DisconnectExternal()
    {
        _externalStatus = _externalStatus with { Phase = VpnPhase.Disconnecting };
        Recompute();
        Log.Shared.Write("stopping external openconnect session");
        var pid = _externalPid;
        try
        {
            using var p = Process.GetProcessById(pid);
            if (!Native.SendCtrlC(p.Id)) p.Kill(true);
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not stop external openconnect: {e.Message}", LogLevel.Error);
        }
        Ui.After(1.5, () => FinishExternalStop(pid, 0));
    }

    /// <summary>
    /// The adopted openconnect has had its Ctrl+C. Once it is really gone (a tunnel takes a few seconds
    /// to come down; 8 s at most, then it is killed) the session is dropped and the connects that waited
    /// for it start. They must not start sooner: it may still own the adapter and the routes.
    /// </summary>
    private void FinishExternalStop(int pid, int tries)
    {
        if (!_externalSession || _externalPid != pid) return;
        var alive = false;
        try
        {
            using var p = Process.GetProcessById(pid);
            alive = !p.HasExited && p.ProcessName.Equals("openconnect", StringComparison.OrdinalIgnoreCase);
            if (alive && tries >= 13) { try { p.Kill(true); } catch { } }
        }
        catch (Exception) { /* gone */ }
        if (alive && tries < 14)
        {
            Ui.After(0.5, () => FinishExternalStop(pid, tries + 1));
            return;
        }
        _externalSession = false;
        _externalStatus = new VpnStatus();
        Recompute();
        var next = _pendingAfterExternal.ToList();
        _pendingAfterExternal.Clear();
        foreach (var (conn, origin) in next)
            if (ConnectionStore.Shared.Get(conn.Id) is { } latest) Connect(latest, origin);
    }

    /// <summary>Clears shown errors once the user has seen them (menu closed).</summary>
    public void ClearError()
    {
        var cleared = false;
        foreach (var s in _sessions.Values.ToList())
        {
            if (s.Status.Phase != VpnPhase.Idle || s.Status.LastError == null) continue;
            s.Status = s.Status with { LastError = null };
            cleared = true;
        }
        if (cleared) Recompute();
    }

    /// <summary>
    /// Called when the app quits: remove every NRPT rule synchronously, including those a background
    /// removal from a disconnect has not finished (it may not before the process exits).
    /// </summary>
    public void ShutdownCleanup()
    {
        var domains = new SortedSet<string>(_pendingRemovals, StringComparer.Ordinal);
        foreach (var s in _sessions.Values)
        {
            domains.UnionWith(s.InstalledDomains);
            s.InstalledDomains.Clear();
        }
        foreach (var d in domains) SplitDns.Remove(d);
        _pendingRemovals.Clear();
        if (_sessions.Values.Any(s => s.TunnelDns)) SplitDns.ClearDefault();
        KillSwitch.Unblock();
    }

    // MARK: Internals

    /// <summary>
    /// The Wintun adapter name for a new tunnel: the lowest free slot, so the first one is always
    /// plain "FiveT" and a session that ends frees its name for the next connect.
    /// </summary>
    private string AllocateAdapterName()
    {
        for (var i = 1; ; i++)
        {
            var name = i == 1 ? Setup.AdapterName : $"{Setup.AdapterName}-{i}";
            if (_sessions.Values.All(s => s.AdapterName != name)) return name;
        }
    }

    private static void ForceStop(VpnSession s)
    {
        if (s.Process is not { HasExited: false } p) return;
        Log.Shared.Write($"[{s.Name}] openconnect did not exit within 8s; killing it", LogLevel.Error);
        try { p.Kill(true); } catch { }
    }

    private void Fail(VpnSession s, string message, bool needsSetup = false)
    {
        Log.Shared.Write($"[{s.Name}] FAILED: {message}", LogLevel.Error);
        // A failed session has nothing left to retry or wait for; without this it would never reach
        // IsFinished (Reconnecting stays true) and NetworkSettled could still pick it up.
        s.CancelTimers();
        CancelReconnect(s);
        EndOtpTrial(s);
        ConnectionStore.Shared.Mutate(s.Id, x => x.LastError = message);
        SetStatus(s, new VpnStatus { ConnectionId = s.Id, ConnectionName = s.Name, LastError = message, NeedsSetup = needsSetup });
        if (ConnectionStore.Shared.NotifyOnChange) Notifier?.Invoke($"{s.Name}: connection failed", message, true);
    }

    /// <summary>Reports a failure for a connection that never got as far as owning an adapter.</summary>
    private void FailBeforeStart(Connection c, string message, bool needsSetup = false)
    {
        if (!_sessions.TryGetValue(c.Id, out var s))
        {
            s = new VpnSession(c, AllocateAdapterName());
            _sessions[c.Id] = s;
        }
        Fail(s, message, needsSetup);
    }

    // MARK: Gateway certificate, checked before every login

    private static string UrlOf(Connection c)
    {
        var realm = c.Realm.Trim();
        return $"https://{FieldCleaner.AsciiHost(c.Host.Trim())}:{c.Port}" + (realm.Length > 0 ? "/" + realm : "");
    }

    /// <summary>
    /// The first field whose text holds a line break or a NUL, else null. The password goes to
    /// openconnect's stdin one line per answer, so a line break in it would split it into extra answers
    /// (and into the wrong ones); the others end up in the URL and arguments. The Mac checks the same.
    /// </summary>
    private static string? FieldWithLineBreak(Connection c)
    {
        // NUL, LF, CR, NEL, line separator, paragraph separator (the Mac checks isNewline; NUL is added here).
        static bool Bad(string t) => t.Any(ch => ch is (char)0 or (char)10 or (char)13 or (char)0x85 or (char)0x2028 or (char)0x2029);
        foreach (var (name, text) in new[] { ("gateway", c.Host), ("realm", c.Realm), ("username", c.Username), ("password", c.Password), ("TOTP secret", c.TotpSecret) })
            if (Bad(text)) return name;
        return null;
    }

    /// <summary>The checks that need no network; false (and the failure reported) when one fails.</summary>
    private bool Precheck(Connection c)
    {
        if (Setup.OpenconnectPath == null)
        {
            // Found but refused (its folder can be changed by ordinary programs) is a different fix from missing.
            FailBeforeStart(c, Setup.OpenconnectRefusal is { } refusal
                ? $"{refusal} Open Settings → General."
                : "OpenConnect is missing. Open Settings → General and click Set Up FiveT.", needsSetup: true);
            return false;
        }
        if (!Paths.IsElevated)
        {
            FailBeforeStart(c, "FiveT must run as administrator to create the tunnel. Open Settings → General.", needsSetup: true);
            return false;
        }
        if (c.Host.Trim().Length == 0)
        {
            FailBeforeStart(c, $"{c.Name} has no gateway address. Open Settings → Connections.");
            return false;
        }
        if (c.Username.Trim().Length == 0)
        {
            // FortiClient profiles often carry no username; openconnect refuses an empty --user= with
            // "Fatal error in command line handling", which tells the user nothing.
            FailBeforeStart(c, $"{c.Name} has no username. Open Settings → Forti, select it and enter the username and password.");
            return false;
        }
        if (FieldWithLineBreak(c) is { } bad)
        {
            FailBeforeStart(c, $"The {bad} of {c.Name} contains a line break. Retype it in Settings → Connections.");
            return false;
        }
        return true;
    }

    /// <summary>
    /// Starts a connect: first the gateway's certificate is fetched and judged, and only then does
    /// openconnect get the password (<see cref="Launch"/>). The rules are the Mac app's (1.8,
    /// VPNManager.handleRefusedCertificate and CertCheck):
    ///
    /// - The certificate this connection trusts for this gateway: go ahead.
    /// - A gateway met for the first time (never logged in to, or its host or port edited): trusted
    ///   without asking only when Windows vouches for it — a root that comes with Windows — for exactly
    ///   the host name FiveT connects to, as a browser would.
    /// - A known gateway with another certificate: a renewal when Windows vouches for it for the host
    ///   name, or, for a gateway reached by IP address, when its chain is good and it carries a name
    ///   the old one had. Once per attempt: a second change right after a renewal always asks.
    /// - Anything else waits for the user as a review saved on the connection (Review Certificate…).
    ///   A click asks at once; an assistant, a link or the command line fails and leaves the review in
    ///   the menu; an automatic reconnect keeps retrying on its schedule without logging in, because a
    ///   hotel Wi-Fi sign-in page that intercepts the connection goes away by itself.
    /// </summary>
    private void Start(Connection c, ConnectOrigin origin)
    {
        if (c.IsOtherVpn) { StartVpn(c, origin); return; }
        if (!Precheck(c)) return;
        if (!_sessions.TryGetValue(c.Id, out var s))
        {
            s = new VpnSession(c, AllocateAdapterName());
            _sessions[c.Id] = s;
        }
        EndOtpTrial(s);   // a new attempt starts from the saved one-time-code mode
        s.Connection = c;
        s.Origin = origin;
        if (origin == ConnectOrigin.User) s.AutoRenewed = false;
        var gen = ++s.CheckGeneration;
        // The gateway this check is about, as text. ConnectionStore.Get hands out the live instance the
        // editor changes in place, so comparing the connection with itself afterwards would never see an
        // edit of host or port (the Mac captures the key the same way).
        var key = c.GatewayKey;
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = s.ReconnectAttempt > 0 ? $"Reconnecting (try {s.ReconnectAttempt})…" : "Checking the gateway's certificate…",
        });
        var host = FieldCleaner.AsciiHost(c.Host.Trim());
        var port = c.Port;
        var ofv = Setup.OpenconnectPath!;
        var url = UrlOf(c);
        Task.Run(() =>
        {
            var (info, err, reached) = GatewayCert.Fetch(host, port);
            // Schannel may refuse a handshake GnuTLS would complete (an old cipher). openconnect then
            // tells us the pin itself — without a password, so it cannot log in.
            string? fallbackPin = null;
            if (info == null && reached) fallbackPin = GatewayCert.PinFromOpenconnect(ofv, url);
            Ui.Post(() => CertChecked(s, gen, key, info, err, reached, fallbackPin));
        });
    }

    private bool StillWanted(VpnSession s, int gen) =>
        _sessions.TryGetValue(s.Id, out var current) && ReferenceEquals(current, s) && s.CheckGeneration == gen
        && s.Status.Phase == VpnPhase.Connecting && !s.IsRunning;

    private void CertChecked(VpnSession s, int gen, string key, GatewayCertInfo? info, string? err, bool reached, string? fallbackPin)
    {
        if (!StillWanted(s, gen)) return;
        var ran = s.Connection;
        var c = ConnectionStore.Shared.Get(ran.Id) ?? ran;
        if (c.GatewayKey != key)
        {
            Log.Shared.Write($"[{c.Name}] the gateway was changed in Settings meanwhile; starting over with it");
            Start(c, s.Origin);
            return;
        }
        var first = !c.KnowsGateway;

        if (info == null)
        {
            if (!reached)
            {
                // The gateway does not answer at all. With a pin, openconnect reports that in its own
                // words (and would refuse any other certificate); with none there is nothing it could
                // safely be given, so this is simply a failed attempt.
                Log.Shared.Write($"[{c.Name}] could not reach the gateway to check its certificate: {err}");
                if (c.HasPinForGateway && c.TrustedCertPin.Length > 0) { Launch(c); return; }
                FailedToReach(s, "Could not reach the gateway. Is another VPN switched on?");
                return;
            }
            if (fallbackPin != null && c.HasPinForGateway && fallbackPin == c.TrustedCertPin) { Launch(c); return; }
            var why = "FiveT could not fetch the gateway's certificate to check it";
            Log.Shared.Write($"[{c.Name}] {why}: {err}", LogLevel.Error);
            Unverified(s, c, first, fallbackPin, fallbackPin ?? "", null, why);
            return;
        }

        // The certificate this connection trusts: by its SHA-256, or by the pin Windows 1.4.0 kept.
        var same = c.KnowsGateway && ((c.TrustedCert.Length > 0 && info.Sha256 == c.TrustedCert)
                                      || (c.TrustedCert.Length == 0 && c.TrustedCertPin.Length > 0 && info.Pin == c.TrustedCertPin));
        // A known gateway with no pin was verified by a certificate authority (the Mac writes this).
        var verifiedByCa = c.KnowsGateway && c.TrustedCert.Length == 0 && c.TrustedCertPin.Length == 0 && info.TrustedForHost;
        if (same || verifiedByCa)
        {
            if (c.TrustedCert != info.Sha256 || c.TrustedCertPin != info.Pin || c.TrustedCertNames.Count == 0)
            {
                // Same certificate, fuller record: the SHA-256 and names the Mac keeps, and the pin.
                var names = c.TrustedCertNames.Count > 0 ? c.TrustedCertNames : info.Names;
                ConnectionStore.Shared.Mutate(c.Id, x => x.Trust(info.Sha256, info.Pin, names));
                c = ConnectionStore.Shared.Get(c.Id) ?? c;
            }
            Launch(c);
            return;
        }

        string reason;
        var renewal = false;
        if (first)
        {
            renewal = info.TrustedForHost;
            reason = info.ChainTrusted
                ? $"Windows trusts the certificate, but it is made out to {string.Join(", ", info.Names)}, not to {c.Host.Trim()}"
                : info.TrustError ?? "Windows does not trust the certificate";
        }
        else if (s.AutoRenewed)
        {
            reason = "it changed again right after a renewal";
        }
        else if (info.TrustedForHost)
        {
            renewal = true;
            reason = "";
        }
        else if (!info.ChainTrusted)
        {
            reason = info.TrustError ?? "Windows does not trust the new certificate";
        }
        else
        {
            var pinned = c.TrustedCertNames.Select(n => n.ToLowerInvariant()).ToHashSet();
            renewal = pinned.Count > 0 && pinned.Overlaps(info.Names);
            reason = pinned.Count == 0
                ? "the new certificate is valid, but FiveT has no record of the old certificate's name to compare"
                : $"the new certificate is made out to {string.Join(", ", info.Names)}, not {string.Join(", ", pinned.OrderBy(x => x))}";
        }

        if (renewal)
        {
            ConnectionStore.Shared.Mutate(c.Id, x => x.Trust(info.Sha256, info.Pin, info.Names));
            c = ConnectionStore.Shared.Get(c.Id) ?? c;
            s.AutoRenewed = !first;
            Log.Shared.Write(first
                ? $"[{c.Name}] Windows vouches for the certificate ({info.Summary}) for {c.Host.Trim()}; trusting it"
                : $"[{c.Name}] the new certificate is {info.Summary}, and Windows vouches for it for this gateway: a renewal; trusting it");
            Launch(c);
            return;
        }
        Log.Shared.Write(first
            ? $"[{c.Name}] first connection to {c.GatewayKey}: checking its certificate {info.Sha256[..12]}… before logging in"
            : $"[{c.Name}] the gateway's certificate has changed (trusted {(c.TrustedCert.Length > 0 ? c.TrustedCert[..Math.Min(12, c.TrustedCert.Length)] : "an older one")}…, now {info.Sha256[..12]}…); not logging in until it is checked",
            first ? LogLevel.Info : LogLevel.Error);
        Unverified(s, c, first, info.Sha256, info.Pin, info, reason);
    }

    /// <summary>Saves the review on the connection and decides what the attempt does next (see <see cref="Start"/>).</summary>
    private void Unverified(VpnSession s, Connection c, bool first, string? cert, string pin, GatewayCertInfo? info, string reason)
    {
        if (string.IsNullOrEmpty(cert))
        {
            // Not even a pin to put in front of the user: nothing to review, so it counts as a failure.
            FailedToReach(s, $"FiveT could not read the certificate of {c.Name}'s gateway, so it did not log in.");
            return;
        }
        var details = Describe(cert, info, first ? null : c, reason);
        ConnectionStore.Shared.Mutate(c.Id, x => x.SetPendingReview(cert, pin, first, details));
        Log.Shared.Write($"[{c.Name}] not trusting the {(first ? "" : "new ")}certificate without asking: {reason}", LogLevel.Error);

        var what = first ? $"FiveT has not connected to {c.Name}'s gateway before and needs you to confirm its certificate"
                         : $"The certificate of {c.Name}'s gateway has changed";
        const string safe = "FiveT did not log in and did not send your password.";
        if (s.Origin == ConnectOrigin.User)
        {
            s.ReconnectAttempt = 0;
            s.Reconnecting = false;
            Fail(s, $"{what}. {safe}");
            ReviewNeeded?.Invoke(c.Id);   // the person who clicked gets the question at once
        }
        else if (s.Origin == ConnectOrigin.Background && s.ReconnectAttempt > 0 && !first)
        {
            Log.Shared.Write($"[{c.Name}] keeps retrying meanwhile (no password is sent to an untrusted certificate)");
            ScheduleReconnect(s, s.ReconnectAttempt + 1, "The gateway shows another certificate");
        }
        else
        {
            CancelReconnect(s);
            Fail(s, $"{what}. {safe} Choose {(first ? "Review Certificate" : "Review New Certificate")} for {c.Name}… in FiveT's menu.");
        }
    }

    /// <summary>An attempt that never got as far as a certificate: retried on schedule in the background, else reported.</summary>
    private void FailedToReach(VpnSession s, string message)
    {
        if (s.Origin == ConnectOrigin.Background && s.ReconnectAttempt > 0)
        {
            Log.Shared.Write($"[{s.Name}] reconnect attempt {s.ReconnectAttempt} failed: {message}", LogLevel.Error);
            ScheduleReconnect(s, s.ReconnectAttempt + 1);
            return;
        }
        var prefix = s.ReconnectAttempt > 0 ? $"Could not reconnect {s.Name}: " : "";
        CancelReconnect(s);
        Fail(s, prefix + message);
    }

    /// <summary>The text of the review: details only from the certificate FiveT fetched itself.</summary>
    private static string Describe(string cert, GatewayCertInfo? info, Connection? old, string reason)
    {
        var lines = new List<string>();
        lines.Add(info != null ? $"The certificate says it is {info.Summary}." : "FiveT could not read the certificate's details.");
        lines.Add(cert.StartsWith("pin-sha256:", StringComparison.Ordinal)
            ? $"Its public key (as openconnect names it): {cert}"
            : $"Its fingerprint (SHA-256): {GatewayCert.GroupedHex(cert)}");
        if (old != null)
            lines.Add(old.TrustedCert.Length > 0
                ? $"Trusted until now: {GatewayCert.GroupedHex(old.TrustedCert)}" + (old.TrustedCertNames.Count == 0 ? "" : $" ({string.Join(", ", old.TrustedCertNames)})")
                : old.TrustedCertPin.Length > 0 ? $"Trusted until now: {old.TrustedCertPin}"
                : "Until now, a certificate from a certificate authority, for this gateway's name.");
        lines.Add($"Why FiveT did not accept it by itself: {reason}.");
        return string.Join("\n", lines);
    }

    /// <summary>Set by the tray app: shows the review for a connection whose certificate question came from a click.</summary>
    public event Action<Guid>? ReviewNeeded;

    // MARK: Failed-login limit (the Mac's LoginGuard rules, VPNManager.swift)

    /// <summary>Set by the tray app: asks the person who clicked Connect whether to log in although the last logins to that gateway failed.</summary>
    public event Action<Guid>? LoginLimitReached;

    /// <summary>Try Anyway: one more login for this connection, only while the failures on record are still this many.</summary>
    private readonly Dictionary<Guid, int> _loginOverrideAt = new();

    /// <summary>True while the failed-login limit holds this connection's gateway back (the menu and MCP say so).</summary>
    public static bool IsLoginLimited(Connection c) => LoginGuard.Shared.IsLimited(c.LoginGuardKey);

    /// <summary>The user's answer to the question: one more login may go out, at the count the question showed.</summary>
    public void TryAnyway(Connection c, int failedShown)
    {
        Log.Shared.Write($"[{c.Name}] the user chose Try Anyway after {failedShown} failed login(s)");
        _loginOverrideAt[c.Id] = failedShown;
        Connect(c, ConnectOrigin.User);
    }

    /// <summary>Logins other tunnels have under way to this gateway: started and not through yet. Each may still fail, so they count against the limit as if they had.</summary>
    private int LoginsInFlight(string key, VpnSession besides) =>
        _sessions.Values.Count(x => x != besides && x.IsRunning && !x.Authenticated && x.Connection.LoginGuardKey == key);

    /// <summary>
    /// The other way of sending the one-time code when every login on record that the gateway refused for
    /// this connection sent it the saved way: the next login then tries the other way rather than one the
    /// gateway refused. Null without a code, without refusals, once both ways were refused, or when the
    /// gateway has taken the saved way before (then a refusal is the password, the account or the gateway).
    /// </summary>
    public static OtpMode? UntriedOtpMode(Connection c)
    {
        if (!c.UsesTotp || c.OtpModeAccepted) return null;
        var other = c.OtpMode == OtpMode.AppendToPassword ? OtpMode.Separate : OtpMode.AppendToPassword;
        var mine = LoginGuard.Shared.Failures(c.LoginGuardKey).Where(f => f.Connection == c.Id && f.Rejected == true).ToList();
        return mine.Any(f => f.OtpMode == c.OtpMode) && !mine.Any(f => f.OtpMode == other) ? other : null;
    }

    public static string Describe(OtpMode mode) => mode == OtpMode.AppendToPassword ? "appended to the password" : "sent as a second step";

    /// <summary>Why FiveT does not log in to this gateway by itself, for the menu, the log and assistants. The first sentence is the headline the menu shows.</summary>
    public static string LoginLimitMessage(Connection c)
    {
        var failed = LoginGuard.Shared.Count(c.LoginGuardKey);
        var text = $"{c.Name} stopped after {failed} failed logins. One more failed login to its gateway gets this network's internet address banned there for hours.";
        if (UntriedOtpMode(c) is { } other)
            text += $" Those logins had the one-time code {Describe(c.OtpMode)}; in the next one it is {Describe(other)}.";
        return text + $" Check the password and the one-time code in Settings → {(c.IsOpenVpn ? "VPN" : "Forti")} (and that the PC's clock is right), then click {c.Name} in FiveT's menu."
               + LastConnectedNote(c);
    }

    /// <summary>For a login the gateway refused on a connection that has connected before: when that was (Mac 1.13.1).</summary>
    private static string LastConnectedNote(Connection c)
    {
        if (c.LastConnectedAt is not { } last) return "";
        var when = last.Date == DateTime.Today ? $"at {last:HH:mm}" : $"on {last:yyyy-MM-dd HH:mm}";
        return $" It last connected {when}; if the password and the code are right, the gateway or the account may have changed, and its administrator can say.";
    }

    /// <summary>The password went out and the login did not get in.</summary>
    private void LoginFailed(VpnSession s)
    {
        var c = s.Connection;
        s.LoginPending = false;
        s.LoginFailedThisRun = true;
        var n = LoginGuard.Shared.RecordFailure(c.LoginGuardKey, c.Id, c.UsesTotp ? c.OtpMode : null, IsAuthFailure(s));
        Log.Shared.Write($"[{s.Name}] login to {c.LoginGuardKey} failed ({n} in a row; FiveT stops at {LoginGuard.Limit})", LogLevel.Error);
    }

    /// <summary>The gateway let this login in: the failed-login count starts over, and the way the code went out is remembered as accepted.</summary>
    private void LoginSucceeded(VpnSession s)
    {
        if (s.Authenticated) return;
        var c = s.Connection;
        s.LoginPending = false;
        s.Authenticated = true;
        var cleared = LoginGuard.Shared.RecordSuccess(c.LoginGuardKey);
        if (cleared > 0) Log.Shared.Write($"[{c.Name}] logged in; the {cleared} failed login(s) before no longer count");
        if (c.UsesTotp && !c.OtpModeAccepted)
        {
            var accepted = c.OtpAcceptedKey;
            ConnectionStore.Shared.Mutate(c.Id, x => x.AcceptedOtp = accepted);
        }
    }

    /// <summary>
    /// Never the failed login that gets this network's address banned: at the limit a click is asked first and
    /// everything else (reconnects, assistants, the command line, links) stops; while failures are on record,
    /// logins to one gateway go one at a time. False when this launch must not go on now.
    /// </summary>
    private bool LoginAllowed(VpnSession s, Connection c)
    {
        var key = c.LoginGuardKey;
        var failed = LoginGuard.Shared.Count(key);
        var tryAnyway = _loginOverrideAt.TryGetValue(c.Id, out var at) && at == failed;
        if (failed >= LoginGuard.Limit && !tryAnyway)
        {
            _loginOverrideAt.Remove(c.Id);
            if (s.Origin == ConnectOrigin.User)
            {
                Log.Shared.Write($"[{c.Name}] {failed} logins to {key} failed in a row; asking before logging in again");
                s.CancelTimers();
                CancelReconnect(s);
                EndOtpTrial(s);
                SetStatus(s, new VpnStatus { ConnectionId = s.Id });
                LoginLimitReached?.Invoke(c.Id);
            }
            else Fail(s, LoginLimitMessage(c));
            return false;
        }
        var inFlight = LoginsInFlight(key, s);
        if (inFlight > 0 && (tryAnyway || failed + inFlight >= LoginGuard.Limit))
        {
            // Another login to this gateway may still fail: one at a time, then decide again.
            Update(s, x => x with { Phase = VpnPhase.Connecting, Detail = "Waiting for another login to the same gateway…" });
            Ui.Cancel(ref s.WaitTimer);
            s.WaitTimer = Ui.After(2, () => { s.WaitTimer = null; if (!s.IsRunning && s.Status.Phase == VpnPhase.Connecting) Relaunch(s, s.OtpTrialOf != null ? s.Connection : ConnectionStore.Shared.Get(c.Id) ?? c); });
            return false;
        }
        return true;
    }

    private void Launch(Connection c)
    {
        var ofv = Setup.OpenconnectPath;
        if (ofv == null)
        {
            FailBeforeStart(c, "OpenConnect is not installed. Open Settings → General.", needsSetup: true);
            return;
        }
        if (!Paths.IsElevated)
        {
            FailBeforeStart(c, "FiveT must run as administrator to create the tunnel. Open Settings → General.", needsSetup: true);
            return;
        }
        if (c.Host.Trim().Length == 0)
        {
            FailBeforeStart(c, $"{c.Name} has no gateway address. Open Settings → Connections.");
            return;
        }

        if (!_sessions.TryGetValue(c.Id, out var s))
        {
            s = new VpnSession(c, AllocateAdapterName());
            _sessions[c.Id] = s;
        }
        // One openconnect per session: a second would be untracked, running as administrator.
        if (s.IsRunning)
        {
            Log.Shared.Write($"[{c.Name}] already starting; not starting a second openconnect", LogLevel.Debug);
            return;
        }
        s.Connection = c;
        // Also here, not only in Precheck: the connection may have been edited since the check started.
        if (FieldWithLineBreak(c) is { } bad)
        {
            Fail(s, $"The {bad} of {c.Name} contains a line break. Retype it in Settings → Connections.");
            return;
        }
        // When only the saved way of sending the one-time code has been refused, the other way goes first.
        if (s.OtpTrialOf == null && UntriedOtpMode(c) is { } untried)
        {
            Log.Shared.Write($"[{c.Name}] the failed login(s) on record had the one-time code {Describe(c.OtpMode)}; this time it is {Describe(untried)}");
            var trial = c.Clone();
            trial.OtpMode = untried;
            s.OtpTrialOf = c;
            s.Connection = c = trial;
        }
        if (!LoginAllowed(s, c)) return;
        s.LoginPending = false;
        s.Authenticated = false;
        s.LoginFailedThisRun = false;
        s.LastErrorLine = null;
        s.SawCertFailure = false;
        s.SawUnreachable = false;
        s.OpenconnectPin = null;
        s.SawAdapterFailure = false;
        s.CurrentCode = null;
        s.PendingTunnelIp = "";

        var password = c.Password;
        string? otp = null;
        if (c.UsesTotp)
        {
            // One instant for the code and for the time left in its window, so a launch right at the
            // boundary cannot take the old window's code and think the new window has 30 s.
            var now = DateTime.UtcNow;
            var code = Totp.Code(c.TotpSecret, 6, now);
            if (code == null)
            {
                // An empty secret is a different fix from a mistyped one.
                Fail(s, c.TotpSecret.Trim().Length == 0
                    ? $"{c.Name} uses a one-time code but has no TOTP secret. Add it in Settings → Connections."
                    : $"The TOTP secret for {c.Name} is not valid Base32.");
                return;
            }
            // Servers reject a reused code, and one about to run out can expire on its way through the
            // TLS handshake and the login POST. Either way, wait for the next 30 s window (4 s, as on the Mac).
            var reused = _lastCodeUsed.TryGetValue(c.Id, out var used) && used == code;
            var remaining = Totp.SecondsRemaining(now);
            if (reused || remaining <= TotpBoundarySeconds)
            {
                var wait = remaining + 1;
                SetStatus(s, new VpnStatus
                {
                    Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
                    Detail = $"Waiting {wait}s for a fresh code…",
                });
                Log.Shared.Write($"[{c.Name}] {(reused ? "current code was already used" : "current code is about to expire")}; waiting {wait}s");
                Ui.Cancel(ref s.WaitTimer);
                s.WaitTimer = Ui.After(wait, () => { s.WaitTimer = null; Launch(c); });
                return;
            }
            Redactor.AddCode(code);
            s.CurrentCode = code;
            if (c.OtpMode == OtpMode.AppendToPassword) password += code; else otp = code;
        }

        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = s.ReconnectAttempt > 0 ? $"Reconnecting (try {s.ReconnectAttempt})…" : "Starting openconnect…",
        });

        var args = new List<string>
        {
            "--protocol=fortinet",
            "--passwd-on-stdin",
            "--user=" + c.Username.Trim(),
            "--reconnect-timeout=30",   // openconnect gives up after 30 s so FiveT's own reconnect loop takes over
        };
        // Each tunnel needs its own adapter: two openconnects asking for the same name fight over it.
        if (Setup.HasWintun(ofv)) args.Add("--interface=" + s.AdapterName);
        if (Setup.VpncScriptPath(ofv) is { } script) args.Add("--script=" + script);
        // The extra options, minus the ones that could run a program, swap the certificate or replace
        // FiveT's own arguments (ExtraOptions). What was left out is named once, never with its value.
        var extra = ExtraOptions.Parse(c.ExtraConfig);
        foreach (var ignored in extra.Ignored)
        {
            // A line that is no option at all (no leading dash) may be a secret pasted in the wrong
            // place; its text is not logged (the Mac says the same, without naming it).
            var what = ignored.StartsWith('-') ? ignored : "a line that is not an option (not shown: it may hold a password)";
            Log.Shared.Write($"[{c.Name}] warning: ignored extra option {what}");
        }
        // Stay on the TLS transport, like the Mac app: openfortivpn has no DTLS at all. A FortiGate that
        // offers DTLS but does not actually carry traffic over it answers no keepalive, so openconnect
        // declares a dead peer about ten seconds after connecting and the session is lost. An accepted
        // extra option about dtls hands the choice back to openconnect.
        if (!extra.Args.Any(a => a.StartsWith('-') && a.Contains("dtls", StringComparison.OrdinalIgnoreCase))) args.Add("--no-dtls");
        // Always a pin by now (CertChecked), so openconnect refuses any certificate but the one checked.
        if (c.TrustedCertPin.Length > 0) args.Add("--servercert=" + c.TrustedCertPin);
        var store = ConnectionStore.Shared;
        var verbose = store.VerboseLogging;
        if (verbose) args.Add(store.VerbosePackets ? "-vv" : "-v");
        // What the log shows: FiveT's own arguments (the pin masked) and the extra options by name only.
        var shown = string.Join(" ", args.Select(a => a.StartsWith("--servercert=") ? "--servercert=…" : a))
                    + $" [extra options: {ExtraOptions.Describe(c.ExtraConfig)}] " + UrlOf(c);
        args.AddRange(extra.Args);
        args.Add(UrlOf(c));

        var psi = new ProcessStartInfo(ofv)
        {
            UseShellExecute = false,
            CreateNoWindow = true,             // gives openconnect its own hidden console, so Ctrl+C can reach it
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(ofv) ?? Paths.ExeDir,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Ui.Post(() => Handle(e.Data, s)); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) Ui.Post(() => Handle(e.Data, s)); };
        p.Exited += (_, _) => Ui.Post(() => Ui.After(0.3, () => ProcessEnded(p, s)));   // let queued lines land first
        try
        {
            Native.AllowCtrlC();   // the child must not inherit the "ignore Ctrl+C" flag from a recent disconnect
            p.Start();
        }
        catch (Exception e)
        {
            p.Dispose();
            Fail(s, $"Could not start openconnect: {e.Message}");
            return;
        }
        // Tracked from here on, before anything is written to it: if it dies at once (a bad option, a
        // missing DLL) ProcessEnded explains it from openconnect's own output instead of a pipe error.
        s.Process = p;
        try
        {
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            // The password is the first line openconnect reads; a "separate" one-time code answers the
            // second prompt. Closing stdin afterwards makes any unexpected prompt fail fast instead of hanging.
            var stdin = p.StandardInput;
            stdin.NewLine = "\n";
            stdin.WriteLine(password);
            // Some FortiGate setups answer the first login POST with a challenge, and openconnect then
            // prompts a second time for the token code — even in "append to password" mode. Queue the
            // code now: if no second prompt comes, the line is simply never read.
            if (otp != null) stdin.WriteLine(otp);
            else if (c.OtpMode == OtpMode.AppendToPassword && s.CurrentCode is { } queued) stdin.WriteLine(queued);
            stdin.Flush();
            stdin.Close();
        }
        catch (IOException e)
        {
            // The pipe broke because openconnect has already exited; its output says why.
            Log.Shared.Write($"[{c.Name}] openconnect closed its input early ({e.GetType().Name}); waiting for its output", LogLevel.Debug);
            try { p.StandardInput.Close(); } catch { }
        }
        catch (Exception e)
        {
            // Not a dead process but something wrong on FiveT's side of the pipes: do not leave it running.
            s.Process = null;
            try { p.Kill(true); } catch { }
            p.Dispose();
            Fail(s, $"Could not start openconnect: {e.Message}");
            return;
        }
        Log.Shared.Write($"[{c.Name}] launched openconnect {shown} (pid {p.Id}) → {c.GatewayDescription}");
    }

    private static bool IsPacketTrace(string t) =>
        t.Contains("data packet") || t.Contains("DTLS packet") || t.Contains("CSTP packet") || t.Contains("packet of ") || t.Contains("Packet outgoing");

    private static readonly string[] ErrorMarkers =
    {
        "Failed", "failed", "Error", "error", "Unauthorized", "Login failed", "Could not", "Unable", "Cannot", "cannot",
        "Unknown host", "unreachable", "timed out", "Access is denied", "refused", "not found", "Invalid",
    };

    /// <summary>openconnect's words for a gateway it could not reach (case-insensitive).</summary>
    private static readonly string[] UnreachableMarkers =
    {
        "Failed to open HTTPS connection", "Failed to connect", "Unknown host", "Name or service not known",
        "No route to host", "unreachable", "timed out", "Connection refused",
    };

    private static readonly string[] EventMarkers =
    {
        "Connected to", "Connected as", "Configured as", "Established", "Certificate", "servercert", "Got CONNECT",
        "Please enter", "Password", "token", "Token", "Disconnected", "Session", "Reconnect", "Wintun", "TAP", "tun device",
    };

    private void Handle(string raw, VpnSession s)
    {
        var line = raw.Trim();
        if (line.Length == 0) return;
        var c = s.Connection;
        var store = ConnectionStore.Shared;
        if (IsPacketTrace(line) && !store.VerbosePackets) return;

        // GnuTLS prints "Server certificate verify failed: …" on every single connection, including the
        // successful ones where --servercert pins the certificate and openconnect carries on regardless.
        // Counting it as an error made every later failure report itself as a certificate problem.
        var benign = line.StartsWith("Server certificate verify failed", StringComparison.Ordinal);
        var isError = !benign && ErrorMarkers.Any(line.Contains);
        // openconnect says why it could not reach the gateway and then still ends with "Failed to
        // complete authentication"; remember the first so the second is not taken for a bad password.
        // A DTLS line is about the optional second channel, and a tunnel that is up has been reached.
        if (!benign && s.Status.Phase == VpnPhase.Connecting && UnreachableMarkers.Any(m => line.Contains(m, StringComparison.OrdinalIgnoreCase))
            && !line.Contains("DTLS", StringComparison.OrdinalIgnoreCase))
            s.SawUnreachable = true;
        // After a refused certificate the lines describe the certificate, in words its maker chose:
        // they are kept out of the events assistants read, and nothing in them is read as state.
        var afterRefusal = s.SawCertFailure;
        // Only the first pin counts (the review shows it); the lines that follow are never state.
        var firstPin = afterRefusal && s.OpenconnectPin == null && line.Contains("pin-sha256:") && line.Contains("--servercert")
            ? GatewayCert.PinIn(line) : null;
        var level = afterRefusal && firstPin == null ? LogLevel.Debug
            : isError ? LogLevel.Error : (store.VerboseLogging && !EventMarkers.Any(line.Contains)) ? LogLevel.Debug : LogLevel.Info;
        Log.Shared.Write($"[{c.Name}] {line}", level);
        if (afterRefusal)
        {
            if (firstPin != null)
            {
                s.OpenconnectPin = firstPin;
                s.LastErrorLine = line;
            }
            return;
        }

        var detail = s.Status.Detail;
        if (line.StartsWith("Connected to ") && !line.Contains("HTTPS")
            && (detail == null || detail.StartsWith("Starting") || detail.StartsWith("Reconnecting")))
        {
            Update(s, x => x with { Detail = "Connected to gateway, logging in…" });
        }
        if (line.Contains("Connected to HTTPS on"))
        {
            // The credentials are posted right after this; from now on the one-time code counts as used.
            if (s.CurrentCode is { } code) _lastCodeUsed[c.Id] = code;
            // From here a login counts (LoginGuard), until the gateway lets it in.
            if (!s.Authenticated) s.LoginPending = true;
            if (_loginOverrideAt.Remove(c.Id))   // Try Anyway was for this one login
                Log.Shared.Write($"[{c.Name}] logging in although the last logins to {c.LoginGuardKey} failed (Try Anyway)");
            // The gateway answered (an earlier "Failed to connect" was another of its addresses).
            s.SawUnreachable = false;
            if (s.Status.Detail is not "Authenticated, building tunnel…") Update(s, x => x with { Detail = "Logging in…" });
        }
        else if (line.Contains("Got CONNECT response") || line.Contains("Session authentication"))
        {
            // "Session authentication will expire at …" also arrives just after the tunnel is up; without
            // this guard it puts the progress text back on a connection that has already finished.
            LoginSucceeded(s);
            if (s.Status.Phase != VpnPhase.Connected) Update(s, x => x with { Detail = "Authenticated, building tunnel…" });
        }
        else if (TunnelIp(line) is { } ip)
        {
            s.PendingTunnelIp = ip;
            if (s.ReconnectAttempt > 0) Log.Shared.Write($"[{c.Name}] reconnected after {s.ReconnectAttempt} attempt(s)");
            s.ReconnectAttempt = 0;
            s.Reconnecting = false;
            s.ReconnectDue = null;
            s.WaitingForNetwork = false;
            s.ProbeFailures = 0;
            s.WatchdogAnnounced = s.WatchdogSkipLogged = false;
            s.AutoRenewed = false;
            s.SweptGhostAdapters = false;   // a later failure to open the adapter may be swept once again
            s.SawUnreachable = false;
            s.LastErrorLine = null;   // whatever failed on the way here (another address of the gateway) is history
            SetStatus(s, new VpnStatus
            {
                Phase = VpnPhase.Connected, ConnectionId = c.Id, ConnectionName = c.Name, Since = DateTime.Now,
                Network = new NetworkInfo { Interface = s.AdapterName, TunnelIP = ip },
            });
            EnsureWatchdog();
            // The other one-time-code mode got us in: only now is it written to connections.json (the
            // trial ran on a copy), so the next connect starts with it.
            var mode = c.OtpMode;
            var trial = s.OtpTrialOf != null;
            if (trial)
            {
                Log.Shared.Write($"[{c.Name}] \"{mode.Label()}\" worked; keeping it for this connection");
                EndOtpTrial(s);
            }
            LoginSucceeded(s);
            store.Mutate(c.Id, x =>
            {
                x.LastConnectedAt = DateTime.Now; x.LastError = null;
                if (trial) x.OtpMode = mode;
            });
            if (store.NotifyOnChange) Notifier?.Invoke("FiveT", $"Connected to {c.Name}", false);
            CaptureNetwork(s);
        }
        else if (line.Contains("pin-sha256:") && line.Contains("--servercert"))
        {
            // openconnect only names a pin when the certificate it got is not the one it was told to
            // accept: the gateway showed it another certificate than FiveT's check saw. Never learn
            // it here, which would trust it without asking: ProcessEnded turns it into a review.
            s.SawCertFailure = true;
            s.OpenconnectPin = GatewayCert.PinIn(line);
            s.LastErrorLine = line;
        }
        else if (line.Contains("Certificate from VPN server") || line.Contains("failed verification")
                 || line.Contains("SSL connection failure: Error in the certificate"))
        {
            // The fatal form only: openconnect aborts here and asks the user to accept the certificate.
            s.SawCertFailure = true;
            s.LastErrorLine = line;
        }
        else if (isError)
        {
            // These two end every failure to connect, whatever the cause. After "could not reach the
            // gateway" they would replace the line that says so and make it read as a login failure.
            var trailer = s.SawUnreachable
                && (line.Contains("Failed to complete authentication", StringComparison.OrdinalIgnoreCase)
                    || line.Contains("Failed to obtain WebVPN cookie", StringComparison.OrdinalIgnoreCase));
            if (!trailer) s.LastErrorLine = line;
            if (line.Contains("Wintun adapter", StringComparison.OrdinalIgnoreCase)
                || line.Contains("Failed to find matching adapter name", StringComparison.Ordinal))
                s.SawAdapterFailure = true;
            if (line.Contains("Access is denied") || line.Contains("not permitted") || line.Contains("Administrator"))
                Update(s, x => x with { NeedsSetup = true });
        }
    }

    /// <summary>"Connected as 192.0.2.1, using SSL…" / "Configured as 192.0.2.1, with SSL connected…" → the address.</summary>
    private static string? TunnelIp(string line)
    {
        foreach (var prefix in new[] { "Configured as ", "Connected as " })
        {
            // Anchored: the same words inside some other line (a certificate name, a server message)
            // must not be taken for the tunnel coming up.
            if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var rest = line[prefix.Length..];
            var ip = new string(rest.TakeWhile(ch => char.IsDigit(ch) || ch == '.').ToArray());
            if (NetTools.IsIPv4(ip)) return ip;
            // IPv6-only or "Connected as 10.0.0.1 + fd00::1" forms: keep whatever precedes the comma.
            var token = rest.Split(',')[0].Trim();
            if (token.Length > 0) return token.Split(' ')[0];
        }
        return null;
    }

    private void ProcessEnded(Process proc, VpnSession s)
    {
        if (!ReferenceEquals(proc, s.Process)) { proc.Dispose(); return; }
        var c = s.Connection;
        RemoveSplitDns(s);
        Ui.Cancel(ref s.StopTimer);
        s.Process = null;
        int code;
        try { code = proc.ExitCode; } catch { code = -1; }
        proc.Dispose();
        Log.Shared.Write($"[{c.Name}] openconnect exited (status {code})");
        // It ended between sending the password and getting in: a failed login, also when it was stopped
        // meanwhile (the gateway has the password by then and judges it anyway).
        if (s.LoginPending) LoginFailed(s);

        var previous = s.Status;
        var restart = s.RestartRequested;   // the watchdog tore the tunnel down on purpose
        s.RestartRequested = false;
        // Wintun regularly fails to remove its adapter at exit, and the dead device then stops the next
        // run from opening one of the same name. Sweeping at launch is too slow to help a connect that
        // starts moments later, so clear the wreckage the moment it actually bites, and try once more.
        if (s.SawAdapterFailure && !s.SweptGhostAdapters && !s.RelaunchWhenStopped && previous.Phase != VpnPhase.Disconnecting)
        {
            s.SweptGhostAdapters = true;
            s.SawAdapterFailure = false;
            Log.Shared.Write($"[{c.Name}] the tunnel adapter could not be opened; clearing dead ones and retrying");
            Update(s, x => x with { Phase = VpnPhase.Connecting, Detail = "Clearing a stale tunnel adapter…" });
            SweepThenRelaunch(s, c, s.CheckGeneration, 0);
            return;
        }
        RemoveGhostTunnelAdapters(s);   // otherwise tidy up in the background, ready for the next connect
        if (s.RelaunchWhenStopped)
        {
            s.RelaunchWhenStopped = false;
            CancelReconnect(s);   // a click starts afresh, as on the Mac
            SetStatus(s, new VpnStatus { ConnectionId = s.Id });
            Start(s.Connection, s.RelaunchOrigin);
            return;
        }
        switch (previous.Phase)
        {
            case VpnPhase.Disconnecting:
            case VpnPhase.Idle:
                SetStatus(s, new VpnStatus { ConnectionId = s.Id });
                if (previous.Phase == VpnPhase.Disconnecting && ConnectionStore.Shared.NotifyOnChange)
                    Notifier?.Invoke("FiveT", $"Disconnected from {c.Name}", false);
                break;
            case VpnPhase.Connected:
            {
                // Dropped while in use (not a manual disconnect).
                var why = Friendly(s, s.LastErrorLine) is { } w ? " " + w : "";
                // A restart the watchdog asked for reconnects even with Auto-reconnect off: it is not a
                // drop the user chose to live with (the Mac does the same).
                if (restart || ConnectionStore.Shared.AutoReconnect)
                {
                    Log.Shared.Write($"[{c.Name}] connection dropped.{why}", LogLevel.Error);
                    ScheduleReconnect(s, 1);
                }
                else
                {
                    Fail(s, $"{c.Name} disconnected unexpectedly.{why}");
                }
                break;
            }
            case VpnPhase.Connecting when s.SawCertFailure && s.OpenconnectPin is { } seen:
            {
                // openconnect was shown another certificate than FiveT's own check (a gateway behind a
                // load balancer can do that; so can someone in the middle choosing whom to fool).
                var latest = ConnectionStore.Shared.Get(c.Id) ?? c;
                Unverified(s, latest, !latest.KnowsGateway, seen, seen, null,
                    "the gateway showed openconnect a different certificate than the one FiveT checked");
                break;
            }
            case VpnPhase.Connecting:
            {
                // Exit status 2 is openconnect's "login rejected", but an unreachable gateway ends the
                // same way ("Failed to complete authentication"): then it is no login failure at all.
                var rejected = LoginRejected(s, code);
                var msg = Friendly(s, s.LastErrorLine) ?? (rejected
                    ? "Login failed. Check the password / TOTP code and that the PC's clock is correct."
                    : $"{c.Name}: connection failed (exit {code}). See the log.");
                if (!previous.NeedsSetup && LoginGuard.Shared.IsLimited(c.LoginGuardKey))
                {
                    // Any retry from here (the other one-time-code mode, a reconnect) would be a login that can
                    // get this network's address banned: only the user goes on, after a check. A run that
                    // never sent its password says what really went wrong first.
                    EndOtpTrial(s);
                    var limit = LoginLimitMessage(ConnectionStore.Shared.Get(c.Id) ?? c);
                    Fail(s, s.LoginFailedThisRun ? limit : msg + " No password was sent this time. " + limit);
                    break;
                }
                if (rejected) msg += LastConnectedNote(c);
                // A one-time code rejected in one mode is usually right in the other: a gateway that
                // wants the code appended to the password answers a separate code with the same
                // "login failed" as a wrong password, so the two are indistinguishable by eye.
                // Try the other way once and keep whichever gets in (the Mac app does this since 1.4.3).
                if (TryOtherOtpMode(s, code)) break;
                if (s.OtpTrialOf != null)
                {
                    // That was the trial. Only a rejection counts against the other mode: a trial that
                    // failed for another reason (no network, a certificate) says nothing about it.
                    EndOtpTrial(s);
                    if (rejected)
                    {
                        Log.Shared.Write($"[{c.Name}] the other one-time-code mode was rejected as well; the saved mode stays");
                        msg += " The one-time code was tried both appended to the password and as a second step.";
                    }
                }
                var retryable = s.ReconnectAttempt > 0 && !previous.NeedsSetup && !rejected;
                if (retryable)
                {
                    Log.Shared.Write($"[{c.Name}] reconnect attempt {s.ReconnectAttempt} failed: {msg}", LogLevel.Error);
                    ScheduleReconnect(s, s.ReconnectAttempt + 1);
                }
                else
                {
                    var prefix = s.ReconnectAttempt > 0 ? $"Could not reconnect {c.Name}: " : "";
                    Fail(s, prefix + msg, previous.NeedsSetup);   // Fail also ends any reconnect loop
                }
                break;
            }
        }
    }

    /// <summary>
    /// Clears the dead Wintun adapters, then launches again. Not while another tunnel is being built
    /// (Connect All): an adapter that is halfway created reads as dead too and would be swept from under
    /// it, so this waits a little (20 s at most) for that tunnel before sweeping.
    /// </summary>
    private void SweepThenRelaunch(VpnSession s, Connection c, int gen, int waited)
    {
        // Disconnected or connected again by hand meanwhile: that attempt is the one that counts now.
        bool Current() => s.CheckGeneration == gen && s.Status.Phase == VpnPhase.Connecting && !s.IsRunning;
        if (!Current()) return;
        if (!CanSweep(s) && waited < 10)
        {
            Ui.Cancel(ref s.WaitTimer);
            s.WaitTimer = Ui.After(2, () => { s.WaitTimer = null; SweepThenRelaunch(s, c, gen, waited + 1); });
            return;
        }
        var sweep = CanSweep(s);
        Task.Run(() =>
        {
            var removed = sweep ? SweepGhostTunnelAdapters() : 0;
            Ui.Post(() =>
            {
                if (removed > 0) Log.Shared.Write($"removed {removed} dead tunnel adapter(s) Wintun left behind");
                if (Current()) Launch(c);
            });
        });
    }

    /// <summary>
    /// A login the gateway answered and refused (not one that never reached it): openconnect's exit
    /// status 2 or its own words about authentication.
    /// </summary>
    private static bool LoginRejected(VpnSession s, int exitCode) =>
        !s.SawUnreachable && (exitCode == 2 || IsAuthFailure(s));

    /// <summary>
    /// After a login was rejected for a connection that uses a one-time code, retries once with the
    /// other code mode ("append to password" / "second step"). Returns true when a retry was started.
    ///
    /// The trial runs on a copy of the connection: nothing saved is changed unless the tunnel comes up
    /// (Handle writes the mode then), so a trial that is cancelled, fails or is overtaken leaves the
    /// user's own setting alone. A reconnect in the background never does this, and it happens at most
    /// once per attempt so the two modes can never ping-pong.
    /// </summary>
    private bool TryOtherOtpMode(VpnSession s, int exitCode)
    {
        var c = s.Connection;
        if (s.OtpTrialOf != null) return false;   // this was the trial itself
        if (!c.UsesTotp || s.ReconnectAttempt > 0) return false;
        if (!LoginRejected(s, exitCode)) return false;
        // Not for a way the gateway has taken before: that one is not the cause, and the try would use up
        // the second of the two logins FiveT allows before it stops (Mac 1.13.1).
        if (c.OtpModeAccepted) return false;

        var original = c.OtpMode;
        var other = original == OtpMode.AppendToPassword ? OtpMode.Separate : OtpMode.AppendToPassword;
        var trial = c.Clone();
        trial.OtpMode = other;
        s.OtpTrialOf = c;
        s.Connection = trial;
        Log.Shared.Write($"[{c.Name}] login rejected with \"{original.Label()}\"; retrying once with \"{other.Label()}\"");
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = "Trying the other one-time-code mode…",
        });
        // Launch() waits for the next 30 s window by itself if the code just used is still current.
        Ui.Cancel(ref s.WaitTimer);
        s.WaitTimer = Ui.After(1, () => { s.WaitTimer = null; Relaunch(s, trial); });
        return true;
    }

    /// <summary>Leaves the one-time-code trial (if one is running): the session goes back to the saved connection.</summary>
    private void EndOtpTrial(VpnSession s)
    {
        if (s.OtpTrialOf is not { } original) return;
        s.OtpTrialOf = null;
        s.Connection = ConnectionStore.Shared.Get(original.Id) ?? original;
    }

    // MARK: Auto-reconnect

    // The Mac app's numbers (VPNManager.swift, 1.8).
    /// <summary>A one-time code this close to the end of its 30 s window is not sent; the next one is used.</summary>
    private const int TotpBoundarySeconds = 4;
    /// <summary>While there is no network, a reconnect is still tried this often, in case Windows' report is wrong.</summary>
    private const double OfflineRetrySeconds = 120;
    /// <summary>After the network comes back or changes, this long for DHCP and DNS before reconnecting.</summary>
    private const double NetworkSettleSeconds = 2;
    /// <summary>A network change starts a session's reconnect at most this often (a flapping Wi-Fi would bypass the back-off).</summary>
    private const double NetworkLaunchSpacingSeconds = 10;

    /// <summary>
    /// Retries in the background after an unexpected drop: 2 s, then 10, 20, … up to 60 s apart,
    /// indefinitely, until it succeeds or the user disconnects. Login failures stop the loop so a
    /// wrong password can never lock the account through repeated attempts. Each tunnel reconnects
    /// on its own schedule and never disturbs the others. Without a network it waits for one (and
    /// still tries every two minutes); the network coming back starts it at once (NetworkSettled).
    /// </summary>
    private void ScheduleReconnect(VpnSession s, int attempt, string why = "Connection lost")
    {
        Ui.Cancel(ref s.ReconnectTimer);
        s.ReconnectAttempt = attempt;
        s.Reconnecting = true;
        if (!NetTools.HasUnderlyingNetwork()) { WaitForNetwork(s, why); return; }
        if (attempt > FailoverAfter && FailOver(s)) return;
        var c = s.Connection;
        s.WaitingForNetwork = false;
        var delay = ReconnectDelay(attempt);
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = $"{why}, retrying in {(int)delay}s (try {attempt})…",
        });
        Log.Shared.Write($"[{c.Name}] reconnect attempt {attempt} scheduled in {(int)delay}s");
        ArmReconnect(s, delay);
    }

    /// <summary>
    /// A reconnect that is due while the PC has no network: an attempt now would only fail and climb
    /// the back-off, so it waits for the network (NetworkSettled starts it the moment it is back). The
    /// slow timer still tries now and then, in case Windows' report of "no network" is wrong. The
    /// attempt number is kept. The status says so (<see cref="VpnStatus.WaitingForNetwork"/>).
    /// </summary>
    private void WaitForNetwork(VpnSession s, string why = "Connection lost")
    {
        var c = s.Connection;
        if (!s.WaitingForNetwork)
            Log.Shared.Write($"[{c.Name}] reconnect attempt {s.ReconnectAttempt} waits for the network (or {(int)OfflineRetrySeconds}s)");
        s.Reconnecting = true;
        s.WaitingForNetwork = true;
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = $"{why}; waiting for the network…", WaitingForNetwork = true,
        });
        ArmReconnect(s, OfflineRetrySeconds);
    }

    private void ArmReconnect(VpnSession s, double delay)
    {
        Ui.Cancel(ref s.ReconnectTimer);
        var c = s.Connection;
        s.ReconnectDue = DateTime.Now.AddSeconds(delay);
        s.ReconnectTimer = Ui.After(delay, () =>
        {
            s.ReconnectTimer = null;   // fired: nothing is pending any more (NetworkSettled and Connect look at this)
            s.ReconnectDue = null;
            var fallback = s.WaitingForNetwork;   // the slow timer of a network wait: try anyway
            s.WaitingForNetwork = false;
            if (!s.Reconnecting || s.IsRunning) return;
            // The network went away while this timer ran: do not spend an attempt on it.
            if (!fallback && !NetTools.HasUnderlyingNetwork()) { WaitForNetwork(s); return; }
            var latest = ConnectionStore.Shared.Get(c.Id) ?? c;   // pick up edited settings
            Start(latest, ConnectOrigin.Background);
        });
    }

    // MARK: Network changes, sleep and wake

    private string? _networkSignature;
    private bool _networkUp = true;
    private UiTimer? _networkTimer, _wakeTimer;
    private DateTime? _lastPathProbe;

    /// <summary>
    /// Windows reports an address or availability change (TrayApp forwards NetworkChange events). Only
    /// a change to the real networks counts — a tunnel adapter of FiveT's own coming and going does not.
    /// </summary>
    public void NetworkChanged()
    {
        Task.Run(() =>
        {
            var (up, signature) = NetTools.UnderlyingNetworkSignature();
            Ui.Post(() =>
            {
                if (signature == _networkSignature && up == _networkUp) return;
                var wasUp = _networkUp;
                var first = _networkSignature == null;
                _networkSignature = signature;
                _networkUp = up;
                if (first) return;   // the first report only sets the baseline
                Ui.Cancel(ref _networkTimer);
                if (!up)
                {
                    Log.Shared.Write("the network is gone");
                    // Reconnects waiting on a back-off timer would only fail: wait for the network
                    // instead (a check or a login already under way is left to finish or fail).
                    foreach (var s in _sessions.Values.ToList())
                        if (s.Reconnecting && !s.IsRunning && s.ReconnectTimer != null && !s.WaitingForNetwork
                            && s.Status.Phase == VpnPhase.Connecting)
                            WaitForNetwork(s);
                    return;
                }
                Log.Shared.Write(wasUp ? $"network changed ({signature})" : $"network is back ({signature})");
                _networkTimer = Ui.After(NetworkSettleSeconds, NetworkSettled);
            });
        });
    }

    /// <summary>
    /// The network is back or different: reconnect what was waiting for a retry or for the network now
    /// instead of on its timer (never one waiting for a fresh one-time code or a certificate check, and
    /// each at most once per 10 s), and probe the tunnels that are up, since they rode on the old
    /// network: a probe into a dead tunnel lets openconnect notice at once.
    /// </summary>
    private void NetworkSettled()
    {
        _networkTimer = null;
        if (!_networkUp) return;
        var now = DateTime.Now;
        foreach (var s in _sessions.Values.ToList())
        {
            if (s.IsRunning || !s.Reconnecting || s.ReconnectDue == null || s.WaitTimer != null || s.Status.Phase != VpnPhase.Connecting) continue;
            if (s.LastNetworkLaunch is { } last && (now - last).TotalSeconds < NetworkLaunchSpacingSeconds)
            {
                // Started by a network change a moment ago: the usual back-off, not the offline wait.
                if (s.WaitingForNetwork) ScheduleReconnect(s, Math.Max(s.ReconnectAttempt, 1));
                continue;
            }
            s.LastNetworkLaunch = now;
            Log.Shared.Write($"[{s.Name}] network is up; reconnecting now");
            ArmReconnect(s, 0.01);
        }
        if (ConnectionStore.Shared.Watchdog && _sessions.Values.Any(x => x.Status.Phase == VpnPhase.Connected))
        {
            if (_lastPathProbe is { } lp && (now - lp).TotalSeconds < WatchdogSeconds) return;
            _lastPathProbe = now;
            ProbeTunnels();
        }
    }

    /// <summary>
    /// The PC is going to sleep (TrayIcon hears PBT_APMSUSPEND). The watchdog pauses: left running,
    /// its overdue round would fire the instant the PC wakes, before Wi-Fi is back, and count a miss
    /// that says nothing about the tunnel.
    /// </summary>
    public void SystemSuspending()
    {
        _watchdog?.Stop();
        Ui.Cancel(ref _wakeTimer);
    }

    /// <summary>
    /// The PC woke up. The gateway has often dropped the session while the tunnel still looks up, so
    /// once Wi-Fi had 8 s to come back the tunnels are probed: a packet into a dead tunnel makes
    /// openconnect meet the dead connection, and auto-reconnect takes over within seconds.
    /// </summary>
    public void SystemResumed()
    {
        foreach (var s in _sessions.Values) s.ProbeFailures = 0;
        _watchdog?.Start();
        if (!ConnectionStore.Shared.Watchdog || !_sessions.Values.Any(x => x.Status.Phase == VpnPhase.Connected))
        {
            Log.Shared.Write("woke from sleep");
            return;
        }
        Log.Shared.Write($"woke from sleep; checking the tunnels in {WakeProbeSeconds}s");
        Ui.Cancel(ref _wakeTimer);
        _wakeTimer = Ui.After(WakeProbeSeconds, () => { _wakeTimer = null; ProbeTunnels(); });
    }

    // MARK: Watchdog

    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _watchdog;
    private const int WatchdogSeconds = 20, WatchdogStrikes = 3, WakeProbeSeconds = 8;

    private void EnsureWatchdog()
    {
        if (_watchdog != null) return;
        _watchdog = Ui.Queue.CreateTimer();
        _watchdog.Interval = TimeSpan.FromSeconds(WatchdogSeconds);
        _watchdog.IsRepeating = true;
        _watchdog.Tick += (_, _) => ProbeTunnels();
        _watchdog.Start();
    }

    /// <summary>
    /// The watchdog, as on the Mac: a tunnel can stay "connected" long after it stopped carrying
    /// anything (the gateway forgot the session, a NAT timed out, the PC slept), and openconnect
    /// notices late or never. Every 20 s each tunnel's DNS server — the first one inside the tunnel's
    /// routes — gets one question (2 s, one try). Any answer, NXDOMAIN and REFUSED included, proves
    /// the path works. Three misses in a row and the tunnel is restarted like a drop, so auto-reconnect
    /// brings it back. Not while the PC has no network (the first probe after it is back decides), and
    /// not for a tunnel with no DNS server inside it. Off in Settings → General.
    /// </summary>
    private void ProbeTunnels()
    {
        if (!ConnectionStore.Shared.Watchdog) return;
        var connected = _sessions.Values.Where(x => x.Status.Phase == VpnPhase.Connected && !x.ProbeRunning && x.IsRunning).ToList();
        if (connected.Count == 0) return;
        Task.Run(() =>
        {
            if (!NetTools.HasUnderlyingNetwork()) return;
            Ui.Post(() => { foreach (var s in connected) Probe(s); });
        });
    }

    private void Probe(VpnSession s)
    {
        if (s.Connection.IsV2Ray) { ProbeV2Ray(s); return; }
        if (s.ProbeRunning || !s.IsRunning || s.Status.Network is not { } n) return;
        var c = s.Connection;
        var name = Connection.CleanDomains(c.DnsDomains, n.SearchDomains).FirstOrDefault() ?? ".";
        s.ProbeRunning = true;
        var since = s.Status.Since;
        var servers = n.DnsServers.ToList();
        var routes = n.Routes.ToList();
        var ifIndex = n.InterfaceIndex;
        Task.Run(() =>
        {
            // Only a server reached through this tunnel says anything about the tunnel. Windows'
            // route list leaves the default route out, so a full tunnel counts every server as inside.
            var full = ifIndex > 0 && NetTools.HasDefaultRoute(ifIndex);
            var server = servers.FirstOrDefault(d => full || NetTools.Ipv4CoveredBy(d, routes));
            var answered = false;
            if (server != null)
            {
                var (_, error) = NetTools.Query(name, server);
                answered = error is null or "NXDOMAIN" or "no A record" || error.StartsWith("rcode ", StringComparison.Ordinal);
            }
            Ui.Post(() =>
            {
                s.ProbeRunning = false;
                if (s.Status.Phase != VpnPhase.Connected || s.Status.Since != since || !s.IsRunning) return;
                if (server == null)
                {
                    if (!s.WatchdogSkipLogged)
                        Log.Shared.Write($"[{s.Name}] watchdog: no DNS server inside the tunnel to probe; not watching this tunnel", LogLevel.Debug);
                    s.WatchdogSkipLogged = true;
                    return;
                }
                if (answered)
                {
                    if (s.ProbeFailures > 0) Log.Shared.Write($"[{s.Name}] watchdog: {server} answers again");
                    else if (!s.WatchdogAnnounced) Log.Shared.Write($"[{s.Name}] watchdog: watching the tunnel via {server} ({name})");
                    s.WatchdogAnnounced = true;
                    s.ProbeFailures = 0;
                    if (s.Status.Health != null) Update(s, x => x with { Health = null });
                    return;
                }
                s.ProbeFailures++;
                var silent = s.ProbeFailures * WatchdogSeconds;
                // Shown with the tunnel (menu, status, diagnostics) from the first miss on, as on the Mac.
                Update(s, x => x with { Health = $"not answering for {silent}s" });
                Log.Shared.Write($"[{s.Name}] watchdog: {server} did not answer ({s.ProbeFailures}/{WatchdogStrikes})", LogLevel.Error);
                if (s.ProbeFailures >= WatchdogStrikes) RestartDeadTunnel(s, $"tunnel stopped answering ({server} silent for {silent}s)");
            });
        });
    }

    /// <summary>Stops openconnect while the session still counts as connected, so ProcessEnded treats it as a drop.</summary>
    private void RestartDeadTunnel(VpnSession s, string reason, string? lastError = "The tunnel stopped answering.", LogLevel level = LogLevel.Error,
        string detail = "Not answering, reconnecting…")
    {
        if (s.Process is not { HasExited: false } p) return;
        Log.Shared.Write($"[{s.Name}] {reason}; reconnecting", level);
        s.LastErrorLine = lastError;
        s.ProbeFailures = 0;
        // ProcessEnded reconnects even when Auto-reconnect is off: the user did not choose this drop.
        s.RestartRequested = true;
        if (s.BlockOnExit != null) BlockInternet(s);   // before its routes go, so nothing slips out
        ClearTunnelDns(s);
        Update(s, x => x with { Detail = detail });
        var ok = false;
        try { ok = Native.SendCtrlC(p.Id); } catch { }
        if (!ok) { try { p.Kill(true); } catch { } }
        Ui.Cancel(ref s.StopTimer);
        s.StopTimer = Ui.After(8, () => { s.StopTimer = null; ForceStop(s); });
    }

    /// <summary>
    /// Backoff schedule (seconds) for reconnect attempt N. The macOS app's schedule is kept here:
    /// a quick first retry for the "Wi-Fi blipped" case, then a gentle ramp so a gateway that is
    /// down for an hour sees one attempt a minute. Tune this if your gateway rate-limits logins.
    /// </summary>
    private static double ReconnectDelay(int attempt) => attempt == 1 ? 2 : Math.Min((attempt - 1) * 10.0, 60);

    private static void CancelReconnect(VpnSession s)
    {
        Ui.Cancel(ref s.ReconnectTimer);
        s.ReconnectAttempt = 0;
        s.Reconnecting = false;
        s.ReconnectDue = null;
        s.WaitingForNetwork = false;
    }

    /// <summary>
    /// The gateway answered and refused the login. Never when openconnect could not reach it: the same
    /// words ("Failed to complete authentication") end that failure too, and reading them as a wrong
    /// password stops the reconnect loop, tells the user to check the password, and flips the one-time-code mode for nothing.
    /// </summary>
    private static bool IsAuthFailure(VpnSession s) =>
        !s.SawUnreachable && s.LastErrorLine is { } line
        && (line.Contains("authenticat", StringComparison.OrdinalIgnoreCase)
            || line.Contains("Login failed", StringComparison.OrdinalIgnoreCase)
            || line.Contains("Unauthorized", StringComparison.OrdinalIgnoreCase)
            || line.Contains("WebVPN cookie", StringComparison.OrdinalIgnoreCase)
            || line.Contains("AUTH_FAILED", StringComparison.Ordinal));

    // MARK: Network facts

    /// <summary>
    /// A moment after the tunnel is up, read what vpnc-script configured for <b>this</b> adapter: its
    /// address, DNS servers and suffix, and the routes over it. Fills the session's Network, logs one
    /// compact summary, then applies split DNS for the connection.
    /// </summary>
    private void CaptureNetwork(VpnSession s)
    {
        var adapter = s.AdapterName;
        var seedIp = s.PendingTunnelIp;
        // Since identifies this particular tunnel: a reconnect replaces it, so a late poll from the
        // previous one recognises that it is stale and stops.
        var startedAt = s.Status.Since;
        Task.Run(async () =>
        {
            // openconnect reports "Configured as <ip>" before Wintun has created the adapter, and the
            // pushed DNS servers and routes appear a moment after that. Reading once, too early, used to
            // yield no DNS and no routes, which silently skipped the split-DNS rules. Poll until the
            // adapter is really there (up to ~20 s), and settle for whatever exists when time runs out.
            NetworkInfo n = new() { TunnelIP = seedIp };
            var deadline = DateTime.UtcNow.AddSeconds(20);
            var previousRoutes = -1;
            while (true)
            {
                await Task.Delay(500);
                if (Ui.Invoke(() => s.Status.Phase != VpnPhase.Connected || s.Status.Since != startedAt)) return;
                var a = NetTools.FindTunnelAdapter(adapter);
                if (a != null)
                {
                    var (routes, peer) = NetTools.Routes(a.Index);
                    n = new NetworkInfo
                    {
                        Interface = a.Name, InterfaceIndex = a.Index,
                        TunnelIP = a.Ip.Length > 0 ? a.Ip : seedIp, PeerIP = peer,
                        DnsServers = a.Dns, SearchDomains = a.Search, Routes = routes,
                    };
                    // vpnc-script adds the pushed routes one at a time, so the first sample with any
                    // route at all catches a half-built table (1 of 58). Wait for the count to settle.
                    if ((n.DnsServers.Count > 0 || s.Connection.IsOpenVpn) && n.Routes.Count > 0 && n.Routes.Count == previousRoutes) break;
                    previousRoutes = n.Routes.Count;
                }
                if (DateTime.UtcNow >= deadline)
                {
                    if (a == null) Log.Shared.Write($"[{s.Name}] no tunnel adapter appeared within 20s", LogLevel.Error);
                    break;
                }
            }
            Ui.Post(() =>
            {
                if (s.Status.Phase != VpnPhase.Connected || s.Status.Since != startedAt) return;
                n = n with { FullTunnel = s.PendingNetwork.FullTunnel };
                if (n.DnsServers.Count == 0) n = n with { DnsServers = s.PendingNetwork.DnsServers };
                Update(s, x => x with { Network = n });
                if (s.Connection.IsOtherVpn) Arm(s);
                if (s.Connection.IsOpenVpn && n.FullTunnel) ApplyTunnelDns(s, n.Interface, n.DnsServers, setAdapter: false);
                Log.Shared.Write($"[{s.Name}] tunnel {n.Interface} {n.TunnelIP} → {n.PeerIP}, dns [{string.Join(", ", n.DnsServers)}]"
                                 + (n.SearchDomains.Count == 0 ? "" : $", search [{string.Join(", ", n.SearchDomains)}]")
                                 + $", {n.Routes.Count} routes via tunnel");
                Log.Shared.Write($"[{s.Name}] routes: {string.Join(" ", n.Routes)}", LogLevel.Debug);
                ApplySplitDns(s, n.DnsServers);
            });
        });
    }

    /// <summary>The same facts for an adopted openconnect: it owns whatever adapter it made.</summary>
    private void CaptureExternalNetwork()
    {
        Task.Run(async () =>
        {
            await Task.Delay(500);
            var a = NetTools.FindTunnelAdapter(Setup.AdapterName);
            if (a == null) return;
            var (routes, peer) = NetTools.Routes(a.Index);
            var n = new NetworkInfo
            {
                Interface = a.Name, InterfaceIndex = a.Index, TunnelIP = a.Ip, PeerIP = peer,
                DnsServers = a.Dns, SearchDomains = a.Search, Routes = routes,
            };
            Ui.Post(() =>
            {
                if (!_externalSession) return;
                _externalStatus = _externalStatus with { Network = n };
                Recompute();
                Log.Shared.Write($"[external] tunnel {n.Interface} {n.TunnelIP} → {n.PeerIP}, {n.Routes.Count} routes via tunnel");
            });
        });
    }

    // MARK: Split DNS

    /// <summary>
    /// Creates NRPT rules for the connection's "DNS domains" plus the DNS suffixes the gateway pushed
    /// (as the Mac does), pointing at the DNS servers the gateway pushed. Windows then sends look-ups
    /// for those domains to the tunnel's DNS even when another VPN owns the default route. Rules are
    /// per-domain, so two tunnels with different domain lists coexist happily; if both claim the same
    /// domain, the one that connected last wins. What is installed is kept in InstalledDomains, and
    /// that same list is what gets removed.
    /// </summary>
    private void ApplySplitDns(VpnSession s, List<string> servers)
    {
        var c = s.Connection;
        var domains = Connection.CleanDomains(c.DnsDomains, s.Status.Network?.SearchDomains ?? new List<string>());
        if (domains.Count == 0) { Update(s, x => x with { SplitDns = null }); return; }
        if (servers.Count == 0)
        {
            Update(s, x => x with { SplitDns = new SplitDnsInfo(domains, "failed", "the gateway pushed no DNS servers") });
            return;
        }
        Update(s, x => x with { SplitDns = new SplitDnsInfo(domains, "pending") });
        var startedAt = s.Status.Since;
        Task.Run(() =>
        {
            var ok = new List<string>();
            var failed = new List<string>();
            var helperNeeded = false;
            foreach (var d in domains)
            {
                var err = SplitDns.Add(d, servers);
                if (err == null) { ok.Add(d); continue; }
                failed.Add(d);
                if (err == "helper_needed") { helperNeeded = true; break; }
                Log.Shared.Write($"[{c.Name}] split dns: could not add {d}: {err}", LogLevel.Error);
            }
            Ui.Post(() =>
            {
                foreach (var d in ok) if (!s.InstalledDomains.Contains(d)) s.InstalledDomains.Add(d);
                if (s.Status.Phase != VpnPhase.Connected || s.Status.Since != startedAt) { RemoveSplitDns(s); return; }
                SplitDnsInfo info;
                if (helperNeeded)
                    info = new SplitDnsInfo(domains, "helper_needed", "FiveT is not running as administrator. Open Settings → General.");
                else if (failed.Count == 0)
                    info = new SplitDnsInfo(domains, "active", $"NRPT rules → {string.Join(", ", servers)}");
                else if (ok.Count == 0)
                    info = new SplitDnsInfo(domains, "failed", "could not create the NRPT rules; see the log");
                else
                    info = new SplitDnsInfo(domains, "partial", $"failed: {string.Join(", ", failed)}");
                Update(s, x => x with { SplitDns = info });
                Log.Shared.Write($"[{c.Name}] split dns {info.State} for [{string.Join(", ", domains)}]{(info.Detail.Length == 0 ? "" : " — " + info.Detail)}",
                    info.State == "active" ? LogLevel.Info : LogLevel.Error);
            });
        });
    }

    /// <summary>Removes only the rules this session installed; another tunnel's stay in place.</summary>
    private void RemoveSplitDns(VpnSession s)
    {
        var ds = new List<string>(s.InstalledDomains);
        s.InstalledDomains.Clear();
        if (s.Status.SplitDns != null) Update(s, x => x with { SplitDns = null });
        if (ds.Count == 0) return;
        // Tracked while the removal runs in the background: Quit may come before it is done, and
        // ShutdownCleanup then finishes it synchronously.
        _pendingRemovals.UnionWith(ds);
        Task.Run(() =>
        {
            foreach (var d in ds)
                if (SplitDns.Remove(d) is { } err) Log.Shared.Write($"split dns: could not remove {d}: {err}", LogLevel.Error);
            Log.Shared.Write($"split dns removed for [{string.Join(", ", ds)}]");
            Ui.Post(() => _pendingRemovals.ExceptWith(ds));
        });
    }

    /// <summary>At launch with no tunnel: remove NRPT rules a crashed earlier run may have left.</summary>
    private static void CleanupStaleResolvers()
    {
        if (!Paths.IsElevated) return;
        Task.Run(() =>
        {
            var removed = SplitDns.RemoveAll();
            if (removed.Count > 0) Log.Shared.Write($"removed stale split-dns rules for [{string.Join(", ", removed)}]");
        });
    }

    /// <summary>
    /// Wintun removes its adapter at exit by spawning rundll32 against a helper it unpacked under
    /// C:\Windows\Temp; when that folder has been cleaned away the removal fails and the device node is
    /// left behind, dead. openconnect then cannot open or recreate an adapter of the same name and the
    /// next connection fails with "Could not open Wintun adapter" — so every second attempt broke.
    /// Sweep the dead ones away. Live adapters report OK and are never touched.
    /// </summary>
    private void RemoveGhostTunnelAdapters(VpnSession? exiting = null)
    {
        if (!CanSweep(exiting)) return;
        Task.Run(() =>
        {
            var removed = SweepGhostTunnelAdapters();
            if (removed > 0) Log.Shared.Write($"removed {removed} dead tunnel adapter(s) Wintun left behind");
        });
    }

    /// <summary>
    /// Sweeping is safe while another tunnel is simply up — only device nodes whose status is not OK
    /// are removed, and a working adapter reports OK — but not while one is still being built, because
    /// an adapter that is halfway created also reads as not-OK and would be swept out from under it.
    /// (Before FiveT could hold two tunnels this was "no openconnect process is running at all".)
    /// <paramref name="self"/> is the session whose own process just ended: it is not building anything.
    /// A tunnel that is only waiting for its next retry (no process, no check, no login) does not hold
    /// the sweep back either, or a reconnect loop would stop the clean-up for as long as it lasts.
    /// </summary>
    private bool CanSweep(VpnSession? self = null) =>
        Paths.IsElevated
        && !_sessions.Values.Any(x => x != self && x.Status.Phase == VpnPhase.Connecting && x.ReconnectTimer == null);

    /// <summary>Removes the dead Wintun device nodes and returns how many went. Blocks; call off the UI thread.</summary>
    private static int SweepGhostTunnelAdapters()
    {
        if (!Paths.IsElevated) return 0;
        var r = Setup.PowerShell(@"
$ErrorActionPreference = 'SilentlyContinue'
foreach ($d in @(Get-PnpDevice -Class Net | Where-Object { $_.InstanceId -like 'SWD\WINTUN\*' -and $_.Status -ne 'OK' })) {
    pnputil /remove-device $d.InstanceId | Out-Null
    if ($LASTEXITCODE -eq 0) { $d.InstanceId }
}
");
        return r.Output.Split('\n').Select(l => l.Trim())
            .Count(l => l.StartsWith("SWD\\WINTUN\\", StringComparison.OrdinalIgnoreCase));
    }

    private static string? Friendly(VpnSession s, string? line)
    {
        // First: openconnect ends a connect failure with "Failed to complete authentication", which is
        // only a login failure when the gateway was reached.
        if (s.SawUnreachable) return "Could not reach the gateway. Is another VPN switched on?";
        if (line == null) return null;
        if (s.SawCertFailure || line.Contains("Certificate", StringComparison.OrdinalIgnoreCase) && line.Contains("verif", StringComparison.OrdinalIgnoreCase))
            return "The gateway's certificate is not the one you trusted, so FiveT did not log in. Click the connection again to review it.";
        if (line.Contains("Access is denied") || line.Contains("not permitted") || line.Contains("Administrator"))
            return "Setup needed: FiveT must run as administrator (Settings → General).";
        if (line.Contains("fgetws (stdin)"))
            return "The gateway asked for another credential and FiveT had nothing left to answer with. "
                   + "If this connection uses a token, try \"Send TOTP code as second step\" in Settings → Connections.";
        // "Failed to find matching adapter name" names no Wintun, so it fell through to the raw line.
        if (s.SawAdapterFailure || line.Contains("Wintun", StringComparison.OrdinalIgnoreCase) || line.Contains("TAP", StringComparison.Ordinal) || line.Contains("tun device"))
            return "Could not set up the virtual network adapter. Check Requirements in Settings → General.";
        if (IsAuthFailure(s))
            return "Login failed. Check the password / TOTP code and that the PC's clock is correct.";
        // The script's own name or openconnect's "Failed to spawn script", not any line that has "script" in it.
        if (line.Contains("vpnc-script", StringComparison.OrdinalIgnoreCase) || line.Contains("spawn script", StringComparison.OrdinalIgnoreCase)
            || line.Contains("script '", StringComparison.OrdinalIgnoreCase))
            return "vpnc-script-win.js failed or is missing. Check Requirements in Settings → General.";
        if (line.Contains("connect", StringComparison.OrdinalIgnoreCase) || line.Contains("resolve") || line.Contains("Unknown host")
            || line.Contains("unreachable") || line.Contains("timed out") || line.Contains("refused"))
            return "Could not reach the gateway. Is another VPN switched on?";
        return line;
    }
}
