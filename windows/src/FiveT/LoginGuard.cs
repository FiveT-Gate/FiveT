using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT;

/// <summary>
/// Counts failed logins per gateway so FiveT never makes the one that gets this network's internet
/// address banned (the Mac's LoginGuard.swift, 1.11.0). FortiGates block an address after a few failed
/// logins in a row, and that address is often shared by a whole office.
///
/// A failure is a login the gateway saw and did not accept: the password went out and the tunnel never
/// authenticated. An attempt that never reaches the gateway (no network, a timeout, a certificate that
/// was not trusted) cannot count against the address and does not count here. Failures are counted per
/// gateway (<see cref="Connection.LoginGuardKey"/>: its address, without the port), since two connections
/// can log in to the same one. A login that gets through clears them; otherwise they are forgotten
/// <see cref="Window"/> after the last one.
///
/// The count lives in one file for every copy of FiveT of this Windows account (a developer copy with its
/// own connections included), re-read under a lock before each decision: two copies must not each allow two.
///
/// At <see cref="Limit"/> VpnManager stops: reconnects, assistants, the command line and links are refused,
/// and a click asks first (Try Anyway allows one more login).
/// </summary>
public sealed class LoginGuard
{
    /// <summary>Always the real app's folder, also for a developer copy: the gateway counts this PC's logins, whichever copy made them.</summary>
    public static LoginGuard Shared { get; } = new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FiveT"), () => DateTime.UtcNow);

    /// <summary>Failed logins in a row after which FiveT stops: one fewer than the usual gateway ban threshold.</summary>
    public const int Limit = 2;
    /// <summary>How long failures are remembered after the last one: longer than the gateway's ban.</summary>
    public static readonly TimeSpan Window = TimeSpan.FromHours(3);

    /// <summary>
    /// One failed login: when, which connection, how it sent the one-time code (null without one) and whether
    /// the gateway said no (rather than going quiet), so the next try can send the code the way that has not
    /// been refused yet.
    /// </summary>
    public sealed record Failure(DateTime At, Guid? Connection, OtpMode? OtpMode, bool? Rejected);

    private Dictionary<string, List<Failure>> _failed = new(StringComparer.Ordinal);
    private readonly string _file, _lockFile;
    private readonly Func<DateTime> _now;
    private readonly object _gate = new();

    public LoginGuard(string directory, Func<DateTime> utcNow)
    {
        _file = Path.Combine(directory, "login-failures.json");
        _lockFile = Path.Combine(directory, ".login-failures.lock");
        _now = utcNow;
        try { Directory.CreateDirectory(directory); } catch { }
    }

    /// <summary>The failures that still count for this gateway, oldest first (none once <see cref="Window"/> has passed since the last one).</summary>
    public IReadOnlyList<Failure> Failures(string key) => Locked(() => Current(key).ToList());

    public int Count(string key) => Failures(key).Count;

    public bool IsLimited(string key) => Count(key) >= Limit;

    /// <summary>When the warning lifts by itself: <see cref="Window"/> after the last failure (UTC).</summary>
    public DateTime? ClearsAt(string key) => Failures(key).LastOrDefault()?.At.Add(Window);

    /// <summary>Records one failed login and returns how many in a row there are now.</summary>
    public int RecordFailure(string key, Guid connection, OtpMode? otpMode, bool rejected) => Locked(() =>
    {
        if (key.Length == 0) return 0;
        var list = Current(key).Append(new Failure(_now(), connection, otpMode, rejected)).ToList();
        _failed[key] = list;
        Save();
        return list.Count;
    });

    /// <summary>A login got through: the gateway starts counting from zero again. Returns how many failures that cleared.</summary>
    public int RecordSuccess(string key) => Locked(() =>
    {
        var n = Current(key).Count;
        if (_failed.Remove(key)) Save();
        return n;
    });

    // MARK: File

    private List<Failure> Current(string key) =>
        _failed.TryGetValue(key, out var list) && list.Count > 0 && _now() - list[^1].At < Window ? list : new List<Failure>();

    /// <summary>Runs <paramref name="body"/> holding an exclusive lock on the file, after reading what other copies wrote.</summary>
    private T Locked<T>(Func<T> body)
    {
        lock (_gate)
        {
            FileStream? held = null;
            // Another copy holds it for a few milliseconds at most; without the lock the count is still right
            // for this copy, so after a second it goes on rather than block a connect.
            for (var attempt = 0; attempt < 20 && held == null; attempt++)
            {
                try { held = new FileStream(_lockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                catch (IOException) { Thread.Sleep(50); }
                catch (Exception) { break; }
            }
            try
            {
                Load();
                return body();
            }
            finally { held?.Dispose(); }
        }
    }

    private void Load()
    {
        string text;
        try
        {
            if (!File.Exists(_file)) { _failed = new(StringComparer.Ordinal); return; }
            text = File.ReadAllText(_file);
        }
        catch (Exception) { return; }   // unreadable right now: keep what this copy knows
        try
        {
            if (Json.Parse(text) is not JsonObject root) throw new FormatException();
            var loaded = new Dictionary<string, List<Failure>>(StringComparer.Ordinal);
            foreach (var (key, value) in root)
            {
                if (value is not JsonArray arr) continue;
                var list = new List<Failure>();
                foreach (var n in arr)
                {
                    if (n is not JsonObject o || Json.Str(o["at"]) is not { } at) continue;
                    if (!DateTime.TryParse(at, System.Globalization.CultureInfo.InvariantCulture,
                            System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var when)) continue;
                    list.Add(new Failure(when,
                        Guid.TryParse(Json.Str(o["connection"]), out var id) ? id : null,
                        Json.Str(o["otpMode"]) is { } mode ? OtpModeExt.FromWire(mode) : null,
                        Json.Bool(o["rejected"])));
                }
                if (list.Count > 0) loaded[key] = list;
            }
            _failed = loaded;
        }
        catch (Exception)
        {
            // Unreadable: keep what this copy knows rather than forget failures.
            Log.Shared.Write("the failed-login count file could not be read; keeping the count in memory", LogLevel.Error);
        }
    }

    private void Save()
    {
        // Gateways whose failures no longer count are left out.
        foreach (var key in _failed.Keys.Where(k => Current(k).Count == 0).ToList()) _failed.Remove(key);
        try
        {
            var root = new JsonObject();
            foreach (var (key, list) in _failed.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                var arr = new JsonArray();
                foreach (var f in list)
                {
                    var o = new JsonObject { ["at"] = f.At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture) };
                    if (f.Connection is { } id) o["connection"] = id.ToString().ToUpperInvariant();
                    if (f.OtpMode is { } mode) o["otpMode"] = mode.Wire();
                    if (f.Rejected is { } rejected) o["rejected"] = rejected;
                    arr.Add(o);
                }
                root[key] = arr;
            }
            SafeFile.Replace(_file, Json.ToPretty(root));
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not save the failed-login count: {e.Message}", LogLevel.Error);
        }
    }
}
