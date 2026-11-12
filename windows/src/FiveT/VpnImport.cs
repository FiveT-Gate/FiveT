using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using FiveT.Core;

namespace FiveT;

/// <summary>What an import needs of the saved connections (ConnectionStore; a plain list in tests).</summary>
public interface IConnectionList
{
    IReadOnlyList<Connection> Connections { get; }
    Connection Add(Connection c);
    void Remove(Guid id);
}

/// <summary>
/// Adding connections to the VPN tab, however they arrive: OpenVPN profiles, V2Ray links, Outline keys
/// (ss://, ssconf://), Xray JSON files, subscriptions (fetched), the saved servers of the Outline app, the
/// profiles of OpenVPN Connect, and whatever is dropped or pasted. Each import returns what it added and
/// one line per thing worth saying, for the message. A port of the Mac's VPNImport.swift.
/// </summary>
public static class VpnImport
{
    public sealed class Outcome
    {
        public List<Connection> Added = new();
        public List<string> Lines = new();
        public void Merge(Outcome o) { Added.AddRange(o.Added); Lines.AddRange(o.Lines); }
        public string Message => Lines.Count == 0 ? "Nothing to import." : string.Join("\n\n", Lines);
    }

    /// <summary>"Office", or "Office 2", "Office 3"… when the name is taken.</summary>
    public static string UniqueName(string name, IReadOnlyCollection<string> taken)
    {
        if (!taken.Contains(name)) return name;
        var n = 2;
        while (taken.Contains($"{name} {n}")) n++;
        return $"{name} {n}";
    }

    private static List<string> Names(IConnectionList store) => store.Connections.Select(c => c.Name).ToList();

    // MARK: V2Ray

    /// <summary>The configs as new connections; one already here (the same server, ID and transport) is skipped.</summary>
    public static Outcome AddV2Ray(IConnectionList store, IEnumerable<V2RayConfig.Imported> imps, string source)
    {
        var o = new Outcome();
        int already = 0, insecure = 0;
        var prefixed = new List<string>();
        var saved = store.Connections.Where(c => c.IsV2Ray).Select(c => c.V2RayOutbound).ToHashSet(StringComparer.Ordinal);
        foreach (var imp in imps)
        {
            var outbound = V2RayConfig.ToJson(imp.Outbound);
            if (!saved.Add(outbound)) { already++; continue; }
            var c = store.Add(V2RayConfig.ConnectionFrom(imp, Names(store)));
            o.Added.Add(c);
            if (imp.Insecure) insecure++;
            if (imp.Prefix) prefixed.Add(c.Name);
        }
        if (o.Added.Count > 0)
        {
            var names = string.Join(", ", o.Added.Take(5).Select(c => c.Name)) + (o.Added.Count > 5 ? ", …" : "");
            o.Lines.Add($"Added {o.Added.Count} {(o.Added.Count == 1 ? "server" : "servers")}: {names}.");
            Log.Shared.Write($"{o.Added.Count} V2Ray connection(s) imported from {source}");
        }
        if (already > 0) o.Lines.Add($"{already} {(already == 1 ? "was" : "were")} already here.");
        if (insecure > 0)
            o.Lines.Add($"{(insecure == 1 ? "One link asks" : $"{insecure} links ask")} to skip checking the server's certificate, which Xray no longer allows. If {(insecure == 1 ? "it does" : "they do")} not connect, ask your provider for a config with a valid certificate or Reality.");
        if (prefixed.Count > 0)
            o.Lines.Add($"{(prefixed.Count == 1 ? $"{prefixed[0]} uses" : $"{prefixed.Count} of these use")} Outline's prefix (a disguise for the first bytes of the connection), which FiveT does not send. {(prefixed.Count == 1 ? "It connects" : "They connect")} on networks that allow Shadowsocks; on one that blocks it, use the Outline app.");
        return o;
    }

    /// <summary>Links, a subscription body, or a JSON config, as text; https:// lines are fetched as subscriptions.</summary>
    public static async Task<Outcome> AddTextAsync(IConnectionList store, string text, string source, HttpMessageHandler? http = null)
    {
        var parsed = V2RayConfig.ImportText(text, source);
        var o = AddV2Ray(store, parsed.Configs, source);
        o.Lines.AddRange(parsed.Problems.Take(5).Select(p => $"Skipped {p}"));
        if (parsed.Problems.Count > 5) o.Lines.Add($"…and {parsed.Problems.Count - 5} more that could not be read.");
        foreach (var url in parsed.Subscriptions) o.Merge(await AddSubscriptionAsync(store, url, http));
        if (parsed.Configs.Count == 0 && parsed.Problems.Count == 0 && parsed.Subscriptions.Count == 0)
            o.Lines.Add("No V2Ray links (vless://, vmess://, trojan://, ss://, hysteria2://), Outline keys (ss://, ssconf://) or subscription address found.");
        return o;
    }

    /// <summary>Every config a subscription lists, each remembering the subscription so Refresh can update it.</summary>
    public static async Task<Outcome> AddSubscriptionAsync(IConnectionList store, Uri url, HttpMessageHandler? http = null)
    {
        try
        {
            var sub = await V2RayConfig.FetchSubscriptionAsync(url, http);
            var o = AddV2Ray(store, sub.Configs, $"subscription {url.Host}");
            o.Lines.Insert(0, $"Subscription {sub.Title ?? url.Host}: {sub.Configs.Count} {(sub.Configs.Count == 1 ? "server" : "servers")}.");
            if (sub.Problems.Count > 0) o.Lines.Add($"{sub.Problems.Count} could not be read.");
            return o;
        }
        catch (V2RayException e)
        {
            return new Outcome { Lines = { $"Subscription {url.Host}: {e.Message}" } };
        }
    }

    /// <summary>
    /// Fetches the subscription again: new servers are added, ones it no longer lists are removed (unless
    /// connected, <paramref name="isActive"/>), and the ones still listed stay as they are (with their settings).
    /// </summary>
    public static async Task<Outcome> RefreshAsync(IConnectionList store, string address, Func<Guid, bool> isActive, HttpMessageHandler? http = null)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var url)) return new Outcome { Lines = { "The subscription address is not valid." } };
        try
        {
            var sub = await V2RayConfig.FetchSubscriptionAsync(url, http);
            // An answer FiveT can read nothing of says nothing about which servers are gone.
            if (sub.Configs.Count == 0)
                return new Outcome { Lines = { $"Could not refresh the subscription: none of the {sub.Problems.Count} servers it lists now could be read. Nothing was changed." } };
            var listed = sub.Configs.Select(c => V2RayConfig.ToJson(c.Outbound)).ToHashSet(StringComparer.Ordinal);
            var gone = store.Connections.Where(c => c.IsV2Ray && c.V2RaySubscription == address && !listed.Contains(c.V2RayOutbound) && !isActive(c.Id)).ToList();
            foreach (var c in gone) store.Remove(c.Id);
            var saved = store.Connections.Where(c => c.IsV2Ray).Select(c => c.V2RayOutbound).ToHashSet(StringComparer.Ordinal);
            var fresh = sub.Configs.Where(c => !saved.Contains(V2RayConfig.ToJson(c.Outbound))).ToList();
            var o = AddV2Ray(store, fresh, $"subscription {url.Host}");
            o.Lines = new List<string> { $"Subscription {sub.Title ?? url.Host}: {sub.Configs.Count} servers now; {o.Added.Count} new, {gone.Count} removed." };
            Log.Shared.Write($"subscription {url.Host} refreshed: {sub.Configs.Count} listed, {o.Added.Count} new, {gone.Count} removed");
            return o;
        }
        catch (V2RayException e)
        {
            return new Outcome { Lines = { $"Could not refresh the subscription: {e.Message}" } };
        }
    }

    // MARK: Outline

    /// <summary>One server saved in the Outline app: the name Outline shows and the key behind it.</summary>
    public sealed record OutlineEntry(string Name, string Key);

    /// <summary>The Outline client for Windows keeps its window's storage here (an Electron app: Chromium's LevelDB files).</summary>
    public static string OutlineStorageFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Outline", "Local Storage", "leveldb");

    public static bool OutlineInstalled => Directory.Exists(Path.GetDirectoryName(Path.GetDirectoryName(OutlineStorageFolder))!);

    private static readonly Regex ServerList = new(@"\[\s*\{[^\[\]]*""accessKey""[^\[\]]*\}\s*\]", RegexOptions.CultureInvariant);

    /// <summary>
    /// The servers saved in the Outline app on this PC, read from its storage files without opening them for
    /// writing. Outline keeps the list (servers_v1: id, name and the key as it was typed) as one stored
    /// string; this finds that string in the files, as 8-bit or as UTF-16 text. Storage that Chromium has
    /// already compacted and compressed cannot be read this way: then the message says to copy the key.
    /// </summary>
    public static List<OutlineEntry> OutlineSavedServers(string? folder = null)
    {
        var dir = folder ?? OutlineStorageFolder;
        if (!Directory.Exists(dir))
            throw new V2RayException("FiveT found no data from the Outline app on this PC. Copy a key (ss://…) and use Paste Links, Keys or Subscription.");
        var result = new List<OutlineEntry>();
        // Newest first: the list is rewritten whole each time it changes, and the newest copy is the current one.
        var files = new DirectoryInfo(dir).GetFiles().Where(f => f.Extension is ".log" or ".ldb" && f.Length < 64_000_000)
            .OrderByDescending(f => f.LastWriteTimeUtc).ToList();
        foreach (var f in files)
        {
            byte[] bytes;
            try
            {
                using var fs = new FileStream(f.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                bytes = new byte[fs.Length];
                fs.ReadExactly(bytes);
            }
            catch (Exception e)
            {
                Log.Shared.Write($"Outline import: {f.Name} not readable: {e.Message}", LogLevel.Error);
                continue;
            }
            var found = new List<OutlineEntry>();
            foreach (var text in new[] { Encoding.Latin1.GetString(bytes), Encoding.Unicode.GetString(bytes), Encoding.Unicode.GetString(bytes, Math.Min(1, bytes.Length), bytes.Length - Math.Min(1, bytes.Length)) })
            {
                // The last complete list in the file is the latest one written to it.
                var m = ServerList.Matches(text);
                if (m.Count > 0) found = OutlineEntries(m[^1].Value);
                if (found.Count > 0) break;
            }
            Log.Shared.Write($"Outline import: {f.Name}: {found.Count} saved server(s)");
            if (found.Count > 0) { result = found; break; }
        }
        if (result.Count == 0)
            throw new V2RayException("FiveT found no saved servers it can read in Outline's data. Copy a key (ss://…) from Outline and use Paste Links, Keys or Subscription.");
        return result;
    }

    /// <summary>The servers in Outline's stored list: [{id, name, accessKey}] (the first version of the app kept [{name, host, port, method, password}]).</summary>
    public static List<OutlineEntry> OutlineEntries(string text)
    {
        var open = text.IndexOf('[');
        var close = text.LastIndexOf(']');
        if (open < 0 || close <= open || Json.Parse(text[open..(close + 1)]) is not JsonArray list) return new List<OutlineEntry>();
        var entries = new List<OutlineEntry>();
        foreach (var d in list.OfType<JsonObject>())
        {
            var name = Json.Str(d["name"])?.Trim() ?? "";
            if (Json.Str(d["accessKey"])?.Trim() is { Length: > 0 } key)
            {
                if (entries.All(e => e.Key != key)) entries.Add(new OutlineEntry(name, key));
                continue;
            }
            var host = Json.Str(d["host"])?.Trim() ?? "";
            var method = Json.Str(d["method"])?.Trim();
            var port = Json.Int(d["port"]) ?? (int.TryParse(Json.Str(d["port"]), out var p) ? p : 0);
            if (d["accessKey"] != null || host.Length == 0 || method == null || Json.Str(d["password"]) is not { } password || port == 0) continue;
            var user = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{method}:{password}")).Replace('+', '-').Replace('/', '_').TrimEnd('=');
            entries.Add(new OutlineEntry(name, $"ss://{user}@{(host.Contains(':') ? $"[{host}]" : host)}:{port}/?outline=1"));
        }
        return entries;
    }

    /// <summary>The servers saved in the Outline app on this PC, under the names they have there.</summary>
    public static async Task<Outcome> AddOutlineAsync(IConnectionList store, string? folder = null, HttpMessageHandler? http = null)
    {
        try { return await AddOutlineAsync(store, OutlineSavedServers(folder), "Outline", http); }
        catch (V2RayException e) { return new Outcome { Lines = { e.Message } }; }
    }

    /// <summary>An ss:// key is one server; an ssconf:// (or https://) key is fetched, and remembered so Refresh can ask it again.</summary>
    public static async Task<Outcome> AddOutlineAsync(IConnectionList store, IReadOnlyList<OutlineEntry> entries, string source, HttpMessageHandler? http = null)
    {
        var imps = new List<V2RayConfig.Imported>();
        var skipped = new List<string>();
        foreach (var e in entries)
        {
            var label = e.Name.Trim().Length > 0 ? e.Name : "a server";
            var low = e.Key.ToLowerInvariant();
            try
            {
                if (low.StartsWith("ss://", StringComparison.Ordinal))
                {
                    var imp = V2RayConfig.Parse(e.Key);
                    if (e.Name.Trim().Length > 0) imp.Name = e.Name;
                    imp.Link = V2RayConfig.MarkedAsOutline(imp.Link);   // it came from Outline: the list says so
                    imps.Add(imp);
                }
                else if (low.StartsWith("ssconf://", StringComparison.Ordinal) || low.StartsWith("https://", StringComparison.Ordinal))
                {
                    var url = V2RayConfig.DynamicKeyUrl(e.Key) ?? throw new V2RayException("its key address is not valid.");
                    var configs = (await V2RayConfig.FetchSubscriptionAsync(url, http)).Configs;
                    if (configs.Count == 1 && e.Name.Trim().Length > 0) configs[0].Name = e.Name;
                    imps.AddRange(configs);
                }
                else skipped.Add($"{label}: this kind of key is not supported (FiveT reads ss:// and ssconf:// keys).");
            }
            catch (V2RayException ex)
            {
                skipped.Add($"{label}: {ex.Message}");
            }
        }
        var o = AddV2Ray(store, imps, source);
        o.Lines.AddRange(skipped.Take(5).Select(s => $"Skipped {s}"));
        if (skipped.Count > 5) o.Lines.Add($"…and {skipped.Count - 5} more that could not be read.");
        if (entries.Count == 0) o.Lines.Add("Outline has no saved servers.");
        return o;
    }

    // MARK: OpenVPN

    /// <summary>
    /// OpenVPN profiles: each becomes a connection (its certificates and keys inside it). A profile that is
    /// already here is skipped; what FiveT left out of a profile is listed. <paramref name="names"/>: the name
    /// each file has in the app it came from, by the file's name without ".ovpn" (OpenVPN Connect).
    /// </summary>
    public static Outcome AddOpenVpn(IConnectionList store, IEnumerable<string> paths, string source, IReadOnlyDictionary<string, string>? names = null)
    {
        var o = new Outcome();
        var any = false;
        foreach (var path in paths)
        {
            any = true;
            try
            {
                var imp = OpenVpnProfile.ImportProfile(path);
                // OpenVPN Connect saves its copies under a number: the name its user sees (or gave) is the
                // one to keep, over the profile's own comments and over its server's name.
                if (names != null && names.TryGetValue(Path.GetFileNameWithoutExtension(path), out var given)) imp.Name = given;
                AddOpenVpn(store, imp, source, o);
            }
            catch (OpenVpnProfileException e)
            {
                o.Lines.Add($"{Path.GetFileName(path)}: {e.Message}");
            }
        }
        if (!any) o.Lines.Add("No OpenVPN profiles found.");
        return o;
    }

    /// <summary>A profile that was pasted as text (no folder to read separate files from).</summary>
    public static Outcome AddOpenVpnText(IConnectionList store, string text, string name, string source)
    {
        var o = new Outcome();
        try { AddOpenVpn(store, OpenVpnProfile.ImportProfile(text, name, null), source, o); }
        catch (OpenVpnProfileException e) { o.Lines.Add(e.Message); }
        return o;
    }

    private static void AddOpenVpn(IConnectionList store, OpenVpnProfile.Imported imp, string source, Outcome o)
    {
        if (store.Connections.FirstOrDefault(c => c.IsOpenVpn && c.OvpnProfile == imp.Text) is { } same)
        {
            o.Lines.Add($"{same.Name} is already here.");
            return;
        }
        var c = store.Add(OpenVpnProfile.ConnectionFrom(imp, Names(store)));
        o.Added.Add(c);
        var line = $"Added {c.Name} ({c.Host}:{c.Port}).";
        if (imp.Dropped.Count > 0) line += $" Left out: {string.Join("; ", imp.Dropped)}.";
        if (OpenVpnProfile.NeedsLogin(imp.Text) && c.Password.Length == 0) line += " Enter its username and password.";
        if (c.OtpMode == OtpMode.Separate && c.TotpSecret.Length == 0) line += " Its server asks for a one-time code: enter the secret.";
        o.Lines.Add(line);
        Log.Shared.Write($"[{c.Name}] OpenVPN profile imported from {source} ({c.Host}:{c.Port})");
    }

    /// <summary>The profiles OpenVPN Connect holds on this PC, under the names they have there.</summary>
    public static Outcome AddOpenVpnConnect(IConnectionList store, string? folder = null, string? stateFile = null)
    {
        var files = OpenVpnProfile.OpenVpnConnectProfiles(folder);
        if (files.Count == 0) return new Outcome { Lines = { "FiveT found no profiles from OpenVPN Connect on this PC." } };
        return AddOpenVpn(store, files, "OpenVPN Connect", OpenVpnProfile.OpenVpnConnectNames(stateFile));
    }

    // MARK: Files and text, by what they hold

    /// <summary>Dropped or chosen files: an OpenVPN profile, an Xray JSON config, or text with V2Ray links.</summary>
    public static async Task<Outcome> AddFilesAsync(IConnectionList store, IEnumerable<string> paths, HttpMessageHandler? http = null)
    {
        var o = new Outcome();
        foreach (var path in paths)
        {
            if (IsOpenVpnProfile(path))
            {
                o.Merge(AddOpenVpn(store, new[] { path }, "a file"));
                continue;
            }
            // The size is asked before the file is read: a huge file dropped by mistake is refused, not loaded.
            string? text = null;
            try
            {
                if (new FileInfo(path).Length < 4_000_000) text = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(path)).TrimStart('\uFEFF');
            }
            catch (Exception) { }
            if (text == null)
            {
                o.Lines.Add($"{Path.GetFileName(path)}: not a VPN config FiveT can read.");
                continue;
            }
            o.Merge(await AddTextAsync(store, text, Path.GetFileName(path), http));
        }
        return o;
    }

    /// <summary>Pasted text: an OpenVPN profile when it reads like one, otherwise links, keys, a subscription or a JSON config.</summary>
    public static Task<Outcome> AddPastedAsync(IConnectionList store, string text, HttpMessageHandler? http = null) =>
        LooksLikeOpenVpn(text) ? Task.FromResult(AddOpenVpnText(store, text, "", "pasted text")) : AddTextAsync(store, text, "Pasted config", http);

    /// <summary>.ovpn, or a .conf/.txt that reads like one ("remote" lines).</summary>
    public static bool IsOpenVpnProfile(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".ovpn") return true;
        if (ext is not (".conf" or ".txt" or "")) return false;
        try
        {
            return new FileInfo(path).Length < 4_000_000 && LooksLikeOpenVpn(File.ReadAllText(path));
        }
        catch (Exception) { return false; }
    }

    /// <summary>Has a "remote …" line, and is not a list of V2Ray links or subscription addresses (a web address in a comment is fine).</summary>
    public static bool LooksLikeOpenVpn(string text)
    {
        var lines = text.Split('\n', '\r').Select(l => l.Trim(' ', '\t')).Where(l => l.Length > 0).ToList();
        return lines.Any(l => l.StartsWith("remote ", StringComparison.Ordinal))
               && !lines.Any(l => V2RayConfig.IsLink(l) || l.StartsWith("http", StringComparison.OrdinalIgnoreCase) || l.StartsWith("ssconf://", StringComparison.OrdinalIgnoreCase));
    }
}
