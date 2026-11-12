using System.Text.RegularExpressions;

namespace FiveT;

/// <summary>Which changes of a switch lower the protection FiveT gives, so an assistant or the command line may only make them with the user's yes (the Mac's 1.21.1).</summary>
public static class Protection
{
    /// <summary>
    /// What <paramref name="changes"/> (setting name, value now, value asked for) would lower, each with the sentence the user is asked about.
    /// A change to the value it already has lowers nothing, and turning protection on or changing another switch needs no question.
    /// </summary>
    public static List<(string Key, string Text)> Lowering(IEnumerable<(string Key, bool Current, bool Wanted)> changes)
    {
        var found = new List<(string, string)>();
        foreach (var (key, current, wanted) in changes)
        {
            if (current == wanted) continue;
            switch (key, wanted)
            {
                case ("kill_switch", false): found.Add((key, "turn the Kill Switch off")); break;
                case ("apps_only", true): found.Add((key, "put only the chosen apps on the VPN (the rest of this PC stops using it)")); break;
                case ("bypass_iranian_websites", true): found.Add((key, "send Iranian websites around the VPN")); break;
            }
        }
        return found;
    }
}

/// <summary>
/// The rules of "Use the VPN for Chosen Apps Only" (the Mac's apps-only mode, 1.21) and of "Switch to Another VPN if One
/// Stops Working" (1.20) that need no window and no tunnel.
/// </summary>
public static class VpnApps
{
    /// <summary>A program on a drive or a network share, by full path: what the list of chosen apps may hold.</summary>
    private static readonly Regex AppPath = new(@"^(?:[A-Za-z]:\\|\\\\[^\\/:*?""<>|\r\n]+\\[^\\/:*?""<>|\r\n]+\\)[^:*?""<>|\r\n]{1,400}\.exe$",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static bool IsAppPath(string? path) =>
        path != null && AppPath.IsMatch(path) && !path.Split('\\').Contains("..") && !path.Contains("\\.\\");

    /// <summary>The list as it may be kept: only full paths of programs, each once (ignoring case), in order, at most 50.</summary>
    public static List<string> Clean(IEnumerable<string?>? paths) =>
        (paths ?? Enumerable.Empty<string?>()).Select(p => p?.Trim()).Where(IsAppPath).Select(p => p!)
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(50).ToList();

    /// <summary>"chrome" for C:\Program Files\Google\Chrome\Application\chrome.exe.</summary>
    public static string Name(string path) => Path.GetFileNameWithoutExtension(path);

    /// <summary>What Chromium and Electron apps (Chrome, Edge, Claude, Slack, VS Code…) take as their proxy; with no other way out, they have no internet when the proxy is down.</summary>
    public static string ProxyArguments(int port) => $"--proxy-server=socks5://127.0.0.1:{port}";

    /// <summary>For programs that read the environment instead.</summary>
    public static IReadOnlyDictionary<string, string> ProxyEnvironment(int port) =>
        new Dictionary<string, string> { ["ALL_PROXY"] = $"socks5h://127.0.0.1:{port}" };

    /// <summary>
    /// The VPN that takes over from <paramref name="current"/>: the next VPN (OpenVPN, V2Ray, Outline) in the list, going
    /// round to the first at the end. Null when there is no other VPN to go to.
    /// </summary>
    public static Connection? NextVpn(IEnumerable<Connection> all, Guid current)
    {
        var vpns = all.Where(c => c.IsOtherVpn).ToList();
        var i = vpns.FindIndex(c => c.Id == current);
        return i < 0 || vpns.Count < 2 ? null : vpns[(i + 1) % vpns.Count];
    }
}
