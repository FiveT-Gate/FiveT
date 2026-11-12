using System.Globalization;
using System.Text;
using FiveT.Core;

namespace FiveT;

public enum LogLevel { Debug = 0, Info = 1, Error = 2 }

public static class LogLevelExt
{
    public static string Tag(this LogLevel l) => l.ToString().ToUpperInvariant();

    public static LogLevel? Parse(string? s) => s?.ToLowerInvariant() switch
    {
        "debug" => LogLevel.Debug,
        "info" => LogLevel.Info,
        "error" => LogLevel.Error,
        _ => null,
    };
}

/// <summary>One log line. <c>Connection</c> is the "[name]" prefix of the message ("mcp" is not a connection).</summary>
public sealed record LogEntry(DateTime Date, LogLevel Level, string? Connection, string Message)
{
    public string Line => $"{Log.Format(Date)} {Level.Tag(),-5} {Message}";
}

/// <summary>
/// Append-only log at %LOCALAPPDATA%\FiveT\Logs\fivet.log plus an in-memory tail that
/// "Copy Diagnostics", the MCP get_log tool and the CLI read. Never log passwords.
/// Levels: Error for failures, Info for events (connect, auth, tunnel up, DNS, routes, MCP calls),
/// Debug for openconnect's verbose chatter.
/// </summary>
public sealed class Log
{
    // Declared before Shared so it exists whenever the first Log is built.
    private static readonly char[] LineBreaks = { '\r', '\n', (char)0x0B, (char)0x0C, (char)0x85, (char)0x2028, (char)0x2029 };

    public static Log Shared { get; } = new();

    public string FilePath => Paths.LogFile;

    private readonly object _lock = new();
    private readonly List<LogEntry> _recent = new();
    private const int MaxRecent = 2000;
    /// <summary>The file is moved to fivet.log.1 (replacing the previous one) when it grows past this.</summary>
    private const long MaxBytes = 5_000_000;
    private FileStream? _stream;
    private StreamWriter? _writer;
    // After a failure, wait before trying again so a locked file does not cost a retry per log line.
    private DateTime _nextOpenTry = DateTime.MinValue, _nextRotateTry = DateTime.MinValue;

    private Log()
    {
        lock (_lock)
        {
            TryOpen();
            if (_stream != null && _stream.Length > MaxBytes) Rotate();
        }
    }

    /// <summary>Opens the log for appending. Never throws; on failure the writer stays null and the next Write tries again later.</summary>
    private bool TryOpen()
    {
        if (DateTime.UtcNow < _nextOpenTry) return false;
        FileStream? fs = null;
        try
        {
            Directory.CreateDirectory(Paths.LogDir);
            // FileShare.Delete: another copy of FiveT (or a person) can rotate or remove the file while we hold it.
            fs = new FileStream(FilePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            _writer = new StreamWriter(fs, new UTF8Encoding(false)) { AutoFlush = true };
            _stream = fs;
            return true;
        }
        catch
        {
            try { fs?.Dispose(); } catch { }
            _writer = null;
            _stream = null;
            _nextOpenTry = DateTime.UtcNow.AddSeconds(15);
            return false;
        }
    }

    private void Close()
    {
        try { _writer?.Dispose(); } catch { }
        try { _stream?.Dispose(); } catch { }
        _writer = null;
        _stream = null;
    }

    /// <summary>
    /// Keeps the log under ~5 MB while the app runs for weeks: the full file becomes fivet.log.1 and a
    /// fresh fivet.log is started. If the move fails (the file is held open elsewhere) logging carries on in
    /// the same file; the writer is reopened either way, so a failed rotation never silences the log.
    /// </summary>
    private void Rotate()
    {
        if (DateTime.UtcNow < _nextRotateTry) return;
        Close();
        try { File.Move(FilePath, FilePath + ".1", overwrite: true); }
        catch { _nextRotateTry = DateTime.UtcNow.AddMinutes(1); }
        _nextOpenTry = DateTime.MinValue;
        TryOpen();
    }

    /// <summary>
    /// One entry, one line: text from outside (an exception, a link, an assistant's arguments, a gateway) must
    /// not be able to add lines that look like FiveT's own, which get_log would then return.
    /// Every kind of line break becomes " ⏎ " (runs of them one).
    /// </summary>
    public static string OneLine(string text) =>
        text.IndexOfAny(LineBreaks) < 0 ? text : string.Join(" ⏎ ", text.Split(LineBreaks, StringSplitOptions.RemoveEmptyEntries));

    public void Write(string message, LogLevel level = LogLevel.Info)
    {
        message = Redactor.Apply(OneLine(message));
        var entry = new LogEntry(DateTime.Now, level, ConnectionIn(message), message);
        lock (_lock)
        {
            _recent.Add(entry);
            if (_recent.Count > MaxRecent) _recent.RemoveRange(0, _recent.Count - MaxRecent);
            if (_writer == null && !TryOpen()) return;
            try
            {
                _writer!.WriteLine(entry.Line);
                if (_stream!.Length > MaxBytes) Rotate();
            }
            catch { }   // disk full or the like: the in-memory tail still has the line
        }
    }

    /// <summary>
    /// Filtered view of the in-memory tail: at least <paramref name="level"/>, optionally one connection,
    /// after <paramref name="since"/>, containing <paramref name="grep"/> (case-insensitive); the last <paramref name="last"/> matches.
    /// </summary>
    public List<LogEntry> Entries(LogLevel level = LogLevel.Info, string? connection = null, DateTime? since = null,
                                  string? grep = null, int last = 60)
    {
        List<LogEntry> all;
        lock (_lock) all = new List<LogEntry>(_recent);
        var conn = connection?.Trim().ToLowerInvariant();
        var needle = grep?.Trim().ToLowerInvariant();
        var outList = new List<LogEntry>();
        for (var i = all.Count - 1; i >= 0; i--)
        {
            var e = all[i];
            if (e.Level < level) continue;
            if (!string.IsNullOrEmpty(conn) && e.Connection?.ToLowerInvariant() != conn) continue;
            if (since is { } s && e.Date < s) continue;
            if (!string.IsNullOrEmpty(needle) && !e.Message.ToLowerInvariant().Contains(needle)) continue;
            outList.Add(e);
            if (outList.Count >= last) break;
        }
        outList.Reverse();
        return outList;
    }

    /// <summary>Event lines (info and above) for diagnostics.</summary>
    public string RecentText(LogLevel level = LogLevel.Info, int last = 300) =>
        string.Join("\n", Entries(level, last: last).Select(e => e.Line));

    /// <summary>"[Office] Tunnel is up" → "Office"; "[mcp] …" → null.</summary>
    public static string? ConnectionIn(string message)
    {
        if (!message.StartsWith('[')) return null;
        var close = message.IndexOf(']');
        if (close < 0) return null;
        var tag = message[1..close];
        return tag == "mcp" || tag.Length == 0 ? null : tag;
    }

    public static string Format(DateTime d) => d.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    /// <summary>Accepts ISO 8601 ("2026-09-05T19:25:38Z", "+03:30", fractional) or "2026-09-05 19:25:38" (local time).</summary>
    public static DateTime? ParseDate(string s)
    {
        var t = s.Trim();
        if (DateTime.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var d))
            return d.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(d, DateTimeKind.Local) : d.ToLocalTime();
        return null;
    }
}

/// <summary>
/// Keeps passwords, one-time codes, TOTP secrets and session cookies out of the log, the diagnostics
/// text and everything built from them (get_log, fivetctl log). Every line passes through
/// <see cref="Apply"/> before it is stored, so a secret that openconnect echoes, that sits in a
/// connection's extra options or that a future log call includes by mistake still never lands on disk.
/// </summary>
public static class Redactor
{
    public const string Mask = "•••";

    private static readonly object Lock = new();
    private static string[] _secrets = Array.Empty<string>();
    private static readonly Queue<string> Codes = new();

    // FortiGate's session cookie, openconnect's --cookie option, and any "Cookie:"/"Set-Cookie:" header
    // a --dump-http-traffic in the extra options would print.
    private static readonly System.Text.RegularExpressions.Regex CookiePattern = new(
        @"(?i)(SVPNCOOKIE|SVPNNETWORKCOOKIE|webvpn(?:context|login)?|--cookie|set-cookie|cookie)(\s*[=:]\s*)(""[^""]*""|[^\s;,]+)",
        System.Text.RegularExpressions.RegexOptions.Compiled);

    /// <summary>
    /// The saved passwords and TOTP secrets; ConnectionStore calls this whenever they change. A secret is
    /// also masked in its URL-encoded forms, which is how it appears in a login URL or form body.
    /// </summary>
    public static void SetSecrets(IEnumerable<string> secrets)
    {
        var plain = secrets.Where(s => s.Length >= 4).Distinct().ToList();
        var all = new List<string>(plain);
        foreach (var s in plain)
        {
            // Percent-encoding (Uri.EscapeDataString) and form encoding (a space as "+"); they differ for ! * ' ( ) and the space.
            // Some encoders write the hex digits in lower case, so that spelling is covered too.
            foreach (var enc in new[] { Uri.EscapeDataString(s), System.Net.WebUtility.UrlEncode(s) })
            {
                if (enc.Length == 0 || enc.Equals(s, StringComparison.Ordinal)) continue;
                all.Add(enc);
                all.Add(System.Text.RegularExpressions.Regex.Replace(enc, "%[0-9A-F]{2}", m => m.Value.ToLowerInvariant()));
            }
        }
        var list = all.Distinct().OrderByDescending(s => s.Length).ToArray();
        lock (Lock) _secrets = list;
    }

    /// <summary>A one-time code that was just generated: masked as a whole number from now on.</summary>
    public static void AddCode(string code)
    {
        lock (Lock)
        {
            if (Codes.Contains(code)) return;
            Codes.Enqueue(code);
            while (Codes.Count > 8) Codes.Dequeue();
        }
    }

    public static string Apply(string text)
    {
        if (text.Length == 0) return text;
        string[] secrets;
        string[] codes;
        lock (Lock) { secrets = _secrets; codes = Codes.ToArray(); }
        foreach (var s in secrets)
            if (text.Contains(s, StringComparison.Ordinal)) text = text.Replace(s, Mask, StringComparison.Ordinal);
        foreach (var c in codes)
            if (text.Contains(c, StringComparison.Ordinal))
                text = System.Text.RegularExpressions.Regex.Replace(text, $@"(?<!\d){c}(?!\d)", Mask);
        return CookiePattern.Replace(text, m => m.Groups[1].Value + m.Groups[2].Value + Mask);
    }
}

public static class StringExt
{
    public static string Trimmed(this string s) => s.Trim();
}
