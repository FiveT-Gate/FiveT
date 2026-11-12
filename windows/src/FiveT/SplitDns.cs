using FiveT.Core;

namespace FiveT;

/// <summary>
/// Split DNS on Windows uses the Name Resolution Policy Table (NRPT): a rule per domain that sends
/// look-ups for that domain (and its subdomains) to the tunnel's DNS servers, whatever the default
/// route is. The macOS app writes /etc/resolver/&lt;domain&gt; for the same effect. Every rule FiveT
/// creates carries the comment "FiveT", so stale ones can be found and removed after a crash.
/// Needs administrator rights (the tray app is always elevated).
/// </summary>
public static class SplitDns
{
    public const string Mark = "FiveT";

    private static string Ps(string s) => s.Replace("'", "''");

    /// <summary>
    /// One NRPT script at a time. A removal still running from the last disconnect must not land after
    /// the rules of the tunnel that just reconnected were added, and the quit-time removal must not
    /// interleave with a background one.
    /// </summary>
    private static readonly object Gate = new();

    /// <summary>Adds the rules for one domain. Returns null on success or the error text.</summary>
    public static string? Add(string domain, IReadOnlyList<string> servers)
    {
        if (!Paths.IsElevated) return "helper_needed";
        if (!IsValidDomain(domain)) return "invalid domain";
        foreach (var server in servers)
            if (!System.Net.IPAddress.TryParse(server, out _)) return $"invalid nameserver {server}";
        var ns = string.Join(",", servers.Select(x => $"'{Ps(x)}'"));
        // ".domain" matches every name under it; "domain" matches the apex itself.
        var script = $@"
$ErrorActionPreference = 'Stop'
Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{Mark}' -and ($_.Namespace -eq '.{Ps(domain)}' -or $_.Namespace -eq '{Ps(domain)}') }} | Remove-DnsClientNrptRule -Force
Add-DnsClientNrptRule -Namespace '.{Ps(domain)}' -NameServers {ns} -Comment '{Mark}' -DisplayName 'FiveT {Ps(domain)}' | Out-Null
Add-DnsClientNrptRule -Namespace '{Ps(domain)}' -NameServers {ns} -Comment '{Mark}' -DisplayName 'FiveT {Ps(domain)}' | Out-Null
Clear-DnsClientCache
";
        Setup.RunResult r;
        lock (Gate) r = Setup.PowerShell(script);
        return r.Status == 0 ? null : r.Output.Trim();
    }

    /// <summary>Removes the rules for one domain.</summary>
    public static string? Remove(string domain)
    {
        if (!IsValidDomain(domain)) return "invalid domain";
        var script = $@"
$ErrorActionPreference = 'Stop'
Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{Mark}' -and ($_.Namespace -eq '.{Ps(domain)}' -or $_.Namespace -eq '{Ps(domain)}') }} | Remove-DnsClientNrptRule -Force
Clear-DnsClientCache
";
        Setup.RunResult r;
        lock (Gate) r = Setup.PowerShell(script);
        return r.Status == 0 ? null : r.Output.Trim();
    }

    /// <summary>Removes every rule FiveT ever created (launch cleanup after a crash). Returns the namespaces removed.</summary>
    public static List<string> RemoveAll()
    {
        var script = $@"
$ErrorActionPreference = 'Stop'
$rules = @(Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{Mark}' }})
foreach ($r in $rules) {{ $r.Namespace }}
$rules | Remove-DnsClientNrptRule -Force
if ($rules.Count -gt 0) {{ Clear-DnsClientCache }}
";
        Setup.RunResult r;
        lock (Gate) r = Setup.PowerShell(script);
        if (r.Status != 0) return new List<string>();
        // Only real domain names: anything else in the captured output is noise, not a removed rule.
        return r.Output.Split('\n').Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('.') && IsValidDomain(l))
            .Distinct().ToList();
    }

    /// <summary>
    /// A VPN that carries all traffic: every name goes to its DNS servers (one NRPT rule for "."). The more
    /// specific rules of a Forti connection's domains still win for those domains. <paramref name="adapter"/>:
    /// also set as that adapter's own DNS servers (Xray's TUN, which nothing else configures).
    /// </summary>
    public static string? SetDefault(IReadOnlyList<string> servers, string? adapter)
    {
        if (!Paths.IsElevated) return "helper_needed";
        foreach (var server in servers)
            if (!System.Net.IPAddress.TryParse(server, out _)) return $"invalid nameserver {server}";
        var ns = string.Join(",", servers.Select(x => $"'{Ps(x)}'"));
        var script = $@"
$ErrorActionPreference = 'Stop'
Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{Mark}' -and $_.Namespace -eq '.' }} | Remove-DnsClientNrptRule -Force
Add-DnsClientNrptRule -Namespace '.' -NameServers {ns} -Comment '{Mark}' -DisplayName 'FiveT full tunnel' | Out-Null
{(adapter == null ? "" : $"Set-DnsClientServerAddress -InterfaceAlias '{Ps(adapter)}' -ServerAddresses {ns}")}
Clear-DnsClientCache
";
        Setup.RunResult r;
        lock (Gate) r = Setup.PowerShell(script);
        return r.Status == 0 ? null : r.Output.Trim();
    }

    /// <summary>Removes the rule <see cref="SetDefault"/> added: names go to the PC's own DNS again.</summary>
    public static string? ClearDefault()
    {
        var script = $@"
$ErrorActionPreference = 'Stop'
Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{Mark}' -and $_.Namespace -eq '.' }} | Remove-DnsClientNrptRule -Force
Clear-DnsClientCache
";
        Setup.RunResult r;
        lock (Gate) r = Setup.PowerShell(script);
        return r.Status == 0 ? null : r.Output.Trim();
    }

    public static bool IsValidDomain(string d) =>
        d.Length > 0 && !d.StartsWith('.') && !d.EndsWith('.') && !d.Contains("..")
        && d.All(ch => char.IsLetterOrDigit(ch) || ch == '.' || ch == '-');
}
