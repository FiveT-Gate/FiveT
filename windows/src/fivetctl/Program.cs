using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT.Cli;

// fivetctl.exe — the command line and the MCP bridge for FiveT.exe (the tray app that owns the
// tunnel). Both are MCP clients of the running app over its named pipe, so they see exactly what
// AI assistants see. Exit codes: 0 success, 1 the action failed (or the host is unreachable),
// 2 usage error, 3 FiveT.exe could not be reached.

internal static class Program
{
    private const string ProtocolVersion = "2025-06-18";

    private static int Main(string[] args)
    {
        // Throws when there is no console to set it on (started without one by a service or a launcher).
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
        if (args.Length == 0) { Console.WriteLine(Usage); return 2; }
        switch (args[0])
        {
            case "--mcp": return Bridge.Run();
            case "--help": case "-h": case "help": Console.WriteLine(Usage); return 0;
            case "--version": case "-v": case "version": Console.WriteLine($"FiveT {Paths.AppVersion}"); return 0;
            default: return Cli.Run(args);
        }
    }

    public static string Usage => $@"FiveT {Paths.AppVersion} — FortiGate SSL-VPN from the command line

usage: fivetctl <command> [options]

  status                      current state, tunnel adapter, DNS, routes
  list                        saved connections
  connect <name>              connect, next to any tunnel already up (waits until up; idempotent)
      [--timeout N] [--no-wait]
  disconnect [name]           disconnect one connection, or all of them when no name is given
  log [--lines N] [--level error|info|debug] [--connection NAME]
      [--since ISO-TIME] [--grep TEXT]
  resolve <host>              resolve via the tunnel DNS and the system resolver
  check <host> [port]         DNS + route + TCP connect diagnosis (default port 443)
  diagnostics                 full diagnostics text
  --mcp                       run as an MCP server over stdio (for AI assistants)
  --version, --help

Add --json to any command for the same JSON the MCP tools return.
Exit codes: 0 ok, 1 failed/unreachable, 2 usage, 3 FiveT.exe not reachable.";

    public static void Warn(string s) => Console.Error.WriteLine("fivet: " + s);
}

// MARK: - Pipe client (shared by the bridge and the CLI)

internal static class AppPipe
{
    /// <summary>Connects to the app's pipe, starting FiveT.exe first if nothing is running. Returns null after printing a reason.</summary>
    public static NamedPipeClientStream? ConnectOrLaunch()
    {
        var s = TryConnect(300);
        if (s != null) return s;

        var alreadyRunning = Paths.GuiRunning();
        if (!alreadyRunning) LaunchApp();
        var deadline = DateTime.Now.AddSeconds(alreadyRunning ? 3 : 25);
        while (DateTime.Now < deadline)
        {
            Thread.Sleep(400);
            s = TryConnect(300);
            if (s != null) return s;
        }
        if (alreadyRunning)
            Program.Warn("FiveT is running but not answering. Either it is an older version (quit it from the tray menu and open it again) " +
                         "or \"Let AI assistants control FiveT\" is off in FiveT → Settings → MCP.");
        else
            Program.Warn($"could not start FiveT.exe (expected pipe {Paths.PipeDisplayPath}). Open FiveT once by hand (accept the UAC prompt), " +
                         "or turn on \"Start FiveT at login\" in Settings → General so it can be started without one.");
        return null;
    }

    private static NamedPipeClientStream? TryConnect(int timeoutMs)
    {
        // Asynchronous (overlapped) is required: the bridge reads and writes this pipe from two threads, and
        // Windows serialises I/O on a non-overlapped handle, so a pending Read would block every Write.
        var pipe = new NamedPipeClientStream(".", Paths.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            pipe.Connect(timeoutMs);
            return pipe;
        }
        catch
        {
            pipe.Dispose();
            return null;
        }
    }

    private static void LaunchApp()
    {
        // The login task starts the app elevated without a UAC prompt; without it, Windows shows the prompt.
        var task = RunHidden("schtasks.exe", new[] { "/Run", "/TN", Paths.TaskName });
        if (task == 0) return;
        try
        {
            Process.Start(new ProcessStartInfo(Paths.GuiExePath) { UseShellExecute = true });
        }
        catch (Exception e)
        {
            Program.Warn("could not start FiveT.exe: " + e.Message);
        }
    }

    private static int RunHidden(string exe, string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return -1;
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode;
        }
        catch { return -1; }
    }
}

// MARK: - Bridge (`fivetctl --mcp`)

/// <summary>No windows, just stdin/stdout forwarded to the app's pipe. Starts FiveT.exe first if it is not running.</summary>
internal static class Bridge
{
    /// <summary>connect waits up to 300 s for the tunnel; a little more than that before giving up on a reply.</summary>
    private static readonly TimeSpan MaxWaitForReplies = TimeSpan.FromSeconds(310);

    public static int Run()
    {
        using var pipe = AppPipe.ConnectOrLaunch();
        if (pipe == null) return 1;
        var stdin = Console.OpenStandardInput();
        var stdout = Console.OpenStandardOutput();
        var pending = new Pending();
        var t = new Thread(() =>
        {
            Pump(stdin, pipe, new LineTap(m => pending.Track(m, request: true)));
            // stdin closed. A pipe cannot be half-closed like the Mac's socket, so wait for the replies
            // still owed (`echo '{...tools/call connect...}' | fivetctl --mcp` must get its answer)
            // before closing; a client that is gone for good only costs the cap.
            pending.WaitIdle(MaxWaitForReplies);
            try { pipe.Close(); } catch { }
        }) { IsBackground = true, Name = "fivet.mcp.stdin" };
        t.Start();
        Pump(pipe, stdout, new LineTap(m => pending.Track(m, request: false)), afterWrite: true);
        return 0;
    }

    /// <summary>
    /// Copies bytes unchanged; <paramref name="tap"/> reads along to learn which request ids are open.
    /// For stdin the tap runs before the write (the app cannot answer a request the bridge has not
    /// registered yet), for the app's replies after it (the answer is out before it counts as delivered).
    /// </summary>
    private static void Pump(Stream src, Stream dst, LineTap tap, bool afterWrite = false)
    {
        var buf = new byte[65536];
        try
        {
            while (true)
            {
                var n = src.Read(buf, 0, buf.Length);
                if (n <= 0) return;
                if (!afterWrite) tap.Feed(buf, n);
                dst.Write(buf, 0, n);
                dst.Flush();
                if (afterWrite) tap.Feed(buf, n);
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    /// <summary>Request ids sent to the app and not answered yet. Notifications have no id and never wait.</summary>
    private sealed class Pending
    {
        private readonly HashSet<string> _ids = new();
        private readonly object _lock = new();

        public void Track(JsonObject msg, bool request)
        {
            if (msg["id"] is not { } id) return;   // a notification, or an error reply to junk (id null)
            var key = Json.ToCompact(id);
            var isRequest = Json.Str(msg["method"]) != null;   // the app answers exactly these (no string method: no reply)
            lock (_lock)
            {
                if (request && isRequest) _ids.Add(key);
                else if (!request && !isRequest && _ids.Remove(key) && _ids.Count == 0) Monitor.PulseAll(_lock);
            }
        }

        public void WaitIdle(TimeSpan max)
        {
            var deadline = DateTime.UtcNow + max;
            lock (_lock)
            {
                while (_ids.Count > 0)
                {
                    var left = deadline - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero) return;
                    Monitor.Wait(_lock, left);
                }
            }
        }
    }

    /// <summary>Splits a byte stream into lines and hands each JSON object (or array element) to <c>onMessage</c>.</summary>
    private sealed class LineTap
    {
        private readonly Action<JsonObject> _onMessage;
        private readonly MemoryStream _line = new();
        private bool _skipping;   // the current line passed the cap: ignore the rest of it

        public LineTap(Action<JsonObject> onMessage) => _onMessage = onMessage;

        public void Feed(byte[] buf, int n)
        {
            var span = buf.AsSpan(0, n);
            while (span.Length > 0)
            {
                var nl = span.IndexOf((byte)'\n');
                var part = nl < 0 ? span : span[..nl];
                if (!_skipping)
                {
                    if (_line.Length + part.Length > LineReader.MaxLineBytes) { _skipping = true; _line.SetLength(0); }
                    else _line.Write(part);
                }
                if (nl < 0) return;
                if (!_skipping) Complete();
                _skipping = false;
                _line.SetLength(0);
                span = span[(nl + 1)..];
            }
        }

        private void Complete()
        {
            // A byte-order mark in front of the first line (PowerShell's pipe puts one there) is not part of the JSON.
            var node = Json.Parse(Encoding.UTF8.GetString(_line.GetBuffer(), 0, (int)_line.Length).TrimStart('﻿'));
            if (node is JsonObject o) _onMessage(o);
            else if (node is JsonArray a) foreach (var m in a) if (m is JsonObject mo) _onMessage(mo);
        }
    }
}

// MARK: - CLI (`fivetctl status`, `fivetctl connect Office`, …)

internal static class Cli
{
    public static int Run(string[] argv)
    {
        var args = argv.ToList();
        var json = args.RemoveAll(a => a == "--json") > 0;
        // `fivetctl --json` alone leaves nothing to run: usage and exit 2, like the Mac's CLI.
        if (args.Count == 0) { Console.WriteLine(Program.Usage); return 2; }
        var command = args[0];
        args.RemoveAt(0);

        string tool;
        var prms = new JsonObject();
        try
        {
            switch (command)
            {
                case "status": tool = "get_status"; break;
                case "list": case "connections": tool = "list_connections"; break;
                case "connect": case "up":
                    if (args.Count == 0 || args[0].StartsWith("--")) throw new RpcException(2, "connect needs a connection name");
                    tool = "connect"; prms["name"] = args[0];
                    if (Option("--timeout", args) is { } t) prms["timeout_seconds"] = int.TryParse(t, out var ti) ? ti : 60;
                    if (args.Contains("--no-wait")) prms["wait"] = false;
                    break;
                case "disconnect": case "down":
                    tool = "disconnect";
                    // Optional: a name stops just that tunnel, no name stops every one of them.
                    if (args.Count > 0 && !args[0].StartsWith("--")) prms["name"] = args[0];
                    break;
                case "log": case "logs":
                    tool = "get_log";
                    if (Option("--lines", args) is { } v) prms["lines"] = int.TryParse(v, out var vi) ? vi : 60;
                    else if (args.Count > 0 && int.TryParse(args[0], out var n)) prms["lines"] = n;
                    if (Option("--level", args) is { } lv) prms["level"] = lv;
                    if (Option("--connection", args) is { } cn) prms["connection"] = cn;
                    if (Option("--since", args) is { } si) prms["since"] = si;
                    if (Option("--grep", args) is { } gr) prms["grep"] = gr;
                    break;
                case "resolve":
                    if (args.Count == 0) throw new RpcException(2, "resolve needs a host name");
                    tool = "resolve"; prms["host"] = args[0];
                    break;
                case "check": case "reach":
                    if (args.Count == 0) throw new RpcException(2, "check needs a host name");
                    tool = "check_reachability"; prms["host"] = args[0];
                    if (args.Count > 1 && int.TryParse(args[1], out var p)) prms["port"] = p;
                    if (Option("--port", args) is { } po) prms["port"] = int.TryParse(po, out var pi) ? pi : 443;
                    break;
                case "diagnostics": case "diag": tool = "get_diagnostics"; break;
                default: throw new RpcException(2, $"unknown command '{command}'");
            }
        }
        catch (RpcException e)
        {
            Program.Warn(e.Message + "\n\n" + Program.Usage);
            return 2;
        }

        using var pipe = AppPipe.ConnectOrLaunch();
        if (pipe == null) return 3;
        var writer = new LineWriter(pipe);
        var reader = new LineReader(pipe);

        JsonObject? Call(int id, string method, JsonObject p)
        {
            writer.Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = p });
            while (reader.NextLine() is { } line)
            {
                if (Json.Parse(line) is not JsonObject obj) continue;
                if (Json.Int(obj["id"]) == id) return obj;
            }
            return null;
        }

        if (Call(1, "initialize", new JsonObject
            {
                ["protocolVersion"] = ProtocolVersionOf(), ["capabilities"] = new JsonObject(),
                ["clientInfo"] = new JsonObject { ["name"] = "fivet-cli", ["version"] = Paths.AppVersion },
            }) == null)
        {
            Program.Warn("no answer from FiveT.exe");
            return 3;
        }
        writer.Send(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" });
        var reply = Call(2, "tools/call", new JsonObject { ["name"] = tool, ["arguments"] = prms });
        if (reply == null) { Program.Warn("connection to FiveT.exe closed"); return 3; }
        if (reply["error"] is JsonObject err)
        {
            Program.Warn(Json.Str(err["message"]) ?? "error");
            return 1;
        }
        var res = reply["result"] as JsonObject ?? new JsonObject();
        var isError = Json.Bool(res["isError"]) ?? false;
        var payload = res["structuredContent"] as JsonObject;
        var text = Json.Str((res["content"] as JsonArray)?.FirstOrDefault()?["text"]) ?? "";
        if (json) Console.WriteLine(payload != null ? Json.ToPretty(payload) : text);
        else if (payload != null) Console.WriteLine(Human(tool, payload));
        else Console.WriteLine(text);
        return isError ? 1 : 0;
    }

    private static string ProtocolVersionOf() => "2025-06-18";

    private static string? Option(string name, List<string> args)
    {
        var i = args.IndexOf(name);
        return i >= 0 && i + 1 < args.Count ? args[i + 1] : null;
    }

    private static string S(JsonNode? n) => Json.Str(n) ?? (n == null ? "" : Json.ToCompact(n));
    private static List<string> L(JsonNode? n) => (n as JsonArray)?.Select(x => Json.Str(x) ?? "").ToList() ?? new List<string>();

    /// <summary>Short, readable output for humans; --json gives the full structure.</summary>
    private static string Human(string tool, JsonObject p)
    {
        // One tunnel (or the idle summary): the summary line, then its network facts, health and split DNS.
        string StatusLine(JsonObject one)
        {
            var s = Json.Str(one["summary"]) ?? Json.Str(one["state"]) ?? "?";
            if (one["network"] is JsonObject n)
            {
                var dns = string.Join(", ", L(n["dns_servers"]));
                s += $"\n  tunnel: {S(n["interface"])} {S(n["tunnel_ip"])}   dns: {(dns.Length == 0 ? "-" : dns)}   routes: {L(n["routes"]).Count}";
                var sd = L(n["search_domains"]);
                if (sd.Count > 0) s += $"   search: {string.Join(", ", sd)}";
            }
            if (Json.Str(one["health"]) is { } health && health != "ok") s += $"\n  health: {health}";
            if (one["split_dns"] is JsonObject sp)
            {
                s += $"\n  split dns: {S(sp["state"])} [{string.Join(", ", L(sp["domains"]))}]";
                if (Json.Str(sp["detail"]) is { Length: > 0 } d) s += $" — {d}";
            }
            return s;
        }
        // One block per tunnel when several are active (the top level is only the newest or the one
        // changing); the plain status otherwise. An app that predates "sessions" has no such array.
        string StatusLines()
        {
            var sessions = (p["sessions"] as JsonArray)?.OfType<JsonObject>().ToList() ?? new List<JsonObject>();
            return sessions.Count > 1 ? string.Join("\n", sessions.Select(StatusLine)) : StatusLine(p);
        }
        switch (tool)
        {
            case "get_status":
                return StatusLines();
            case "connect":
            case "disconnect":
            {
                var s = $"{S(p["outcome"])}: " + StatusLines();
                if (Json.Str(p["message"]) is { } m) s += $"\n  {m}";
                return s;
            }
            case "list_connections":
            {
                var lines = new List<string>();
                foreach (var c in (p["connections"] as JsonArray)?.OfType<JsonObject>() ?? Enumerable.Empty<JsonObject>())
                {
                    var state = S(c["state"]);
                    var mark = state == "connected" ? "●" : state == "connecting" ? "◐" : "○";
                    var s = $"{mark} {S(c["name"])}  {S(c["gateway"])}  {S(c["username"])}  {state}";
                    var d = L(c["dns_domains"]);
                    if (d.Count > 0) s += $"  dns: {string.Join(", ", d)}";
                    if (Json.Str(c["last_error"]) is { } e) s += $"\n    last error: {e}";
                    lines.Add(s);
                }
                return string.Join("\n", lines);
            }
            case "get_log":
                return string.Join("\n", L(p["lines"]));
            case "resolve":
            {
                var s = S(p["host"]);
                if (p["tunnel_dns"] is JsonObject t)
                    s += $"\n  tunnel dns{(Json.Str(t["server"]) is { } sv ? $" ({sv})" : "")}: {string.Join(", ", L(t["addresses"]))}{(Json.Str(t["error"]) is { } te ? $" — {te}" : "")}";
                if (p["system_dns"] is JsonObject y)
                    s += $"\n  system resolver: {string.Join(", ", L(y["addresses"]))}{(Json.Str(y["error"]) is { } ye ? $" — {ye}" : "")}";
                if (Json.Str(p["hint"]) is { } h) s += $"\n  {h}";
                return s;
            }
            case "check_reachability":
            {
                var s = Human("resolve", p);
                if (p["tcp"] is JsonObject t)
                    s += $"\n  tcp {S(t["address"])}:{S(t["port"])} {((Json.Bool(t["connected"]) ?? false) ? "open" : "closed/timeout")} ({S(t["latency_ms"])} ms)";
                if (Json.Bool(p["route_via_tunnel"]) is { } r) s += $"   route via tunnel: {(r ? "yes" : "no")}";
                s += $"\n  {S(p["diagnosis"])}";
                return s;
            }
            default:
                return Json.ToPretty(p);
        }
    }
}
