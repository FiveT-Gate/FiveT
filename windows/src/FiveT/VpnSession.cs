using System.Diagnostics;
using Timer = FiveT.UiTimer;

namespace FiveT;

/// <summary>
/// One tunnel: the openconnect process for a single connection plus every piece of state that used
/// to be a field on <see cref="VpnManager"/> when only one tunnel could exist at a time.
///
/// FiveT can hold several tunnels open at once (Office and Lab together, say), so all of this is
/// per-session: its own openconnect process, its own Wintun adapter name, its own reconnect timer
/// and its own list of installed NRPT rules. <see cref="VpnManager"/> owns the sessions and does
/// the work; this type only holds the state, so the logic stays in one place.
/// </summary>
public sealed class VpnSession
{
    public VpnSession(Connection connection, string adapterName)
    {
        Connection = connection;
        AdapterName = adapterName;
        Status = new VpnStatus { ConnectionId = connection.Id, ConnectionName = connection.Name };
    }

    /// <summary>The connection as it was when this session started; reconnects re-read the store.</summary>
    public Connection Connection { get; set; }

    public Guid Id => Connection.Id;
    public string Name => Connection.Name;

    /// <summary>
    /// The Wintun adapter this tunnel gets: "FiveT" for the first one, then "FiveT-2", "FiveT-3".
    /// Two tunnels cannot share a name — openconnect fails to open the adapter if they do — and the
    /// name is also how the network facts for this tunnel are found again afterwards.
    /// </summary>
    public string AdapterName { get; set; }

    public VpnStatus Status { get; set; }

    public Process? Process;

    /// <summary>Set while stopping to say "launch this session again as soon as the process is gone".</summary>
    public bool RelaunchWhenStopped;
    /// <summary>The watchdog is tearing this tunnel down to bring it back: reconnect even with Auto-reconnect off.</summary>
    public bool RestartRequested;
    public ConnectOrigin RelaunchOrigin = ConnectOrigin.User;

    /// <summary>Who started the current attempt (a click, automation, or an automatic reconnect).</summary>
    public ConnectOrigin Origin = ConnectOrigin.User;
    /// <summary>A changed certificate was trusted as a renewal during this attempt; a second change always asks.</summary>
    public bool AutoRenewed;
    /// <summary>The pin openconnect reported for a certificate it refused (it saw another one than FiveT checked).</summary>
    public string? OpenconnectPin;
    /// <summary>The next reconnect is waiting for the network to come back.</summary>
    public bool WaitingForNetwork;
    /// <summary>When a network change last started this session's reconnect (at most once per 10 s).</summary>
    public DateTime? LastNetworkLaunch;

    /// <summary>
    /// Counts certificate checks. Each connect bumps it before the check starts, and a disconnect bumps
    /// it too, so a check (or a trust prompt) that finishes after the user changed their mind is ignored.
    /// </summary>
    public int CheckGeneration;

    /// <summary>The password went out and no answer yet (LoginGuard counts from here).</summary>
    public bool LoginPending;
    /// <summary>This run's login got through.</summary>
    public bool Authenticated;
    /// <summary>This run's login was counted as failed.</summary>
    public bool LoginFailedThisRun;
    public string? LastErrorLine;
    public bool SawCertFailure;
    /// <summary>
    /// openconnect could not reach the gateway (refused, no route, timed out, unknown host). It ends
    /// such a failure with "Failed to complete authentication", which must not be read as a login failure.
    /// </summary>
    public bool SawUnreachable;
    /// <summary>openconnect could not open the Wintun adapter.</summary>
    public bool SawAdapterFailure;
    /// <summary>… and the dead adapters have already been cleared once for this session.</summary>
    public bool SweptGhostAdapters;

    public string? CurrentCode;

    public Timer? StopTimer, WaitTimer, ReconnectTimer;
    public int ReconnectAttempt;
    /// <summary>True between scheduling a reconnect and the attempt actually starting.</summary>
    public bool Reconnecting;
    /// <summary>When the scheduled reconnect fires; null once it has (waking up or a network change brings it forward).</summary>
    public DateTime? ReconnectDue;

    // Watchdog: every 20 s a DNS question goes to the tunnel's own DNS server (see VpnManager.Probe).
    public bool ProbeRunning;
    public int ProbeFailures;
    /// <summary>"watching via …" / "nothing to probe" were logged once for this tunnel.</summary>
    public bool WatchdogAnnounced, WatchdogSkipLogged;

    /// <summary>
    /// Set while a login is being retried with the other one-time-code mode: the connection as it was.
    /// The trial runs on a clone (<see cref="Connection"/> holds it meanwhile), so the saved connection
    /// is only changed once the tunnel is up.
    /// </summary>
    public Connection? OtpTrialOf;

    public string PendingTunnelIp = "";

    // OpenVPN, V2Ray and Outline (VpnManager.Vpn.cs)
    /// <summary>This run sends a password (an OpenVPN profile may use a certificate only; V2Ray has no login).</summary>
    public bool SentCredentials;
    /// <summary>OpenVPN: the kernel driver could not carry this profile once; the TAP driver is used for the retry.</summary>
    public bool ForceTap;
    /// <summary>What the VPN said about its tunnel while connecting (address, DNS, all traffic or not).</summary>
    public NetworkInfo PendingNetwork = new();
    /// <summary>The server's addresses, looked up before the tunnel (kill switch), and the PC's own DNS servers from before the tunnel took over.</summary>
    public List<string> ServerIps = new(), LocalDns = new();
    /// <summary>Kill switch: what stays reachable if this program ends by itself; null when a stop is wanted or the
    /// switch does not apply. Read off the UI thread by the exit handler (Interlocked).</summary>
    public List<string>? BlockOnExit;
    /// <summary>The NRPT rule that sends every name to this tunnel's DNS is installed.</summary>
    public bool TunnelDns;

    /// <summary>The domains whose NRPT rules this session created, so only its own are removed.</summary>
    public readonly List<string> InstalledDomains = new();

    public bool IsRunning => Process is { HasExited: false };

    public bool IsBusy => Status.Phase is VpnPhase.Connecting or VpnPhase.Disconnecting;

    /// <summary>True once the session has nothing left to do and can be dropped from the registry.</summary>
    public bool IsFinished => !IsRunning && !Reconnecting && Status.Phase == VpnPhase.Idle && Status.LastError == null;

    public void CancelTimers()
    {
        Ui.Cancel(ref StopTimer);
        Ui.Cancel(ref WaitTimer);
        Ui.Cancel(ref ReconnectTimer);
    }
}
