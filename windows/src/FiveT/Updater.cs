using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using FiveT.Core;

namespace FiveT;

public enum UpdatePhase { Idle, Checking, UpToDate, Available, Downloading, Failed }

/// <summary>
/// Self-update. Reads the signed feed (<see cref="UpdateFeed"/>), and once the person agrees downloads the
/// setup file the feed names, checks its SHA-256, hands it to a small PowerShell helper and quits. The helper
/// waits for this process to end (setup refuses to run while FiveT.exe holds its mutex), runs the setup
/// silently and starts FiveT again.
///
/// FiveT runs as administrator, so it never runs a file an ordinary program could have swapped: the setup is
/// downloaded into <c>updates\</c> inside the install folder, and only when that folder passes
/// <see cref="Setup.IsAdminOnlyDirectory"/> (a per-user or developer copy only reports that an update exists).
/// </summary>
public sealed class Updater
{
    public static Updater Shared { get; } = new();

    private const long MaxBytes = 400L * 1024 * 1024;   // the setup files are about 60 MB
    private static readonly TimeSpan CheckEvery = TimeSpan.FromHours(24), RetryAfter = TimeSpan.FromHours(5);

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

    private string _askedVersion = "";

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
        Ui.After(60, () => AutoCheck());
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
                else if (Phase == UpdatePhase.Available && Release is { } r && _askedVersion != r.Version)
                {
                    _askedVersion = r.Version;   // once per version and start
                    Ask(r);
                }
            }
        }
        catch (Exception e) { Log.Shared.Write($"update check failed: {e.Message}", LogLevel.Error); }
        Ui.After(next.TotalSeconds, () => AutoCheck());
    }

    // MARK: Check

    public async Task CheckAsync()
    {
        if (Phase is UpdatePhase.Checking or UpdatePhase.Downloading) return;
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

    private async void Ask(UpdateRelease rel)
    {
        try
        {
            if (!CanInstall)
            {
                Notify?.Invoke("FiveT update", $"FiveT {rel.Version} is available. This copy cannot update itself: install the new setup from FiveT's GitHub releases page.", false);
                return;
            }
            var notes = rel.Notes is { Length: > 0 } n ? (n.Length > 600 ? n[..600] + "…" : n) : null;
            var r = await PromptWindow.Ask("update:" + rel.Version, new PromptSpec
            {
                Title = $"FiveT {rel.Version} is available",
                Message = $"You have {Paths.AppVersion}. Install the new version now? FiveT restarts, and every open connection is disconnected.",
                Detail = notes,
                Primary = "Install and Restart",
                Secondary = "Later",
                AutomationId = "UpdatePrompt",
            });
            if (r.Accepted) await InstallAsync();
        }
        catch (Exception e) { Log.Shared.Write($"update prompt failed: {e.Message}", LogLevel.Error); }
    }

    /// <summary>Downloads, verifies and starts the installer; on success FiveT quits and comes back as the new version.</summary>
    public async Task<bool> InstallAsync()
    {
        if (Phase != UpdatePhase.Available || Release is not { } rel || !CanInstall) return false;
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
            Launch(file);
            Log.Shared.Write($"installing FiveT {rel.Version}: FiveT quits and setup restarts it");
            Ui.Post(() => TrayApp.Current?.Quit());
            return true;
        }
        catch (Exception e)
        {
            Log.Shared.Write($"update to {rel.Version} failed: {e.Message}", LogLevel.Error);
            if (file != null) try { File.Delete(file); } catch { }
            var msg = e is InvalidDataException ? e.Message : "The update could not be downloaded.";
            Fail(msg);
            Notify?.Invoke("FiveT update failed", msg, true);
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
