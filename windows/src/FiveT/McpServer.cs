using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT;

// FiveT as an MCP server (Model Context Protocol), so AI assistants such as Claude Desktop,
// Claude Code or Cursor can see and control the VPN. Shell scripts get the same tools through
// fivetctl.exe (`fivetctl status`, `fivetctl connect Office`, …).
//
// How the pieces fit:
//
//   assistant ──spawns──▶ `fivetctl --mcp` (bridge, plain stdio)        shell ──▶ `fivetctl status`
//                              │  named pipe, DACL = this user only                  │
//                              ▼◀────────────────────────────────────────────────────┘
//                        FiveT.exe (McpServer, the process that owns the tunnel)
//
// MCP clients start a fresh process per session and talk JSON-RPC 2.0 over its stdin/stdout,
// one JSON object per line. The VPN state lives in the running tray app, so that process is
// only a bridge: it forwards the bytes to the app's pipe (starting the app if needed).
// The app itself answers `initialize`, `tools/list` and `tools/call`.

/// <summary>One connected assistant.</summary>
public sealed class McpClientSession
{
    public NamedPipeServerStream Pipe { get; }
    public LineWriter Writer { get; }
    public string ClientName { get; set; } = "assistant";

    public McpClientSession(NamedPipeServerStream pipe)
    {
        Pipe = pipe;
        Writer = new LineWriter(pipe);
    }

    public void Send(JsonObject o) => Writer.Send(o);
}

/// <summary>
/// Listens on the named pipe and answers MCP requests. Start/stop on the UI thread; every request
/// is handled on the thread pool and hops onto the UI thread only for the moments it touches
/// VpnManager / ConnectionStore.
/// </summary>
public sealed class McpServer
{
    public static McpServer Shared { get; } = new();
    public const string ProtocolVersion = "2025-06-18";
    private static readonly HashSet<string> SupportedVersions = new() { "2024-11-05", "2025-03-26", "2025-06-18" };

    public bool IsListening { get; private set; }
    public int ClientCount { get; private set; }
    public event Action? Changed;

    private CancellationTokenSource? _cts;
    private readonly object _lock = new();
    private readonly HashSet<McpClientSession> _clients = new();

    private McpServer() { }

    public void Start()
    {
        if (_cts != null) return;
        var cts = new CancellationTokenSource();
        _cts = cts;
        IsListening = true;
        Changed?.Invoke();
        Log.Shared.Write($"[mcp] listening on {Paths.PipeDisplayPath}");
        Task.Run(() => AcceptLoop(cts.Token));
    }

    public void Stop()
    {
        if (_cts == null) return;
        Log.Shared.Write("[mcp] stopping");
        _cts.Cancel();
        _cts = null;
        List<McpClientSession> open;
        lock (_lock) open = _clients.ToList();
        foreach (var c in open) { try { c.Pipe.Dispose(); } catch { } }
        IsListening = false;
        Changed?.Invoke();
    }

    /// <summary>
    /// The DACL of every pipe FiveT serves (this one and the link hand-off): this user only, and not
    /// over the network. A network logon of the same account (SMB to \\host\pipe\…) carries the same
    /// user SID, so the Allow alone would let it in; the Deny on the NETWORK SID is listed first and wins.
    /// </summary>
    internal static PipeSecurity OwnerOnlyPipeSecurity()
    {
        var ps = new PipeSecurity();
        ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        using var id = WindowsIdentity.GetCurrent();
        ps.AddAccessRule(new PipeAccessRule(id.User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        return ps;
    }

    private async Task AcceptLoop(CancellationToken ct)
    {
        var security = OwnerOnlyPipeSecurity();
        var first = true;
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? pipe = null;
            Exception? failure = null;
            // FirstPipeInstance on the first instance only: if another process already owns the name,
            // assistants would reach that process instead of this one. After a quick off/on in Settings
            // the previous server's last instances may still be closing, so that one case is retried briefly.
            for (var attempt = 0; attempt < (first ? 10 : 1) && pipe == null; attempt++)
            {
                if (attempt > 0) await Task.Delay(200, CancellationToken.None);
                if (ct.IsCancellationRequested) return;
                try
                {
                    pipe = NamedPipeServerStreamAcl.Create(Paths.PipeName, PipeDirection.InOut,
                        NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | (first ? PipeOptions.FirstPipeInstance : PipeOptions.None),
                        65536, 65536, security);
                }
                catch (Exception e)
                {
                    failure = e;
                    if (e is not (IOException or UnauthorizedAccessException)) break;
                }
            }
            if (pipe == null)
            {
                Log.Shared.Write(first
                    ? $"[mcp] not listening: the pipe name is already taken by another process ({failure?.Message})"
                    : $"[mcp] cannot create pipe: {failure?.Message}", LogLevel.Error);
                Ui.Post(() => { IsListening = false; Changed?.Invoke(); });
                return;
            }
            first = false;
            try
            {
                await pipe.WaitForConnectionAsync(ct);
            }
            catch (OperationCanceledException) { pipe.Dispose(); return; }
            catch (Exception e)
            {
                Log.Shared.Write($"[mcp] accept failed: {e.Message}", LogLevel.Error);
                pipe.Dispose();
                await Task.Delay(500, CancellationToken.None);
                continue;
            }
            var session = new McpClientSession(pipe);
            // A client accepted while Stop() ran must not survive it (the Mac's generation counter):
            // Register refuses once the token is cancelled, under the lock Stop() snapshots the clients with.
            if (!Register(session, ct)) { pipe.Dispose(); return; }
            _ = Task.Run(() => Serve(session));
        }
    }

    private bool Register(McpClientSession s, CancellationToken ct)
    {
        int n;
        lock (_lock)
        {
            if (ct.IsCancellationRequested) return false;
            _clients.Add(s);
            n = _clients.Count;
        }
        Ui.Post(() => { ClientCount = n; Changed?.Invoke(); });
        Log.Shared.Write($"[mcp] assistant connected ({n} total)", LogLevel.Debug);
        return true;
    }

    private void Unregister(McpClientSession s)
    {
        int n;
        lock (_lock) { _clients.Remove(s); n = _clients.Count; }
        Ui.Post(() => { ClientCount = n; Changed?.Invoke(); });
        Log.Shared.Write($"[mcp] {s.ClientName} disconnected ({n} left)", LogLevel.Debug);
    }

    private void Serve(McpClientSession session)
    {
        var reader = new LineReader(session.Pipe);
        try
        {
            while (reader.NextLine() is { } line) Handle(line, session);
            if (reader.TooLong)
                Log.Shared.Write($"[mcp] {session.ClientName} sent a line over {LineReader.MaxLineBytes / (1024 * 1024)} MB without a newline; dropped", LogLevel.Error);
        }
        catch (Exception e)
        {
            Log.Shared.Write($"[mcp] {session.ClientName}: {e.Message}", LogLevel.Error);
        }
        Unregister(session);
        try { session.Pipe.Dispose(); } catch { }
    }

    private void Handle(string line, McpClientSession session)
    {
        if (line.Trim().Length == 0) return;
        var obj = Json.Parse(line);
        if (obj == null) { session.Send(ErrorReply(null, new RpcException(-32700, "Parse error"))); return; }
        if (obj is JsonArray batch)
        {
            foreach (var m in batch) if (m is JsonObject mo) Dispatch(mo, session);
        }
        else if (obj is JsonObject msg) Dispatch(msg, session);
        else session.Send(ErrorReply(null, new RpcException(-32600, "Invalid request")));
    }

    private void Dispatch(JsonObject msg, McpClientSession session)
    {
        var id = msg["id"];
        var isNotification = id == null;
        if (Json.Str(msg["method"]) is not { } method) return;   // a response to nothing, or junk
        var prms = msg["params"] as JsonObject ?? new JsonObject();
        if (isNotification)
        {
            if (method == "notifications/initialized") Log.Shared.Write($"[mcp] {session.ClientName} ready", LogLevel.Debug);
            return;
        }
        var idCopy = id!.DeepClone();
        Task.Run(() =>
        {
            JsonObject reply;
            try
            {
                var result = HandleMethod(method, prms, session);
                reply = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = idCopy, ["result"] = result };
            }
            catch (RpcException e) { reply = ErrorReply(idCopy, e); }
            catch (Exception e) { reply = ErrorReply(idCopy, new RpcException(-32603, e.Message)); }
            session.Send(reply);
        });
    }

    private static JsonObject ErrorReply(JsonNode? id, RpcException e) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["error"] = new JsonObject { ["code"] = e.Code, ["message"] = e.Message },
    };

    public const string Instructions =
        "FiveT is a Windows tray app that manages FortiGate SSL-VPN connections (via OpenConnect's fortinet protocol), and VPN connections (kind openvpn or v2ray; v2ray covers Outline). " +
        "Any number of Forti connections run together, plus at most one VPN: connecting a VPN while another is up switches to it. " +
        "After 2 failed logins to a gateway, connect returns login_limit_reached: do not retry, only the user can choose Try Anyway in FiveT's menu. " +
        "Use list_connections to see the saved connections and get_status for the current state, including the tunnel " +
        "adapter, the DNS servers and routes the gateway pushed. connect starts a tunnel and by default waits until it " +
        "is up or has failed (a few seconds when the gateway answers; up to timeout_seconds); it is idempotent. " +
        "Several connections can be up at the same time, each with its own tunnel adapter, routes and DNS: connect " +
        "adds a tunnel next to the ones already up, the same as clicking it in the tray menu. disconnect with a name " +
        "stops that one tunnel and leaves the others up; without a name it stops them all. get_status describes the " +
        "tunnel that is changing state (or else the newest connected one) at the top level, every active tunnel " +
        "under \"sessions\" and the names of the connected ones under \"active_connections\". " +
        "DNS caveat: when another VPN owns the default route, Windows may not " +
        "ask the tunnel's DNS for internal host names, so they fail to resolve while a direct query to the pushed DNS " +
        "server works. The fix is split DNS: add the internal domains to the connection's \"DNS domains\" (Settings → " +
        "Connections); FiveT then installs NRPT rules while connected. Use resolve and check_reachability to diagnose " +
        "\"VPN up but host unreachable\" in one call; they report both the tunnel DNS and the system resolver. get_log " +
        "returns event lines (info and errors) by default; ask for level \"debug\" for openconnect chatter. " +
        "get_settings and set_settings read and change the switches (kill switch, failover, Bypass Iranian Websites, apps-only mode and its app list, reconnect, watchdog, notifications); unblock_internet lifts a kill switch block. " +
        "These protect the user's privacy: change only what they asked for. Lowering protection (kill switch off, apps-only on, Bypass Iranian Websites on, unblock_internet) makes FiveT ask the user in a dialog on this PC; if they decline, nothing changes. " +
        "In apps-only mode (V2Ray and Outline) the VPN carries just the chosen apps, which the user starts from FiveT's menu (Open with VPN): the rest of the PC is not on the VPN, and get_status shows interface \"app-proxy\". " +
        "Passwords and one-time-code secrets are never exposed.";

    private JsonObject HandleMethod(string method, JsonObject prms, McpClientSession session)
    {
        switch (method)
        {
            case "initialize":
            {
                var requested = Json.Str(prms["protocolVersion"]) ?? ProtocolVersion;
                var version = SupportedVersions.Contains(requested) ? requested : ProtocolVersion;
                if (prms["clientInfo"] is JsonObject info && Json.Str(info["name"]) is { } name)
                {
                    var v = Json.Str(info["version"]) is { } ver ? " " + ver : "";
                    session.ClientName = name + v;
                }
                Log.Shared.Write($"[mcp] initialize from {session.ClientName} (protocol {requested} → {version})", LogLevel.Debug);
                return new JsonObject
                {
                    ["protocolVersion"] = version,
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = "fivet", ["title"] = "FiveT VPN", ["version"] = Paths.AppVersion },
                    ["instructions"] = Instructions,
                };
            }
            case "ping":
                return new JsonObject();
            case "tools/list":
                return new JsonObject { ["tools"] = McpTools.Definitions() };
            case "tools/call":
            {
                var name = Json.Str(prms["name"]) ?? throw new RpcException(-32602, "Missing tool name");
                var args = prms["arguments"] as JsonObject ?? new JsonObject();
                var shown = string.Join(" ", args.Select(kv => $"{kv.Key}={Json.ToCompact(kv.Value)}").OrderBy(s => s));
                Log.Shared.Write($"[mcp] {session.ClientName} → {name} {shown}");
                return McpTools.Call(name, args);
            }
            default:
                throw new RpcException(-32601, $"Method not found: {method}");
        }
    }
}

// MARK: - Tools

/// <summary>What an assistant may do. Read-only tools never block; connect/disconnect wait for the tunnel to settle.</summary>
public static class McpTools
{
    public sealed record ToolDef(string Name, string Description);

    /// <summary>Names and descriptions, for the Settings window.</summary>
    public static IReadOnlyList<ToolDef> Summary { get; } = new List<ToolDef>
    {
        new("get_status", "Current VPN state (disconnected / connecting / connected / disconnecting), which connection, uptime, progress detail, last error, tunnel health while connected, and once connected the network facts: adapter, tunnel IP, DNS servers, search domains, routes pushed by the gateway, and split-DNS state. The top level describes the tunnel that is changing state, or else the newest connected one; \"sessions\" lists every active tunnel the same way and \"active_connections\" the names of the connected ones."),
        new("list_connections", "The saved VPN connections: name, gateway, username, one-time-code mode, split-DNS domains, last successful connect time, last error, and each one's state (several can be connected at once). Never includes passwords."),
        new("connect", "Connect to a saved VPN connection by name. Idempotent: if that connection is already up it returns outcome \"already_connected\" with the uptime and does not reconnect. By default waits until the tunnel is up or the attempt failed and returns the resulting status with network facts. Other connections that are already up are left alone: FiveT holds several tunnels at the same time."),
        new("disconnect", "Disconnect one VPN connection by name, leaving the other tunnels up; without a name, disconnect every tunnel. Also stops a reconnect loop. Waits until the tunnel is down and returns the resulting status. Safe to call when nothing is connected."),
        new("get_settings", "FiveT's switches as they are now: kill_switch, bypass_iranian_websites, failover (switch to the next VPN when one stays down), apps_only (the VPN carries only the apps in vpn_apps, V2Ray and Outline), vpn_apps (full paths of the chosen programs), auto_reconnect, watchdog, notify_on_change."),
        new("set_settings", "Change the switches get_settings lists: only the ones given. These protect the user's privacy (the kill switch, apps-only), so change only what the user asked for, and say what you changed. vpn_apps replaces the whole list; give the full path of each program's .exe file, such as C:\\Program Files\\Slack\\slack.exe. Passwords, certificate trust, connections and updates are not available here: the user does those in FiveT. Turning protection on needs nothing; lowering it (kill_switch off, apps_only on, bypass_iranian_websites on) makes FiveT ask the user in a dialog on this PC, and nothing changes unless they allow it."),
        new("unblock_internet", "Lifts the kill switch block that is holding this PC's internet shut because a VPN dropped (the same as Unblock Internet in FiveT's menu). Without a VPN the PC's traffic then goes out unprotected, so use it only when the user asks. FiveT asks the user in a dialog on this PC first, and nothing is lifted unless they allow it."),
        new("get_log", "Recent lines of FiveT's log: connect/disconnect events, authentication, tunnel up, DNS and routes, errors, MCP calls. Default level \"info\" hides openconnect's verbose chatter; packet traces are never stored unless enabled in Settings."),
        new("get_diagnostics", "Full diagnostics text: setup checks (openconnect, driver, administrator rights, login task), app version, status, network facts, connections without secrets, and the recent event log."),
        new("resolve", "Resolve a host name two ways: directly against the tunnel's DNS servers (what nslookup does) and through the system resolver (what curl, Python and apps use). Different answers mean split DNS is needed for that domain."),
        new("check_reachability", "One-call diagnosis of \"VPN up but host unreachable\": resolves the host via tunnel DNS and system DNS, checks whether the address is covered by a pushed route, then tries a TCP connect to host:port (3 s timeout) and returns a plain-language diagnosis."),
    };

    public static JsonArray Definitions()
    {
        var d = Summary.ToDictionary(t => t.Name, t => t.Description);
        var a = new JsonArray
        {
            Tool("get_status", d["get_status"], readOnly: true),
            Tool("list_connections", d["list_connections"], readOnly: true),
            Tool("connect", d["connect"],
                properties: new JsonObject
                {
                    ["name"] = Prop("string", "Connection name as shown by list_connections (case-insensitive; the id also works)."),
                    ["timeout_seconds"] = Prop("integer", "How long to wait for the tunnel before returning outcome \"still_connecting\".", min: 5, max: 300, def: 60),
                    ["wait"] = new JsonObject { ["type"] = "boolean", ["default"] = true, ["description"] = "false returns immediately with outcome \"started\"; poll get_status afterwards." },
                },
                required: new[] { "name" }),
            Tool("disconnect", d["disconnect"],
                properties: new JsonObject
                {
                    ["name"] = Prop("string", "Which connection to disconnect (case-insensitive; the id also works). Leave it out to disconnect every tunnel."),
                }),
            Tool("get_settings", d["get_settings"], readOnly: true),
            Tool("set_settings", d["set_settings"],
                properties: new JsonObject
                {
                    ["kill_switch"] = new JsonObject { ["type"] = "boolean" },
                    ["bypass_iranian_websites"] = new JsonObject { ["type"] = "boolean" },
                    ["failover"] = new JsonObject { ["type"] = "boolean" },
                    ["apps_only"] = new JsonObject { ["type"] = "boolean", ["description"] = "Switching it restarts a V2Ray or Outline tunnel that is up in the other mode." },
                    ["vpn_apps"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
                    ["auto_reconnect"] = new JsonObject { ["type"] = "boolean" },
                    ["watchdog"] = new JsonObject { ["type"] = "boolean" },
                    ["notify_on_change"] = new JsonObject { ["type"] = "boolean" },
                },
                destructive: true),
            Tool("unblock_internet", d["unblock_internet"], destructive: true),
            Tool("get_log", d["get_log"],
                properties: new JsonObject
                {
                    ["lines"] = Prop("integer", "How many trailing lines to return (after filtering).", min: 1, max: 1000, def: 60),
                    ["level"] = new JsonObject { ["type"] = "string", ["enum"] = Json.Array(new[] { "error", "info", "debug" }), ["default"] = "info", ["description"] = "Minimum level: error = failures only; info = events; debug = everything." },
                    ["connection"] = Prop("string", "Only lines tagged with this connection name."),
                    ["since"] = Prop("string", "Only lines at or after this time (ISO 8601, e.g. 2026-09-05T19:25:00Z, or \"2026-09-05 19:25:00\" local time)."),
                    ["grep"] = Prop("string", "Only lines containing this text (case-insensitive)."),
                },
                readOnly: true),
            Tool("get_diagnostics", d["get_diagnostics"], readOnly: true),
            Tool("resolve", d["resolve"],
                properties: new JsonObject { ["host"] = Prop("string", "Host name, e.g. intranet.example.com.") },
                required: new[] { "host" }, readOnly: true),
            Tool("check_reachability", d["check_reachability"],
                properties: new JsonObject
                {
                    ["host"] = Prop("string", "Host name or IP address."),
                    ["port"] = Prop("integer", null, min: 1, max: 65535, def: 443),
                },
                required: new[] { "host" }, readOnly: true),
        };
        return a;
    }

    private static JsonObject Prop(string type, string? description, int? min = null, int? max = null, int? def = null)
    {
        var o = new JsonObject { ["type"] = type };
        if (description != null) o["description"] = description;
        if (min is { } mn) o["minimum"] = mn;
        if (max is { } mx) o["maximum"] = mx;
        if (def is { } df) o["default"] = df;
        return o;
    }

    private static JsonObject Tool(string name, string description, JsonObject? properties = null, string[]? required = null, bool readOnly = false, bool destructive = false)
    {
        var schema = new JsonObject { ["type"] = "object", ["properties"] = properties ?? new JsonObject(), ["additionalProperties"] = false };
        if (required is { Length: > 0 }) schema["required"] = Json.Array(required);
        var annotations = readOnly
            ? new JsonObject { ["readOnlyHint"] = true, ["openWorldHint"] = false }
            : new JsonObject { ["readOnlyHint"] = false, ["destructiveHint"] = destructive, ["idempotentHint"] = true, ["openWorldHint"] = false };
        return new JsonObject { ["name"] = name, ["description"] = description, ["inputSchema"] = schema, ["annotations"] = annotations };
    }

    public static JsonObject Call(string name, JsonObject args)
    {
        switch (name)
        {
            case "get_status":
                // The top level is the tunnel that is changing, else the newest connected one, with its
                // own network facts; "sessions" has every tunnel the same way (the Mac's withSessions).
                return Result(WithSessions(StatusDict(CurrentStatus()), legacyAliases: true));

            case "list_connections":
            {
                // One look at the UI-thread state, so the states and the connected names agree.
                var (conns, states, up) = Ui.Invoke(() =>
                {
                    var cs = ConnectionStore.Shared.Connections.Select(c => c.Clone()).ToList();
                    return (cs, cs.Select(c => VpnManager.Shared.StatusFor(c.Id)).ToList(), ConnectedNames(VpnManager.Shared.Sessions));
                });
                var arr = new JsonArray();
                // Each connection reports its own tunnel: with two up, neither is "the one".
                for (var i = 0; i < conns.Count; i++) arr.Add(Summarize(conns[i], states[i]));
                return Result(new JsonObject
                {
                    ["connections"] = arr,
                    ["active"] = up.Count > 0 ? up[^1] : null,   // the newest connected one, as the Mac
                    ["active_connections"] = Json.Array(up),
                });
            }

            case "connect":
            {
                var raw = Json.Str(args["name"]);
                if (string.IsNullOrWhiteSpace(raw)) throw new RpcException(-32602, "'name' is required");
                var timeout = Math.Min(Math.Max(Json.Int(args["timeout_seconds"]) ?? 60, 5), 300);
                var wait = Json.Bool(args["wait"]) ?? true;
                var conns = Ui.Invoke(() => ConnectionStore.Shared.Connections.Select(c => c.Clone()).ToList());
                var c = ResolveName(raw, conns);
                if (c == null)
                {
                    var names = string.Join(", ", conns.Select(x => $"'{x.Name}'"));
                    return Result(new JsonObject { ["outcome"] = "unknown_connection", ["message"] = $"No connection called '{raw}'. Saved connections: {names}." }, isError: true);
                }
                // This connection's own tunnel: another one being up is irrelevant to it now.
                var before = StatusOf(c.Id);
                if (before.Phase == VpnPhase.Connected)
                {
                    var d0 = WithSessions(StatusDict(before));
                    d0["outcome"] = "already_connected";
                    d0["message"] = $"{c.Name} has been connected for {VpnStatus.DurationText(before.UptimeSeconds ?? 0)}.";
                    return Result(d0);
                }
                if (before.Phase == VpnPhase.Connecting && !wait)
                {
                    var d1 = WithSessions(StatusDict(before));
                    d1["outcome"] = "started";
                    d1["message"] = $"{c.Name} is already connecting.";
                    return Result(d1);
                }
                var others = ConnectedNow();   // who is already up, for the message
                // An assistant is automation: a certificate FiveT does not trust makes the connect fail
                // at once and leaves Review Certificate… in the menu for a person.
                Ui.Invoke(() => VpnManager.Shared.Connect(c, ConnectOrigin.Automation));
                if (!wait)
                {
                    var d2 = WithSessions(StatusDict(StatusOf(c.Id)));
                    d2["outcome"] = "started";
                    d2["message"] = $"Connecting to {c.Name}; poll get_status.";
                    return Result(d2);
                }
                var st = WaitFor(c.Id, timeout, s => s.Phase is VpnPhase.Connected or VpnPhase.Idle);
                // This tunnel's own status at the top level (also when it failed: its error is the news here).
                var d = WithSessions(StatusDict(st));
                if (st.Phase == VpnPhase.Connected)
                {
                    d["outcome"] = "connected";
                    if (others.Count > 0) d["message"] = $"{c.Name} is up alongside {string.Join(", ", others)}.";
                    return Result(d);
                }
                if (st.Phase == VpnPhase.Idle)
                {
                    var after = Ui.Invoke(() => ConnectionStore.Shared.Get(c.Id)?.Clone());
                    if (after?.HasPendingReview == true)
                    {
                        // Only the user can answer this, in FiveT's menu; retrying cannot (the Mac's outcome).
                        d["outcome"] = "certificate_review_needed";
                        d["message"] = (after.LastError ?? $"{c.Name}'s gateway showed a certificate FiveT does not trust.")
                                       + " Ask the user to choose Review New Certificate… in FiveT's menu; no tool can trust a certificate.";
                    }
                    else if (after != null && Ui.Invoke(() => VpnManager.IsLoginLimited(after)))
                    {
                        // Two refused logins in a row: FiveT stops, and only the user can say "Try Anyway".
                        // An assistant that kept retrying is exactly what gets an account locked.
                        d["outcome"] = "login_limit_reached";
                        d["message"] = (st.LastError ?? after.LastError ?? VpnManager.LoginLimitMessage(after))
                                       + " Do not retry: ask the user to check the password and one-time code, then click the connection in FiveT's menu and choose Try Anyway.";
                    }
                    else
                    {
                        d["outcome"] = "failed";
                        d["message"] = st.LastError ?? after?.LastError ?? $"{c.Name} did not connect.";
                    }
                    return Result(d, isError: true);
                }
                d["outcome"] = "still_connecting";
                d["message"] = $"Still connecting after {timeout} s. Call get_status to follow it, or disconnect to stop.";
                return Result(d);
            }

            case "disconnect":
            {
                // No name = every tunnel, which is what this tool always did when only one existed.
                var raw = Json.Str(args["name"]);
                if (string.IsNullOrWhiteSpace(raw))
                {
                    var beforeAll = CurrentStatus();
                    if (beforeAll.Phase == VpnPhase.Idle)
                    {
                        var dn = WithSessions(StatusDict(beforeAll));
                        dn["outcome"] = "not_connected";
                        return Result(dn);
                    }
                    Ui.Invoke(() => VpnManager.Shared.DisconnectAll());
                    var stAll = Wait(12, s => s.Phase == VpnPhase.Idle);
                    var dAll = WithSessions(StatusDict(stAll));
                    dAll["outcome"] = stAll.Phase == VpnPhase.Idle ? "disconnected" : "still_disconnecting";
                    return Result(dAll);
                }
                var conns = Ui.Invoke(() => ConnectionStore.Shared.Connections.Select(x => x.Clone()).ToList());
                var target = ResolveName(raw, conns);
                if (target == null)
                {
                    var names = string.Join(", ", conns.Select(x => $"'{x.Name}'"));
                    return Result(new JsonObject { ["outcome"] = "unknown_connection", ["message"] = $"No connection called '{raw}'. Saved connections: {names}." }, isError: true);
                }
                if (Ui.Invoke(() => VpnManager.Shared.StatusFor(target.Id).Phase) == VpnPhase.Idle)
                {
                    var d0 = WithSessions(StatusDict(CurrentStatus()));
                    d0["outcome"] = "not_connected";
                    d0["message"] = $"{target.Name} is not connected.";
                    return Result(d0);
                }
                Ui.Invoke(() => VpnManager.Shared.Disconnect(target.Id));
                var st = WaitFor(target.Id, 12, s => s.Phase == VpnPhase.Idle);
                var gone = st.Phase == VpnPhase.Idle;
                // The top level is whatever is still up (or still going down); "connection" is not
                // overwritten with the target's name, as that would pair it with another tunnel's state.
                var d = WithSessions(StatusDict(CurrentStatus()));
                d["outcome"] = gone ? "disconnected" : "still_disconnecting";
                var up = ConnectedNow();
                d["message"] = gone
                    ? $"{target.Name} disconnected" + (up.Count == 0 ? "." : $"; {string.Join(", ", up)} still connected.")
                    : $"{target.Name} is still disconnecting.";
                return Result(d);
            }

            case "get_settings":
                return Result(Ui.Invoke(() => SettingsDict()));

            case "set_settings":
            {
                List<string>? apps = null;
                if (args["vpn_apps"] is { } rawApps)
                {
                    if (rawApps is not JsonArray list || list.Any(x => Json.Str(x) == null)) throw new RpcException(-32602, "'vpn_apps' must be a list of program paths");
                    var paths = list.Select(x => Json.Str(x)!).ToList();
                    foreach (var p in paths.Where(p => !VpnApps.IsAppPath(p) || !File.Exists(p)))
                        throw new RpcException(-32602, $"'{p}' is not an installed program: give the full path of its .exe file, e.g. C:\\Program Files\\Slack\\slack.exe");
                    apps = paths;
                }
                var values = new List<(string Key, Func<ConnectionStore, bool> Get, Action<ConnectionStore, bool> Set, bool Value)>();
                foreach (var (key, get, set) in SettingFlags)
                {
                    if (args[key] == null) continue;
                    if (Json.Bool(args[key]) is not { } wanted) throw new RpcException(-32602, $"'{key}' must be true or false");
                    values.Add((key, get, set, wanted));
                }
                if (values.Count == 0 && apps == null) throw new RpcException(-32602, "give at least one setting to change (see get_settings)");
                // Lowering protection from outside the app (an assistant, the command line) needs the user's yes, asked by FiveT
                // itself, so a prompt-injected assistant cannot switch it off on its own. Read from the settings as they are now.
                List<(string Key, string Text)> Lowering()
                {
                    var st = ConnectionStore.Shared;
                    return Protection.Lowering(values.Select(v => (v.Key, v.Get(st), v.Value)));
                }
                var asked = Ui.Invoke(Lowering);
                if (asked.Count > 0 && !UserAllows(string.Join(" and ", asked.Select(a => a.Text))))
                    return Result(new JsonObject { ["changed"] = new JsonArray(), ["denied"] = true, ["message"] = "The user did not allow this change in FiveT's dialog. Nothing was changed." }, isError: true);
                // Applied in one step that reads the settings again: a change that lowers protection and was not in what the user
                // allowed (the setting moved while the dialog was open) is refused, not applied.
                var outcome = Ui.Invoke<List<string>?>(() =>
                {
                    var st = ConnectionStore.Shared;
                    if (!Lowering().Select(l => l.Key).ToHashSet().IsSubsetOf(asked.Select(a => a.Key))) return null;
                    var done = new List<string>();
                    foreach (var (key, get, set, value) in values)
                        if (get(st) != value) { set(st, value); done.Add(key); }
                    if (apps != null && !apps.SequenceEqual(st.VpnAppPaths, StringComparer.OrdinalIgnoreCase)) { st.SetVpnAppPaths(apps); done.Add("vpn_apps"); }
                    return done;
                });
                if (outcome == null)
                    return Result(new JsonObject { ["changed"] = new JsonArray(), ["denied"] = true, ["message"] = "A setting changed while this request was being checked. Nothing was changed: ask again." }, isError: true);
                Log.Shared.Write($"[mcp] settings changed: {(outcome.Count == 0 ? "nothing (already so)" : string.Join(", ", outcome))}");
                var settings = Ui.Invoke(() => SettingsDict());
                settings["changed"] = Json.Array(outcome);
                return Result(settings);
            }

            case "unblock_internet":
            {
                var was = Ui.Invoke(() => VpnManager.Shared.KillSwitchActive);
                if (was && !UserAllows("lift the Kill Switch block and let this PC's internet out without the VPN"))
                    return Result(new JsonObject
                    {
                        ["was_blocked"] = true, ["denied"] = true, ["kill_switch_blocking"] = true,
                        ["message"] = "The user did not allow this in FiveT's dialog. The block stays.",
                    }, isError: true);
                Ui.Invoke(() => VpnManager.Shared.ReleaseKillSwitch());
                return Result(new JsonObject { ["was_blocked"] = was, ["kill_switch_blocking"] = Ui.Invoke(() => VpnManager.Shared.KillSwitchActive) });
            }

            case "get_log":
            {
                var n = Math.Min(Math.Max(Json.Int(args["lines"]) ?? 60, 1), 1000);
                var level = LogLevelExt.Parse(Json.Str(args["level"]) ?? "info") ?? LogLevel.Info;
                DateTime? since = null;
                if (Json.Str(args["since"]) is { } s && s.Trim().Length > 0)
                    since = Log.ParseDate(s) ?? throw new RpcException(-32602, $"'since' is not an ISO 8601 timestamp: {s}");
                var entries = Log.Shared.Entries(level, Json.Str(args["connection"]), since, Json.Str(args["grep"]), n);
                return Result(new JsonObject
                {
                    ["lines"] = Json.Array(entries.Select(e => e.Line)),
                    ["count"] = entries.Count,
                    ["level"] = level.ToString().ToLowerInvariant(),
                });
            }

            case "get_diagnostics":
                // Runs openconnect and schtasks to check the setup, which takes a moment: never on the UI
                // thread (the tray would freeze). Diagnostics.Text hops onto it only where it must.
                return Text(Task.Run(Diagnostics.Text).GetAwaiter().GetResult());

            case "resolve":
            {
                var host = Json.Str(args["host"])?.Trim();
                if (string.IsNullOrEmpty(host)) throw new RpcException(-32602, "'host' is required");
                return Result(NetTools.Resolve(host, MergedStatus()));
            }

            case "check_reachability":
            {
                var host = Json.Str(args["host"])?.Trim();
                if (string.IsNullOrEmpty(host)) throw new RpcException(-32602, "'host' is required");
                var port = Math.Min(Math.Max(Json.Int(args["port"]) ?? 443, 1), 65535);
                var r = NetTools.CheckReachability(host, port, MergedStatus());
                return Result(r, isError: Json.Bool(r["reachable"]) == false);
            }

            default:
                throw new RpcException(-32602, $"Unknown tool: {name}");
        }
    }

    // MARK: helpers

    /// <summary>The on/off switches get_settings and set_settings share: tool name, and how to read and write it.</summary>
    private static readonly (string Key, Func<ConnectionStore, bool> Get, Action<ConnectionStore, bool> Set)[] SettingFlags =
    {
        ("kill_switch", s => s.KillSwitch, (s, v) => s.KillSwitch = v),
        ("bypass_iranian_websites", s => s.BypassIran, (s, v) => s.BypassIran = v),
        ("failover", s => s.AutoFailover, (s, v) => s.AutoFailover = v),
        ("apps_only", s => s.AppsOnly, (s, v) => s.AppsOnly = v),
        ("auto_reconnect", s => s.AutoReconnect, (s, v) => s.AutoReconnect = v),
        ("watchdog", s => s.Watchdog, (s, v) => s.Watchdog = v),
        ("notify_on_change", s => s.NotifyOnChange, (s, v) => s.NotifyOnChange = v),
    };

    /// <summary>The switches as they are now. UI thread.</summary>
    private static JsonObject SettingsDict()
    {
        var st = ConnectionStore.Shared;
        var o = new JsonObject();
        foreach (var (key, get, _) in SettingFlags) o[key] = get(st);
        o["vpn_apps"] = Json.Array(st.VpnAppPaths);
        return o;
    }

    /// <summary>
    /// Asks the user, in a dialog of FiveT's own on this PC, whether to allow <paramref name="what"/>. The default is Don't Allow:
    /// nothing is pre-selected, and Allow only works after a moment, like a browser's permission prompt. Each request has its own
    /// dialog (never one shared with another request's wording). No answer in five minutes is a no.
    /// </summary>
    private static bool UserAllows(string what)
    {
        var task = Ui.Invoke(() => PromptWindow.Ask("mcp-lowering:" + Guid.NewGuid(), new PromptSpec
        {
            Title = "Allow this change?",
            Message = $"An assistant or the command line asked FiveT to {what}. This lowers the protection FiveT gives you. Allow it only if you asked for it.",
            Primary = "Allow", Secondary = "Don't Allow", Warning = true, AutomationId = "McpAllow",
        }));
        return task.Wait(TimeSpan.FromMinutes(5)) && task.Result.Accepted;
    }

    /// <summary>
    /// One status for the whole manager, as the Mac's VPNManager.status: a tunnel that is changing
    /// state first, otherwise the newest connected one (with its own network facts), otherwise idle
    /// with the last error. VpnManager.Status is not used because, with two tunnels up, it joins the
    /// names and leaves the network facts out.
    /// </summary>
    public static VpnStatus CurrentStatus() => Ui.Invoke(() =>
    {
        var all = VpnManager.Shared.Sessions;
        if (all.FirstOrDefault(s => s.Phase is VpnPhase.Connecting or VpnPhase.Disconnecting) is { } busy) return busy;
        var newest = all.Where(s => s.Phase == VpnPhase.Connected).OrderBy(s => s.Since ?? DateTime.MinValue).LastOrDefault();
        return newest ?? VpnManager.Shared.Status;
    });

    /// <summary>Every connected tunnel folded into one status (DNS and routes of all of them), for resolve and check_reachability.</summary>
    public static VpnStatus MergedStatus() => Ui.Invoke(() => VpnManager.Shared.MergedStatus());

    /// <summary>The status of one connection's own tunnel (other tunnels do not affect it).</summary>
    public static VpnStatus StatusOf(Guid id) => Ui.Invoke(() => VpnManager.Shared.StatusFor(id));

    /// <summary>Names of the connected tunnels, oldest first, so the last one is "the active one" as on the Mac.</summary>
    private static List<string> ConnectedNames(IEnumerable<VpnStatus> sessions) =>
        sessions.Where(s => s.Phase == VpnPhase.Connected && s.ConnectionName != null)
                .OrderBy(s => s.Since ?? DateTime.MinValue)
                .Select(s => s.ConnectionName!).ToList();

    private static List<string> ConnectedNow() => Ui.Invoke(() => ConnectedNames(VpnManager.Shared.Sessions));

    /// <summary>
    /// Adds "sessions" (every active tunnel, each as get_status describes one) and "active_connections"
    /// (the connected ones' names) to a status payload: the Mac's withSessions. With
    /// <paramref name="legacyAliases"/> also "connections" (every session, including a failed one still
    /// showing its error) and "connected_count": what get_status returned in Windows 1.3 to 1.4, kept so
    /// nothing reading them breaks. The other tools never had them, so they do not get a second copy.
    /// </summary>
    private static JsonObject WithSessions(JsonObject d, bool legacyAliases = false)
    {
        var all = Ui.Invoke(() => VpnManager.Shared.Sessions.ToList());
        var sessions = new JsonArray();
        foreach (var s in all.Where(s => s.Phase != VpnPhase.Idle)) sessions.Add(StatusDict(s));
        d["sessions"] = sessions;
        d["active_connections"] = Json.Array(ConnectedNames(all));
        if (legacyAliases)
        {
            var connections = new JsonArray();
            foreach (var s in all) connections.Add(StatusDict(s));
            d["connections"] = connections;
            d["connected_count"] = all.Count(s => s.Phase == VpnPhase.Connected);
        }
        return d;
    }

    /// <summary>Like <see cref="Wait"/>, but watching a single connection rather than the summary.</summary>
    private static VpnStatus WaitFor(Guid id, double timeout, Func<VpnStatus, bool> done)
    {
        var deadline = DateTime.Now.AddSeconds(timeout);
        var st = StatusOf(id);
        while (!done(st) && DateTime.Now < deadline)
        {
            Thread.Sleep(250);
            st = StatusOf(id);
        }
        return st;
    }

    /// <summary>Polls the status until <paramref name="done"/> is true or the timeout passes; returns the last status seen.</summary>
    private static VpnStatus Wait(double timeout, Func<VpnStatus, bool> done)
    {
        var deadline = DateTime.Now.AddSeconds(timeout);
        var st = CurrentStatus();
        while (!done(st) && DateTime.Now < deadline)
        {
            Thread.Sleep(250);
            st = CurrentStatus();
        }
        return st;
    }

    /// <summary>Exact name (case-insensitive) first, then the id, then a unique prefix.</summary>
    private static Connection? ResolveName(string raw, List<Connection> conns)
    {
        var q = raw.Trim();
        if (conns.FirstOrDefault(c => string.Equals(c.Name, q, StringComparison.OrdinalIgnoreCase)) is { } exact) return exact;
        if (Guid.TryParse(q, out var id) && conns.FirstOrDefault(c => c.Id == id) is { } byId) return byId;
        var prefix = conns.Where(c => c.Name.StartsWith(q, StringComparison.OrdinalIgnoreCase)).ToList();
        return prefix.Count == 1 ? prefix[0] : null;
    }

    public static JsonObject StatusDict(VpnStatus st)
    {
        var d = new JsonObject
        {
            ["state"] = st.StateName,
            ["connection"] = st.ConnectionName,
            ["needs_setup"] = st.NeedsSetup,
            ["summary"] = st.Summary,
        };
        if (st.ConnectionId is { } id) d["connection_id"] = id.ToString().ToUpperInvariant();
        if (st.Since is { } since)
        {
            d["connected_since"] = Json.Iso(since);
            d["uptime_seconds"] = st.UptimeSeconds ?? 0;
        }
        if (st.Detail is { } detail) d["detail"] = detail;
        // The watchdog's verdict ("ok", or e.g. "not answering for 40s"): a tunnel can be "connected" and dead.
        if (st.Phase == VpnPhase.Connected) d["health"] = st.Health ?? "ok";
        if (st.WaitingForNetwork) d["waiting_for_network"] = true;
        // Only the user lifts it (FiveT's menu → Unblock Internet), or the VPN coming back.
        if (KillSwitch.IsActive) d["kill_switch_active"] = true;
        if (st.LastError is { } err) d["last_error"] = err;
        if (st.Network is { } n)
        {
            d["interface"] = n.Interface;
            d["dns_servers"] = Json.Array(n.DnsServers);
            d["network"] = new JsonObject
            {
                ["interface"] = n.Interface,
                ["interface_index"] = n.InterfaceIndex,
                ["tunnel_ip"] = n.TunnelIP,
                ["peer_ip"] = n.PeerIP,
                ["dns_servers"] = Json.Array(n.DnsServers),
                ["search_domains"] = Json.Array(n.SearchDomains),
                ["routes"] = Json.Array(n.Routes),
            };
        }
        if (st.SplitDns is { } s)
            d["split_dns"] = new JsonObject { ["domains"] = Json.Array(s.Domains), ["state"] = s.State, ["detail"] = s.Detail };
        return d;
    }

    private static JsonObject Summarize(Connection c, VpnStatus st)
    {
        // st is this connection's own status, so its phase is the answer directly.
        var state = st.StateName;
        return new JsonObject
        {
            ["id"] = c.Id.ToString().ToUpperInvariant(),
            ["name"] = c.Name,
            ["gateway"] = c.GatewayDescription,
            ["username"] = c.Username,
            ["one_time_code"] = c.OtpMode.Wire(),
            ["kind"] = c.Kind.Wire(),
            ["certificate_trusted"] = c.KnowsGateway,
            ["login_limit_reached"] = !c.IsV2Ray && VpnManager.IsLoginLimited(c),
            // A gateway certificate FiveT did not trust by itself waits for the user (FiveT's menu →
            // Review New Certificate…); no tool can trust it.
            ["certificate_review_needed"] = c.HasPendingReview,
            ["dns_domains"] = Json.Array(c.DnsDomainList),
            ["last_connected_at"] = c.LastConnectedAt is { } d ? Json.Iso(d) : null,
            ["last_error"] = c.LastError,
            ["state"] = state,
        };
    }

    public static JsonObject Result(JsonObject payload, bool isError = false) => new()
    {
        ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = Json.ToPretty(payload) } },
        ["structuredContent"] = payload.DeepClone(),
        ["isError"] = isError,
    };

    private static JsonObject Text(string s) => new()
    {
        ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = s } },
        ["isError"] = false,
    };
}

// MARK: - Registering FiveT with assistants

/// <summary>Writes the `fivet` server entry into the assistants' config files (Settings → MCP).</summary>
public static class McpClientSetup
{
    /// <summary>The command an assistant runs: fivetctl.exe next to FiveT.exe.</summary>
    public static string Command => Paths.CliExePath;

    public static JsonObject ServerEntry() => new() { ["command"] = Command, ["args"] = Json.Array(new[] { "--mcp" }) };

    public static string Snippet => Json.ToPretty(new JsonObject { ["mcpServers"] = new JsonObject { ["fivet"] = ServerEntry() } });

    public static string ClaudeDesktopConfig =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude_desktop_config.json");

    public static string CursorConfig =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cursor", "mcp.json");

    /// <summary>Merges the entry into a {"mcpServers": {...}} file, keeping everything else in it.</summary>
    public static string Add(string path, string appName)
    {
        // The Settings page awaits this string and keeps its buttons disabled until it arrives, so no
        // exception (a locked or read-only file, a missing folder right) may escape: it becomes the message.
        try
        {
            JsonObject root = new();
            if (File.Exists(path))
            {
                var text = File.ReadAllText(path);
                // An empty file is a new one; anything else that is not a JSON object is left alone.
                if (text.Trim().Length > 0)
                {
                    if (Json.Parse(text) is not JsonObject obj)
                        return $"{Path.GetFileName(path)} is not valid JSON. Fix or remove it, then try again.";
                    root = obj;
                }
            }
            var servers = root["mcpServers"] as JsonObject ?? new JsonObject();
            servers["fivet"] = ServerEntry();
            root["mcpServers"] = servers;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            WriteAtomically(path, Json.ToPretty(root));
            Log.Shared.Write($"[mcp] registered in {path}");
            return $"Added to {appName}. Restart {appName} so it picks up the new server.";
        }
        catch (Exception e)
        {
            return $"Could not write {path}: {e.Message}";
        }
    }

    /// <summary>
    /// Writes a temp file next to <paramref name="path"/> and swaps it in, so the assistant's config is never
    /// left half written (a crash or a full disk mid-write would otherwise destroy the user's other servers).
    /// File.Replace keeps the old file's attributes and permissions.
    /// </summary>
    private static void WriteAtomically(string path, string content)
    {
        var tmp = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(tmp, content);
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }

    /// <summary>Uses the `claude` CLI so the entry lands wherever Claude Code keeps user-scope servers.</summary>
    public static string AddToClaudeCode()
    {
        var manual = $"claude mcp add -s user fivet -- \"{Command}\" --mcp";
        try   // same reason as Add: the page waits for a string
        {
            var claude = FindClaude();
            if (claude == null) return $"Claude Code CLI not found. In a terminal run:  {manual}";
            Setup.Run(claude, new[] { "mcp", "remove", "-s", "user", "fivet" });   // replace an older entry, if any
            var r = Setup.Run(claude, new[] { "mcp", "add", "-s", "user", "fivet", "--", Command, "--mcp" });
            if (r.Status == 0)
            {
                Log.Shared.Write($"[mcp] registered with Claude Code via {claude}");
                return "Added to Claude Code (user scope). New Claude Code sessions can use it; type /mcp there to check.";
            }
            return $"claude mcp add failed: {r.Output.Trim()}\nTry in a terminal:  {manual}";
        }
        catch (Exception e)
        {
            return $"Could not run the Claude Code CLI: {e.Message}\nTry in a terminal:  {manual}";
        }
    }

    private static string? FindClaude()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new List<string>
        {
            Path.Combine(local, "Programs", "claude-code", "claude.exe"),
            Path.Combine(home, ".claude", "local", "claude.exe"),
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(appData, "npm", "claude.cmd"),
        };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(dir.Trim(), "claude.exe"));
            candidates.Add(Path.Combine(dir.Trim(), "claude.cmd"));
        }
        return candidates.FirstOrDefault(File.Exists);
    }
}
