using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using FiveT.Core;

namespace FiveT;

public enum UpdatePhase { Idle, Checking, UpToDate, Available, Downloading, Ready, Failed }

/// <summary>
/// Self-update, like the Mac's: no dialogs. Reads the signed feed (<see cref="UpdateFeed"/>), downloads the
/// setup file the feed names in the background, checks its SHA-256 and keeps it until no tunnel is in use
/// (two quiet looks in a row); then hands it to a small PowerShell helper and quits. The helper
/// waits for this process to end (setup refuses to run while FiveT.exe holds its mutex), runs the setup
/// silently and starts FiveT again. "Install and Restart" in Settings skips the wait.
///
/// FiveT runs as administrator, so it never runs a file an ordinary program could have swapped: the setup is
/// downloaded into <c>updates\</c> inside the install folder, and only when that folder passes
/// <see cref="Setup.IsAdminOnlyDirectory"/> (a per-user or developer copy only reports that an update exists).
/// </summary>
public sealed class Updater
{
    public static Updater Shared { get; } = new();

    private const long MaxBytes = 400L * 1024 * 1024;   // the setup files are about 60 MB
    private static readonly TimeSpan CheckEvery = TimeSpan.FromHours(24), RetryAfter = TimeSpan.FromHours(5), QuietEvery = TimeSpan.FromMinutes(3);

    private readonly HttpClient _http = new(new SocketsHttpHandler { UseCookies = false, MaxAutomaticRedirections = 5 })
    {
        Timeout = TimeSpan.FromMinutes(10),
        MaxResponseContentBufferSize = 1024 * 1024,   // the feed; the download streams
    };

    public UpdatePhase Phase { get; private set; }
    public UpdateRelease? Release { get; private set; }
    public string? Problem { get; private set; }
    public DateTime? LastChecked { get; private set; }

    /// <summary>Raised on the UI thread whenever the phase changes.</summary>
    public event Action? Changed;

    /// <summary>Set by the tray app: shows a notification-area balloon.</summary>
    public Action<string, string, bool>? Notify { get; set; }

    /// <summary>Set by the tray app: true while a restart would get in someone's way (a tunnel is up or starting).</summary>
    public Func<bool> IsBusy { get; set; } = () => false;

    private string _askedVersion = "";
    private string? _staged;     // the verified setup file, waiting for a quiet moment
    private int _quietTicks;
    private UiTimer? _timer;     // held so it cannot be collected while it waits

    private Updater()
    {
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("FiveT/" + Paths.AppVersion);
    }

    public static string Arch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";

    /// <summary>FIVET_UPDATE_URL points a developer build at another feed. The signature check stays on, and
    /// the environment is ignored by a normal run: an environment variable must not steer an elevated app.</summary>
    private static Uri FeedUrl =>
        Paths.IsDev && Uri.TryCreate(Environment.GetEnvironmentVariable("FIVET_UPDATE_URL"), UriKind.Absolute, out var u) ? u : UpdateFeed.DefaultUrl;

    /// <summary>True when this copy may replace itself.</summary>
    public static bool CanInstall => !Paths.IsDev && Paths.IsElevated && Setup.IsAdminOnlyDirectory(Paths.ExeDir);

    private static string UpdatesDir => Path.Combine(Paths.ExeDir, "updates");

    private void Set(UpdatePhase phase, string? problem = null)
    {
        Phase = phase;
        Problem = problem;
        Ui.Post(() => Changed?.Invoke());
    }

    // MARK: Schedule

    /// <summary>First look a minute after start (never while the PC is still logging in), then once a day.</summary>
    public void Start()
    {
        if (Paths.IsDev) return;
        try { if (Directory.Exists(UpdatesDir)) Directory.Delete(UpdatesDir, true); } catch { }   // a setup left by an update that did not finish
        _timer = Ui.After(60, () => AutoCheck());
    }

    private async void AutoCheck()
    {
        var next = CheckEvery;
        try
        {
            if (ConnectionStore.Shared.AutoUpdateCheck)
            {
                await CheckAsync();
                if (Phase == UpdatePhase.Failed) next = RetryAfter;
                else if (Phase == UpdatePhase.Available && Release is { } r)
                {
                    if (CanInstall) { if (!await DownloadAsync(r, userAsked: false)) next = RetryAfter; }
                    else if (_askedVersion != r.Version)
                    {
                        _askedVersion = r.Version;   // once per version and start
                        Notify?.Invoke("FiveT update", $"FiveT {r.Version} is available. This copy cannot update itself: install the new setup from FiveT's GitHub releases page.", false);
                    }
                }
            }
        }
        catch (Exception e) { Log.Shared.Write($"update check failed: {e.Message}", LogLevel.Error); }
        _timer = Ui.After(next.TotalSeconds, () => AutoCheck());
    }

    /// <summary>A downloaded update looks for a quiet moment every 3 minutes; two in a row (3 to 6 minutes), so a
    /// restart never lands between a disconnect and the next connect.</summary>
    private void QuietTick()
    {
        if (Phase != UpdatePhase.Ready) return;
        _quietTicks = ConnectionStore.Shared.AutoUpdateCheck && !IsBusy() ? _quietTicks + 1 : 0;
        if (_quietTicks >= 2)
        {
            Log.Shared.Write("no tunnel in use; installing the update");
            Install();
            return;
        }
        _timer = Ui.After(QuietEvery.TotalSeconds, QuietTick);
    }

    // MARK: Check

    public async Task CheckAsync()
    {
        if (Phase is UpdatePhase.Checking or UpdatePhase.Downloading or UpdatePhase.Ready) return;
        Set(UpdatePhase.Checking);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var json = await _http.GetStringAsync(FeedUrl, timeout.Token);
            LastChecked = DateTime.Now;
            var rel = UpdateFeed.Parse(json, Arch, UpdateFeed.ReleaseKeys, out var problem);
            if (rel == null)
            {
                Log.Shared.Write($"update feed refused: {problem}", LogLevel.Error);
                Fail(char.ToUpper(problem![0]) + problem[1..] + ".");
                return;
            }
            if (!UpdateFeed.IsNewer(rel.Version, Paths.AppVersion))
            {
                Release = null;
                Set(UpdatePhase.UpToDate);
                return;
            }
            Release = rel;
            Log.Shared.Write($"update {rel.Version} is available (this is {Paths.AppVersion})");
            Set(UpdatePhase.Available);
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException)
        {
            Log.Shared.Write($"update check failed: {e.Message}", LogLevel.Error);
            Fail("Could not reach the update feed.");
        }
    }

    private void Fail(string problem) => Set(UpdatePhase.Failed, problem);

    // MARK: Install

    /// <summary>"Install and Restart" in Settings: downloads first when that has not happened yet, then installs now.</summary>
    public async Task<bool> InstallAsync()
    {
        if (Phase == UpdatePhase.Available && Release is { } rel && CanInstall && !await DownloadAsync(rel, userAsked: true)) return false;
        if (Phase != UpdatePhase.Ready) return false;
        return Install();
    }

    /// <summary>Downloads and verifies the setup file, then waits for a quiet moment. The background run only logs a failure.</summary>
    private async Task<bool> DownloadAsync(UpdateRelease rel, bool userAsked)
    {
        if (!CanInstall) return false;
        Set(UpdatePhase.Downloading);
        string? file = null;
        try
        {
            Directory.CreateDirectory(UpdatesDir);
            file = Path.Combine(UpdatesDir, $"FiveT-Setup-{rel.Version}-{rel.Arch}.exe");
            using (var resp = await _http.GetAsync(rel.Url, HttpCompletionOption.ResponseHeadersRead))
            {
                resp.EnsureSuccessStatusCode();
                if (resp.Content.Headers.ContentLength > MaxBytes) throw new InvalidDataException("The download is larger than any FiveT setup.");
                await using var src = await resp.Content.ReadAsStreamAsync();
                await using var dst = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buf = new byte[81920];
                long total = 0;
                int n;
                while ((n = await src.ReadAsync(buf)) > 0)
                {
                    total += n;
                    if (total > MaxBytes) throw new InvalidDataException("The download is larger than any FiveT setup.");
                    hash.AppendData(buf, 0, n);
                    await dst.WriteAsync(buf.AsMemory(0, n));
                }
                if (!Convert.ToHexString(hash.GetHashAndReset()).Equals(rel.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The download does not match the checksum in the signed feed.");
            }
            _staged = file;
            Log.Shared.Write($"update {rel.Version} downloaded and verified");
            Set(UpdatePhase.Ready);
            _quietTicks = 0;
            _timer = Ui.After(QuietEvery.TotalSeconds, QuietTick);
            return true;
        }
        catch (Exception e)
        {
            Log.Shared.Write($"update to {rel.Version} failed: {e.Message}", LogLevel.Error);
            if (file != null) try { File.Delete(file); } catch { }
            var msg = e is InvalidDataException ? e.Message : "The update could not be downloaded.";
            Fail(msg);
            if (userAsked) Notify?.Invoke("FiveT update failed", msg, true);
            return false;
        }
    }

    /// <summary>Starts the installer; FiveT quits and comes back as the new version.</summary>
    private bool Install()
    {
        try
        {
            Launch(_staged!);
            Log.Shared.Write($"installing FiveT {Release?.Version}: FiveT quits and setup restarts it");
            Ui.Post(() => TrayApp.Current?.Quit());
            return true;
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not start the update: {e.Message}", LogLevel.Error);
            Fail("The update could not be started.");
            return false;
        }
    }
    /// <summary>
    /// A hidden PowerShell waits for this process to exit, runs the setup silently (it replaces the files
    /// and keeps the login task), deletes it and starts FiveT again, through the login task when there is one.
    /// </summary>
    private static void Launch(string setup)
    {
        static string Q(string s) => "'" + s.Replace("'", "''") + "'";
        var script =
            $"try {{ Wait-Process -Id {Environment.ProcessId} -Timeout 120 -ErrorAction Stop }} catch {{ }}; " +
            $"Start-Process -FilePath {Q(setup)} -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait; " +
            $"Remove-Item -LiteralPath {Q(setup)} -Force -ErrorAction SilentlyContinue; " +
            $"schtasks.exe /Run /TN {Paths.TaskName} | Out-Null; " +
            $"if ($LASTEXITCODE -ne 0) {{ Start-Process -FilePath {Q(Paths.GuiExePath)} }}";
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) })
            psi.ArgumentList.Add(a);
        Process.Start(psi)?.Dispose();
    }
}
