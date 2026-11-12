namespace FiveT;

public enum VpnPhase { Idle, Connecting, Connected, Disconnecting }

/// <summary>What the tunnel produced, captured once openconnect reports the tunnel as configured.</summary>
public sealed record NetworkInfo
{
    public string Interface { get; init; } = "";          // adapter alias, e.g. "FiveT"
    public int InterfaceIndex { get; init; }
    public string TunnelIP { get; init; } = "";
    public string PeerIP { get; init; } = "";
    public List<string> DnsServers { get; init; } = new();
    public List<string> SearchDomains { get; init; } = new();
    public List<string> Routes { get; init; } = new();    // "a.b.c.d/nn"
    /// <summary>OpenVPN, V2Ray, Outline: all traffic goes through the tunnel (redirect-gateway), so its DNS is the PC's too.</summary>
    public bool FullTunnel { get; init; }
}

/// <summary>State of the NRPT rules for the connection's "DNS domains".</summary>
public sealed record SplitDnsInfo(List<string> Domains, string State, string Detail = "");
// State: active | partial | helper_needed | failed | pending

public sealed record VpnStatus
{
    public VpnPhase Phase { get; init; } = VpnPhase.Idle;
    public Guid? ConnectionId { get; init; }
    public string? ConnectionName { get; init; }
    public DateTime? Since { get; init; }
    /// <summary>Progress text while connecting ("Logging in…").</summary>
    public string? Detail { get; init; }
    /// <summary>Last failure, shown in the menu until it is opened once.</summary>
    public string? LastError { get; init; }
    /// <summary>True when the failure needs setting up (Settings → General) (openconnect missing, not elevated, …).</summary>
    public bool NeedsSetup { get; init; }
    public NetworkInfo? Network { get; init; }
    public SplitDnsInfo? SplitDns { get; init; }
    /// <summary>Watchdog verdict while connected: null or "ok" while the tunnel answers, else "not answering for 40s" (the Mac's <c>health</c>).</summary>
    public string? Health { get; init; }
    /// <summary>The next reconnect is waiting for the network to come back (the Mac's <c>waitingForNetwork</c>).</summary>
    public bool WaitingForNetwork { get; init; }

    public string StateName => Phase switch
    {
        VpnPhase.Idle => "disconnected",
        VpnPhase.Connecting => "connecting",
        VpnPhase.Connected => "connected",
        VpnPhase.Disconnecting => "disconnecting",
        _ => "unknown",
    };

    public int? UptimeSeconds => Since is { } s ? (int)(DateTime.Now - s).TotalSeconds : null;

    /// <summary>
    /// The first sentence of an error, 90 characters at most, for the menu and the icon's tooltip (Mac
    /// 1.11.1: "a short one-line message … instead of a line wider than the screen"). The full text stays
    /// in <see cref="LastError"/> and is shown under the connection in Settings → Connections.
    /// </summary>
    public static string ShortError(string error)
    {
        var text = error.ReplaceLineEndings(" ").Trim();
        // A sentence ends at ". " (not at the dot inside "vpn.example.com" or "1.5").
        var end = text.IndexOf(". ", StringComparison.Ordinal);
        if (end > 0) text = text[..(end + 1)];
        const int max = 90;
        return text.Length <= max ? text : text[..(max - 1)].TrimEnd() + "…";
    }

    public static string DurationText(int s) =>
        s >= 3600 ? $"{s / 3600}:{(s % 3600) / 60:D2}:{s % 60:D2}" : $"{s / 60}:{s % 60:D2}";

    /// <summary>One readable line, e.g. "connected to Office since 2026-09-05 19:25:38 (up 0:42)".</summary>
    public string Summary
    {
        get
        {
            var s = StateName;
            if (ConnectionName is { } n) s += " " + (Phase == VpnPhase.Idle ? $"({n})" : $"to {n}");
            if (Since is { } since) s += $" since {Log.Format(since)} (up {DurationText(UptimeSeconds ?? 0)})";
            if (Detail is { } d) s += $" — {d}";
            if (Health is { } h) s += $" — {h}";
            if (LastError is { } e) s += $" — last error: {e}";
            if (NeedsSetup) s += " — setup needed";
            return s;
        }
    }
}
