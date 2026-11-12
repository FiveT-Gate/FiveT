using System.Text.Json;
using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT;

/// <summary>
/// Persists connections + app settings to %LOCALAPPDATA%\FiveT\connections.json.
/// Passwords and TOTP secrets are stored DPAPI-encrypted (current user scope), so the file is
/// only readable by this Windows account, on this machine. All access happens on the UI thread.
/// </summary>
public sealed class ConnectionStore : IConnectionList
{
    public static ConnectionStore Shared { get; } = new();

    public List<Connection> Connections { get; private set; } = new();
    IReadOnlyList<Connection> IConnectionList.Connections => Connections;

    private bool _notify, _autoReconnect = true, _verboseLogging, _verbosePackets, _mcpEnabled = true;
    private bool _welcomeShown, _watchdog = true, _killSwitch, _bypassIran = true;
    private bool _autoUpdateCheck = true;
    private string _openconnectPath = "";

    /// <summary>Settings → General → VPN Settings: block this PC's internet while a VPN that carries all traffic is down
    /// without having been switched off (the Mac's killSwitch). Off by default.</summary>
    public bool KillSwitch { get => _killSwitch; set { _killSwitch = value; Persist(); Changed?.Invoke(); KillSwitchChanged?.Invoke(); } }
    /// <summary>V2Ray and Outline: .ir names and Iranian addresses skip the server and go direct (the Mac's bypassIran). On by default.</summary>
    public bool BypassIran { get => _bypassIran; set { _bypassIran = value; Persist(); Changed?.Invoke(); } }
    public event Action? KillSwitchChanged;

    /// <summary>Show a notification balloon when the connection state changes (the Windows counterpart of "name in menu bar").</summary>
    public bool NotifyOnChange { get => _notify; set { _notify = value; Persist(); Changed?.Invoke(); } }
    public bool AutoReconnect { get => _autoReconnect; set { _autoReconnect = value; Persist(); Changed?.Invoke(); } }
    public bool VerboseLogging { get => _verboseLogging; set { _verboseLogging = value; Persist(); Changed?.Invoke(); } }
    /// <summary>Keep openconnect's per-packet trace lines (-vv, thousands per minute).</summary>
    public bool VerbosePackets { get => _verbosePackets; set { _verbosePackets = value; Persist(); Changed?.Invoke(); } }
    /// <summary>Settings → MCP: run the MCP server so assistants can control the app.</summary>
    public bool McpEnabled { get => _mcpEnabled; set { _mcpEnabled = value; Persist(); McpEnabledChanged?.Invoke(value); Changed?.Invoke(); } }
    /// <summary>Explicit path to openconnect.exe chosen in Setup; empty = search the usual places.</summary>
    public string OpenconnectPath { get => _openconnectPath; set { _openconnectPath = value; Persist(); Changed?.Invoke(); } }
    /// <summary>"Reconnect when the tunnel stops answering": the watchdog (on by default, as on the Mac).</summary>
    public bool Watchdog { get => _watchdog; set { _watchdog = value; Persist(); Changed?.Invoke(); } }

    /// <summary>"Check for updates automatically": once a day, from FiveT's own GitHub releases (on by default).</summary>
    public bool AutoUpdateCheck { get => _autoUpdateCheck; set { _autoUpdateCheck = value; Persist(); Changed?.Invoke(); } }
    /// <summary>Settings has opened by itself once (the first start); it does not do that again.</summary>
    public bool WelcomeShown { get => _welcomeShown; set { _welcomeShown = value; Persist(); } }

    /// <summary>Fires after any change (connections or settings).</summary>
    public event Action? Changed;
    public event Action<bool>? McpEnabledChanged;

    public string FilePath => Paths.ConnectionsFile;
    public string Directory => Paths.DataDir;

    private bool _loading = true;

    /// <summary>connections.json existed but could not be read (or only partly): it has to be copied to a
    /// .bad file before anything is saved over it.</summary>
    private bool _needsBackup;
    private bool _blockedLogged;

    /// <summary>Plain-words note for the user when connections.json could not be read at start (else null).</summary>
    public string? LoadProblem { get; private set; }

    /// <summary>"...Protected" values that could not be decrypted (another Windows account or PC), by connection and field,
    /// so saving writes them back untouched instead of an empty secret.</summary>
    private readonly Dictionary<(Guid Id, string Key), string> _unreadableSecrets = new();

    private enum FileState { Missing, Ok, Damaged }

    private ConnectionStore()
    {
        System.IO.Directory.CreateDirectory(Paths.DataDir);
        var seeded = false;
        var state = ReadFile(out var root, out var problem);
        if (state == FileState.Ok)
        {
            try { if (!Load(root!)) problem = "has entries FiveT did not understand"; }
            catch (Exception e) { state = FileState.Damaged; problem = $"could not be decoded ({e.Message})"; }
        }
        if (state == FileState.Missing)
        {
            // Only a file that is not there at all means a first start. A file that is there but cannot be
            // read must never be replaced by the seeds: the next save would destroy the user's connections.
            Connections = Connection.Seeds();
            seeded = true;
        }
        else if (problem != null)
        {
            var restored = false;
            if (state == FileState.Damaged)
            {
                Connections = new();
                _welcomeShown = true;   // there was a file, so this is not a first start
                restored = RestoreFromLastGood();
            }
            _needsBackup = true;
            var copy = BackUpFile();
            LoadProblem = $"connections.json {problem}. "
                + (restored ? $"FiveT restored your {Connections.Count} connection(s) from the copy it made at an earlier start ({Path.GetFileName(LastGoodPath)}); anything changed after that copy is missing. " : "")
                + (copy != null
                    ? $"The damaged file was kept as {copy} in {Paths.DataDir}" + (restored ? "." : "; FiveT will not save over the original until that copy exists.")
                    : "No copy of the damaged file could be made, so FiveT will not save any change until it can.");
            Log.Shared.Write($"ERROR connections.json {problem}; " + (restored ? "restored from the last good copy; " : "")
                             + (copy != null ? $"copy kept as {copy}" : "no copy could be made, not saving"), LogLevel.Error);
        }
        _loading = false;
        if (seeded) Persist();
        else if (state == FileState.Ok && problem == null)
        {
            // A file that loaded whole is the one worth keeping a copy of: it is what RestoreFromLastGood reads
            // when a later start finds connections.json damaged. Made before anything is written back.
            KeepLastGood();
            if (_repaired.Count > 0)
            {
                // Connections saved with a pasted blank line or a whole "remote …" line are put right once
                // (the Mac's 1.13.3).
                Log.Shared.Write($"repaired pasted text in the saved connection(s): {string.Join(", ", _repaired)}");
                Persist();
            }
        }
        UpdateRedactor();
    }

    /// <summary>connections.json.bak: the file as it was at the last start that read it whole.</summary>
    private string LastGoodPath => FilePath + ".bak";

    private void KeepLastGood()
    {
        try
        {
            var bytes = File.ReadAllBytes(FilePath);
            if (File.Exists(LastGoodPath) && new FileInfo(LastGoodPath).Length == bytes.Length
                && File.ReadAllBytes(LastGoodPath).AsSpan().SequenceEqual(bytes)) return;
            SafeFile.Replace(LastGoodPath, bytes);
        }
        catch (Exception e) { Log.Shared.Write($"could not keep a copy of connections.json: {e.Message}", LogLevel.Error); }
    }

    /// <summary>
    /// connections.json is damaged: read the copy made at the last start that went well. True when it gave
    /// the connections back. The damaged file itself is kept as a .bad copy by the caller before any save.
    /// </summary>
    private bool RestoreFromLastGood()
    {
        try
        {
            if (!File.Exists(LastGoodPath)) return false;
            if (Json.Parse(File.ReadAllText(LastGoodPath)) is not JsonObject root) return false;
            _repaired.Clear();
            Load(root);
            return Connections.Count > 0;
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not read the last good copy of connections.json: {e.Message}", LogLevel.Error);
            Connections = new();
            return false;
        }
    }

    /// <summary>Names of the connections whose pasted fields were cleaned while loading.</summary>
    private readonly List<string> _repaired = new();

    /// <summary>
    /// Reads the file, trying again a few times when it is locked (an antivirus scanner or backup tool holding it for
    /// a moment right after a save is the usual reason). <paramref name="problem"/> says what is wrong when it is damaged.
    /// </summary>
    private FileState ReadFile(out JsonObject? root, out string? problem)
    {
        root = null;
        problem = null;
        string? text = null;
        for (var attempt = 0; text == null; attempt++)
        {
            try
            {
                if (!File.Exists(FilePath)) return FileState.Missing;
                text = File.ReadAllText(FilePath);
            }
            catch (Exception e) when (attempt < 4 && (e is IOException or UnauthorizedAccessException))
            {
                Thread.Sleep(100 * (attempt + 1));
            }
            catch (Exception e)
            {
                problem = $"could not be read ({e.Message})";
                return FileState.Damaged;
            }
        }
        root = Json.Parse(text) as JsonObject;
        if (root == null)
        {
            problem = "is not valid JSON (an object was expected)";
            return FileState.Damaged;
        }
        return FileState.Ok;
    }

    /// <summary>
    /// Copies connections.json to connections.json.bad-yyyyMMdd-HHmmss and returns that name; null when it could not
    /// be copied. An identical earlier copy is reused, so a file that stays broken does not pile up a copy per start.
    /// </summary>
    private string? BackUpFile()
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (!File.Exists(FilePath)) { _needsBackup = false; return "(nothing left to copy)"; }
                var bytes = File.ReadAllBytes(FilePath);
                foreach (var old in System.IO.Directory.GetFiles(Paths.DataDir, Path.GetFileName(FilePath) + ".bad-*"))
                    if (new FileInfo(old).Length == bytes.Length && File.ReadAllBytes(old).AsSpan().SequenceEqual(bytes))
                    {
                        _needsBackup = false;
                        return Path.GetFileName(old);
                    }
                var stem = FilePath + ".bad-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", System.Globalization.CultureInfo.InvariantCulture);
                var target = stem;
                for (var n = 2; File.Exists(target); n++) target = stem + "-" + n;
                File.WriteAllBytes(target, bytes);
                _needsBackup = false;
                return Path.GetFileName(target);
            }
            catch (Exception e)
            {
                if (attempt == 2) Log.Shared.Write($"ERROR could not copy connections.json: {e.Message}", LogLevel.Error);
                else Thread.Sleep(100 * (attempt + 1));
            }
        }
        return null;
    }

    /// <summary>Tells the log which strings it must never write (see <see cref="Redactor"/>).</summary>
    private void UpdateRedactor() =>
        Redactor.SetSecrets(Connections.SelectMany(c => new[] { c.Password, c.TotpSecret, c.TotpSecret.Replace(" ", ""), c.V2RayLink, c.V2RaySubscription }
            .Concat(V2RayConfig.SecretsOf(c.V2RayOutbound))));

    /// <summary>Reads the settings and connections. False when something in the file was not understood (it is skipped).</summary>
    private bool Load(JsonObject root)
    {
        var clean = true;
        // Tolerant decoding so older files keep loading when fields are added.
        // Only Windows' own key: the Mac's showNameInMenuBar means something else and must not switch notifications on.
        _notify = Json.Bool(root["notifyOnChange"]) ?? false;
        _verboseLogging = Json.Bool(root["verboseLogging"]) ?? false;
        _verbosePackets = Json.Bool(root["verbosePackets"]) ?? false;
        _autoReconnect = Json.Bool(root["autoReconnect"]) ?? true;
        _mcpEnabled = Json.Bool(root["mcpEnabled"]) ?? true;
        _openconnectPath = Json.Str(root["openconnectPath"]) ?? "";
        // "linksConnectWithoutAsking" / "linksAlwaysAllow" are no longer read: links always ask (Mac 1.15.1).
        _watchdog = Json.Bool(root["watchdog"]) ?? true;
        _autoUpdateCheck = Json.Bool(root["autoUpdateCheck"]) ?? true;
        _killSwitch = Json.Bool(root["killSwitch"]) ?? false;
        // "Bypass Iranian Websites" used to be set per V2Ray connection on the Mac (v2rayIranDirect): a file
        // from then means on, unless every V2Ray connection had it off.
        var anyV2Ray = false;
        var anyIranDirect = false;
        var list = new List<Connection>();
        if (root["connections"] is JsonArray arr)
        {
            foreach (var n in arr)
            {
                if (n is not JsonObject o) { clean = false; continue; }
                var id = Guid.TryParse(Json.Str(o["id"]), out var g) ? g : Guid.NewGuid();
                var name = Json.Str(o["name"]) ?? "Connection";
                var c = new Connection
                {
                    Id = id,
                    Name = name,
                    Kind = VpnKindExt.FromWire(Json.Str(o["kind"])),
                    OvpnProfile = Secret(o, "ovpnProfile", id, name),
                    V2RayOutbound = Secret(o, "v2rayOutbound", id, name),
                    V2RayLink = Secret(o, "v2rayLink", id, name),
                    V2RaySubscription = Secret(o, "v2raySubscription", id, name),
                    AcceptedOtp = Json.Str(o["acceptedOTP"]) ?? "",
                    Host = Json.Str(o["host"]) ?? "",
                    Port = Json.Int(o["port"]) ?? 10443,
                    Realm = Json.Str(o["realm"]) ?? "",
                    Username = Json.Str(o["username"]) ?? "",
                    Password = Secret(o, "password", id, name),
                    TotpSecret = Secret(o, "totpSecret", id, name),
                    OtpMode = OtpModeExt.FromWire(Json.Str(o["otpMode"])),
                    TrustedCert = Json.Str(o["trustedCert"]) ?? "",
                    TrustedCertHost = Json.Str(o["trustedCertHost"]) ?? "",
                    TrustedCertNames = (o["trustedCertNames"] as JsonArray)?.Select(Json.Str).OfType<string>().ToList() ?? new List<string>(),
                    TrustedCertPin = Json.Str(o["trustedCertPin"]) ?? "",
                    PendingCert = Json.Str(o["pendingCert"]) ?? "",
                    PendingCertHost = Json.Str(o["pendingCertHost"]) ?? "",
                    PendingCertFirst = Json.Bool(o["pendingCertFirst"]) ?? false,
                    PendingCertInfo = Json.Str(o["pendingCertInfo"]) ?? "",
                    PendingCertPin = Json.Str(o["pendingCertPin"]) ?? "",
                    ExtraConfig = Json.Str(o["extraConfig"]) ?? "",
                    DnsDomains = Json.Str(o["dnsDomains"]) ?? "",
                    LastError = Json.Str(o["lastError"]),
                };
                c.LastConnectedAt = ParseWhen(o["lastConnectedAt"]);
                // Windows 1.4.0 and older kept openconnect's pin in trustedCert. Move it to its own
                // field: trustedCert is the Mac's hex SHA-256, filled in by the next certificate check.
                if (c.TrustedCert.StartsWith("pin-sha256:", StringComparison.Ordinal))
                {
                    if (c.TrustedCertPin.Length == 0) c.TrustedCertPin = c.TrustedCert;
                    c.TrustedCert = "";
                }
                // Saved before the gateway was recorded (the Mac's rule): a pin, or a login before, means
                // the gateway as it is set now is a known one.
                if (o["trustedCertHost"] == null && (c.TrustedCert.Length > 0 || c.TrustedCertPin.Length > 0 || c.LastConnectedAt != null))
                    c.TrustedCertHost = c.GatewayKey;
                // Saved before the accepted way was remembered: a connection that has connected before did so the way it is saved.
                if (o["acceptedOTP"] == null && c.LastConnectedAt != null) c.AcceptedOtp = c.OtpAcceptedKey;
                if (c.IsV2Ray)
                {
                    anyV2Ray = true;
                    if (Json.Bool(o["v2rayIranDirect"]) ?? true) anyIranDirect = true;
                }
                // After the certificate fields: a repaired host is a gateway met for the first time, as an edit is.
                // Connections saved with blank lines pasted into their fields are repaired once here (Mac 1.13.3).
                var cleaned = c.CleanPastedFields();
                if (cleaned.Count > 0) _repaired.Add($"{c.Name} ({string.Join(", ", cleaned)})");
                list.Add(c);
            }
        }
        else if (root["connections"] != null) clean = false;
        Connections = list;
        _bypassIran = Json.Bool(root["bypassIran"]) ?? (!anyV2Ray || anyIranDirect);
        // Someone updating from a version without this flag has already been through the first start.
        _welcomeShown = Json.Bool(root["welcomeShown"]) ?? list.Count > 0;
        return clean;
    }

    /// <summary>
    /// lastConnectedAt as Windows writes it (ISO 8601 text) or as the Mac's JSONEncoder does (a number:
    /// seconds since 2001-01-01 00:00:00 UTC). Null when it is neither.
    /// </summary>
    private static DateTime? ParseWhen(JsonNode? node)
    {
        try
        {
            if (Json.Str(node) is { } text)
                return DateTime.TryParse(text, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d) ? d.ToLocalTime() : null;
            if (node is JsonValue v && v.TryGetValue<double>(out var seconds) && double.IsFinite(seconds))
                return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(seconds).ToLocalTime();
        }
        catch (ArgumentOutOfRangeException) { }   // a number too large to be a date
        return null;
    }

    /// <summary>
    /// Reads "&lt;key&gt;Protected" (DPAPI, base64) or falls back to a plain "&lt;key&gt;" (e.g. a file copied from the Mac).
    /// When the DPAPI value cannot be decrypted (the file came from another Windows account or PC) the original text is
    /// remembered and written back by <see cref="Persist"/> until the user enters a new value, so one bad start does not erase it.
    /// </summary>
    private string Secret(JsonObject o, string key, Guid id, string name)
    {
        if (Json.Str(o[key + "Protected"]) is { Length: > 0 } enc)
        {
            try { return Dpapi.Unprotect(enc); }
            catch (Exception e)
            {
                _unreadableSecrets[(id, key)] = enc;
                Log.Shared.Write($"ERROR could not decrypt the saved {key} of '{name}' ({e.Message}); it stays as it is in connections.json until a new one is entered", LogLevel.Error);
            }
        }
        return Json.Str(o[key]) ?? "";
    }

    /// <summary>The "&lt;key&gt;Protected" text to save: the value encrypted, or, for a secret that could not be decrypted and is still empty, the original.</summary>
    private string ProtectedSecret(Connection c, string key, string value)
    {
        if (value.Length == 0) return _unreadableSecrets.TryGetValue((c.Id, key), out var original) ? original : "";
        _unreadableSecrets.Remove((c.Id, key));   // a new value replaces the unreadable one
        return Dpapi.Protect(value);
    }

    public void Persist()
    {
        if (_loading) return;
        UpdateRedactor();
        // An unreadable connections.json is only ever replaced once a copy of it exists.
        if (_needsBackup && BackUpFile() == null)
        {
            if (!_blockedLogged) Log.Shared.Write("ERROR not saving connections.json: the file on disk could not be read and could not be copied, so saving would destroy it", LogLevel.Error);
            _blockedLogged = true;
            return;
        }
        try
        {
            var root = new JsonObject
            {
                ["version"] = 2,
                ["notifyOnChange"] = _notify,
                ["verboseLogging"] = _verboseLogging,
                ["verbosePackets"] = _verbosePackets,
                ["autoReconnect"] = _autoReconnect,
                ["mcpEnabled"] = _mcpEnabled,
                ["openconnectPath"] = _openconnectPath,
                ["watchdog"] = _watchdog,
                ["autoUpdateCheck"] = _autoUpdateCheck,
                ["killSwitch"] = _killSwitch,
                ["bypassIran"] = _bypassIran,
                ["welcomeShown"] = _welcomeShown,   // Windows only; the Mac drops it when it saves
            };
            var arr = new JsonArray();
            foreach (var c in Connections)
            {
                var o = new JsonObject
                {
                    ["id"] = c.Id.ToString().ToUpperInvariant(),
                    ["name"] = c.Name,
                    ["kind"] = c.Kind.Wire(),
                    ["host"] = c.Host,
                    ["port"] = c.Port,
                    ["realm"] = c.Realm,
                    ["username"] = c.Username,
                    ["passwordProtected"] = ProtectedSecret(c, "password", c.Password),
                    ["totpSecretProtected"] = ProtectedSecret(c, "totpSecret", c.TotpSecret),
                    ["otpMode"] = c.OtpMode.Wire(),
                    ["trustedCert"] = c.TrustedCert,
                    ["trustedCertHost"] = c.TrustedCertHost,
                    ["trustedCertNames"] = Json.Array(c.TrustedCertNames),
                    ["trustedCertPin"] = c.TrustedCertPin,
                    ["pendingCert"] = c.PendingCert,
                    ["pendingCertHost"] = c.PendingCertHost,
                    ["pendingCertFirst"] = c.PendingCertFirst,
                    ["pendingCertInfo"] = c.PendingCertInfo,
                    ["pendingCertPin"] = c.PendingCertPin,
                    ["extraConfig"] = c.ExtraConfig,
                    ["dnsDomains"] = c.DnsDomains,
                };
                if (c.AcceptedOtp.Length > 0) o["acceptedOTP"] = c.AcceptedOtp;
                // Only what the kind uses: a Forti connection carries no empty VPN fields. All four hold
                // something secret (a private key, a user id, a password, a subscription token).
                if (c.IsOpenVpn) o["ovpnProfileProtected"] = ProtectedSecret(c, "ovpnProfile", c.OvpnProfile);
                if (c.IsV2Ray)
                {
                    o["v2rayOutboundProtected"] = ProtectedSecret(c, "v2rayOutbound", c.V2RayOutbound);
                    o["v2rayLinkProtected"] = ProtectedSecret(c, "v2rayLink", c.V2RayLink);
                    o["v2raySubscriptionProtected"] = ProtectedSecret(c, "v2raySubscription", c.V2RaySubscription);
                }
                if (c.LastConnectedAt is { } d) o["lastConnectedAt"] = Json.Iso(d);
                if (c.LastError is { } e) o["lastError"] = e;
                arr.Add(o);
            }
            root["connections"] = arr;
            SafeFile.Replace(FilePath, Json.ToPretty(root));
            SaveProblem = null;
        }
        catch (Exception e)
        {
            // The file on disk is still the last one that was saved whole (SafeFile never writes into it).
            SaveProblem = $"FiveT could not save connections.json ({e.Message}). Your last saved connections are still on disk; changes made since are only in memory.";
            Log.Shared.Write($"ERROR saving connections.json: {e.Message}", LogLevel.Error);
        }
    }

    /// <summary>Plain-words note when the last save failed (else null). The file on disk is the previous good one.</summary>
    public string? SaveProblem { get; private set; }

    public Connection? Get(Guid id) => Connections.FirstOrDefault(c => c.Id == id);

    /// <summary>Changes fields of the stored copy and saves.</summary>
    public void Mutate(Guid id, Action<Connection> change)
    {
        var c = Get(id);
        if (c == null) return;
        change(c);
        Persist();
        Changed?.Invoke();
    }

    public Connection Add()
    {
        var c = new Connection();
        Connections.Add(c);
        Persist();
        Changed?.Invoke();
        return c;
    }

    /// <summary>Adds one connection made elsewhere (an imported OpenVPN profile or V2Ray server) and saves.</summary>
    public Connection Add(Connection c)
    {
        Connections.Add(c);
        Persist();
        Changed?.Invoke();
        return c;
    }

    /// <summary>Adds connections made elsewhere (the FortiClient import) and saves once.</summary>
    public void AddRange(IEnumerable<Connection> added)
    {
        Connections.AddRange(added);
        Persist();
        Changed?.Invoke();
    }

    public void Remove(Guid id)
    {
        Connections.RemoveAll(c => c.Id == id);
        Persist();
        Changed?.Invoke();
    }
}
