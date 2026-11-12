using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using FiveT.Core;

namespace FiveT;

public sealed class OpenVpnProfileException : Exception
{
    public OpenVpnProfileException(string message) : base(message) { }
}

/// <summary>
/// OpenVPN profiles (.ovpn): importing one into a connection, checking it against what FiveT allows
/// (<see cref="AllowedOptions"/>), and the text FiveT hands openvpn.exe to start a tunnel, the login
/// included, which never touches the disk. A port of the Mac's OpenVPNProfile.swift and of the check in
/// its root helper (Setup.swift, ovpn-run).
///
/// Why the check matters on Windows: FiveT runs openvpn.exe as administrator, and connections.json can
/// be written by any program of the user. An OpenVPN option that runs a program (up, down, route-up,
/// plugin…), reads or writes a file, or opens a control socket would hand that program administrator
/// rights. So the profile is checked when it is imported and again, on the very text that is passed on,
/// each time a tunnel starts.
/// </summary>
public static class OpenVpnProfile
{
    /// <summary>What an import produced.</summary>
    public sealed class Imported
    {
        public string Text = "";              // the profile to keep: every certificate and key inline
        public string Name = "";
        public string Host = "";              // its first server
        public int Port = 1194;
        public string Username = "";          // from an auth-user-pass file or block, if the profile had one
        public string Password = "";
        public bool StaticChallenge;          // the server asks for a one-time code with the password
        public List<string> Dropped = new();  // options FiveT left out, and why
    }

    /// <summary>The largest profile FiveT takes (the Mac helper's limit), counted on the text that is passed on.</summary>
    public const int MaxConfigBytes = 262_144;

    /// <summary>
    /// The OpenVPN options FiveT passes on; it refuses a profile with any other. Left out are the ones that,
    /// as administrator, run a program (up, down, route-up, ipchange, tls-verify, plugin…, and
    /// script-security, which FiveT sets to 1), read a file (askpass, config, capath, and the file forms of
    /// ca, cert, key, tls-auth…: only their inline blocks are allowed), write one (log, status, writepid,
    /// tls-export-cert), open a control socket (management), or answer a one-time-code question on the
    /// console (static-challenge: FiveT sends the code with the password instead). The Mac's list, plus
    /// the two Windows options that only tighten DNS (block-outside-dns, register-dns).
    /// </summary>
    public static readonly string[] AllowedOptions =
    {
        "client", "tls-client", "pull", "dev", "dev-type", "topology", "proto", "remote", "remote-random",
        "remote-random-hostname", "port", "rport", "lport", "nobind", "bind", "float", "resolv-retry",
        "connect-retry", "connect-retry-max", "connect-timeout", "server-poll-timeout", "persist-key",
        "persist-tun", "persist-remote-ip", "persist-local-ip", "remote-cert-tls", "remote-cert-ku",
        "remote-cert-eku", "verify-x509-name", "ns-cert-type", "cipher", "data-ciphers",
        "data-ciphers-fallback", "ncp-ciphers", "auth", "tls-version-min", "tls-version-max", "tls-cipher",
        "tls-ciphersuites", "tls-groups", "tls-cert-profile", "ecdh-curve", "key-direction", "tls-timeout",
        "hand-window", "tran-window", "reneg-sec", "reneg-bytes", "reneg-pkts", "auth-user-pass",
        "auth-nocache", "auth-retry", "auth-token", "auth-token-user", "comp-lzo", "compress",
        "allow-compression", "redirect-gateway", "redirect-private", "route", "route-ipv6", "route-gateway",
        "route-ipv6-gateway", "route-metric", "route-delay", "route-nopull", "pull-filter", "block-ipv6",
        "ifconfig", "ifconfig-ipv6", "tun-ipv6", "ignore-unknown-option", "setenv", "setenv-safe",
        "dhcp-option", "explicit-exit-notify", "keepalive", "ping", "ping-restart", "ping-exit",
        "ping-timer-rem", "inactive", "mute", "mute-replay-warnings", "verb", "suppress-timestamps",
        "tun-mtu", "tun-mtu-extra", "link-mtu", "mssfix", "fragment", "sndbuf", "rcvbuf", "txqueuelen",
        "fast-io", "replay-window", "push-peer-info", "peer-fingerprint", "http-proxy", "http-proxy-option",
        "http-proxy-retry", "socks-proxy", "socks-proxy-retry", "tls-exit", "single-session", "disable-occ",
        "allow-recursive-routing", "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "extra-certs", "pkcs12", "crl-verify",
        "block-outside-dns", "register-dns",
    };

    /// <summary>Inline blocks FiveT accepts (&lt;ca&gt;…&lt;/ca&gt;), and the options it accepts only that way.</summary>
    public static readonly string[] InlineBlocks =
    {
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs", "pkcs12", "crl-verify",
        "auth-user-pass", "peer-fingerprint", "http-proxy-user-pass",
    };
    public static readonly string[] InlineOnly =
    {
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs", "pkcs12", "crl-verify", "auth-user-pass",
    };

    private static readonly HashSet<string> Allowed = new(AllowedOptions, StringComparer.Ordinal);
    private static readonly HashSet<string> Blocks = new(InlineBlocks, StringComparer.Ordinal);
    private static readonly HashSet<string> InlineOnlySet = new(InlineOnly, StringComparer.Ordinal);

    /// <summary>
    /// Windows options FiveT decides itself (which driver and adapter, how routes are set): left out at import
    /// with a note. On the Mac this list is "Windows-only options OpenVPN stops at"; here they would work,
    /// but each one changes how the tunnel is built behind FiveT's back.
    /// </summary>
    private static readonly HashSet<string> SetByFiveT = new(StringComparer.Ordinal)
    {
        "dhcp-renew", "dhcp-release", "dhcp-pre-release", "windows-driver", "route-method", "ip-win32", "tap-sleep",
        "service", "show-net-up", "allow-nonadmin", "win-sys", "dev-node", "disable-dco",
    };

    /// <summary>Options common in profiles that FiveT does itself or never allows: left out at import, with a note, rather than refusing the whole profile.</summary>
    private static readonly Dictionary<string, string> LeftOut = new(StringComparer.Ordinal)
    {
        ["up"] = "scripts", ["down"] = "scripts", ["up-delay"] = "scripts", ["down-pre"] = "scripts", ["up-restart"] = "scripts",
        ["route-up"] = "scripts", ["route-pre-down"] = "scripts", ["ipchange"] = "scripts", ["script-security"] = "scripts",
        ["plugin"] = "plug-ins", ["log"] = "log files", ["log-append"] = "log files", ["status"] = "status files",
        ["status-version"] = "status files", ["writepid"] = "pid files", ["daemon"] = "running in the background",
        ["user"] = "dropping administrator rights", ["group"] = "dropping administrator rights", ["chroot"] = "dropping administrator rights",
        ["management"] = "the management interface", ["management-hold"] = "the management interface",
        ["management-query-passwords"] = "the management interface", ["management-client"] = "the management interface",
    };

    /// <summary>Options whose argument is a file: read at import and kept inline.</summary>
    private static readonly HashSet<string> FileOptions = new(StringComparer.Ordinal)
    {
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs", "pkcs12", "crl-verify",
    };

    // MARK: OpenVPN Connect

    /// <summary>OpenVPN Connect's own copies of the profiles imported into it.</summary>
    public static string OpenVpnConnectFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenVPN Connect", "profiles");

    /// <summary>OpenVPN Connect's saved state, where it keeps the names of its profiles.</summary>
    public static string OpenVpnConnectState =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenVPN Connect", "config.json");

    public static List<string> OpenVpnConnectProfiles(string? folder = null)
    {
        try
        {
            return Directory.GetFiles(folder ?? OpenVpnConnectFolder)
                .Where(f => Path.GetExtension(f).Equals(".ovpn", StringComparison.OrdinalIgnoreCase))
                .OrderBy(f => f, StringComparer.Ordinal).ToList();
        }
        catch (Exception) { return new List<string>(); }
    }

    /// <summary>
    /// The name OpenVPN Connect shows for each of its profiles, by the number its copy of the profile is
    /// saved under ("1781727071873.ovpn" → "1781727071873"). The names, a rename made in the app included,
    /// are in config.json, whose "persist:root" holds the app's saved state as JSON inside JSON (status →
    /// profiles → one entry per profile). Empty when the file is missing or laid out differently (another
    /// version of the app): the import then names a profile after its server.
    /// </summary>
    public static Dictionary<string, string> OpenVpnConnectNames(string? stateFile = null)
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var path = stateFile ?? OpenVpnConnectState;
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > 8_000_000) return names;
            // A JSON object, or a string holding one (how the saved state nests its parts).
            static JsonObject? Obj(JsonNode? value) =>
                value as JsonObject ?? (Json.Str(value) is { } s ? Json.Parse(s) as JsonObject : null);
            if (Obj((Json.Parse(File.ReadAllText(path)) as JsonObject)?["persist:root"]) is not { } root
                || Obj(root["status"]) is not { } status || Obj(status["profiles"]) is not { } profiles) return names;
            foreach (var (id, entry) in profiles)
            {
                if (entry is not JsonObject p) continue;
                // It becomes a connection's name, in the menu and the log: one short line.
                var name = new[] { "profileDisplayName", "profileName", "name" }
                    .Select(k => Json.Str(p[k]) is { } v ? FieldCleaner.Line(v) : "").FirstOrDefault(v => v.Length > 0);
                if (name != null) names[id] = name.Length > 100 ? name[..100] : name;
            }
        }
        catch (Exception) { names.Clear(); }
        return names;
    }

    // MARK: Import

    public static Imported ImportProfile(string path)
    {
        byte[] data;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaxConfigBytes) throw new IOException();
            data = File.ReadAllBytes(path);
        }
        catch (Exception)
        {
            throw new OpenVpnProfileException($"{Path.GetFileName(path)} could not be read, or is larger than an OpenVPN profile can be.");
        }
        return ImportProfile(Decode(data), Path.GetFileNameWithoutExtension(path), Path.GetDirectoryName(Path.GetFullPath(path)));
    }

    /// <summary>UTF-8 (with or without a byte-order mark), or UTF-16 with one (Notepad's "Unicode").</summary>
    private static string Decode(byte[] data)
    {
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE) return Encoding.Unicode.GetString(data, 2, data.Length - 2);
        if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(data, 2, data.Length - 2);
        return Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
    }

    private static readonly Regex NameComment = new(@"^#\s*(OVPN_ACCESS_SERVER_FRIENDLY_NAME|OVPN_ACCESS_SERVER_PROFILE|Friendly name)\s*[=:]\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary><paramref name="folder"/>: where file names in the profile are looked up (null: the profile was pasted).</summary>
    public static Imported ImportProfile(string raw, string name, string? folder)
    {
        var output = new List<string>();
        var result = new Imported { Name = name };
        var dropped = new SortedDictionary<string, SortedSet<string>>(StringComparer.Ordinal);   // why → options
        void Drop(string why, string option)
        {
            if (!dropped.TryGetValue(why, out var set)) dropped[why] = set = new SortedSet<string>(StringComparer.Ordinal);
            set.Add(option);
        }
        string? inBlock = null;
        var blockLines = new List<string>();
        var lines = raw.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');

        foreach (var line in lines)
        {
            var t = line.Trim(' ', '\t');
            if (inBlock is { } b)
            {
                // Prefix, not exact equality: OpenVPN itself ends the block on any line starting with
                // "</name>" and discards anything after the tag on that line, so "</ca>x" must close it
                // here too, or everything up to the real next close tag is read as block content.
                if (t.StartsWith($"</{b}>", StringComparison.Ordinal))
                {
                    if (b == "auth-user-pass")
                    {
                        // A login written into the profile goes into the connection's fields instead.
                        var creds = blockLines.Select(x => x.Trim(' ', '\t')).Where(x => x.Length > 0).ToList();
                        result.Username = creds.Count > 0 ? creds[0] : "";
                        result.Password = creds.Count > 1 ? creds[1] : "";
                        output.Add("auth-user-pass");
                    }
                    else
                    {
                        // The canonical tag, not the raw line: re-emitting "</ca>x" verbatim would carry
                        // the same trick into the text Problems() checks next.
                        output.Add($"<{b}>");
                        output.AddRange(blockLines);
                        output.Add($"</{b}>");
                    }
                    inBlock = null;
                    blockLines = new List<string>();
                }
                else blockLines.Add(line);
                continue;
            }
            if (t.Length == 0 || t.StartsWith('#') || t.StartsWith(';'))
            {
                // "# OVPN_ACCESS_SERVER_PROFILE=user@vpn.example.com" or a friendly-name comment.
                if (NameComment.Match(t) is { Success: true } m)
                {
                    var v = t[m.Length..].Trim(' ', '\t');
                    if (v.Length > 0) result.Name = v;
                }
                continue;
            }
            if (t.StartsWith('<') && t.EndsWith('>') && !t.StartsWith("</", StringComparison.Ordinal) && t != "<connection>")
            {
                inBlock = t[1..^1];
                blockLines = new List<string>();
                continue;
            }
            if (t is "<connection>" or "</connection>") { output.Add(t); continue; }

            var (words, text) = Scan(t);
            if (words.Count == 0) continue;
            if (words[0].StartsWith("--", StringComparison.Ordinal)) words[0] = words[0][2..];
            var key = words[0];
            // "setenv opt <option>" is that option, if OpenVPN knows it.
            if (key == "setenv" && words.Count >= 3 && words[1] == "opt") key = words[2];

            if (SetByFiveT.Contains(key)) { Drop("set by FiveT", key); continue; }
            if (LeftOut.TryGetValue(key, out var why)) { Drop(why, key); continue; }
            switch (key)
            {
                case "static-challenge":
                    result.StaticChallenge = true;   // FiveT sends the code with the password itself
                    continue;
                case "askpass":
                    throw new OpenVpnProfileException("This profile's private key is protected by a passphrase, which FiveT does not support yet. Export the profile with an unencrypted key, or ask your VPN administrator for one.");
                case "auth-user-pass":
                    if (words.Count >= 2)
                    {
                        var creds = ReadFile(words[1], "login file", folder).Split('\n').Select(x => x.Trim(' ', '\t')).ToList();
                        result.Username = creds.Count > 0 ? creds[0] : "";
                        result.Password = creds.Count > 1 ? creds[1] : "";
                    }
                    output.Add("auth-user-pass");
                    continue;
            }
            if (FileOptions.Contains(key) && words.Count >= 2 && words[0] == key && words[1] == "[inline]")
            {
                // "ca [inline]": the <ca> block in the profile holds it, and is all FiveT keeps.
                if (key == "tls-auth" && words.Count >= 3) output.Add($"key-direction {words[2]}");
                continue;
            }
            if (FileOptions.Contains(key) && words.Count >= 2 && words[0] == key)
            {
                var content = ReadFile(words[1], key, folder);
                if (key == "tls-auth" && words.Count >= 3) output.Add($"key-direction {words[2]}");
                output.Add($"<{key}>");
                output.Add(content);
                output.Add($"</{key}>");
                continue;
            }
            // Without a comment after the option: the check counts its words as arguments.
            output.Add(text.Trim(' ', '\t'));
        }
        if (inBlock != null) throw new OpenVpnProfileException($"The profile's <{inBlock}> block is not closed: the file looks cut off.");

        result.Text = string.Join("\n", output) + "\n";
        var bad = Problems(result.Text);
        if (bad.Count > 0) throw new OpenVpnProfileException($"This profile uses OpenVPN options FiveT does not allow: {string.Join(", ", bad)}.");
        var remotes = Remotes(result.Text);
        if (remotes.Count == 0) throw new OpenVpnProfileException("This profile names no server (no \"remote\" line).");
        result.Host = remotes[0].Host;
        result.Port = remotes[0].Port;
        // OpenVPN Connect names its copies by number ("1781727071873.ovpn"): the server says more.
        if (result.Name.Length == 0 || result.Name.All(char.IsDigit)) result.Name = remotes[0].Host;
        result.Dropped = dropped.Select(kv => $"{kv.Key}: {string.Join(", ", kv.Value)}").ToList();
        return result;
    }

    /// <summary>
    /// A file the profile points to (ca, cert, auth-user-pass…) is read from next to the profile only: an
    /// absolute path, or one a link walks outside that folder, could otherwise read anything the user can
    /// (an SSH key, cloud credentials…), and for auth-user-pass its first two lines become this
    /// connection's username and password, sent to its server.
    /// </summary>
    private static string ReadFile(string path, string option, string? folder)
    {
        if (folder == null)
            throw new OpenVpnProfileException($"The profile's {option} is in a separate file, {path}, but this profile was not opened from a file FiveT can look next to it in. Use a profile with everything inline.");
        var outside = $"The profile's {option} names a file outside its own folder ({path}), which FiveT will not read for safety. Put everything inline in the profile instead.";
        if (path.Length == 0 || Path.IsPathRooted(path) || path.StartsWith('~') || path.Contains(':') || path.StartsWith(@"\\", StringComparison.Ordinal))
            throw new OpenVpnProfileException(outside);
        string full, root;
        try
        {
            root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
            full = Path.GetFullPath(Path.Combine(root, path));
        }
        catch (Exception) { throw new OpenVpnProfileException(outside); }
        if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new OpenVpnProfileException(outside);
        byte[] data;
        try
        {
            // A link or junction anywhere between the profile's folder and the file leads somewhere else.
            for (var p = full; p.Length > root.Length; p = Path.GetDirectoryName(p) ?? root)
                if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new OpenVpnProfileException(outside);
            var info = new FileInfo(full);
            if (info.Length > MaxConfigBytes) throw new IOException("too large");
            data = File.ReadAllBytes(full);
        }
        catch (OpenVpnProfileException) { throw; }
        catch (Exception)
        {
            throw new OpenVpnProfileException($"The profile's {option} is in a separate file, {path}, which FiveT could not read. Put the file next to the profile, or use a profile with everything inline.");
        }
        if (option == "pkcs12") return Convert.ToBase64String(data, Base64FormattingOptions.InsertLineBreaks).Replace("\r\n", "\n");
        // Windows line ends go: a login file's "user\r" would be refused at connect as a line break. So does
        // Notepad's byte-order mark, which would become the first letter of the username.
        return Decode(data).Replace("\uFEFF", "").Replace("\r\n", "\n").Replace('\r', '\n').Trim(' ', '\t', '\n');
    }

    /// <summary>A new connection from an import, named apart from the ones in <paramref name="taken"/>.</summary>
    public static Connection ConnectionFrom(Imported imp, IReadOnlyCollection<string> taken)
    {
        var c = new Connection { Kind = VpnKind.OpenVpn };
        c.Name = VpnImport.UniqueName(imp.Name.Trim().Length == 0 ? imp.Host : imp.Name.Trim(), taken);
        Apply(imp, c);
        return c;
    }

    /// <summary>
    /// The imported profile into <paramref name="c"/> (a new connection, or Replace Profile… on one): a login
    /// found in the profile fills empty fields only, and a server that asks for a one-time code with the
    /// password gets it sent that way (OpenVPN's static challenge), once a secret is entered.
    /// </summary>
    public static void Apply(Imported imp, Connection c)
    {
        c.OvpnProfile = imp.Text;
        c.Host = imp.Host;
        c.Port = imp.Port;
        c.Realm = "";
        if (c.Username.Length == 0) c.Username = imp.Username;
        if (c.Password.Length == 0) c.Password = imp.Password;
        if (imp.StaticChallenge && c.OtpMode == OtpMode.None) c.OtpMode = OtpMode.Separate;
    }

    // MARK: Checks

    private static readonly Regex BlockOpen = new("^<[A-Za-z0-9-]+>$", RegexOptions.CultureInvariant);
    private static readonly Regex TunDev = new("^tun[0-9]*$", RegexOptions.CultureInvariant);

    /// <summary>What FiveT refuses in <paramref name="text"/> (empty when it may run). The Mac helper's ovpn-run rules.</summary>
    public static List<string> Problems(string text)
    {
        var bad = new List<string>();
        void Add(string w) { if (!bad.Contains(w)) bad.Add(w); }
        string? inBlock = null;
        var conn = false;
        foreach (var line in text.Split('\n'))
        {
            var t = line.Trim(' ', '\t').Trim('\r');
            // OpenVPN ends an inline block on any line that starts with "</name>", not only a line that is
            // exactly that, discarding anything after the tag on that same line: "</ca>x" closes it. An
            // exact-match check here would read everything up to the next real close tag as block content,
            // hiding whatever it holds from the checks below.
            if (inBlock is { } b) { if (t.StartsWith($"</{b}>", StringComparison.Ordinal)) inBlock = null; continue; }
            if (t.Length == 0 || t.StartsWith('#') || t.StartsWith(';')) continue;
            if (t == "<connection>") { if (conn) Add("nested <connection>"); conn = true; continue; }
            if (t == "</connection>") { if (!conn) Add("</connection>"); conn = false; continue; }
            if (BlockOpen.IsMatch(t))
            {
                var name = t[1..^1];
                if (!Blocks.Contains(name)) Add($"<{name}>");
                inBlock = name;
                continue;
            }
            if (t.StartsWith('<')) { Add("a line starting with <"); continue; }
            // Tokens(), not a raw whitespace split: OpenVPN unquotes each word before reading it, so a
            // quoted "opt" right after setenv (or a quoted option name) must not hide from this list.
            var w = Tokens(t);
            if (w.Count == 0) continue;
            if (w[0].StartsWith("--", StringComparison.Ordinal)) w[0] = w[0][2..];
            if (w[0] == "setenv" && w.Count >= 2 && w[1] == "opt")
            {
                if (w.Count < 3) continue;
                w.RemoveRange(0, 2);
                if (w[0].StartsWith("--", StringComparison.Ordinal)) w[0] = w[0][2..];
            }
            var key = w[0];
            if (!Allowed.Contains(key)) { Add(key); continue; }
            if (InlineOnlySet.Contains(key) && w.Count > 1) Add($"{key} with a file");
            // No argument is refused too.
            var arg = w.Count > 1 ? w[1] : "";
            if (key == "dev" && !TunDev.IsMatch(arg)) Add($"dev {arg}");
            if (key == "dev-type" && arg != "tun") Add($"dev-type {arg}");
            if (key is "http-proxy" or "socks-proxy" && w.Count > 3) Add($"{key} with a password file");
        }
        if (inBlock != null) Add($"unclosed <{inBlock}>");
        if (conn) Add("unclosed <connection>");
        return bad;
    }

    /// <summary>The profile asks for a username and password (an auth-user-pass line).</summary>
    public static bool NeedsLogin(string text) => Directives(text).Any(d => d[0] == "auth-user-pass");

    /// <summary>The profile itself sends all traffic through the tunnel (servers often push this instead).</summary>
    public static bool RedirectsGateway(string text) => Directives(text).Any(d => d[0] == "redirect-gateway");

    /// <summary>
    /// Windows: the kernel driver (ovpn-dco) carries only AEAD ciphers, no compression and no fragmenting.
    /// A profile that asks for anything else gets the TAP driver from the start.
    /// </summary>
    public static bool NeedsTapDriver(string text)
    {
        foreach (var d in Directives(text))
        {
            switch (d[0])
            {
                case "comp-lzo" when d.Count == 1 || d[1] != "no":
                case "compress" when d.Count > 1 && d[1] != "stub" && d[1] != "stub-v2" && d[1] != "migrate":
                case "fragment":
                case "secret":
                    return true;
                case "cipher" or "data-ciphers-fallback" when d.Count > 1 && !IsAead(d[1]):
                    return true;
                case "data-ciphers" or "ncp-ciphers" when d.Count > 1 && d[1].Split(':').All(c => !IsAead(c)):
                    return true;
            }
        }
        return false;

        static bool IsAead(string cipher) =>
            cipher.Contains("GCM", StringComparison.OrdinalIgnoreCase) || cipher.Contains("CHACHA20", StringComparison.OrdinalIgnoreCase);
    }

    public sealed record Remote(string Host, int Port, string Proto);

    /// <summary>Its servers in order: host, port, protocol ("udp" unless the profile says otherwise).</summary>
    public static List<Remote> Remotes(string text)
    {
        var port = 1194;
        var proto = "udp";
        var hosts = new List<(string Host, int? Port, string? Proto)>();
        foreach (var d in Directives(text))
        {
            switch (d[0])
            {
                case "port" or "rport": if (d.Count > 1 && int.TryParse(d[1], out var p)) port = p; break;
                case "proto": if (d.Count > 1) proto = d[1]; break;
                case "remote":
                    if (d.Count > 1) hosts.Add((d[1], d.Count > 2 && int.TryParse(d[2], out var rp) ? rp : null, d.Count > 3 ? d[3] : null));
                    break;
            }
        }
        return hosts.Select(h => new Remote(h.Host, h.Port ?? port, (h.Proto ?? proto).StartsWith("tcp", StringComparison.Ordinal) ? "tcp" : "udp")).ToList();
    }

    /// <summary>Every host OpenVPN itself connects to: the servers, or the proxy it reaches them through.</summary>
    public static List<string> ServerHosts(string text)
    {
        var proxies = Directives(text).Where(d => d[0] is "http-proxy" or "socks-proxy" && d.Count > 1).Select(d => d[1]).ToList();
        return proxies.Count > 0 ? proxies : Remotes(text).Select(r => r.Host).ToList();
    }

    // MARK: Launch

    /// <summary>
    /// The profile as FiveT hands it to openvpn.exe: the login inline (username, then the password, with the
    /// one-time code appended or as OpenVPN's static-challenge answer), never on disk.
    /// </summary>
    public static string ForLaunch(Connection c, string? code)
    {
        var text = c.OvpnProfile;
        if (!NeedsLogin(text)) return text;
        // The bare auth-user-pass line would make OpenVPN ask on the console: the inline block replaces it.
        var lines = new List<string>();
        string? inBlock = null;
        foreach (var line in text.Split('\n'))
        {
            var t = line.Trim(' ', '\t', '\r');
            if (inBlock is { } b) { if (t.StartsWith($"</{b}>", StringComparison.Ordinal)) inBlock = null; lines.Add(line); continue; }
            if (BlockOpen.IsMatch(t) && t != "<connection>") inBlock = t[1..^1];
            var first = Tokens(t).FirstOrDefault() ?? "";
            if (first.StartsWith("--", StringComparison.Ordinal)) first = first[2..];
            if (first == "auth-user-pass" && inBlock == null) continue;
            lines.Add(line);
        }
        var password = c.Password;
        if (code != null)
        {
            switch (c.OtpMode)
            {
                case OtpMode.AppendToPassword: password += code; break;
                case OtpMode.Separate:
                    password = "SCRV1:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(c.Password)) + ":" + Convert.ToBase64String(Encoding.UTF8.GetBytes(code));
                    break;
            }
        }
        text = string.Join("\n", lines);
        if (!text.EndsWith('\n')) text += "\n";
        return text + $"<auth-user-pass>\n{c.Username.Trim()}\n{password}\n</auth-user-pass>\n";
    }

    // MARK: Parsing

    /// <summary>Every option line outside inline blocks (those inside &lt;connection&gt; too), as words.</summary>
    private static List<List<string>> Directives(string text)
    {
        var output = new List<List<string>>();
        string? inBlock = null;
        foreach (var line in text.Split('\n'))
        {
            var t = line.Trim(' ', '\t', '\r');
            if (inBlock is { } b) { if (t.StartsWith($"</{b}>", StringComparison.Ordinal)) inBlock = null; continue; }
            if (t.Length == 0 || t.StartsWith('#') || t.StartsWith(';') || t is "<connection>" or "</connection>") continue;
            if (t.StartsWith('<') && t.EndsWith('>')) { inBlock = t[1..^1]; continue; }
            var w = Tokens(t);
            if (w.Count > 0 && w[0].StartsWith("--", StringComparison.Ordinal)) w[0] = w[0][2..];
            if (w.Count > 0) output.Add(w);
        }
        return output;
    }

    /// <summary>
    /// A line split into words the way OpenVPN reads it: spaces separate, "double" or 'single' quotes keep a
    /// word together, and a backslash escapes the next character outside single quotes.
    /// </summary>
    public static List<string> Tokens(string line) => Scan(line).Words;

    /// <summary>…and the line without the comment OpenVPN ends it at: a "#" or ";" where a new word would start.</summary>
    private static (List<string> Words, string Text) Scan(string line)
    {
        var words = new List<string>();
        var cur = new StringBuilder();
        var have = false;
        char? quote = null;
        var escape = false;
        var end = line.Length;
        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            if (escape) { cur.Append(ch); escape = false; have = true; continue; }
            if (!have && quote == null && ch is '#' or ';') { end = i; break; }
            if (ch == '\\' && quote != '\'') { escape = true; continue; }
            if (quote is { } q)
            {
                if (ch == q) quote = null; else cur.Append(ch);
                continue;
            }
            if (ch is '"' or '\'') { quote = ch; have = true; continue; }
            if (ch is ' ' or '\t')
            {
                if (have) { words.Add(cur.ToString()); cur.Clear(); have = false; }
                continue;
            }
            cur.Append(ch);
            have = true;
        }
        if (have) words.Add(cur.ToString());
        return (words, line[..end]);
    }
}
