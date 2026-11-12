using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using FiveT.Core;
using Microsoft.Win32;

namespace FiveT;

public enum LinkAction { Connect, Toggle, Disconnect, Settings }

/// <summary>A parsed fivet:// link. <see cref="Name"/> is the connection, or null for "all" / no argument.</summary>
public sealed record LinkCommand(LinkAction Action, string? Name, string Url);

/// <summary>
/// fivet:// links, the same ones the Mac app understands (1.8):
///   fivet://connect/Office      connect (always asks first; Mac 1.15.1 removed "Always allow")
///   fivet://toggle/Lab          connect, or disconnect when it is up
///   fivet://disconnect          every tunnel;  fivet://disconnect/Office  just that one
///   fivet://settings            opens Settings
/// Links can only connect and disconnect. They never change settings, trust a certificate or show a
/// password. Names match case-insensitively; %20 is a space.
///
/// Windows starts "FiveT.exe fivet://…" for a link. That copy is not elevated and the real app is,
/// so it hands the link over a named pipe that only this user can open (the same rule as the MCP pipe)
/// and exits; if FiveT is not running yet it starts it first.
/// </summary>
public static class Links
{
    public const string Scheme = "fivet";

    public static bool IsLink(string arg) => arg.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The Mac's LinkCommand.parse: "fivet://connect/My%20VPN", "fivet:connect/Office" and
    /// "fivet://connect?name=Office" all name "Office"; up/down are connect/disconnect, open is settings.
    /// Words after the verb are joined with "/", so a name may contain one.
    /// </summary>
    public static LinkCommand? Parse(string url) => Interpret(url).Command;

    /// <summary>
    /// Why <see cref="Parse"/> refuses <paramref name="url"/>, in the words of the Mac's LinkCommand
    /// failures (for the log), or null when Parse accepts it. Never repeats the link's own text: the
    /// page that opened the link chose it.
    /// </summary>
    public static string? Explain(string url) => Interpret(url).Reason;

    private const string Examples = "fivet://connect/<name>, fivet://disconnect/<name>, fivet://disconnect, fivet://toggle/<name> or fivet://settings";

    /// <summary>No real link is this long (names are short); the hand-off pipe carries 4 KB at most.</summary>
    private const int MaxUrlLength = 2048;

    private static (LinkCommand? Command, string? Reason) Interpret(string url)
    {
        if (!IsLink(url)) return (null, "Not a FiveT link (the scheme is not fivet:).");
        if (url.Length > MaxUrlLength) return (null, $"This FiveT link is too long (over {MaxUrlLength} characters).");
        var rest = url[(Scheme.Length + 1)..];
        var fragment = rest.IndexOf('#');
        if (fragment >= 0) rest = rest[..fragment];
        string? queryName = null;
        var qm = rest.IndexOf('?');
        if (qm >= 0)
        {
            foreach (var part in rest[(qm + 1)..].Split('&'))
            {
                var eq = part.IndexOf('=');
                if (eq > 0 && part[..eq].Equals("name", StringComparison.OrdinalIgnoreCase) && eq + 1 < part.Length)
                    queryName ??= Unescape(part[(eq + 1)..]);
            }
            rest = rest[..qm];
        }
        var words = rest.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Unescape).Where(w => w is { Length: > 0 }).Cast<string>().ToList();
        if (words.Count == 0 && queryName == null)
            return (null, $"This FiveT link says nothing to do. Links look like {Examples}.");
        if (queryName != null) words.Add(queryName);
        var verb = words[0].Trim().ToLowerInvariant();
        var joined = string.Join("/", words.Skip(1)).Trim();
        var name = joined.Length == 0 ? null : joined;
        switch (verb)
        {
            case "connect" or "up":
                return name != null
                    ? (new LinkCommand(LinkAction.Connect, name, url), null)
                    : (null, "fivet://connect needs a connection name, e.g. fivet://connect/Office.");
            case "toggle":
                return name != null
                    ? (new LinkCommand(LinkAction.Toggle, name, url), null)
                    : (null, "fivet://toggle needs a connection name, e.g. fivet://toggle/Office.");
            case "disconnect" or "down":
                return (new LinkCommand(LinkAction.Disconnect, name, url), null);
            case "settings" or "open":
                return (new LinkCommand(LinkAction.Settings, name, url), null);
            default:
                return (null, $"This link asks for something FiveT links cannot do. Links look like {Examples}.");
        }
    }

    private static string? Unescape(string s)
    {
        try { return Uri.UnescapeDataString(s); }
        catch { return null; }
    }

    /// <summary>Link text for the log: one line, printable, short (the page that opened the link chose it).</summary>
    public static string Sanitized(string s)
    {
        var clean = new string(s.Select(ch => char.IsControl(ch) ? '?' : ch).ToArray());
        return clean.Length > 80 ? clean[..80] + "…" : clean;
    }

    // MARK: Registration (HKCU\Software\Classes\fivet)

    private const string KeyPath = @"Software\Classes\" + Scheme;

    private static string CommandLine => $"\"{Paths.GuiExePath}\" \"%1\"";

    /// <summary>Points fivet:// at this FiveT.exe for the signed-in user. Cheap when it already does.</summary>
    public static void Register()
    {
        if (Paths.IsDev) return;   // a test build must never take the links over from the installed app
        try
        {
            using (var existing = Registry.CurrentUser.OpenSubKey(KeyPath + @"\shell\open\command"))
                if (existing?.GetValue(null) as string == CommandLine) return;
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
            key.SetValue(null, "URL:FiveT link");
            key.SetValue("URL Protocol", "");
            using (var icon = key.CreateSubKey("DefaultIcon")) icon.SetValue(null, $"\"{Paths.GuiExePath}\",0");
            using (var cmd = key.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, CommandLine);
            Log.Shared.Write("registered fivet:// links");
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not register fivet:// links: {e.Message}", LogLevel.Error);
        }
    }

    public static void Unregister()
    {
        try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, throwOnMissingSubKey: false); }
        catch (Exception e) { Log.Shared.Write($"could not remove fivet:// links: {e.Message}", LogLevel.Error); }
    }

    // MARK: Hand-off from a second FiveT.exe

    // The user's SID never changes while the process runs; asking Windows once avoids a token handle per call.
    private static readonly string PipeName = (Paths.IsDev ? "fivet-link-dev-" : "fivet-link-")
                                              + (WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName);

    private static CancellationTokenSource? _cts;

    /// <summary>Runs in the tray app: each connection on the pipe delivers one link line.</summary>
    public static void Listen(Action<string> onLink)
    {
        if (_cts != null) return;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        Task.Run(async () =>
        {
            var security = McpServer.OwnerOnlyPipeSecurity();   // this user only, never over the network
            var first = true;
            var firstTries = 0;
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    // FirstPipeInstance on the first one: if another process already owns the name, ours
                    // would never be reached (or links would land in that process).
                    using var pipe = NamedPipeServerStreamAcl.Create(PipeName, PipeDirection.InOut, 4, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | (first ? PipeOptions.FirstPipeInstance : PipeOptions.None), 4096, 4096, security);
                    first = false;
                    await pipe.WaitForConnectionAsync(ct);
                    var buffer = new byte[4096];
                    var read = 0;
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    timeout.CancelAfter(3000);
                    while (read < buffer.Length)
                    {
                        var n = await pipe.ReadAsync(buffer.AsMemory(read), timeout.Token);
                        if (n == 0) break;
                        read += n;
                        if (Array.IndexOf(buffer, (byte)'\n', 0, read) >= 0) break;
                    }
                    if (read == buffer.Length && Array.IndexOf(buffer, (byte)'\n', 0, read) < 0)
                        // A cut-off link could parse as a different one, so none is better than half of one.
                        Log.Shared.Write("[link] refused: a link longer than 4 KB arrived on the hand-off pipe", LogLevel.Error);
                    else
                    {
                        var line = Encoding.UTF8.GetString(buffer, 0, read).Split('\n')[0].Trim();
                        // The handler runs on the UI thread, where an exception nobody catches ends the app.
                        if (IsLink(line)) Ui.Post(() =>
                        {
                            try { onLink(line); }
                            catch (Exception e) { Log.Shared.Write($"[link] handling a link failed: {e.Message}", LogLevel.Error); }
                        });
                    }
                    await pipe.WriteAsync(Encoding.UTF8.GetBytes("ok\n"), ct);
                    await pipe.FlushAsync(ct);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
                catch (Exception e) when (first && (e is IOException || e is UnauthorizedAccessException))
                {
                    // Creating the very first instance failed: the name is taken. A copy of FiveT that is
                    // just quitting (it released the single-instance mutex a moment before its pipe went away)
                    // is worth a couple of seconds; after that, retrying would only fill the log.
                    if (++firstTries < 10) { await Task.Delay(200, CancellationToken.None); continue; }
                    Log.Shared.Write($"[link] cannot listen: another process already owns the link pipe ({e.Message})", LogLevel.Error);
                    return;
                }
                catch (Exception e)
                {
                    Log.Shared.Write($"[link] pipe: {e.Message}", LogLevel.Error);
                    await Task.Delay(500, CancellationToken.None);
                }
            }
        });
    }

    public static void StopListening()
    {
        _cts?.Cancel();
        _cts = null;
    }

    /// <summary>Gives the link to the running FiveT. Waits up to <paramref name="waitMs"/> for it to listen.</summary>
    public static bool Forward(string url, int waitMs = 3000)
    {
        var deadline = Environment.TickCount64 + waitMs;
        do
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
                pipe.Connect(Math.Max(200, (int)Math.Min(1000, deadline - Environment.TickCount64)));
                var bytes = Encoding.UTF8.GetBytes(url + "\n");
                pipe.Write(bytes);
                pipe.Flush();
                var reply = new byte[8];
                return pipe.Read(reply) > 0;   // the app answers as soon as it has the line
            }
            catch (TimeoutException) { }
            catch (IOException) { Thread.Sleep(300); }
            catch (Exception) { return false; }
        } while (Environment.TickCount64 < deadline);
        return false;
    }
}
