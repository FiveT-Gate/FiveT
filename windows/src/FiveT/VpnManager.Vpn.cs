using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using FiveT.Core;

namespace FiveT;

/// <summary>
/// The VPN connections (OpenVPN, V2Ray, Outline), the Mac's rules from VPNManager.swift 1.17.1:
/// any number of Forti connections, plus at most one VPN. Clicking a VPN while another is up or starting
/// stops the other first ("switching from X") and starts the new one once the old routes are gone. Forti
/// connections are left alone by a switch, and a Forti stop never touches the kill switch.
///
/// OpenVPN runs FiveT's own openvpn.exe with the profile on its stdin (the login inline, never on disk);
/// V2Ray and Outline run FiveT's own xray.exe with a config FiveT builds and checks. Both only from the
/// install folder, which ordinary programs cannot change (<see cref="Setup.OpenVpnPath"/>).
/// </summary>
public sealed partial class VpnManager
{
    public const string OpenVpnAdapter = "FiveT OpenVPN", OpenVpnTapAdapter = "FiveT OpenVPN TAP";
    /// <summary>LastErrorLine of a run whose server carried no traffic (see <see cref="FriendlyVpn"/>).</summary>
    private const string V2RayNoTraffic = "V2RAY_NO_TRAFFIC";

    // MARK: Starting, and one VPN at a time

    private void StartVpn(Connection c, ConnectOrigin origin)
    {
        if (!Paths.IsElevated)
        {
            FailBeforeStart(c, "FiveT must run as administrator to create the tunnel. Open Settings → General.", needsSetup: true);
            return;
        }
        var exe = c.IsV2Ray ? Setup.XrayPath : Setup.OpenVpnPath;
        if (exe == null)
        {
            FailBeforeStart(c, $"{(c.IsV2Ray ? "Xray" : "OpenVPN")} is missing from this copy of FiveT, or its folder can be changed by ordinary programs. Install FiveT with its setup file.", needsSetup: true);
            return;
        }
        if (FieldWithLineBreak(c) is { } bad)
        {
            FailBeforeStart(c, $"The {bad} of {c.Name} contains a line break. Retype it in Settings → VPN.");
            return;
        }
        if (!_sessions.TryGetValue(c.Id, out var s))
        {
            s = new VpnSession(c, c.IsV2Ray ? V2RayConfig.TunName : OpenVpnAdapter);
            _sessions[c.Id] = s;
        }
        if (s.IsRunning) return;   // one program per session
        // A trial of the other one-time-code way goes on being tried (the clone is what was passed in).
        if (!(s.OtpTrialOf != null && ReferenceEquals(c, s.Connection))) EndOtpTrial(s);
        s.Connection = c;
        s.Origin = origin;
        Ui.Cancel(ref s.WaitTimer);
        var gen = ++s.CheckGeneration;
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connecting, ConnectionId = c.Id, ConnectionName = c.Name,
            Detail = s.ReconnectAttempt > 0 ? $"Reconnecting (try {s.ReconnectAttempt})…" : "Starting…",
        });

        // One VPN (OpenVPN, V2Ray, Outline) at a time: another one that is up or starting stops first, and
        // this one starts once the other has let go of its routes (they would clash). With the kill switch
        // on, a switch from one VPN to another stays blocked in between.
        var guarded = ConnectionStore.Shared.KillSwitch;
        var others = _sessions.Values.Where(o => o != s && o.Connection.IsOtherVpn && (o.IsRunning || o.Status.Phase != VpnPhase.Idle)).ToList();
        foreach (var o in others.Where(o => o.Status.Phase != VpnPhase.Disconnecting))
        {
            Log.Shared.Write($"[{c.Name}] switching from {o.Name}: one VPN at a time");
            if (guarded && o.BlockOnExit != null)
            {
                Log.Shared.Write($"[{c.Name}] kill switch: blocking this PC's internet before {o.Name} stops, until {c.Name} is up");
                BlockInternet(o);
            }
            Halt(o);
        }
        if (others.Any(o => o.IsRunning || o.Status.Phase == VpnPhase.Disconnecting))
        {
            Update(s, x => x with { Detail = $"Switching from {others[0].Name}…" });
            s.WaitTimer = Ui.After(0.5, () =>
            {
                s.WaitTimer = null;
                if (StillWanted(s, gen)) StartVpn(s.Connection, s.Origin);
            });
            return;
        }
        // This PC's own DNS servers, read while no tunnel of FiveT's answers for them: the kill switch leaves
        // them reachable, so a blocked PC can still look up its VPN server; .ir names are asked of them.
        var dns = SystemDnsServers();
        if (dns.Count > 0) s.LocalDns = dns;
        // Still blocked from the VPN before: this VPN keeps it so, with its own server let through later.
        if (KillSwitch.IsActive && guarded) BlockInternet(s);
        s.LoginPending = s.Authenticated = s.LoginFailedThisRun = false;
        s.LastErrorLine = null;
        s.SawUnreachable = false;
        s.CurrentCode = null;
        if (c.IsV2Ray) LaunchV2Ray(s, c, gen, exe); else LaunchOpenVpn(s, c, gen, exe);
    }

    /// <summary>Launches the session again with <paramref name="c"/>, whatever kind it is (a wait, a retry of the other one-time-code way).</summary>
    private void Relaunch(VpnSession s, Connection c)
    {
        if (c.IsOtherVpn) StartVpn(c, s.Origin); else Launch(c);
    }

    /// <summary>Stops a VPN for good: no relaunch, and no kill switch when its program ends.</summary>
    private void Halt(VpnSession s)
    {
        s.BlockOnExit = null;
        StopSession(s.Id);
    }

    /// <summary>
    /// Looks <paramref name="names"/> up with this PC's own DNS, off the UI thread, then goes on with
    /// <paramref name="then"/> on it (at once when there is none to look up), unless the session was stopped
    /// or started again meanwhile.
    /// </summary>
    private void Resolve(VpnSession s, int gen, List<string> names, Action<Dictionary<string, List<string>>> then)
    {
        if (names.Count == 0) { then(new Dictionary<string, List<string>>()); return; }
        Update(s, x => x with { Detail = "Looking up the server…" });
        Task.Run(() =>
        {
            var found = LookUp(names);
            Ui.Post(() => { if (StillWanted(s, gen)) then(found); });
        });
    }

    /// <summary>
    /// The addresses this PC's own DNS gives each name now, IPv4 first; a name it cannot answer is missing.
    /// A lookup can wait many seconds on a dead network, so every name gets its own task and the wait is capped.
    /// </summary>
    public static Dictionary<string, List<string>> LookUp(IReadOnlyList<string> names)
    {
        var found = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var tasks = names.Select(name => Task.Run(() =>
        {
            try
            {
                var ips = Dns.GetHostAddresses(name).Where(a => !(a.AddressFamily == AddressFamily.InterNetworkV6 && a.IsIPv6LinkLocal))
                    .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).Select(a => a.ToString()).Distinct().ToList();
                lock (found) found[name] = ips;
            }
            catch (Exception) { }
        })).ToArray();
        Task.WaitAll(tasks, TimeSpan.FromSeconds(12));
        lock (found) return new Dictionary<string, List<string>>(found, StringComparer.Ordinal);
    }

    /// <summary>The DNS servers this PC uses now, on its real network adapters (not FiveT's own tunnels).</summary>
    private static List<string> SystemDnsServers()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                            && !n.Name.StartsWith("FiveT", StringComparison.OrdinalIgnoreCase))
                .SelectMany(n => n.GetIPProperties().DnsAddresses)
                // fec0:0:0:ffff::1-3 are Windows' placeholders on an adapter with no IPv6 DNS server.
                .Where(a => !a.IsIPv6SiteLocal && !a.ToString().StartsWith("198.18.", StringComparison.Ordinal))
                .Select(a => a.ToString()).Distinct().ToList();
        }
        catch (Exception) { return new List<string>(); }
    }

    private static bool IsIp(string s) => IPAddress.TryParse(s, out _);

    // MARK: V2Ray and Outline (Xray)

    /// <summary>
    /// A server given by name is looked up now, with the PC's own DNS, before FiveT's tunnel and DNS exist:
    /// once they do, Xray can only ask through the server, and cannot reach the server without the answer
    /// (the Mac's 1.15.1 fix: an Outline key that names its server never connected). There is no login, so
    /// no failed-login count.
    /// </summary>
    private void LaunchV2Ray(VpnSession s, Connection c, int gen, string exe)
    {
        var names = V2RayConfig.ServerNames(c.V2RayOutbound);
        Resolve(s, gen, names, found =>
        {
            var missing = names.FirstOrDefault(n => !found.TryGetValue(n, out var ips) || ips.Count == 0);
            if (missing != null)
            {
                if (s.ReconnectAttempt > 0)
                {
                    // An automatic reconnect (the network changed, the PC woke): the new network's DNS may not
                    // answer yet. Keep trying; giving up here would leave the connection down for good.
                    Log.Shared.Write($"[{c.Name}] reconnect attempt {s.ReconnectAttempt} failed: could not look up {missing}", LogLevel.Error);
                    ScheduleReconnect(s, s.ReconnectAttempt + 1, "Could not look up the server");
                    return;
                }
                FailVpn(s, $"FiveT could not find {missing}, the address of {c.Name}'s server, with this PC's DNS. Check the internet connection (another VPN or a filter can block the lookup), then try again.");
                return;
            }
            foreach (var (name, ips) in found.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                Log.Shared.Write($"[{c.Name}] {name} is {string.Join(", ", ips)} (looked up before the tunnel starts)", LogLevel.Debug);
            s.ServerIps = V2RayConfig.ServerAddresses(c.V2RayOutbound).Where(IsIp).Concat(found.Values.SelectMany(x => x)).Distinct().ToList();

            var store = ConnectionStore.Shared;
            // .ir names are asked of the DNS server the PC uses now, as they would be without the VPN.
            var localDns = s.LocalDns.Where(NetTools.IsIPv4).ToList();
            // Forti gateways given by address stay off the V2Ray server.
            var direct = store.Connections.Where(x => x.Kind == VpnKind.Fortinet).Select(x => x.Host.Trim()).Where(NetTools.IsIPv4)
                .Distinct().OrderBy(x => x, StringComparer.Ordinal).Select(x => x + "/32").ToList();
            string? config;
            List<string> problems;
            // Apps-only: no tunnel at all, just a local proxy the chosen apps are started with.
            int? appPort = store.AppsOnly ? V2RayConfig.AppProxyPort : null;
            try
            {
                (problems, config) = XrayConfigCheck.Check(
                    V2RayConfig.ForLaunch(c, appPort == null ? V2RayConfig.TunName : null, localDns, direct, found, store.VerboseLogging, store.BypassIran, appPort), appPort);
            }
            catch (V2RayException e)
            {
                FailVpn(s, $"{c.Name} cannot be used: {e.Message}. Import it again in Settings → VPN.");
                return;
            }
            if (config == null)
            {
                FailVpn(s, $"FiveT does not allow this in a V2Ray config: {string.Join(", ", problems)}. Import {c.Name} again in Settings → VPN.");
                return;
            }
            s.SentCredentials = false;
            s.AppProxyPort = appPort;
            if (appPort != null)
            {
                // A block the kill switch holds for a full tunnel that dropped stays (StartVpn kept it, with this server let
                // through): only the user (Unblock Internet, Disconnect) lifts it, never a connect.
                s.AdapterName = "app-proxy";
                s.PendingNetwork = new NetworkInfo { Interface = "app-proxy", TunnelIP = "127.0.0.1", FullTunnel = false };
                AppProxyHold.Shared.Release();   // Xray takes the port now
            }
            else
            {
                s.AdapterName = V2RayConfig.TunName;
                s.PendingNetwork = new NetworkInfo
                {
                    Interface = V2RayConfig.TunName, TunnelIP = V2RayConfig.TunAddress, PeerIP = V2RayConfig.TunDns,
                    DnsServers = new List<string> { V2RayConfig.TunDns }, FullTunnel = true,
                };
            }
            // Xray reads the list of Iranian and private addresses from its own folder only.
            RunEngine(s, exe, new[] { "run", "-c", "stdin:" }, config, "xray", new() { ["XRAY_LOCATION_ASSET"] = Path.GetDirectoryName(exe)! });
        });
    }

    private static readonly Regex XrayTimestamp = new(@"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? ", RegexOptions.CultureInvariant);

    /// <summary>
    /// One line of Xray's log. Started is not connected: the PC's DNS goes into the tunnel, then
    /// <see cref="CheckV2Ray"/> makes sure the server really carries traffic.
    /// </summary>
    private void HandleV2Ray(string line, VpnSession s)
    {
        var c = s.Connection;
        var text = XrayTimestamp.Replace(line, "");
        var error = text.StartsWith("[Error]", StringComparison.Ordinal) || text.StartsWith("Failed to start", StringComparison.Ordinal)
                    || text.StartsWith("ERROR:", StringComparison.Ordinal);
        Log.Shared.Write($"[{c.Name}] {text}", error ? LogLevel.Error : text.StartsWith("[Warning]", StringComparison.Ordinal) ? LogLevel.Info : LogLevel.Debug);
        if (text.Contains("core: Xray") && text.Contains(" started"))
        {
            if (s.Status.Phase != VpnPhase.Connecting) return;
            Update(s, x => x with { Detail = "Checking the server…" });
            if (s.AppProxyPort == null)
            {
                // Still blocked by the kill switch: now that the tunnel's adapter exists, it may pass.
                if (KillSwitch.IsActive) BlockInternet(s, InterfaceLuid(V2RayConfig.TunName));
                ApplyTunnelDns(s, V2RayConfig.TunName, new List<string> { V2RayConfig.TunDns }, setAdapter: true);
            }
            CheckV2Ray(s, s.Process, 1);
        }
        else if (error && s.LastErrorLine == null) s.LastErrorLine = text;
    }

    /// <summary>Up once a web request gets through the server (three tries, about 20 s); otherwise the run ends as a failure, which VpnProcessEnded reports (or retries, for a reconnect).</summary>
    private void CheckV2Ray(VpnSession s, Process? run, int attempt)
    {
        var appPort = s.AppProxyPort;
        var pid = run?.Id;
        Task.Run(async () =>
        {
            if (attempt == 1) await Task.Delay(1500);   // a moment for the routes and the DNS rule to take effect
            var ok = V2RayCarriesTraffic(6, appPort, pid);
            Ui.Post(() =>
            {
                if (run == null || !ReferenceEquals(s.Process, run) || s.Status.Phase != VpnPhase.Connecting) return;
                if (ok)
                {
                    Log.Shared.Write($"[{s.Name}] the server carries traffic");
                    VpnTunnelUp(s);
                }
                else if (attempt < 3)
                {
                    Log.Shared.Write($"[{s.Name}] no answer through the server yet (try {attempt}/3)", LogLevel.Debug);
                    Update(s, x => x with { Detail = $"Checking the server (try {attempt + 1})…" });
                    CheckV2Ray(s, run, attempt + 1);
                }
                else
                {
                    Log.Shared.Write($"[{s.Name}] no web request got through the server", LogLevel.Error);
                    s.LastErrorLine = V2RayNoTraffic;
                    EndRun(s);
                }
            });
        });
    }

    /// <summary>Ends the running program as a failed attempt, not a disconnect: VpnProcessEnded then says why, or tries again when this was a reconnect.</summary>
    private static void EndRun(VpnSession s)
    {
        if (s.Process is not { HasExited: false } p) return;
        var ok = false;
        try { ok = Native.SendCtrlC(p.Id); } catch { }
        if (!ok) { try { p.Kill(true); } catch { } }
    }

    /// <summary>A small web request through whatever carries the PC's traffic: any HTTP answer counts. Plain HTTP to two well-known "generate_204" addresses, so no certificate gets in the way.</summary>
    public static bool V2RayCarriesTraffic(double timeoutSeconds, int? socksPort = null, int? ownerPid = null) =>
        TrafficCheck.Carries(timeoutSeconds, socksPort, ownerPid);

    // MARK: OpenVPN

    private void LaunchOpenVpn(VpnSession s, Connection c, int gen, string exe)
    {
        if (c.OvpnProfile.Trim().Length == 0)
        {
            FailVpn(s, $"{c.Name} has no OpenVPN profile. Import one in Settings → VPN.");
            return;
        }
        // Checked here and again on the very text that is passed on (StartOpenVpn): connections.json can be
        // changed by any program of the user, and openvpn.exe runs as administrator.
        var bad = OpenVpnProfile.Problems(c.OvpnProfile);
        if (bad.Count > 0)
        {
            FailVpn(s, $"{c.Name}'s OpenVPN profile uses options FiveT does not allow: {string.Join(", ", bad)}. Import it again in Settings → VPN.");
            return;
        }
        if (OpenVpnProfile.NeedsLogin(c.OvpnProfile))
        {
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
        }
        // The addresses of the profile's servers, for the kill switch (OpenVPN looks the names up again
        // itself). Before the one-time code is made: a slow lookup must not let it expire.
        var hosts = OpenVpnProfile.ServerHosts(c.OvpnProfile);
        var names = ConnectionStore.Shared.KillSwitch ? hosts.Where(h => !IsIp(h)).ToList() : new List<string>();
        Resolve(s, gen, names, found =>
        {
            s.ServerIps = hosts.Where(IsIp).Concat(found.Values.SelectMany(x => x)).Distinct().ToList();
            if (KillSwitch.IsActive) BlockInternet(s);
            StartOpenVpn(s, c, exe);
        });
    }

    /// <summary>The last step for OpenVPN: the login as it goes out now.</summary>
    private void StartOpenVpn(VpnSession s, Connection c, string exe)
    {
        string? code = null;
        if (c.UsesTotp && OpenVpnProfile.NeedsLogin(c.OvpnProfile))
        {
            var now = DateTime.UtcNow;
            code = Totp.Code(c.TotpSecret, 6, now);
            if (code == null)
            {
                FailVpn(s, c.TotpSecret.Trim().Length == 0
                    ? $"{c.Name} uses a one-time code but has no TOTP secret. Add it in Settings → VPN."
                    : $"The TOTP secret for {c.Name} is not valid Base32.");
                return;
            }
            // Servers reject a reused code, and one sent in the last seconds of its window can expire on the way.
            var reused = _lastCodeUsed.TryGetValue(c.Id, out var used) && used == code;
            var remaining = Totp.SecondsRemaining(now);
            if (reused || remaining <= TotpBoundarySeconds)
            {
                var wait = remaining + 1;
                Update(s, x => x with { Detail = $"Waiting {wait}s for a fresh code…" });
                Log.Shared.Write($"[{c.Name}] {(reused ? "current code was already used" : "current code is about to expire")}; waiting {wait}s");
                var waitGen = s.CheckGeneration;
                Ui.Cancel(ref s.WaitTimer);
                s.WaitTimer = Ui.After(wait, () => { s.WaitTimer = null; if (StillWanted(s, waitGen)) StartOpenVpn(s, c, exe); });
                return;
            }
            Redactor.AddCode(code);
            s.CurrentCode = code;
        }
        var config = OpenVpnProfile.ForLaunch(c, code);
        var bytes = Encoding.UTF8.GetByteCount(config);
        if (bytes > OpenVpnProfile.MaxConfigBytes)
        {
            FailVpn(s, $"{c.Name}'s OpenVPN profile, with its login added, is {bytes} bytes: more than FiveT allows ({OpenVpnProfile.MaxConfigBytes}). Use a smaller certificate or key, or ask your VPN administrator for a shorter profile.");
            return;
        }
        var bad = OpenVpnProfile.Problems(config);
        if (bad.Count > 0)
        {
            FailVpn(s, $"{c.Name}'s OpenVPN profile uses options FiveT does not allow: {string.Join(", ", bad)}. Import it again in Settings → VPN.");
            return;
        }
        s.SentCredentials = OpenVpnProfile.NeedsLogin(c.OvpnProfile);
        // The kernel driver (ovpn-dco) is the fast one; a profile it cannot carry gets the TAP driver.
        var tap = s.ForceTap || OpenVpnProfile.NeedsTapDriver(c.OvpnProfile);
        s.AdapterName = tap ? OpenVpnTapAdapter : OpenVpnAdapter;
        s.PendingNetwork = new NetworkInfo { Interface = s.AdapterName, FullTunnel = OpenVpnProfile.RedirectsGateway(c.OvpnProfile) };
        Update(s, x => x with { Detail = "Preparing the OpenVPN adapter…" });
        var gen = s.CheckGeneration;
        Task.Run(() =>
        {
            var problem = Setup.EnsureOpenVpnAdapter(tap);
            Ui.Post(() =>
            {
                if (!StillWanted(s, gen)) return;
                if (problem != null) { FailVpn(s, problem, needsSetup: true); return; }
                // After the profile, so they win: no scripts, no login retries of its own (FiveT counts failed
                // logins), and an exit instead of a restart of its own (FiveT reconnects, with a fresh code).
                var args = new List<string>
                {
                    "--config", "stdin", "--script-security", "1", "--auth-retry", "none", "--remap-usr1", "SIGTERM",
                    "--suppress-timestamps", "--verb", ConnectionStore.Shared.VerboseLogging ? "4" : "3", "--dev-node", s.AdapterName,
                };
                if (tap) args.Add("--disable-dco");
                RunEngine(s, exe, args, config, "openvpn", new());
            });
        });
    }

    private static readonly string[] OpenVpnErrors =
    {
        "ERROR:", "AUTH_FAILED", "Options error", "Exiting due to fatal error", "TLS Error", "TLS handshake failed", "VERIFY ERROR",
        "Cannot resolve host", "RESOLVE: Cannot", "Connection refused", "Connection timed out", "Operation timed out",
        "Network is unreachable", "Cannot open TUN/TAP", "Cannot allocate TUN/TAP", "Unrecognized option", "No route to host",
        "All tap-windows6 adapters", "All ovpn-dco adapters", "There are no TAP-Windows", "CreateFile failed on", "Access is denied",
    };

    /// <summary>OpenVPN's routine detail: kept at debug level, out of the events assistants read.</summary>
    private static readonly string[] OpenVpnChatter =
    {
        "net_", "OPTIONS IMPORT", "Outgoing Data Channel", "Incoming Data Channel", "TLS: ", "VERIFY OK", "Socket Buffers",
        "TCPv4_CLIENT", "TCPv6_CLIENT", "UDPv4", "UDPv6", "TCP/UDP:", "Data Channel MTU", "ROUTE_GATEWAY", "ROUTE6_GATEWAY",
        "SENT CONTROL", "library versions", "Note:", "DCO", "Originally developed by", "Control Channel MTU", "Timers:", "MTU:",
        "Using peer cipher", "Preserving recently used", "WARNING: this configuration may cache passwords", "NOTE: Tried to delete pre-existing",
        "Protocol options:", "++ Certificate has EKU", "Validating certificate", "C:\\WINDOWS\\system32\\route.exe", "Route addition", "NETSH:",
        "Windows version", "do_ifconfig", "TEST ROUTES", "Blocking outside", "IPv4 MTU", "Set TAP-Windows", "Notified TAP-Windows", "Successful ARP Flush",
    };

    /// <summary>
    /// One line of OpenVPN's log (verb 3, no timestamps). The login goes out with the key exchange ("Peer
    /// Connection Initiated"); the server answers AUTH_FAILED, or sends the tunnel's settings (PUSH_REPLY),
    /// and "Initialization Sequence Completed" means up.
    /// </summary>
    private void HandleOpenVpn(string line, VpnSession s)
    {
        var c = s.Connection;
        var error = OpenVpnErrors.Any(line.Contains);
        Log.Shared.Write($"[{c.Name}] {line}", error ? LogLevel.Error : OpenVpnChatter.Any(p => line.StartsWith(p, StringComparison.Ordinal)) ? LogLevel.Debug : LogLevel.Info);

        if (line.Contains("Peer Connection Initiated"))
        {
            if (s.SentCredentials && !s.Authenticated)
            {
                // From here the login counts (LoginGuard), and its one-time code is used.
                s.LoginPending = true;
                if (s.CurrentCode is { } code) _lastCodeUsed[c.Id] = code;
                if (_loginOverrideAt.Remove(c.Id))   // Try Anyway was for this one login
                    Log.Shared.Write($"[{c.Name}] logging in although the last logins to {c.LoginGuardKey} failed (Try Anyway)");
                Update(s, x => x with { Detail = "Logging in…" });
            }
            else if (!s.SentCredentials) Update(s, x => x with { Detail = "Connected to the server, setting up…" });
            // else: already authenticated this run (a TLS renegotiation can print this line again on a
            // connection that is still fine): nothing to redo, and never a fresh "login" to count.
        }
        else if (line.Contains("AUTH_FAILED"))
        {
            s.LastErrorLine = line;
            if (s.LoginPending) LoginFailed(s);
        }
        else if (line.IndexOf("PUSH_REPLY,", StringComparison.Ordinal) is var at and >= 0)
        {
            if (s.SentCredentials && !s.Authenticated) LoginSucceeded(s); else s.Authenticated = true;
            // "PUSH_REPLY,route 10.99.0.0 255.255.255.0,dhcp-option DNS 10.8.0.1,redirect-gateway def1,ifconfig 10.8.0.2 255.255.255.0,…'"
            var n = s.PendingNetwork;
            var dns = n.DnsServers.ToList();
            var search = n.SearchDomains.ToList();
            foreach (var option in line[(at + "PUSH_REPLY,".Length)..].TrimEnd('\'').Split(','))
            {
                var w = option.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (w.Length == 0) continue;
                switch (w[0])
                {
                    case "ifconfig" when w.Length > 1: n = n with { TunnelIP = w[1] }; break;
                    case "route-gateway" when w.Length > 1: n = n with { PeerIP = w[1] }; break;
                    case "redirect-gateway": n = n with { FullTunnel = true }; break;
                    case "dhcp-option" when w.Length > 2:
                        if (w[1].ToUpperInvariant() is "DNS" or "DNS6") { if (IsIp(w[2]) && !dns.Contains(w[2])) dns.Add(w[2]); }
                        else if (w[1].ToUpperInvariant() is "DOMAIN" or "DOMAIN-SEARCH" or "ADAPTER_DOMAIN_SUFFIX") search = Connection.CleanDomains("", search.Append(w[2]));
                        break;
                }
            }
            s.PendingNetwork = n with { DnsServers = dns, SearchDomains = search };
            Update(s, x => x with { Detail = "Setting up the tunnel…" });
        }
        else if (line.Contains("Initialization Sequence Completed"))
        {
            if (s.Status.Phase == VpnPhase.Connecting) VpnTunnelUp(s);
        }
        else if (error)
        {
            // The first specific error explains the exit; a rejected login always does.
            if (s.LastErrorLine == null || (!IsAuthFailure(s) && !line.Contains("Exiting due to fatal error"))) s.LastErrorLine = line;
            if (line.Contains("Access is denied")) Update(s, x => x with { NeedsSetup = true });
        }
    }

    // MARK: Running a VPN program

    /// <summary>
    /// Starts openvpn.exe or xray.exe for <paramref name="s"/> with <paramref name="input"/> on its stdin (the
    /// profile with its login, or the config: never on disk, never on the command line); its output comes
    /// back line by line. Its own hidden console, so Ctrl+C can stop it cleanly (routes and DNS restored).
    /// </summary>
    private void RunEngine(VpnSession s, string exe, IEnumerable<string> args, string input, string what, Dictionary<string, string> environment)
    {
        var c = s.Connection;
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Path.GetDirectoryName(exe) ?? Paths.ExeDir,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        // Nothing of the user's environment decides what a program run as administrator loads.
        foreach (var name in new[] { "OPENSSL_CONF", "OPENSSL_MODULES", "OPENSSL_ENGINES", "XRAY_LOCATION_ASSET", "XRAY_LOCATION_CONFIG", "XRAY_LOCATION_CONFDIR", "xray.location.asset" })
            psi.Environment.Remove(name);
        foreach (var (k, v) in environment) psi.Environment[k] = v;
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        void Line(string? data) { if (data != null) Ui.Post(() => { var t = data.Trim(); if (t.Length == 0) return; if (s.Connection.IsV2Ray) HandleV2Ray(t, s); else HandleOpenVpn(t, s); }); }
        p.OutputDataReceived += (_, e) => Line(e.Data);
        p.ErrorDataReceived += (_, e) => Line(e.Data);
        p.Exited += (_, _) =>
        {
            // Kill switch: the program ended by itself and its routes went with it. Blocked here, on this
            // thread, before anything else: every moment until then, traffic leaves unprotected.
            var blocked = Interlocked.Exchange(ref s.BlockOnExit, null) is { } addresses && KillSwitch.Block(addresses, null) == null;
            Ui.Post(() => Ui.After(0.3, () => VpnProcessEnded(p, s, blocked, what)));   // let queued lines land first
        };
        try
        {
            Native.AllowCtrlC();
            p.Start();
        }
        catch (Exception e)
        {
            p.Dispose();
            FailVpn(s, $"Could not start {what}: {e.Message}");
            return;
        }
        s.Process = p;
        try
        {
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.StandardInput.Write(input);
            p.StandardInput.Close();
        }
        catch (IOException)
        {
            // The pipe broke because the program has already exited; its output says why.
            try { p.StandardInput.Close(); } catch { }
        }
        var codeNote = c.IsOpenVpn && c.UsesTotp && s.CurrentCode != null ? $", one-time code {Describe(c.OtpMode)}" : "";
        Log.Shared.Write($"[{c.Name}] launched {what} (pid {p.Id}) → {c.Host}:{c.Port}{codeNote}");
    }

    /// <summary>The tunnel is up: connected, with what was learned while connecting.</summary>
    private void VpnTunnelUp(VpnSession s)
    {
        var c = s.Connection;
        var store = ConnectionStore.Shared;
        if (s.ReconnectAttempt > 0) Log.Shared.Write($"[{c.Name}] reconnected after {s.ReconnectAttempt} attempt(s)");
        s.ReconnectAttempt = 0;
        s.FailedOver = false;
        s.Reconnecting = false;
        s.ReconnectDue = null;
        s.WaitingForNetwork = false;
        s.ProbeFailures = 0;
        s.WatchdogAnnounced = s.WatchdogSkipLogged = false;
        s.LastErrorLine = null;
        s.ForceTap = false;
        SetStatus(s, new VpnStatus
        {
            Phase = VpnPhase.Connected, ConnectionId = c.Id, ConnectionName = c.Name, Since = DateTime.Now, Network = s.PendingNetwork,
        });
        // The tunnel's routes carry everything again (an apps-only proxy's do not, so a block stays until the user lifts it).
        if (s.AppProxyPort == null) ReleaseKillSwitch();
        Arm(s);
        EnsureWatchdog();
        var mode = c.OtpMode;
        var trial = s.OtpTrialOf != null;
        if (trial)
        {
            Log.Shared.Write($"[{c.Name}] the server wants the one-time code {Describe(mode)}; saved that under One-time code");
            EndOtpTrial(s);
        }
        store.Mutate(c.Id, x =>
        {
            x.LastConnectedAt = DateTime.Now; x.LastError = null;
            if (trial) x.OtpMode = mode;
        });
        if (store.NotifyOnChange) Notifier?.Invoke("FiveT", $"Connected to {c.Name}", false);
        // OpenVPN: read what it configured on its adapter (routes, DNS), then split DNS and the full tunnel's DNS.
        if (c.IsOpenVpn) CaptureNetwork(s);
    }

    private void VpnProcessEnded(Process proc, VpnSession s, bool blocked, string what)
    {
        if (!ReferenceEquals(proc, s.Process)) { proc.Dispose(); return; }
        var c = s.Connection;
        var previous = s.Status;
        var restart = s.RestartRequested;   // the watchdog tore the tunnel down on purpose
        s.RestartRequested = false;
        if (blocked)
        {
            // A stop the user asked for just as the program ended by itself is still their stop.
            if (previous.Phase == VpnPhase.Disconnecting && !restart) ReleaseKillSwitch();
            else Log.Shared.Write($"[{s.Name}] kill switch: the VPN ended, so this PC's internet is blocked until it is back", LogLevel.Error);
        }
        RemoveSplitDns(s);
        ClearTunnelDns(s);
        Ui.Cancel(ref s.StopTimer);
        if (s.AppProxyPort is { } held) AppProxyHold.Shared.Take(held);   // apps-only: nobody else gets the port while Xray is away
        s.Process = null;
        int code;
        try { code = proc.ExitCode; } catch { code = -1; }
        proc.Dispose();
        Log.Shared.Write($"[{c.Name}] {what} exited (status {code})");
        if (s.LoginPending) LoginFailed(s);

        if (s.RelaunchWhenStopped)
        {
            s.RelaunchWhenStopped = false;
            CancelReconnect(s);
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
                var why = FriendlyVpn(s.LastErrorLine) is { } w ? " " + w : "";
                if (restart || ConnectionStore.Shared.AutoReconnect)
                {
                    Log.Shared.Write($"[{c.Name}] connection dropped.{why}", LogLevel.Error);
                    ScheduleReconnect(s, 1);
                }
                else FailVpn(s, $"{c.Name} disconnected unexpectedly.{why}");
                break;
            }
            case VpnPhase.Connecting:
            {
                var msg = FriendlyVpn(s.LastErrorLine) ?? $"{c.Name}: connection failed (exit {code}). See the log.";
                if (!previous.NeedsSetup && c.IsOpenVpn && LoginGuard.Shared.IsLimited(c.LoginGuardKey))
                {
                    EndOtpTrial(s);
                    var limit = LoginLimitMessage(ConnectionStore.Shared.Get(c.Id) ?? c);
                    FailVpn(s, s.LoginFailedThisRun ? limit : msg + " No password was sent this time. " + limit);
                    break;
                }
                // shortcut: any adapter or driver trouble with the kernel driver gets one try with the TAP
                // driver; a server that pushes a cipher ovpn-dco cannot carry ends the same way.
                if (c.IsOpenVpn && !s.ForceTap && !s.Authenticated && s.LastErrorLine is { } l
                    && (l.Contains("dco", StringComparison.OrdinalIgnoreCase) || l.Contains("adapter", StringComparison.OrdinalIgnoreCase) || l.Contains("TUN/TAP")))
                {
                    s.ForceTap = true;
                    Log.Shared.Write($"[{c.Name}] the fast OpenVPN driver could not be used; trying once with the TAP driver");
                    StartVpn(c, s.Origin);
                    break;
                }
                var rejected = IsAuthFailure(s);
                if (TryOtherOtpMode(s, code)) break;
                if (s.OtpTrialOf != null)
                {
                    EndOtpTrial(s);
                    if (rejected) msg += " The one-time code was tried both appended to the password and as a second step.";
                }
                if (rejected) msg += LastConnectedNote(c);
                if ((s.ReconnectAttempt > 0 || s.FailedOver) && !previous.NeedsSetup && !rejected)
                {
                    Log.Shared.Write($"[{c.Name}] reconnect attempt {s.ReconnectAttempt} failed: {msg}", LogLevel.Error);
                    ScheduleReconnect(s, s.ReconnectAttempt + 1);
                }
                else FailVpn(s, (s.ReconnectAttempt > 0 ? $"Could not reconnect {c.Name}: " : "") + msg, previous.NeedsSetup);
                break;
            }
        }
    }

    /// <summary>A failed VPN says so, and that the kill switch still blocks when it does.</summary>
    private void FailVpn(VpnSession s, string message, bool needsSetup = false) =>
        Fail(s, KillSwitch.IsActive
            ? message + " The kill switch keeps this PC's internet blocked: connect again, or choose Unblock Internet in FiveT's menu."
            : message, needsSetup);

    private static string? FriendlyVpn(string? l)
    {
        if (l == null) return null;
        if (l == V2RayNoTraffic)
            return "The V2Ray server did not answer: it may be down or blocked, or the config is out of date. Try another server, or refresh the subscription in Settings → VPN.";
        if (l.Contains("Failed to start") || l.Contains("infra/conf") || l.Contains("proxy/tun"))
        {
            if (l.Contains("is prohibited")) return "Xray refuses this config: it would send the traffic unencrypted. Ask your provider for a config with TLS or Reality.";
            var detail = l.Split(" > ").Last().Trim();
            return $"Xray could not start with this config: {detail}";
        }
        if (l.Contains("AUTH_FAILED")) return "Login failed. Check the password and the TOTP secret, and that the PC's clock is correct.";
        if (l.IndexOf("Options error: ", StringComparison.Ordinal) is var at and >= 0)
            return $"The OpenVPN profile has a setting OpenVPN cannot use: {l[(at + "Options error: ".Length)..]}";
        if (l.Contains("VERIFY ERROR")) return "The server's certificate does not match the OpenVPN profile. Ask your VPN administrator for a current profile.";
        if (l.Contains("TLS key negotiation failed") || l.Contains("TLS handshake failed") || l.Contains("TLS Error"))
            return "The OpenVPN server did not answer in time. Check the network, and whether another VPN or a firewall blocks it.";
        if (l.Contains("adapters on this system are currently in use") || l.Contains("There are no TAP-Windows") || l.Contains("CreateFile failed on"))
            return "Windows did not give OpenVPN its network adapter (another OpenVPN program may be using it). Try again; if it keeps failing, restart the PC.";
        if (l.Contains("Connection refused")) return "The VPN server refused the connection. Check the server address and port, or ask your VPN administrator.";
        if (l.Contains("Cannot resolve host") || l.Contains("RESOLVE:") || l.Contains("unreachable") || l.Contains("timed out"))
            return "Could not reach the server. Is another VPN switched on?";
        return l.Replace("ERROR:", "").Trim();
    }

    /// <summary>The watchdog for V2Ray and Outline: Xray answers DNS itself, server or no server, so only a real request says.</summary>
    private void ProbeV2Ray(VpnSession s)
    {
        if (s.ProbeRunning || !s.IsRunning) return;
        s.ProbeRunning = true;
        var since = s.Status.Since;
        var appPort = s.AppProxyPort;
        var pid = s.Process?.Id;
        Task.Run(() =>
        {
            var alive = V2RayCarriesTraffic(5, appPort, pid);
            Ui.Post(() =>
            {
                s.ProbeRunning = false;
                if (s.Status.Phase != VpnPhase.Connected || s.Status.Since != since || !s.IsRunning) return;
                if (alive)
                {
                    if (s.ProbeFailures > 0) Log.Shared.Write($"[{s.Name}] watchdog: the V2Ray server answers again");
                    s.ProbeFailures = 0;
                    if (s.Status.Health != null) Update(s, x => x with { Health = null });
                    return;
                }
                s.ProbeFailures++;
                var silent = s.ProbeFailures * WatchdogSeconds;
                Update(s, x => x with { Health = $"not answering for {silent}s" });
                Log.Shared.Write($"[{s.Name}] watchdog: no web request got through ({s.ProbeFailures}/{WatchdogStrikes})", LogLevel.Error);
                if (s.ProbeFailures >= WatchdogStrikes) RestartDeadTunnel(s, $"tunnel stopped answering (the V2Ray server silent for {silent}s)");
            });
        });
    }

    // MARK: Switch to another VPN (the Mac's 1.20)

    /// <summary>This many failed reconnects, then the next VPN takes over (Settings → General → VPN Settings).</summary>
    private const int FailoverAfter = 3;

    /// <summary>
    /// Hands over to the next VPN in the list after <paramref name="s"/>, going round to the first at the end, when the setting is
    /// on and <paramref name="s"/> is a VPN. False: nothing else to switch to, <paramref name="s"/> keeps retrying. Connecting
    /// the other one stops <paramref name="s"/> ("one VPN at a time", with the kill switch still blocking in between).
    /// </summary>
    private bool FailOver(VpnSession s)
    {
        if (!ConnectionStore.Shared.AutoFailover || !s.Connection.IsOtherVpn) return false;
        if (VpnApps.NextVpn(ConnectionStore.Shared.Connections, s.Connection.Id) is not { } next) return false;
        Log.Shared.Write($"[{s.Name}] still down after {FailoverAfter} tries; failing over to {next.Name}", LogLevel.Error);
        Connect(next, ConnectOrigin.Background);
        if (_sessions.TryGetValue(next.Id, out var other)) other.FailedOver = true;
        return true;
    }

    // MARK: Apps only (the Mac's 1.21)

    /// <summary>Settings → General → apps-only was switched: a V2Ray or Outline tunnel that is up starts again in the other mode.</summary>
    public void AppsModeChanged()
    {
        foreach (var s in _sessions.Values.Where(x => x.Connection.IsV2Ray && x.Status.Phase == VpnPhase.Connected).ToList())
            RestartDeadTunnel(s, "apps-only mode was switched", lastError: null, LogLevel.Info, detail: "Switching mode…");
    }

    private VpnSession? AppProxySession => _sessions.Values.FirstOrDefault(s => s.AppProxyPort != null && s.Status.Phase == VpnPhase.Connected);

    /// <summary>True while a VPN that carries the chosen apps is up.</summary>
    public bool AppProxyReady => AppProxySession != null;

    /// <summary>
    /// Starts the app at <paramref name="path"/> through the VPN's local proxy, with the rights of the signed-in user, not FiveT's.
    /// Chromium and Electron apps take the proxy as a switch (the environment covers programs that read it). An app that is
    /// running ignores the switch, so it must be closed first. Returns what to tell the user when it cannot.
    /// </summary>
    public string? OpenThroughVpn(string path)
    {
        if (AppProxySession?.AppProxyPort is not { } port) return "Connect a V2Ray or Outline VPN first.";
        var name = VpnApps.Name(path);
        if (!ConnectionStore.Shared.VpnAppPaths.Contains(path, StringComparer.OrdinalIgnoreCase))
            return $"{name} is not in the list of apps in Settings → General.";
        if (!File.Exists(path)) return $"{name} was not found at {path}. Remove it in Settings → General and add it again.";
        if (IsProgramRunning(path)) return $"{name} is already open, and an open app cannot be moved onto the VPN. Quit it (also from the tray), then choose this again.";
        var (pid, problem) = UserProcess.Start(path, VpnApps.ProxyArguments(port), VpnApps.ProxyEnvironment(port));
        Log.Shared.Write($"opened {name} through the VPN proxy 127.0.0.1:{port}" + (pid != null ? $" (pid {pid})" : $" (failed: {problem})"), pid != null ? LogLevel.Info : LogLevel.Error);
        return pid != null ? null : $"Windows could not open {name}: {problem}";
    }

    /// <summary>A program with this full path is running now (any of its processes).</summary>
    private static bool IsProgramRunning(string path)
    {
        foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path)))
        {
            try { if (string.Equals(p.MainModule?.FileName, path, StringComparison.OrdinalIgnoreCase)) return true; }
            catch (Exception) { }   // a process FiveT may not look into is not the app
            finally { p.Dispose(); }
        }
        return false;
    }

    // MARK: A full tunnel's DNS

    /// <summary>
    /// A VPN that carries all traffic: its DNS servers answer every name while it is up (an NRPT rule for
    /// "."), so names are not looked up by the local network's resolver, which may answer differently or be
    /// filtered. Windows otherwise asks the DNS servers of every adapter at once. For Xray the adapter's own
    /// DNS server is set too (Xray does not set it).
    /// </summary>
    private void ApplyTunnelDns(VpnSession s, string adapter, List<string> servers, bool setAdapter)
    {
        servers = servers.Where(IsIp).ToList();
        if (servers.Count == 0)
        {
            Log.Shared.Write($"[{s.Name}] all traffic goes through the tunnel, but the server sent no DNS server: the PC keeps its own DNS");
            return;
        }
        s.TunnelDns = true;
        var name = s.Name;
        Task.Run(() =>
        {
            var err = SplitDns.SetDefault(servers, setAdapter ? adapter : null);
            Log.Shared.Write(err == null ? $"[{name}] DNS: every name now goes to {string.Join(", ", servers)} through the tunnel"
                : $"[{name}] could not make the tunnel's DNS the PC's: {err}", err == null ? LogLevel.Info : LogLevel.Error);
        });
    }

    private void ClearTunnelDns(VpnSession s)
    {
        if (!s.TunnelDns) return;
        s.TunnelDns = false;
        var name = s.Name;
        Task.Run(() =>
        {
            var err = SplitDns.ClearDefault();
            Log.Shared.Write(err == null ? $"[{name}] DNS: back to the PC's own" : $"[{name}] could not restore the PC's DNS: {err}", err == null ? LogLevel.Info : LogLevel.Error);
        });
    }

    // MARK: Kill switch

    /// <summary>The kill switch is blocking this PC's internet now (a VPN that carried all traffic is down and nobody switched it off).</summary>
    public bool KillSwitchActive => KillSwitch.IsActive;

    /// <summary>
    /// The kill switch covers a VPN that carries all of the PC's traffic: V2Ray, Outline, and OpenVPN when it
    /// redirects the gateway. While such a tunnel is up, its routes take everything and nothing is filtered.
    /// When it goes down without the user having switched it off (a drop, a dead tunnel, a network change),
    /// everything that leaves the PC is blocked except the local network, the VPN's server and the PC's DNS
    /// servers, so FiveT can reconnect. shortcut: a program that ends by itself is blocked a moment after its
    /// routes went (as on the Mac); filtering all the time would close that but also stop Xray's own direct
    /// connections ("Iranian sites go direct"). Upgrade if that moment ever matters.
    /// </summary>
    private void Arm(VpnSession s)
    {
        var wanted = ConnectionStore.Shared.KillSwitch && s.Connection.IsOtherVpn && (s.Status.Network ?? s.PendingNetwork).FullTunnel;
        s.BlockOnExit = wanted ? KillSwitchAddresses(s) : null;
    }

    /// <summary>What stays reachable while blocked: the VPN's server and the PC's own DNS servers.</summary>
    private static List<string> KillSwitchAddresses(VpnSession s) => s.ServerIps.Concat(s.LocalDns).Where(IsIp).Distinct().ToList();

    /// <summary>Blocks the PC's internet for <paramref name="s"/> now, or updates what the block lets through (<paramref name="tunnel"/>: the adapter a V2Ray run has opened, so its check that the server carries traffic gets out).</summary>
    private void BlockInternet(VpnSession s, ulong? tunnel = null)
    {
        s.BlockOnExit = null;
        var was = KillSwitch.IsActive;
        if (KillSwitch.Block(KillSwitchAddresses(s), tunnel) is { } err)
        {
            Log.Shared.Write($"kill switch: could not block the internet: {err}", LogLevel.Error);
            return;
        }
        if (!was)
        {
            Log.Shared.Write($"[{s.Name}] kill switch: this PC's internet is blocked until the VPN is back", LogLevel.Error);
            Recompute();
        }
    }

    /// <summary>Lifts the block (the tunnel is back, the user disconnected or chose Unblock Internet), and keeps a program that is stopping from setting it.</summary>
    public void ReleaseKillSwitch()
    {
        foreach (var s in _sessions.Values) s.BlockOnExit = null;
        if (!KillSwitch.IsActive) return;
        KillSwitch.Unblock();
        Log.Shared.Write("kill switch: this PC's internet is open again");
        Recompute();
    }

    /// <summary>Settings → General → Kill Switch was switched: off lifts a block; on covers the tunnel that is up.</summary>
    public void KillSwitchSettingChanged()
    {
        if (!ConnectionStore.Shared.KillSwitch) { ReleaseKillSwitch(); return; }
        foreach (var s in _sessions.Values.Where(x => x.Status.Phase == VpnPhase.Connected)) Arm(s);
    }

    /// <summary>The LUID Windows knows a network adapter by (what a filter on "this adapter" takes), or null.</summary>
    private static ulong? InterfaceLuid(string alias)
    {
        try
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == alias);
            var index = nic?.GetIPProperties().GetIPv4Properties()?.Index;
            return index is { } i && ConvertInterfaceIndexToLuid((uint)i, out var luid) == 0 ? luid : null;
        }
        catch (Exception) { return null; }
    }

    [DllImport("iphlpapi.dll")] private static extern uint ConvertInterfaceIndexToLuid(uint index, out ulong luid);

    /// <summary>
    /// After a crash: FiveT's own openvpn.exe or xray.exe still running with no app to stop it. Both are FiveT's
    /// alone (another app's openvpn runs from elsewhere), so they go. The kill switch needs no cleanup: Windows
    /// removed its filters when the old FiveT ended.
    /// </summary>
    private static void StopLeftoverVpnPrograms()
    {
        foreach (var name in new[] { "xray", "openvpn" })
            foreach (var p in Process.GetProcessesByName(name))
            {
                try
                {
                    if (p.MainModule?.FileName is { } path && path.StartsWith(Paths.ExeDir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    {
                        Log.Shared.Write($"stopping FiveT's {name} left running by an earlier FiveT (pid {p.Id})");
                        p.Kill(true);
                    }
                }
                catch (Exception) { }
                finally { p.Dispose(); }
            }
    }
}
