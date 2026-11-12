using FiveT.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace FiveT;

/// <summary>The Settings pages, in the Mac app's order (Setup was merged into General in 1.4.1).</summary>
public enum SettingsTab { Connections, Vpn, General, Mcp }

/// <summary>The notification-area icon, its flyout and the app lifecycle (the AppDelegate of the macOS app).</summary>
public sealed class TrayApp
{
    private readonly TrayIcon _icon = new();
    private SettingsWindow? _settings;
    private readonly DispatcherQueueTimer _animTimer;
    private int _animFrame;
    private bool _quitting;

    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private readonly VpnManager _vpn = VpnManager.Shared;

    /// <summary>The running tray app, for Settings pages that need to quit it properly.</summary>
    public static TrayApp? Current { get; private set; }

    public TrayApp(string[] args)
    {
        Current = this;
        MemoryTrim.WindowOpen = () => _settings != null || (_flyoutWindow?.IsShown ?? false);
        _animTimer = Ui.Queue.CreateTimer();
        _animTimer.Interval = TimeSpan.FromMilliseconds(350);
        _animTimer.IsRepeating = true;
        _animTimer.Tick += (_, _) => TickAnimation();

        // Left click opens the same flyout as right click (closest thing to a menu bar item).
        _icon.Selected += ToggleFlyout;
        _icon.ContextRequested += ToggleFlyout;
        _icon.ThemeChanged += RefreshIcon;   // redraw the glyph when the taskbar switches light/dark
        _icon.Resumed += () => Ui.Post(_vpn.SystemResumed);
        _icon.Suspending += () => Ui.Post(_vpn.SystemSuspending);
        _vpn.StatusChanged += _ => RefreshIcon();
        _vpn.Notifier = (title, text, isError) => _icon.ShowBalloon(title, text, isError);
        // A certificate question that came from a click is asked at once (the Mac's onReviewNeeded).
        _vpn.ReviewNeeded += id => Ui.Post(() => CertReview.Present(id));
        // Two refused logins in a row: the person who clicked is asked whether to try anyway.
        _vpn.LoginLimitReached += id => Ui.Post(() => LoginLimitPrompt.Present(id));
        _store.KillSwitchChanged += () => Ui.Post(_vpn.KillSwitchSettingChanged);
        _store.AppsOnlyChanged += () => Ui.Post(_vpn.AppsModeChanged);
        // Both fire on background threads, often several times for one change; VpnManager compares
        // the real networks before it does anything.
        System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += (_, _) => Ui.Post(_vpn.NetworkChanged);
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += (_, _) => Ui.Post(_vpn.NetworkChanged);
        _vpn.NetworkChanged();   // the baseline to compare the first change with
        if (!Paths.IsDev)
        {
            _store.McpEnabledChanged += on => { if (on) McpServer.Shared.Start(); else McpServer.Shared.Stop(); };
            if (_store.McpEnabled) McpServer.Shared.Start();
        }
        Links.Register();
        Links.Listen(HandleLink);
        Updater.Shared.Notify = (title, text, isError) => _icon.ShowBalloon(title, text, isError);
        Updater.Shared.IsBusy = () => _vpn.IsRunning;
        Updater.Shared.Start();

        Log.Shared.Write($"FiveT launched from {Paths.ExeDir}" + (Paths.IsDev ? " (developer mode)" : ""));
        // Developer mode never adopts (or stops) an openconnect session it did not start: the real app may own it.
        if (!Paths.IsDev) _vpn.DetectExistingSession();
        RefreshIcon();
        _icon.Show();

        // A connections.json FiveT could not read is shown at once, on General where the warning is: an
        // empty list with no explanation would look like the connections had been deleted.
        if (_store.LoadProblem != null) ShowSettings(SettingsTab.General);
        else if (args.Contains("--setup")) ShowSettings(SettingsTab.General);
        else if (args.Contains("--settings")) ShowSettings(SettingsTab.Connections);
        // Developer mode only: the notification area cannot be driven by UI automation, so this is the
        // only way to put the flyout on screen for a screenshot or an automated check.
        else if (Paths.IsDev && args.Contains("--flyout")) Ui.After(0.5, () => ToggleFlyout(0, 0));
        else if (!_store.WelcomeShown)
        {
            // Like the Mac app: the very first start opens Settings on General, where Set Up FiveT
            // and Add Your VPN… are waiting.
            _store.WelcomeShown = true;
            ShowSettings(SettingsTab.General);
        }
        else if (!Paths.IsDev) OpenSettingsWhileSetupIsMissing();
        if (args.FirstOrDefault(Links.IsLink) is { } link) Ui.After(0.5, () => HandleLink(link));
        // Start-up touches far more memory than the tray icon needs afterwards.
        MemoryTrim.Soon(20);
    }

    // MARK: The flyout window

    private TrayFlyout? _flyoutWindow;
    private long _flyoutHiddenAt = -10_000;

    /// <summary>
    /// The flyout is a whole WinUI window (XAML tree, composition surface, text engine): built when the icon
    /// is first clicked rather than at start, so a FiveT nobody opens the menu of never pays for it
    /// (measured: ~10 MB private memory and ~300 handles). It is kept once built: closing and rebuilding
    /// it freed almost nothing more (WinUI holds on to its framework state) and made the next click slower;
    /// what returns the memory is <see cref="MemoryTrim"/> after it hides.
    /// </summary>
    private TrayFlyout Flyout
    {
        get
        {
            if (_flyoutWindow != null) return _flyoutWindow;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var f = new TrayFlyout(this);
            f.Hidden += OnFlyoutHidden;
            Log.Shared.Write($"flyout window built in {watch.ElapsedMilliseconds} ms", LogLevel.Debug);
            return _flyoutWindow = f;
        }
    }

    private void OnFlyoutHidden()
    {
        _flyoutHiddenAt = Environment.TickCount64;
        MemoryTrim.Soon();
    }

    /// <summary>
    /// Like the Mac app (it opens Settings on every launch while it is not set up): a FiveT that
    /// cannot connect yet says so where the fix is, instead of failing at the first click. The login
    /// task only saves UAC prompts, so it does not count (as in Settings → General).
    /// </summary>
    private void OpenSettingsWhileSetupIsMissing()
    {
        Task.Run(() =>
        {
            var missing = Setup.Checks(full: false).Any(c => c.Id != "task" && !c.Ok);
            if (missing) Ui.Post(() => ShowSettings(SettingsTab.General));
        });
    }

    // MARK: fivet:// links

    /// <summary>When each connection (or "all") was last acted on by a link: repeats within 3 s are ignored.</summary>
    private readonly Dictionary<string, DateTime> _lastLinkAction = new();

    /// <summary>
    /// Does what the link asks, as the same click in the menu would (the Mac's handleLink). Any web
    /// page can open a link, so: a connect always asks first, a name must
    /// match exactly, nothing from the link is shown back, and a certificate is never trusted by one.
    /// </summary>
    private async void HandleLink(string url)
    {
        // async void: an exception here would take the whole app down, so nothing escapes.
        try { await HandleLinkCore(url); }
        catch (Exception e) { Log.Shared.Write($"[link] failed: {e}", LogLevel.Error); }
    }

    private async Task HandleLinkCore(string url)
    {
        var cmd = Links.Parse(url);
        if (cmd == null)
        {
            // The reason never repeats the link's own text (the page that opened it chose every word).
            Log.Shared.Write($"[link] refused: {Links.Sanitized(url)} — {Links.Explain(url) ?? "not a link FiveT can follow"}", LogLevel.Error);
            // Not echoed: the link's text is whatever the page that opened it chose.
            _icon.ShowBalloon("FiveT", "FiveT could not follow a fivet:// link. Links look like fivet://connect/<name>; see the log.", true);
            return;
        }
        Log.Shared.Write($"[link] {Links.Sanitized(url)}");
        if (cmd.Action == LinkAction.Settings)
        {
            ShowSettings(cmd.Name?.ToLowerInvariant() switch { "general" => SettingsTab.General, "mcp" => SettingsTab.Mcp, "vpn" => SettingsTab.Vpn, _ => SettingsTab.Connections });
            return;
        }
        Connection? c = null;
        if (cmd.Name != null)
        {
            // The exact name (capitals aside) or the id; never a guess from a prefix.
            c = _store.Connections.FirstOrDefault(x => string.Equals(x.Name.Trim(), cmd.Name, StringComparison.OrdinalIgnoreCase))
                ?? (Guid.TryParse(cmd.Name, out var gid) ? _store.Get(gid) : null);
            if (c == null)
            {
                Log.Shared.Write($"[link] asked for “{Links.Sanitized(cmd.Name)}”, which is not the exact name of a connection", LogLevel.Error);
                _icon.ShowBalloon("FiveT", "A fivet:// link named a connection FiveT does not have. Links need the exact name shown in FiveT's menu.", true);
                return;
            }
        }
        bool TooSoon(string key)
        {
            var now = DateTime.Now;
            if (_lastLinkAction.TryGetValue(key, out var last) && (now - last).TotalSeconds < 3)
            {
                Log.Shared.Write("[link] ignored: another link acted on the same connection a moment ago", LogLevel.Debug);
                return true;
            }
            _lastLinkAction[key] = now;
            return false;
        }
        switch (cmd.Action)
        {
            case LinkAction.Disconnect:
                if (TooSoon(c?.Id.ToString() ?? "all")) return;
                if (c == null) _vpn.DisconnectAll(); else _vpn.Disconnect(c.Id);
                return;
            case LinkAction.Connect when _vpn.IsActive(c!.Id):
                Log.Shared.Write($"[link] {c.Name} is already {_vpn.StatusFor(c.Id).StateName}", LogLevel.Debug);   // nothing to ask
                return;
        }
        if (TooSoon(c!.Id.ToString())) return;
        if (cmd.Action == LinkAction.Toggle && _vpn.IsActive(c.Id))
        {
            _vpn.Disconnect(c.Id);
            return;
        }
        // Always asked (Mac 1.15.1 removed "Always allow"): any web page can open a link, and a VPN that
        // comes up unasked changes where this PC's traffic goes.
        var r = await PromptWindow.Ask("link:" + c.Id, new PromptSpec
        {
            Title = $"Connect to {c.Name}?",
            Message = $"A fivet:// link from another app or a web page asks FiveT to connect to {c.Name}. If you did not just click such a link, choose Cancel.",
            Primary = "Connect",
            Secondary = "Cancel",
            DefaultSecondary = true,   // Cancel is the default, as on the Mac
            AutomationId = "LinkPrompt",
        });
        if (!r.Accepted) { Log.Shared.Write($"[link] connecting {c.Name} cancelled"); return; }
        // A link is automation: a certificate question fails and waits in the menu for a person.
        if (_store.Get(c.Id) is { } latest && !_vpn.IsActive(latest.Id)) _vpn.Connect(latest, ConnectOrigin.Automation);
    }

    private void OnExit()
    {
        Links.StopListening();
        McpServer.Shared.Stop();     // closes the pipe so a bridge never waits on a dead app
        _vpn.ShutdownCleanup();      // never leave NRPT rules behind
        _icon.Dispose();
    }

    public async void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        try
        {
            // Nothing may ask for a new tunnel while the old ones are being stopped.
            _vpn.Closing = true;
            Links.StopListening();
            McpServer.Shared.Stop();
            _flyoutWindow?.HideFlyout();
            if (_vpn.IsRunning)
            {
                Log.Shared.Write("quit requested while connected; disconnecting first");
                _vpn.DisconnectAll();
                var deadline = DateTime.Now.AddSeconds(6);
                while (_vpn.IsRunning && DateTime.Now < deadline) await Task.Delay(100);
                if (_vpn.IsRunning)
                {
                    // A tunnel that ignores the polite stop must not outlive the app: an openconnect left
                    // behind keeps its Wintun adapter and its routes, and the next start adopts it as "external".
                    Log.Shared.Write("a tunnel did not stop in 6 s; killing it", LogLevel.Error);
                    _vpn.ForceStopAll();
                    var kill = DateTime.Now.AddSeconds(2);
                    while (_vpn.IsRunning && DateTime.Now < kill) await Task.Delay(100);
                }
            }
            OnExit();
        }
        catch (Exception e)
        {
            Log.Shared.Write($"error while quitting: {e.Message}", LogLevel.Error);
        }
        finally
        {
            Application.Current.Exit();
        }
    }

    private void ToggleFlyout(int x, int y)
    {
        if (_quitting) return;
        if (_flyoutWindow is { IsShown: true } shown) { shown.HideFlyout(); return; }
        // Clicking the icon while the flyout is open first deactivates (hides) it, then this
        // callback arrives: treat that as "close", not "reopen".
        if (Environment.TickCount64 - _flyoutHiddenAt < 400) return;
        var rect = _icon.GetRect();
        if (!rect.IsEmpty) { x = (rect.Left + rect.Right) / 2; y = (rect.Top + rect.Bottom) / 2; }
        Flyout.ShowAt(x, y);
    }

    // MARK: Tray icon

    /// <summary>
    /// The icon follows the Mac's refreshIcon: one tunnel changing state animates it even while another
    /// is up; waiting for the network (which can last a whole flight) holds a half-filled shield still;
    /// otherwise connected / error / idle.
    /// </summary>
    private void RefreshIcon()
    {
        var all = _vpn.Sessions;
        var busy = all.FirstOrDefault(x => (x.Phase == VpnPhase.Connecting && !x.WaitingForNetwork) || x.Phase == VpnPhase.Disconnecting);
        var offline = all.FirstOrDefault(x => x.WaitingForNetwork);
        var up = all.Where(x => x.Phase == VpnPhase.Connected).Select(x => x.ConnectionName ?? "VPN").ToList();

        if (busy != null)
        {
            _animTip = busy.Phase == VpnPhase.Connecting
                ? $"FiveT — connecting to {busy.ConnectionName ?? "VPN"}…"
                : $"FiveT — disconnecting {busy.ConnectionName}…".Replace("  ", " ");
            // A running animation keeps going: restarting it on every progress line pins it to frame 0.
            if (!_animTimer.IsRunning)
            {
                _animFrame = 0;
                TickAnimation();
                _animTimer.Start();
            }
            return;
        }
        _animTimer.Stop();
        if (up.Count > 0)
            _icon.SetIcon(TrayGlyph.Check, "FiveT — connected to " + string.Join(" + ", up));
        else if (offline != null)
            _icon.SetIcon(TrayGlyph.HalfFilled, $"FiveT — {offline.ConnectionName ?? "VPN"}: waiting for the network to reconnect");
        else if (_vpn.KillSwitchActive)
            _icon.SetIcon(TrayGlyph.Error, "FiveT — internet blocked by the kill switch until the VPN is back");
        else if (_vpn.Status.LastError is { } err)
            _icon.SetIcon(TrayGlyph.Error, "FiveT — " + VpnStatus.ShortError(err));
        else
            _icon.SetIcon(TrayGlyph.Outline, "FiveT — not connected");
    }

    private string _animTip = "";

    private void TickAnimation()
    {
        var frames = new[] { TrayGlyph.Outline, TrayGlyph.HalfFilled, TrayGlyph.Filled, TrayGlyph.HalfFilled };
        _icon.SetIcon(frames[_animFrame % frames.Length], _animTip);
        _animFrame++;
    }

    // MARK: Settings window

    public void ShowSettings(SettingsTab tab)
    {
        _flyoutWindow?.HideFlyout();
        if (_settings == null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => { _settings = null; MemoryTrim.Soon(); };
        }
        _settings.Select(tab);
        if (_settings.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        _settings.Activate();
        NativeUi.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(_settings));
    }
}
