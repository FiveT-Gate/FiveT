using System.Xml;
using Microsoft.Win32;

namespace FiveT;

/// <summary>A profile as FortiClient describes it, before it becomes a connection.</summary>
/// <param name="Server">"host", "host:port", "host/realm", "host:port/realm"; several may be joined by ";".</param>
/// <param name="IsSsl">False for an IPsec profile: listed, never imported (openconnect's fortinet mode is SSL-VPN).</param>
public sealed record FortiClientProfile(string Name, string Server, int? Port, string Username, bool IsSsl);

/// <summary>
/// Reads FortiClient's VPN profiles so they can become FiveT connections, like the Mac app's import
/// (1.4.0, FortiClientImport.swift). Two sources:
///
/// - the profiles FortiClient keeps on this PC, in the registry: one key per connection under
///   ...\Fortinet\FortiClient\Sslvpn\Tunnels\&lt;name&gt; (HKLM for machine-wide ones, HKCU for the
///   user's own, where a remembered user name also sits) and ...\IPSec\Tunnels for IPsec;
/// - a configuration backup (FortiClient → Settings → Backup), an XML .conf file. Passwords in it
///   are encrypted and stay behind; a backup made with a password is encrypted as a whole and refused.
///
/// Name, gateway, port, realm (from "host:port/realm") and user name come across — never passwords.
/// </summary>
public static class FortiClientImport
{
    private const string Root = @"SOFTWARE\Fortinet\FortiClient";

    public static List<FortiClientProfile> ReadRegistry()
    {
        var found = new Dictionary<(string, bool), FortiClientProfile>();
        foreach (var (sub, ssl) in new[] { (@"\Sslvpn\Tunnels", true), (@"\IPSec\Tunnels", false) })
        foreach (var (hive, view) in new[]
                 {
                     (RegistryHive.LocalMachine, RegistryView.Registry64), (RegistryHive.LocalMachine, RegistryView.Registry32),
                     (RegistryHive.CurrentUser, RegistryView.Registry64), (RegistryHive.CurrentUser, RegistryView.Registry32),
                 })
        {
            try
            {
                using var root = RegistryKey.OpenBaseKey(hive, view);
                using var tunnels = root.OpenSubKey(Root + sub);
                if (tunnels == null) continue;
                foreach (var name in tunnels.GetSubKeyNames())
                {
                    using var k = tunnels.OpenSubKey(name);
                    if (k == null) continue;
                    // The same connection appears in HKLM (the gateway) and HKCU (the saved user name).
                    found.TryGetValue((name.ToLowerInvariant(), ssl), out var earlier);
                    var server = Value(k, "Server") ?? Value(k, "remote_gw") ?? earlier?.Server ?? "";
                    var user = Value(k, "username") ?? earlier?.Username ?? "";
                    if (server.Length == 0 && earlier == null && ssl) continue;
                    found[(name.ToLowerInvariant(), ssl)] = new FortiClientProfile(name, server, PortValue(k) ?? earlier?.Port, user, ssl);
                }
            }
            catch (Exception e)
            {
                Log.Shared.Write($"FortiClient import: could not read {hive} ({view}): {e.Message}", LogLevel.Debug);
            }
        }
        return found.Values.OrderBy(p => !p.IsSsl).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string? Value(RegistryKey k, string name)
    {
        // Value names differ in case between FortiClient versions ("username", "UserName").
        var actual = k.GetValueNames().FirstOrDefault(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase));
        return actual != null && k.GetValue(actual) is string s && s.Trim().Length > 0 ? s.Trim() : null;
    }

    /// <summary>
    /// A port kept apart from the server, as the Mac's profile has (ServerPort, used unless EnableCustomPort says
    /// no; the default is yes). A port written into the server ("host:10443") is read from there instead and wins,
    /// like the Mac's parseServer. Registry numbers are DWORDs, but some versions write text.
    /// </summary>
    private static int? PortValue(RegistryKey k)
    {
        var names = k.GetValueNames();
        object? Get(string name) => names.FirstOrDefault(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase)) is { } actual ? k.GetValue(actual) : null;
        if (Get("EnableCustomPort") is { } custom && (custom is int i ? i == 0 : custom is string t && (t.Trim() == "0" || t.Trim().Equals("false", StringComparison.OrdinalIgnoreCase))))
            return null;
        var raw = Get("ServerPort") ?? Get("Port");
        var port = raw switch { int whole => whole, string text when int.TryParse(text.Trim(), out var parsed) => parsed, _ => 0 };
        return ValidPort(port) ? port : null;
    }

    private static bool ValidPort(int port) => port is >= 1 and <= 65535;

    /// <summary>
    /// FortiClient backup: &lt;forticlient_configuration&gt;&lt;vpn&gt;&lt;sslvpn&gt;&lt;connections&gt;&lt;connection&gt;…
    /// (and &lt;ipsecvpn&gt;, which is listed but not imported). Throws with a message for the user.
    /// </summary>
    public static List<FortiClientProfile> ReadBackup(string path)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception e) { throw new InvalidDataException($"Could not read the file: {e.Message}"); }
        var head = text.TrimStart();
        // FortiClient writes an encrypted backup as base64-like text without any XML.
        if (head.Length > 0 && !head.Contains('<'))
            throw new InvalidDataException("This backup is encrypted. In FortiClient, make the backup again without a password, then import that file.");
        if (!(head.Contains("<forticlient_configuration", StringComparison.OrdinalIgnoreCase)
              || head.Contains("<sslvpn", StringComparison.OrdinalIgnoreCase) || head.Contains("<vpn>", StringComparison.OrdinalIgnoreCase)
              || head.StartsWith("<?xml", StringComparison.Ordinal)))
            throw new InvalidDataException("This is not a FortiClient configuration (expected a FortiClient backup .conf or .xml).");

        var profiles = new List<FortiClientProfile>();
        var path2 = new List<string>();
        var current = new Dictionary<string, string>();
        var sb = new System.Text.StringBuilder();
        try
        {
            using var reader = XmlReader.Create(new StringReader(text), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        var n = reader.LocalName.ToLowerInvariant();
                        sb.Clear();
                        if (n == "connection") current = new Dictionary<string, string>();
                        if (reader.IsEmptyElement)
                        {
                            if (path2.Count >= 1 && path2[^1] == "connection") current[n] = "";
                        }
                        else path2.Add(n);
                        break;
                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                        sb.Append(reader.Value);
                        break;
                    case XmlNodeType.EndElement:
                        var end = reader.LocalName.ToLowerInvariant();
                        if (path2.Count >= 2 && path2[^2] == "connection") current[end] = sb.ToString().Trim();
                        if (end == "connection")
                        {
                            var ssl = path2.Contains("sslvpn");
                            if (ssl || path2.Contains("ipsecvpn"))
                                profiles.Add(new FortiClientProfile(
                                    current.GetValueOrDefault("name") ?? "Imported connection",
                                    current.GetValueOrDefault("server") ?? current.GetValueOrDefault("remote_gw") ?? "",
                                    int.TryParse(current.GetValueOrDefault("port"), out var p) ? p : null,
                                    current.GetValueOrDefault("username") ?? current.GetValueOrDefault("user") ?? "",
                                    ssl));
                        }
                        if (path2.Count > 0) path2.RemoveAt(path2.Count - 1);
                        sb.Clear();
                        break;
                }
            }
        }
        catch (XmlException e)
        {
            throw new InvalidDataException($"The file is not valid XML ({e.Message}).");
        }
        return profiles;
    }

    /// <summary>"host:10443/realm" → (host, port, realm). Several servers joined by ";" → the first one.</summary>
    public static (string Host, int? Port, string Realm) ParseServer(string raw)
    {
        var s = raw.Split(';')[0].Trim();
        foreach (var prefix in new[] { "https://", "http://" })
            if (s.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) s = s[prefix.Length..];
        var realm = "";
        var slash = s.IndexOf('/');
        if (slash >= 0)
        {
            realm = s[(slash + 1)..].Trim('/', ' ');
            s = s[..slash];
        }
        int? port = null;
        var colon = s.LastIndexOf(':');
        if (colon >= 0 && s.Count(ch => ch == ':') == 1 && int.TryParse(s[(colon + 1)..], out var p))
        {
            port = p;
            s = s[..colon];
        }
        return (s, port, realm);
    }

    public static Connection ToConnection(FortiClientProfile p)
    {
        // The Mac's order: the port in the server text, else the profile's own port field, else 443.
        var (host, port, realm) = ParseServer(p.Server);
        var separate = p.Port is { } sp && ValidPort(sp) ? sp : (int?)null;
        return new Connection { Name = p.Name, Host = host, Port = port ?? separate ?? 443, Realm = realm, Username = p.Username };
    }

    /// <summary>The saved connection this profile already is (same host, port, realm and user), if any.</summary>
    public static Connection? AlreadySaved(FortiClientProfile p, IEnumerable<Connection> saved)
    {
        var c = ToConnection(p);
        return saved.FirstOrDefault(x => x.Host.Equals(c.Host, StringComparison.OrdinalIgnoreCase) && x.Port == c.Port
                                         && x.Realm.Equals(c.Realm, StringComparison.OrdinalIgnoreCase)
                                         // A profile without a username is the gateway already saved, not a second account.
                                         && (c.Username.Length == 0 || x.Username.Equals(c.Username, StringComparison.OrdinalIgnoreCase)));
    }

    /// <summary>The connections to add for the chosen profiles: a name already in use gets " (FortiClient)".</summary>
    public static List<Connection> Merge(IEnumerable<FortiClientProfile> chosen, IReadOnlyList<Connection> saved)
    {
        var added = new List<Connection>();
        foreach (var p in chosen)
        {
            if (!p.IsSsl) continue;
            var c = ToConnection(p);
            if (c.Host.Length == 0 || AlreadySaved(p, saved.Concat(added)) != null) continue;
            if (saved.Concat(added).Any(x => x.Name.Equals(c.Name, StringComparison.OrdinalIgnoreCase))) c.Name += " (FortiClient)";
            added.Add(c);
        }
        return added;
    }
}
