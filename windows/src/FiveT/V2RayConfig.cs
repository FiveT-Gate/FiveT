using System.Net;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT;

public sealed class V2RayException : Exception
{
    public V2RayException(string message) : base(message) { }
}

/// <summary>
/// V2Ray connections, run by Xray. Share links (vless:// vmess:// trojan:// ss:// hysteria2://), Xray JSON
/// files and subscriptions each become a connection. A connection keeps only its server, as an Xray
/// outbound (<see cref="Connection.V2RayOutbound"/>); FiveT puts it into its own config (TUN, routing, DNS)
/// at connect time and checks the result (<see cref="XrayConfigCheck"/>), so nothing an import brings
/// decides what runs as administrator. A port of the Mac's V2RayConfig.swift.
/// </summary>
public static class V2RayConfig
{
    public sealed class Imported
    {
        public string Name = "";
        /// <summary>The share link it came from; empty for a JSON config.</summary>
        public string Link = "";
        public JsonObject Outbound = new();
        public string Host = "";
        public int Port;
        /// <summary>The subscription it came from, to refresh it later.</summary>
        public string Subscription = "";
        /// <summary>The link asks to skip the server's certificate check, which Xray no longer does.</summary>
        public bool Insecure;
        /// <summary>An Outline key with a prefix (bytes Outline puts in front of the first packet so a firewall does
        /// not see Shadowsocks). Xray does not send it: the server still answers, but a network that blocks plain
        /// Shadowsocks will not let it through.</summary>
        public bool Prefix;
    }

    /// <summary>The server protocols FiveT runs (the config check accepts the same ones).</summary>
    public static readonly HashSet<string> Protocols = new(StringComparer.Ordinal) { "vless", "vmess", "trojan", "shadowsocks", "hysteria" };
    public static readonly string[] Schemes = { "vless", "vmess", "trojan", "ss", "hysteria2", "hy2" };

    // MARK: Share links

    public static bool IsLink(string s)
    {
        var i = s.IndexOf("://", StringComparison.Ordinal);
        return i > 0 && Schemes.Contains(s[..i].ToLowerInvariant());
    }

    /// <summary>One share link as an Xray outbound.</summary>
    public static Imported Parse(string raw)
    {
        var imp = ParseLink(raw);
        var low = raw.ToLowerInvariant();
        imp.Insecure = new[] { "allowinsecure=1", "allowinsecure=true", "insecure=1", "insecure=true", "\"allowinsecure\":\"1\"", "\"allowinsecure\":true" }.Any(low.Contains)
                       || (low.StartsWith("vmess://", StringComparison.Ordinal)
                           && (DecodeBase64(raw[8..].Split('#')[0])?.Replace(" ", "").ToLowerInvariant().Contains("\"allowinsecure\":\"1\"") ?? false));
        return imp;
    }

    private static Imported ParseLink(string raw)
    {
        var s = raw.Trim();
        var i = s.IndexOf("://", StringComparison.Ordinal);
        if (i < 0) throw new V2RayException("Not a V2Ray link.");
        var scheme = s[..i].ToLowerInvariant();
        var body = s[(i + 3)..];
        switch (scheme)
        {
            case "vmess":
                if (DecodeBase64(body.Split('#')[0]) is { } json && Json.Parse(json) is JsonObject obj) return VmessJson(obj, s);
                return UrlStyle("vmess", body, s);
            case "vless": return UrlStyle("vless", body, s);
            case "trojan": return UrlStyle("trojan", body, s);
            case "ss": return Shadowsocks(body, s);
            case "hysteria2" or "hy2": return UrlStyle("hysteria", body, s);
            default: throw new V2RayException($"{scheme}:// links are not supported.");
        }
    }

    /// <summary>The parts of "user@host:port/?query#name", decoded. Done by hand: names are often raw Persian text or emoji.</summary>
    private sealed class LinkParts
    {
        public string User = "", Host = "", Name = "";
        public int Port;
        public Dictionary<string, string> Query = new(StringComparer.Ordinal);
    }

    private static string Unescape(string s)
    {
        try { return Uri.UnescapeDataString(s); }
        catch (Exception) { return s; }
    }

    private static string? NonEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;
    private static string? Q(Dictionary<string, string> q, string key) => q.TryGetValue(key, out var v) ? NonEmpty(v) : null;

    private static LinkParts Split(string body)
    {
        var p = new LinkParts();
        var rest = body;
        var h = rest.IndexOf('#');
        if (h >= 0)
        {
            p.Name = Unescape(rest[(h + 1)..]).Trim();
            rest = rest[..h];
        }
        var q = rest.IndexOf('?');
        if (q >= 0)
        {
            foreach (var pair in rest[(q + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = pair.IndexOf('=');
                var k = eq < 0 ? pair : pair[..eq];
                if (k.Length == 0) continue;
                p.Query[k] = eq < 0 ? "" : Unescape(pair[(eq + 1)..]);
            }
            rest = rest[..q];
        }
        // The path starts at the first "/" after the "@": an older Shadowsocks link keeps its user part
        // in plain base64, which can hold a "/" itself.
        var at = rest.LastIndexOf('@');
        var slash = rest.IndexOf('/', Math.Max(at, 0));
        if (slash >= 0) rest = rest[..slash];
        var hostPort = rest;
        at = rest.LastIndexOf('@');
        if (at >= 0)
        {
            p.User = Unescape(rest[..at]);
            hostPort = rest[(at + 1)..];
        }
        if (hostPort.StartsWith('[') && hostPort.IndexOf(']') is var close and > 0)
        {
            p.Host = hostPort[1..close];
            var after = hostPort[(close + 1)..];
            if (after.StartsWith(':')) int.TryParse(after[1..], out p.Port);
        }
        else if (hostPort.LastIndexOf(':') is var colon and >= 0)
        {
            p.Host = hostPort[..colon];
            int.TryParse(hostPort[(colon + 1)..], out p.Port);
        }
        else p.Host = hostPort;
        if (p.Host.Length == 0 || p.Port is < 1 or > 65535) throw new V2RayException("The link has no server address and port.");
        return p;
    }

    private static JsonObject Server(string host, int port) => new() { ["address"] = host, ["port"] = port };

    private static Imported UrlStyle(string proto, string body, string link)
    {
        var p = Split(body);
        var q = p.Query;
        var o = new JsonObject { ["protocol"] = proto };
        string Type() => q.TryGetValue("type", out var t) ? t : "tcp";
        string Security(string fallback) => q.TryGetValue("security", out var t) ? t : fallback;
        switch (proto)
        {
            case "vless":
            {
                if (p.User.Length == 0) throw new V2RayException("The VLESS link has no user ID.");
                var user = new JsonObject { ["id"] = p.User, ["encryption"] = Q(q, "encryption") ?? "none" };
                if (Q(q, "flow") is { } flow) user["flow"] = flow;
                var server = Server(p.Host, p.Port);
                server["users"] = new JsonArray(user);
                o["settings"] = new JsonObject { ["vnext"] = new JsonArray(server) };
                o["streamSettings"] = Stream(q, Type(), Security("none"));
                break;
            }
            case "vmess":
            {
                if (p.User.Length == 0) throw new V2RayException("The VMess link has no user ID.");
                var user = new JsonObject { ["id"] = p.User, ["security"] = Q(q, "encryption") ?? "auto" };
                var server = Server(p.Host, p.Port);
                server["users"] = new JsonArray(user);
                o["settings"] = new JsonObject { ["vnext"] = new JsonArray(server) };
                o["streamSettings"] = Stream(q, Type(), Security("none"));
                break;
            }
            case "trojan":
            {
                if (p.User.Length == 0) throw new V2RayException("The Trojan link has no password.");
                var server = Server(p.Host, p.Port);
                server["password"] = p.User;
                o["settings"] = new JsonObject { ["servers"] = new JsonArray(server) };
                o["streamSettings"] = Stream(q, Type(), Security("tls"));
                break;
            }
            default:   // hysteria2: the server in settings, the password in hysteriaSettings, QUIC over TLS (h3)
            {
                o["settings"] = new JsonObject { ["version"] = 2, ["address"] = p.Host, ["port"] = p.Port };
                var hq = new Dictionary<string, string>(q, StringComparer.Ordinal);
                if (Q(hq, "alpn") == null) hq["alpn"] = "h3";
                var s = Stream(hq, "hysteria", "tls");
                var hs = new JsonObject { ["version"] = 2 };
                if (p.User.Length > 0) hs["auth"] = p.User;
                s["hysteriaSettings"] = hs;
                if (Q(q, "obfs") is { } obfs)
                {
                    if (obfs != "salamander" || Q(q, "obfs-password") is not { } pw)
                        throw new V2RayException($"The Hysteria2 link uses {obfs} obfuscation, which is not supported.");
                    s["finalmask"] = new JsonObject
                    {
                        ["udp"] = new JsonArray(new JsonObject { ["type"] = "salamander", ["settings"] = new JsonObject { ["password"] = pw } }),
                    };
                }
                o["streamSettings"] = s;
                break;
            }
        }
        return new Imported { Name = p.Name, Link = link, Outbound = o, Host = p.Host, Port = p.Port };
    }

    /// <summary>vmess://base64(JSON), the v2rayN format: v, ps, add, port, id, aid, scy, net, type, host, path, tls, sni, alpn, fp.</summary>
    private static Imported VmessJson(JsonObject j, string link)
    {
        string F(string k) => j[k] is JsonValue v
            ? (v.TryGetValue<string>(out var s) ? s.Trim() : v.ToJsonString().Trim('"'))
            : "";
        var host = F("add");
        int.TryParse(F("port"), out var port);
        if (host.Length == 0 || port is < 1 or > 65535 || F("id").Length == 0) throw new V2RayException("The VMess link is missing its server, port or ID.");
        var q = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["host"] = F("host"), ["path"] = F("path"), ["sni"] = F("sni"), ["alpn"] = F("alpn"), ["fp"] = F("fp"),
        };
        var net = F("net").Length == 0 ? "tcp" : F("net");
        switch (net)
        {
            case "grpc": q["serviceName"] = F("path"); q["mode"] = F("type"); break;
            case "kcp": q["headerType"] = F("type"); q["seed"] = F("path"); break;
            case "xhttp" or "splithttp": q["mode"] = F("type"); break;
            default: q["headerType"] = F("type"); break;
        }
        int.TryParse(F("aid"), out var aid);
        var user = new JsonObject { ["id"] = F("id"), ["alterId"] = aid, ["security"] = F("scy").Length == 0 ? "auto" : F("scy") };
        var server = Server(host, port);
        server["users"] = new JsonArray(user);
        var o = new JsonObject
        {
            ["protocol"] = "vmess",
            ["settings"] = new JsonObject { ["vnext"] = new JsonArray(server) },
            ["streamSettings"] = Stream(q, net, F("tls")),
        };
        return new Imported { Name = F("ps"), Link = link, Outbound = o, Host = host, Port = port };
    }

    /// <summary>
    /// ss://base64(method:password)@host:port#name (SIP002), or ss://base64(method:password@host:port)#name.
    /// Outline's access keys are this form with "/?outline=1" (and sometimes "&amp;prefix=…") after the port.
    /// </summary>
    private static Imported Shadowsocks(string body, string link)
    {
        var b = body;
        var name = "";
        var prefix = false;
        var h = b.IndexOf('#');
        if (h >= 0)
        {
            name = Unescape(b[(h + 1)..]).Trim();
            b = b[..h];
        }
        var q = b.IndexOf('?');
        if (q >= 0)
        {
            var query = b[(q + 1)..];
            if (query.Contains("plugin=", StringComparison.Ordinal)) throw new V2RayException("Shadowsocks links with a plugin are not supported.");
            prefix = query.Split('&').Any(x => x.StartsWith("prefix=", StringComparison.Ordinal) && x.Length > "prefix=".Length);
            b = b[..q];
        }
        if (!b.Contains('@') && DecodeBase64(b) is { } whole) b = whole;
        var p = Split(b + (name.Length == 0 ? "" : "#" + name));
        var userinfo = p.User;
        if (!userinfo.Contains(':') && DecodeBase64(userinfo) is { } decoded) userinfo = decoded;
        var colon = userinfo.IndexOf(':');
        if (colon < 0) throw new V2RayException("The Shadowsocks link has no method and password.");
        var method = userinfo[..colon];
        var password = userinfo[(colon + 1)..];
        var server = Server(p.Host, p.Port);
        server["method"] = method;
        server["password"] = password;
        var o = new JsonObject { ["protocol"] = "shadowsocks", ["settings"] = new JsonObject { ["servers"] = new JsonArray(server) } };
        return new Imported { Name = name, Link = link, Outbound = o, Host = p.Host, Port = p.Port, Prefix = prefix };
    }

    /// <summary>The server an Outline "online config" describes: {"server", "server_port", "password", "method", optionally "prefix"}, what an ssconf:// (dynamic) key answers with.</summary>
    private static Imported? OutlineJson(JsonObject d, string name)
    {
        var host = Json.Str(d["server"])?.Trim() ?? "";
        var method = Json.Str(d["method"])?.Trim() ?? "";
        if (host.Length == 0 || method.Length == 0 || Json.Str(d["password"]) is not { } password) return null;
        var raw = d["server_port"] ?? d["port"];
        var port = Json.Int(raw) ?? (int.TryParse(Json.Str(raw), out var sp) ? sp : 0);
        if (port is < 1 or > 65535) return null;
        var server = Server(host, port);
        server["method"] = method;
        server["password"] = password;
        var o = new JsonObject { ["protocol"] = "shadowsocks", ["settings"] = new JsonObject { ["servers"] = new JsonArray(server) } };
        return new Imported { Name = name, Outbound = o, Host = host, Port = port, Prefix = Json.Str(d["prefix"]) is { Length: > 0 } };
    }

    private static JsonArray StringArray(IEnumerable<string> items) => new(items.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());

    /// <summary>Xray streamSettings from a link's query (Xray's share-link standard).</summary>
    private static JsonObject Stream(Dictionary<string, string> q, string network, string security)
    {
        var net = network.ToLowerInvariant();
        if (net.Length == 0 || net == "raw") net = "tcp";
        if (net == "splithttp") net = "xhttp";
        if (net == "h2") net = "http";
        if (net == "mkcp") net = "kcp";
        var s = new JsonObject { ["network"] = net };
        var path = q.TryGetValue("path", out var pv) ? pv : "";
        var host = q.TryGetValue("host", out var hv) ? hv : "";
        var hosts = host.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
        string PathOrRoot() => path.Length == 0 ? "/" : path;
        switch (net)
        {
            case "tcp":
                if (q.TryGetValue("headerType", out var ht) && ht == "http")
                {
                    var req = new JsonObject { ["path"] = StringArray(new[] { PathOrRoot() }) };
                    if (hosts.Count > 0) req["headers"] = new JsonObject { ["Host"] = StringArray(hosts) };
                    s["tcpSettings"] = new JsonObject { ["header"] = new JsonObject { ["type"] = "http", ["request"] = req } };
                }
                break;
            case "ws" or "httpupgrade":
            {
                var w = new JsonObject { ["path"] = PathOrRoot() };
                if (host.Length > 0) w["host"] = host;
                s[net == "ws" ? "wsSettings" : "httpupgradeSettings"] = w;
                break;
            }
            case "xhttp":
            {
                var x = new JsonObject { ["path"] = PathOrRoot() };
                if (host.Length > 0) x["host"] = host;
                if (Q(q, "mode") is { } m) x["mode"] = m;
                if (Q(q, "extra") is { } e && Json.Parse(e) is { } extra) x["extra"] = extra;
                s["xhttpSettings"] = x;
                break;
            }
            case "grpc":
            {
                var g = new JsonObject { ["serviceName"] = q.TryGetValue("serviceName", out var sn) ? sn : path };
                if (q.TryGetValue("mode", out var gm) && gm == "multi") g["multiMode"] = true;
                if (Q(q, "authority") is { } a) g["authority"] = a;
                s["grpcSettings"] = g;
                break;
            }
            case "kcp":
            {
                var k = new JsonObject();
                if (Q(q, "headerType") is { } t && t != "none") k["header"] = new JsonObject { ["type"] = t };
                if (Q(q, "seed") is { } seed) k["seed"] = seed;
                s["kcpSettings"] = k;
                break;
            }
            case "http":
            {
                var hh = new JsonObject { ["path"] = PathOrRoot() };
                if (hosts.Count > 0) hh["host"] = StringArray(hosts);
                s["httpSettings"] = hh;
                break;
            }
            case "hysteria":
                break;
            default:
                throw new V2RayException($"The {network} transport is not supported.");
        }
        switch (security.ToLowerInvariant())
        {
            case "" or "none":
                break;
            case "tls":
            {
                var t = new JsonObject();
                // Without one, the Host the link names (a CDN address given as an IP): Xray would otherwise
                // ask for a certificate for the IP address, and the handshake fails.
                if ((Q(q, "sni") ?? Q(q, "peer") ?? hosts.FirstOrDefault()) is { } sni) t["serverName"] = sni;
                if (Q(q, "fp") is { } fp) t["fingerprint"] = fp;
                if (Q(q, "alpn") is { } alpn) t["alpn"] = StringArray(alpn.Split(',').Select(x => x.Trim()));
                if (Q(q, "pinSHA256") is { } pin) t["pinnedPeerCertificateChainSha256"] = StringArray(new[] { pin });
                s["security"] = "tls";
                s["tlsSettings"] = t;
                break;
            }
            case "reality":
            {
                if (Q(q, "pbk") is not { } pbk) throw new V2RayException("The Reality link has no public key (pbk).");
                var r = new JsonObject { ["publicKey"] = pbk, ["fingerprint"] = Q(q, "fp") ?? "chrome" };
                if (Q(q, "sni") is { } sni) r["serverName"] = sni;
                if (q.TryGetValue("sid", out var sid)) r["shortId"] = sid;
                if (Q(q, "spx") is { } spx) r["spiderX"] = spx;
                if (Q(q, "pqv") is { } pqv) r["mldsa65Verify"] = pqv;
                s["security"] = "reality";
                s["realitySettings"] = r;
                break;
            }
            default:
                throw new V2RayException($"The {security} security is not supported.");
        }
        return s;
    }

    // MARK: JSON configs

    /// <summary>An Xray/V2Ray JSON config (its proxy outbounds), one outbound, or a list of either.</summary>
    public static List<Imported> ImportJson(string text, string name)
    {
        var obj = Json.Parse(text) ?? throw new V2RayException($"{name} is not valid JSON.");
        var found = new List<Imported>();
        void Walk(JsonNode? o, string label)
        {
            if (o is JsonArray list)
            {
                for (var i = 0; i < list.Count; i++) Walk(list[i], list.Count > 1 ? $"{label} {i + 1}" : label);
            }
            else if (o is JsonObject d)
            {
                var remark = NonEmpty(Json.Str(d["remarks"])?.Trim());
                if (d["outbounds"] is JsonArray outs)
                {
                    var proxies = outs.OfType<JsonObject>().Where(x => Protocols.Contains((Json.Str(x["protocol"]) ?? "").ToLowerInvariant())).ToList();
                    for (var i = 0; i < proxies.Count; i++)
                    {
                        var baseName = remark ?? label;
                        if (OutboundOf(proxies[i], proxies.Count > 1 ? $"{baseName} {i + 1}" : baseName) is { } imp) found.Add(imp);
                    }
                }
                else if (OutboundOf(d, remark ?? label) is { } one) found.Add(one);
                else if (OutlineJson(d, NonEmpty(Json.Str(d["name"])?.Trim()) ?? remark ?? label) is { } outline) found.Add(outline);
            }
        }
        Walk(obj, name);
        if (found.Count == 0) throw new V2RayException($"{name} holds no VLESS, VMess, Trojan, Shadowsocks (Outline) or Hysteria2 server.");
        return found;
    }

    /// <summary>One outbound as FiveT keeps it: the proxy part only. Its tag, mux and sockopt are FiveT's to set.</summary>
    private static Imported? OutboundOf(JsonObject d, string name)
    {
        var proto = Json.Str(d["protocol"])?.ToLowerInvariant();
        if (proto == null || !Protocols.Contains(proto)) return null;
        var o = new JsonObject { ["protocol"] = proto };
        if (d["settings"] is { } settings) o["settings"] = settings.DeepClone();
        if (d["streamSettings"] is JsonObject st)
        {
            var copy = (JsonObject)st.DeepClone();
            copy.Remove("sockopt");
            (copy["tlsSettings"] as JsonObject)?.Remove("allowInsecure");
            o["streamSettings"] = copy;
        }
        var (host, port) = ServerOf(o);
        return host.Length == 0 ? null : new Imported { Name = name, Outbound = o, Host = host, Port = port };
    }

    /// <summary>The server an outbound connects to.</summary>
    public static (string Host, int Port) ServerOf(JsonObject o)
    {
        var settings = o["settings"] as JsonObject ?? new JsonObject();
        var first = (settings["vnext"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault()
                    ?? (settings["servers"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault() ?? settings;
        var host = Json.Str(first["address"])?.Trim() ?? "";
        var port = Json.Int(first["port"]) ?? (int.TryParse(Json.Str(first["port"]), out var p) ? p : 0);
        return (host, port);
    }

    // MARK: Text: pasted, dropped, or a subscription's body

    public sealed record TextImport(List<Imported> Configs, List<string> Problems, List<Uri> Subscriptions);

    /// <summary>Every link (or JSON config) in <paramref name="text"/>; a subscription body may be all of it in base64. https:// lines are returned as subscriptions to fetch.</summary>
    public static TextImport ImportText(string text, string name = "Pasted config")
    {
        var t = text.Trim();
        if (t.StartsWith('{') || t.StartsWith('['))
        {
            try { return new TextImport(ImportJson(t, name), new(), new()); }
            catch (V2RayException e) { return new TextImport(new(), new() { e.Message }, new()); }
        }
        if (!t.Contains("://", StringComparison.Ordinal)
            && DecodeBase64(new string(t.Where(ch => !char.IsWhiteSpace(ch)).ToArray())) is { } decoded
            && decoded.Contains("://", StringComparison.Ordinal))
            t = decoded;
        var configs = new List<Imported>();
        var problems = new List<string>();
        var subs = new List<Uri>();
        foreach (var token in Tokens(t))
        {
            var low = token.ToLowerInvariant();
            if (low.StartsWith("https://", StringComparison.Ordinal) || low.StartsWith("http://", StringComparison.Ordinal))
            {
                if (Uri.TryCreate(token, UriKind.Absolute, out var u)) subs.Add(u);
            }
            else if (low.StartsWith("ssconf://", StringComparison.Ordinal))
            {
                if (DynamicKeyUrl(token) is { } u) subs.Add(u); else problems.Add($"{ShortLink(token)}: not a valid key address.");
            }
            else if (IsLink(token))
            {
                try { configs.Add(Parse(token)); }
                catch (V2RayException e) { problems.Add($"{ShortLink(token)}: {e.Message}"); }
            }
        }
        return new TextImport(configs, problems, subs);
    }

    /// <summary>
    /// The links in <paramref name="text"/>: one per line, or several on a line. A link ends where the next
    /// one starts, not at a space: names after "#" are often typed with spaces, not as %20.
    /// </summary>
    public static List<string> Tokens(string text)
    {
        var starts = Schemes.Concat(new[] { "https", "http", "ssconf" }).Select(x => x + "://").ToArray();
        var output = new List<string>();
        foreach (var l in text.Split(new[] { '\n', '\r', '\u0085', '\u2028', '\u2029' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var cuts = new List<int>();
            for (var i = 0; i < l.Length; i++)
            {
                if (i != 0 && !char.IsWhiteSpace(l[i - 1])) continue;
                // Only the 12 characters a scheme can fill (hysteria2://): lowercasing the rest of the line
                // at every word would make a long line quadratic.
                var head = l.AsSpan(i, Math.Min(12, l.Length - i)).ToString().ToLowerInvariant();
                if (starts.Any(s => head.StartsWith(s, StringComparison.Ordinal))) cuts.Add(i);
            }
            for (var n = 0; n < cuts.Count; n++)
            {
                var end = n + 1 < cuts.Count ? cuts[n + 1] : l.Length;
                var piece = l[cuts[n]..end].Trim();
                // A subscription URL never has a space in it; anything after one is not part of it.
                output.Add(piece.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? new string(piece.TakeWhile(ch => !char.IsWhiteSpace(ch)).ToArray()) : piece);
            }
        }
        return output;
    }

    /// <summary>
    /// An Outline dynamic key (ssconf://host/path#name) as the https:// address it is fetched from; the name
    /// after "#" stays in the URL's fragment, which a request never sends.
    /// </summary>
    public static Uri? DynamicKeyUrl(string key)
    {
        var rest = key.Trim();
        var i = rest.IndexOf("://", StringComparison.Ordinal);
        if (i < 0) return null;
        rest = rest[(i + 3)..];
        var address = rest;
        var name = "";
        var h = rest.IndexOf('#');
        if (h >= 0)
        {
            address = rest[..h];
            name = Unescape(rest[(h + 1)..]).Trim();
        }
        if (address.Length == 0 || address.Any(char.IsWhiteSpace)) return null;
        if (!Uri.TryCreate("https://" + address, UriKind.Absolute, out var u) || u.Host.Length == 0) return null;
        return name.Length == 0 ? u : new UriBuilder(u) { Fragment = Uri.EscapeDataString(name) }.Uri;
    }

    public sealed record Subscription(string? Title, List<Imported> Configs, List<string> Problems);

    /// <summary>The configs a subscription URL lists now, and the title its server gives it.</summary>
    public static async Task<Subscription> FetchSubscriptionAsync(Uri url, HttpMessageHandler? handler = null)
    {
        // No cookies, no cache, no proxy of the user's: a one-off request.
        using var client = new HttpClient(handler ?? new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = true, MaxAutomaticRedirections = 5 })
        {
            Timeout = TimeSpan.FromSeconds(20),
            MaxResponseContentBufferSize = 8_000_000,
        };
        using var req = new HttpRequestMessage(HttpMethod.Get, new UriBuilder(url) { Fragment = "" }.Uri);
        // Panels (Marzban, 3x-ui…) answer in the format of the client they recognise; this one is the plain list of links.
        req.Headers.TryAddWithoutValidation("User-Agent", "v2rayN/7.0");
        HttpResponseMessage response;
        try { response = await client.SendAsync(req).ConfigureAwait(false); }
        catch (TaskCanceledException) { throw new V2RayException("The subscription server did not answer in time."); }
        catch (HttpRequestException e) { throw new V2RayException($"The subscription server could not be reached ({e.Message})."); }
        using (response)
        {
            if (!response.IsSuccessStatusCode) throw new V2RayException($"The subscription server answered {(int)response.StatusCode}.");
            string? title = null;
            if (response.Headers.TryGetValues("profile-title", out var titles) && titles.FirstOrDefault() is { } rawTitle)
                title = rawTitle.StartsWith("base64:", StringComparison.Ordinal) ? DecodeBase64(rawTitle[7..]) : rawTitle;
            string text;
            try { text = new UTF8Encoding(false, true).GetString(await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false)); }
            catch (Exception) { throw new V2RayException("The subscription is not text."); }
            var fallback = title ?? url.Host;
            var r = ImportText(text, fallback);
            foreach (var c in r.Configs) c.Subscription = url.AbsoluteUri;
            // An Outline dynamic key carries its name in the address, not in what the server answers (whose
            // one server ImportText names after the fallback).
            var fragmentName = NonEmpty(Unescape(url.Fragment.TrimStart('#')).Trim());
            if (fragmentName != null)
                foreach (var c in r.Configs.Where(c => c.Name.Trim().Length == 0 || c.Name == fallback)) c.Name = fragmentName;
            if (r.Configs.Count == 0 && r.Problems.Count == 0) throw new V2RayException("The subscription lists no configs FiveT can use.");
            return new Subscription(title, r.Configs, r.Problems);
        }
    }

    // MARK: Connections

    /// <summary>A new connection from an import, named apart from the ones in <paramref name="taken"/>.</summary>
    public static Connection ConnectionFrom(Imported imp, IReadOnlyCollection<string> taken)
    {
        var c = new Connection { Kind = VpnKind.V2Ray };
        c.Name = VpnImport.UniqueName(imp.Name.Trim().Length == 0 ? imp.Host : imp.Name.Trim(), taken);
        Apply(imp, c);
        return c;
    }

    public static void Apply(Imported imp, Connection c)
    {
        c.V2RayOutbound = ToJson(imp.Outbound);
        c.V2RayLink = imp.Link;
        c.V2RaySubscription = imp.Subscription;
        c.Host = imp.Host;
        c.Port = imp.Port;
        c.Realm = "";
    }

    /// <summary>A Shadowsocks server (what Outline's keys are), for labels. The outbound is written with sorted keys and no spaces, so this is a plain text test.</summary>
    public static bool IsShadowsocks(string outboundJson) => outboundJson.Contains("\"protocol\":\"shadowsocks\"", StringComparison.Ordinal);

    /// <summary>The link with outline=1 in its query (before any #name), which is how <see cref="KindLabel"/> knows a key from the Outline app is an Outline key even when its own text does not say so.</summary>
    public static string MarkedAsOutline(string link)
    {
        if (link.Contains("outline=1", StringComparison.Ordinal)) return link;
        var h = link.IndexOf('#');
        var head = h < 0 ? link : link[..h];
        var tail = h < 0 ? "" : link[h..];
        return head + (head.Contains('?') ? "&" : "?") + "outline=1" + tail;
    }

    /// <summary>What the list and the detail title call a connection: Outline for a Shadowsocks server that came as an Outline key or an ssconf:// address, Shadowsocks for any other, V2Ray for the rest.</summary>
    public static string KindLabel(Connection c)
    {
        if (c.IsOpenVpn) return "OpenVPN";
        if (!IsShadowsocks(c.V2RayOutbound)) return "V2Ray";
        return c.V2RayLink.Contains("outline=1", StringComparison.Ordinal) || c.V2RaySubscription.Length > 0 ? "Outline" : "Shadowsocks";
    }

    /// <summary>"VLESS · Reality · xhttp", for Settings.</summary>
    public static string Summary(string outboundJson)
    {
        if (Json.Parse(outboundJson) is not JsonObject o) return "";
        var proto = (Json.Str(o["protocol"]) ?? "").ToLowerInvariant();
        var names = new Dictionary<string, string> { ["vless"] = "VLESS", ["vmess"] = "VMess", ["trojan"] = "Trojan", ["shadowsocks"] = "Shadowsocks", ["hysteria"] = "Hysteria2" };
        var parts = new List<string> { names.TryGetValue(proto, out var n) ? n : proto };
        var st = o["streamSettings"] as JsonObject;
        if (Json.Str(st?["security"]) is { } sec && sec != "none") parts.Add(sec == "reality" ? "Reality" : sec.ToUpperInvariant());
        if (Json.Str(st?["network"]) is { } net && net != "tcp" && net != "hysteria") parts.Add(net);
        return string.Join(" · ", parts);
    }

    private static readonly JsonSerializerOptions Plain = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = false };

    /// <summary>JSON with sorted keys and no spaces: two imports of the same server give the same text (how duplicates are found).</summary>
    public static string ToJson(JsonNode? node) => Sorted(node)?.ToJsonString(Plain) ?? "null";

    private static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => new KeyValuePair<string, JsonNode?>(kv.Key, Sorted(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Sorted).ToArray()),
        null => null,
        _ => node.DeepClone(),
    };

    /// <summary>The user ids and passwords inside an outbound: the log never shows them (see Redactor).</summary>
    public static IEnumerable<string> SecretsOf(string outboundJson)
    {
        if (outboundJson.Length == 0 || Json.Parse(outboundJson) is not JsonObject o) yield break;
        var found = new List<string>();
        void Walk(JsonNode? v)
        {
            if (v is JsonObject d)
            {
                foreach (var (k, x) in d)
                {
                    if (k is "id" or "password" or "auth" or "seed" && Json.Str(x) is { Length: >= 6 } s) found.Add(s);
                    else Walk(x);
                }
            }
            else if (v is JsonArray list) foreach (var x in list) Walk(x);
        }
        Walk(o);
        foreach (var s in found) yield return s;
    }

    // MARK: Running

    /// <summary>The adapter Xray creates for its TUN (one VPN at a time, so one name).</summary>
    public const string TunName = "FiveT-VPN";
    /// <summary>The PC's address on Xray's TUN (198.18.0.1/30). Xray takes every packet routed into the TUN, whatever its destination.</summary>
    public const string TunAddress = "198.18.0.1";
    /// <summary>
    /// Where the PC's DNS questions go while connected: an address inside the TUN's own /30 that is not the
    /// PC's, so the question enters the TUN and Xray answers it itself (its dns outbound). Names are looked
    /// up through the server, never by the local network's resolver, which in Iran answers blocked names with
    /// a wrong address.
    /// </summary>
    public const string TunDns = "198.18.0.2";
    /// <summary>DNS servers Xray asks, through the V2Ray server, over TCP (the Mac's choice; UDP is not carried, see ForLaunch).</summary>
    public static readonly string[] RemoteDns = { "tcp://1.1.1.1", "tcp://8.8.8.8" };
    /// <summary>The list of Iranian and private address ranges next to xray.exe (categories "ir" and "private").</summary>
    public const string GeoFile = "geoip-lite.dat";

    /// <summary>The host names (not addresses) the server settings connect to. FiveT looks them up before the tunnel exists and gives Xray the answers.</summary>
    public static List<string> ServerNames(string outboundJson) =>
        // A real server has one or two (the address, perhaps a second hop). A cap, because an import can hold
        // thousands of "address" fields and each name is a lookup.
        ServerAddresses(outboundJson).Where(IsHostName).Take(8).ToList();

    /// <summary>Every "address" in the outbound, names and IP addresses alike, sorted.</summary>
    public static List<string> ServerAddresses(string outboundJson)
    {
        var names = new SortedSet<string>(StringComparer.Ordinal);
        void Walk(JsonNode? v)
        {
            if (v is JsonObject d)
            {
                foreach (var (k, x) in d)
                {
                    if (k == "address" && Json.Str(x) is { } s) names.Add(s.Trim().ToLowerInvariant()); else Walk(x);
                }
            }
            else if (v is JsonArray list) foreach (var x in list) Walk(x);
        }
        if (outboundJson.Length > 0) Walk(Json.Parse(outboundJson));
        return names.ToList();
    }

    /// <summary>A DNS name Xray would look up: ASCII letters, digits, "-", "_" and dots, not an IP address.</summary>
    private static bool IsHostName(string s) =>
        s.Length is > 0 and <= 253 && s.All(ch => ch < 128 && (char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_' or '.')) && !IPAddress.TryParse(s, out _);

    /// <summary>
    /// The whole Xray config for <paramref name="c"/>: one TUN that takes all of the PC's traffic, the server,
    /// and routing that sends the local network, <paramref name="direct"/> (the Forti gateways) and, with
    /// Bypass Iranian Websites on, Iranian sites (.ir names, Iranian addresses) straight out.
    /// <paramref name="localDns"/> answers .ir names then, as it would without the VPN. <paramref name="serverIps"/>
    /// are the addresses the PC's own DNS gave the server's name before the tunnel existed: with the PC's DNS
    /// pointing into the tunnel, Xray can only look the name up through the server, which it cannot reach
    /// without the answer. The result goes through <see cref="XrayConfigCheck"/> before Xray sees it.
    ///
    /// UDP: only DNS (port 53) is answered, by Xray's own DNS. Any other UDP is dropped inside the tunnel, as
    /// on the Mac (there Xray cannot send UDP on past the TUN; here the same rule is kept so both apps behave
    /// alike and nothing can loop). Browsers fall back from QUIC to TCP; voice calls and games that need UDP
    /// do not work through a V2Ray or Outline connection.
    /// </summary>
    public static string ForLaunch(Connection c, string tun, IReadOnlyList<string> localDns, IReadOnlyList<string> direct,
        IReadOnlyDictionary<string, List<string>> serverIps, bool verbose, bool bypassIran)
    {
        if (Json.Parse(c.V2RayOutbound) is not JsonObject proxy
            || Json.Str(proxy["protocol"]) is not { } proto || !Protocols.Contains(proto.ToLowerInvariant()))
            throw new V2RayException("its server settings are missing");
        proxy = (JsonObject)proxy.DeepClone();
        proxy["tag"] = "proxy";
        proxy.Remove("mux");
        if (proxy["streamSettings"] is JsonObject st)
        {
            st.Remove("sockopt");   // the TUN's autoOutboundsInterface keeps every outbound off the tunnel
            (st["tlsSettings"] as JsonObject)?.Remove("allowInsecure");   // refused by Xray since 2026
        }
        var geo = "ext:" + GeoFile;
        var rules = new JsonArray
        {
            // The PC's DNS questions (it asks TunDns) are answered by Xray's DNS.
            new JsonObject { ["inboundTag"] = StringArray(new[] { "tun" }), ["network"] = "udp", ["port"] = "53", ["outboundTag"] = "dns-out" },
            // Any other UDP is dropped (see the summary above); the log shows "[tun -> block]" for each dropped flow.
            new JsonObject { ["inboundTag"] = StringArray(new[] { "tun" }), ["network"] = "udp", ["outboundTag"] = "block" },
            new JsonObject { ["ip"] = StringArray(new[] { geo + ":private" }), ["outboundTag"] = "direct" },
        };
        if (direct.Count > 0) rules.Add(new JsonObject { ["ip"] = StringArray(direct), ["outboundTag"] = "direct" });
        var servers = new JsonArray();
        var local = localDns.FirstOrDefault();
        if (bypassIran)
        {
            rules.Add(new JsonObject { ["domain"] = StringArray(new[] { "domain:ir" }), ["outboundTag"] = "direct" });
            rules.Add(new JsonObject { ["ip"] = StringArray(new[] { geo + ":ir" }), ["outboundTag"] = "direct" });
            if (local != null)
                servers.Add(new JsonObject { ["address"] = local, ["domains"] = StringArray(new[] { "domain:ir" }), ["skipFallback"] = true });
        }
        foreach (var r in RemoteDns) servers.Add(r);
        // Last: a name the world's DNS does not know (some Iranian sites' .com and .io names only exist on
        // Iranian resolvers) is asked of the local one, whose answer counts only when it is an Iranian
        // address, so a filter's fake answer never does.
        if (bypassIran && local != null)
            servers.Add(new JsonObject { ["address"] = local, ["expectIPs"] = StringArray(new[] { geo + ":ir" }) });
        // The server's own name, answered from what the PC found: no lookup through a server that is not
        // reachable yet. A name with only IPv6 addresses needs Xray to ask for them.
        var dns = new JsonObject { ["tag"] = "dns-internal", ["queryStrategy"] = "UseIPv4", ["servers"] = servers };
        var known = serverIps.Where(kv => kv.Value.Count > 0).ToList();
        if (known.Count > 0)
        {
            var hosts = new JsonObject();
            foreach (var (name, ips) in known) hosts["full:" + name.ToLowerInvariant()] = StringArray(ips);
            dns["hosts"] = hosts;
            if (known.Any(kv => kv.Value.All(ip => ip.Contains(':')))) dns["queryStrategy"] = "UseIP";
        }
        rules.Add(new JsonObject { ["network"] = "tcp,udp", ["outboundTag"] = "proxy" });
        var config = new JsonObject
        {
            ["log"] = new JsonObject { ["loglevel"] = verbose ? "info" : "warning" },
            ["inbounds"] = new JsonArray(new JsonObject
            {
                ["tag"] = "tun",
                ["protocol"] = "tun",
                ["settings"] = new JsonObject
                {
                    ["name"] = tun,
                    ["mtu"] = 1500,
                    ["gateway"] = StringArray(new[] { TunAddress + "/30" }),
                    // Xray adds the routes itself and binds its own connections to the Wi-Fi or Ethernet,
                    // re-picked when it changes. Quarters, not halves: the PC's default route stays, and
                    // another VPN that takes everything with two halves (OpenVPN's def1) neither blocks these
                    // routes nor wins over them.
                    ["autoSystemRoutingTable"] = StringArray(new[] { "0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2", "::/2", "4000::/2", "8000::/2", "c000::/2" }),
                    ["autoOutboundsInterface"] = "auto",
                },
                ["sniffing"] = new JsonObject { ["enabled"] = true, ["destOverride"] = StringArray(new[] { "http", "tls", "quic" }), ["routeOnly"] = true },
            }),
            ["outbounds"] = new JsonArray
            {
                proxy,
                new JsonObject { ["protocol"] = "freedom", ["tag"] = "direct" },
                new JsonObject { ["protocol"] = "blackhole", ["tag"] = "block" },
                // A and AAAA go to Xray's DNS; every other type (HTTPS, TXT…) is answered at once with no
                // records and no error, so a browser's HTTPS lookup falls back to plain A/AAAA without a fuss.
                new JsonObject
                {
                    ["protocol"] = "dns", ["tag"] = "dns-out",
                    ["settings"] = new JsonObject
                    {
                        ["rules"] = new JsonArray
                        {
                            new JsonObject { ["action"] = "hijack", ["qType"] = "1,28" },
                            new JsonObject { ["action"] = "return", ["rCode"] = 0 },
                        },
                    },
                },
            },
            ["dns"] = dns,
            ["routing"] = new JsonObject { ["domainStrategy"] = "AsIs", ["rules"] = rules },
        };
        return ToJson(config);
    }

    // MARK: Helpers

    /// <summary>Base64, standard or URL-safe, with or without padding; null unless it decodes to UTF-8 text.</summary>
    public static string? DecodeBase64(string s)
    {
        var t = s.Trim().Replace('-', '+').Replace('_', '/');
        if (t.Length == 0 || !t.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '+' or '/' or '=')) return null;
        while (t.Length % 4 != 0) t += "=";
        try { return new UTF8Encoding(false, true).GetString(Convert.FromBase64String(t)); }
        catch (Exception) { return null; }
    }

    /// <summary>A link for a message: its scheme and server, never its ID or password.</summary>
    public static string ShortLink(string s)
    {
        var i = s.IndexOf("://", StringComparison.Ordinal);
        if (i < 0) return "a line";
        var scheme = s[..i];
        var at = s.LastIndexOf('@');
        if (at < 0) return $"a {scheme}:// link";
        var hp = new string(s[(at + 1)..].TakeWhile(ch => ch is not ('?' or '#' or '/')).ToArray());
        return $"{scheme}://…@{hp}";
    }
}
