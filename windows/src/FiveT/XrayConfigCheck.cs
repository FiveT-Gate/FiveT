using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using FiveT.Core;

namespace FiveT;

/// <summary>
/// The check every Xray config passes before FiveT starts Xray with it (the Mac helper's xray-run check,
/// Setup.swift). Xray runs as administrator, and the server settings come from a file any program of the
/// user can change, so the config may only do what a VPN needs: the TUN as the one way in, servers, direct,
/// block and DNS as the ways out, and nothing anywhere that names a file (logs, certificates, TLS key logs,
/// address lists other than FiveT's own) or opens a port (api, metrics, other inbounds).
///
/// Xray (Go) matches key names ignoring case, even across some non-ASCII letters ("maſterKeyLog" is
/// masterKeyLog to it), and reads comments: so keys must be plain ASCII and unique ignoring case, and Xray
/// gets the config as this check re-wrote it, never the text that came in.
/// </summary>
public static class XrayConfigCheck
{
    private static readonly string[] TopLevel = { "log", "inbounds", "outbounds", "routing", "dns", "policy" };
    private static readonly string[] LogKeys = { "loglevel", "dnsLog", "maskAddress" };
    private static readonly string[] InboundKeys = { "tag", "protocol", "settings", "sniffing" };
    private static readonly string[] OutboundProtocols = { "vless", "vmess", "trojan", "shadowsocks", "hysteria", "freedom", "blackhole", "dns" };
    private static readonly Regex PlainKey = new("^[A-Za-z0-9_.:-]+$", RegexOptions.CultureInvariant);
    private static readonly Regex ExternalList = new("^(ext|ext-ip|ext-domain|ext-site):", RegexOptions.CultureInvariant);
    private static readonly Regex BuiltInList = new("^(geoip|geosite):", RegexOptions.CultureInvariant);

    /// <summary>
    /// What the config holds that FiveT does not allow (empty when it may run), and the config re-written
    /// from what was parsed: that text, not the input, is what Xray is given.
    /// </summary>
    public static (List<string> Problems, string? Rewritten) Check(string text)
    {
        // Anything the check itself trips over (the same key twice in one object, say) refuses the config.
        try { return CheckCore(text); }
        catch (Exception) { return (new List<string> { "a config FiveT could not check" }, null); }
    }

    private static (List<string> Problems, string? Rewritten) CheckCore(string text)
    {
        var bad = new List<string>();
        void No(string w) { if (!bad.Contains(w)) bad.Add(w); }
        JsonNode? parsed;
        try { parsed = JsonNode.Parse(text); }   // strict: no comments, no trailing commas
        catch (Exception) { return (new List<string> { "a config that is not JSON" }, null); }
        if (parsed is not JsonObject c) return (new List<string> { "a config that is not a JSON object" }, null);

        void Only(JsonNode? o, string[] allowed, string where)
        {
            if (o == null) return;
            if (o is not JsonObject obj) { No(where); return; }
            foreach (var (k, _) in obj) if (!allowed.Contains(k)) No(where + k);
        }
        Only(c, TopLevel, "");
        Only(c["log"], LogKeys, "log.");

        if (c["inbounds"] is JsonArray inbounds)
        {
            foreach (var i in inbounds)
            {
                if (i is not JsonObject inbound || Json.Str(inbound["protocol"]) != "tun")
                {
                    No("inbound " + (Json.Str((i as JsonObject)?["protocol"]) ?? "null"));
                    continue;
                }
                Only(inbound, InboundKeys, "tun inbound ");
                var name = (inbound["settings"] as JsonObject)?["name"];
                if (name != null && Json.Str(name) != V2RayConfig.TunName) No("tun name " + (Json.Str(name) ?? name.ToJsonString()));
            }
        }
        else No("inbound null");

        if (c["outbounds"] is JsonArray outbounds)
        {
            foreach (var o in outbounds)
                if (o is not JsonObject outbound || !OutboundProtocols.Contains(Json.Str(outbound["protocol"]) ?? ""))
                    No("outbound " + (Json.Str((o as JsonObject)?["protocol"]) ?? "null"));
        }
        else No("outbound null");

        void Walk(JsonNode? v)
        {
            switch (v)
            {
                case JsonArray list:
                    foreach (var x in list) Walk(x);
                    break;
                case JsonObject obj:
                {
                    var seen = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var (k, x) in obj)
                    {
                        if (!PlainKey.IsMatch(k)) { No("the key " + Json.ToCompact(JsonValue.Create(k))); continue; }
                        var l = k.ToLowerInvariant();
                        if (!seen.Add(l)) No("two keys " + k);
                        if (l.EndsWith("file", StringComparison.Ordinal) || l == "masterkeylog") No(k);
                        Walk(x);
                    }
                    break;
                }
                default:
                    if (Json.Str(v) is { } s)
                    {
                        // Address and site lists Xray reads from disk: only the one FiveT ships.
                        var r = s.TrimStart('!').ToLowerInvariant();
                        var refused = ExternalList.IsMatch(r) ? r.Split(':').ElementAtOrDefault(1) != V2RayConfig.GeoFile : BuiltInList.IsMatch(r);
                        if (refused) No(s);
                    }
                    break;
            }
        }
        Walk(c);
        return bad.Count > 0 ? (bad, null) : (bad, V2RayConfig.ToJson(c));
    }
}
