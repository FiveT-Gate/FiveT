using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using WinRT.Interop;

namespace FiveT;

/// <summary>
/// The Windows 11 style flyout that opens from the notification-area icon (the menu of the macOS
/// app): a small borderless acrylic window above the taskbar that closes when it loses focus.
/// </summary>
public sealed partial class TrayFlyout : Window
{
    private const double WidthDip = 320;

    private readonly TrayApp _app;
    private readonly IntPtr _hwnd;
    private readonly DispatcherQueueTimer _clock;
    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private readonly VpnManager _vpn = VpnManager.Shared;

    public bool IsShown { get; private set; }
    /// <summary>The flyout went away (TrayApp ignores the click that caused it, and schedules releasing the window).</summary>
    public event Action? Hidden;

    private readonly Action<VpnStatus> _onStatus;

    public TrayFlyout(TrayApp app)
    {
        _app = app;
        _onStatus = _ => RequestRebuild();
        InitializeComponent();
        _hwnd = WindowNative.GetWindowHandle(this);

        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        NativeUi.RoundCorners(_hwnd);

        _clock = Ui.Queue.CreateTimer();
        _clock.Interval = TimeSpan.FromSeconds(1);
        _clock.IsRepeating = true;
        _clock.Tick += (_, _) => TickClock();

        Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) HideFlyout(); };
        _vpn.StatusChanged += _onStatus;
        _store.Changed += RequestRebuild;
        // Only at exit in practice, but a closed window must not stay subscribed to the engine.
        Closed += (_, _) =>
        {
            _vpn.StatusChanged -= _onStatus;
            _store.Changed -= RequestRebuild;
            _clock.Stop();
            IsShown = false;
        };
        // Buttons mark their pointer events handled, so ask for those too: a click is "in progress"
        // from press to release, and the rows must not be swapped for new ones in between.
        void Down(object _, PointerRoutedEventArgs __) { _pointerDown = true; _pointerDownAt = Environment.TickCount64; }
        void Up(object _, PointerRoutedEventArgs __) => _pointerDown = false;
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(Down), true);
        Root.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(Up), true);
        Root.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler(Up), true);
        Root.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(Up), true);
    }

    private bool _pointerDown, _rebuildPending;
    private long _pointerDownAt;

    /// <summary>
    /// A status change while the flyout is open (a connection logging in sends many) rebuilds the rows:
    /// coalesced, and never while a click is in progress (it would be lost), with keyboard focus kept
    /// on the same row.
    /// </summary>
    private void RequestRebuild()
    {
        if (!IsShown || _rebuildPending) return;
        _rebuildPending = true;
        Ui.After(0.12, FlushRebuild);
    }

    private void FlushRebuild()
    {
        if (!IsShown) { _rebuildPending = false; return; }
        // A press whose release never arrived (let go outside the window, focus lost) must not freeze the
        // rows: no click lasts two seconds.
        if (_pointerDown && Environment.TickCount64 - _pointerDownAt < 2000) { Ui.After(0.12, FlushRebuild); return; }
        _pointerDown = false;
        _rebuildPending = false;
        var focused = FocusManager.GetFocusedElement(Root.XamlRoot) is DependencyObject d ? AutomationProperties.GetAutomationId(d) : "";
        Rebuild();
        if (focused.Length == 0) return;
        foreach (var b in Items.Children.OfType<Button>())
            if (AutomationProperties.GetAutomationId(b) == focused && b.IsEnabled) { b.Focus(FocusState.Keyboard); break; }
    }

    /// <summary>Opens the flyout next to <paramref name="anchorX"/>/<paramref name="anchorY"/> (screen pixels, the icon's centre).</summary>
    public void ShowAt(int anchorX, int anchorY)
    {
        _pointerDown = false;
        Rebuild();
        var scale = NativeUi.Scale(_hwnd);
        var width = (int)Math.Round(WidthDip * scale);
        Panel.Measure(new Windows.Foundation.Size(WidthDip, double.PositiveInfinity));
        var height = (int)Math.Ceiling(Math.Max(Panel.DesiredSize.Height, 120) * scale);
        AppWindow.ResizeClient(new SizeInt32(width, height));
        Place(anchorX, anchorY);

        IsShown = true;
        _shownAt = Environment.TickCount64;
        AppWindow.Show();
        Activate();
        NativeUi.SetForegroundWindow(_hwnd);
        Header.Focus(FocusState.Programmatic);
        _clock.Start();
    }

    private long _shownAt;

    /// <summary>
    /// The Enter/Space that opened the flyout from the keyboard (or a UI Automation Invoke on the
    /// icon) is still in flight when the window appears: never let it trigger a row.
    /// </summary>
    private void Root_PreviewKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space && Environment.TickCount64 - _shownAt < 500)
            e.Handled = true;
    }

    private int _anchorX, _anchorY;

    private void Place(int anchorX, int anchorY)
    {
        _anchorX = anchorX;
        _anchorY = anchorY;
        var scale = NativeUi.Scale(_hwnd);
        var size = AppWindow.Size;
        var area = DisplayArea.GetFromPoint(new PointInt32(anchorX, anchorY), DisplayAreaFallback.Nearest).WorkArea;
        var margin = (int)Math.Round(12 * scale);
        var x = Math.Clamp(anchorX - size.Width / 2, area.X + margin, Math.Max(area.X + margin, area.X + area.Width - size.Width - margin));
        int y;
        if (anchorY >= area.Y + area.Height) y = area.Y + area.Height - size.Height - margin;      // taskbar at the bottom
        else if (anchorY < area.Y) y = area.Y + margin;                                                // taskbar at the top
        else
        {
            // Taskbar on the left or right: sit beside it, level with the icon.
            y = Math.Clamp(anchorY - size.Height / 2, area.Y + margin, Math.Max(area.Y + margin, area.Y + area.Height - size.Height - margin));
            x = anchorX < area.X + area.Width / 2 ? area.X + margin : area.X + area.Width - size.Width - margin;
        }
        AppWindow.Move(new PointInt32(x, y));
    }

    public void HideFlyout()
    {
        if (!IsShown) return;
        IsShown = false;
        _clock.Stop();
        AppWindow.Hide();
        _vpn.ClearError();   // the error was shown once; the icon goes back to the plain shield
        Hidden?.Invoke();
    }

    /// <summary>After a real layout pass the height may differ from the estimate: fit the window to the content.</summary>
    private void Panel_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!IsShown) return;
        var scale = NativeUi.Scale(_hwnd);
        var height = (int)Math.Ceiling(e.NewSize.Height * scale);
        if (Math.Abs(height - AppWindow.ClientSize.Height) < 2) return;
        AppWindow.ResizeClient(new SizeInt32(AppWindow.ClientSize.Width, height));
        Place(_anchorX, _anchorY);
    }

    private void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape) { HideFlyout(); e.Handled = true; }
    }

    // MARK: Content

    /// <summary>The header line: the summary across every tunnel (VpnManager builds the name).</summary>
    private static string StatusLine(VpnStatus st) => st.Phase switch
    {
        VpnPhase.Connected => $"{st.ConnectionName ?? "VPN"} — Connected {VpnStatus.DurationText(st.UptimeSeconds ?? 0)}",
        VpnPhase.Connecting => $"{st.ConnectionName ?? "VPN"} — {st.Detail ?? "Connecting…"}",
        VpnPhase.Disconnecting => $"{st.ConnectionName ?? "VPN"} — Disconnecting…",
        _ => "Not connected",
    };

    /// <summary>The label of each connection row with the connection it shows, so the clock can update the time in it.</summary>
    private readonly List<(TextBlock Label, Guid Id, string Name)> _rowLabels = new();

    /// <summary>"Office — Connected 0:42 · not answering for 40s" / "Office — Logging in…" / "Office", as the Mac menu writes it.</summary>
    private static string RowText(string name, VpnStatus own) => own.Phase switch
    {
        VpnPhase.Connected => $"{name} — Connected {VpnStatus.DurationText(own.UptimeSeconds ?? 0)}"
                              + (own.Health is { } h && h != "ok" ? $" · {h}" : ""),
        VpnPhase.Connecting => $"{name} — {own.Detail ?? "Connecting…"}",
        VpnPhase.Disconnecting => $"{name} — Disconnecting…",
        _ => name,
    };

    private void TickClock()
    {
        StatusText.Text = StatusLine(_vpn.Status);
        foreach (var (label, id, name) in _rowLabels) label.Text = RowText(name, _vpn.StatusFor(id));
    }

    private void Rebuild()
    {
        var st = _vpn.Status;
        var conns = _store.Connections;
        StatusText.Text = StatusLine(st);
        Items.Children.Clear();
        _rowLabels.Clear();

        if (conns.Count == 0)
            Items.Children.Add(Note("No connections yet — open Settings", "FlyoutEmpty"));
        var index = 0;
        // Forti connections first, then the VPNs (one of those runs at a time), as in the Mac's menu.
        var ordered = conns.Where(c => !c.IsOtherVpn).Concat(conns.Where(c => c.IsOtherVpn)).ToList();
        var dividerDone = !ordered.Any(c => c.IsOtherVpn) || !ordered.Any(c => !c.IsOtherVpn);
        foreach (var c in ordered)
        {
            if (c.IsOtherVpn && !dividerDone) { Items.Children.Add(Separator()); dividerDone = true; }
            // Every connection now carries its own state: clicking one adds a tunnel next to
            // whatever else is up rather than replacing it, so each row shows only its own dot.
            var own = _vpn.StatusFor(c.Id);
            var active = own.Phase is VpnPhase.Connected or VpnPhase.Connecting;
            var dot = own.Phase switch
            {
                VpnPhase.Connected => "StateConnectedBrush",
                VpnPhase.Connecting or VpnPhase.Disconnecting => "StateBusyBrush",
                _ => "StateIdleBrush",
            };
            var id = c.Id;
            var name = c.Name.Length == 0 ? "Untitled" : c.Name;
            var row = Row(RowText(name, own), active ? "Disconnect" : "Connect",
                () => { if (_store.Get(id) is { } cc) _vpn.Toggle(cc); }, dot, $"FlyoutConnection{index++}");
            AutomationProperties.SetName(row, name);
            if (((Grid)row.Content).Children.OfType<TextBlock>().FirstOrDefault() is { } label) _rowLabels.Add((label, id, name));
            row.IsEnabled = own.Phase != VpnPhase.Disconnecting;
            var tip = c.IsOtherVpn ? $"{V2RayConfig.KindLabel(c)}  ·  {c.Host}:{c.Port}" : $"{c.GatewayDescription}  ·  {c.Username}";
            if (own.Phase == VpnPhase.Connected)
                tip += $"\nConnected {VpnStatus.DurationText(own.UptimeSeconds ?? 0)}"
                       + (own.Network is { Interface.Length: > 0 } n ? $"  ·  {n.Interface} {n.TunnelIP}" : "");
            else if (own.Detail is { } d) tip += "\n" + d;
            ToolTipService.SetToolTip(row, tip);
            Items.Children.Add(row);
        }
        // An openconnect FiveT did not start has no connection row of its own.
        if (_vpn.Sessions.Any(x => x.ConnectionId == null && x.Phase == VpnPhase.Connected))
            Items.Children.Add(Row("Stop: openconnect session", null, () => _vpn.DisconnectExternal(), "StateConnectedBrush", "FlyoutStop"));
        // The bulk rows get their own section, as on the Mac: "Connect All" while any saved connection is
        // down (not while one is still disconnecting), "Disconnect All" while two or more have a tunnel.
        var own2 = _vpn.Sessions;
        var bulk = new List<Button>();
        var forti = conns.Where(c => !c.IsOtherVpn).ToList();
        if (forti.Count > 1 && forti.Any(c => _vpn.StatusFor(c.Id).Phase == VpnPhase.Idle))
        {
            var all = Row("Connect All", null, _vpn.ConnectAll, null, "FlyoutConnectAll");
            all.IsEnabled = !own2.Any(x => x.Phase == VpnPhase.Disconnecting);
            bulk.Add(all);
        }
        // A session that only shows an error (idle) has no tunnel to stop.
        var withTunnel = own2.Count(x => x.ConnectionId != null && x.Phase != VpnPhase.Idle);
        if (withTunnel > 1)
        {
            var none = Row($"Disconnect All ({withTunnel})", null, () => _vpn.DisconnectAll(), null, "FlyoutDisconnectAll");
            none.IsEnabled = own2.Any(x => x.Phase != VpnPhase.Disconnecting);
            bulk.Add(none);
        }
        if (bulk.Count > 0)
        {
            Items.Children.Add(Separator());
            foreach (var b in bulk) Items.Children.Add(b);
        }

        // Apps-only mode: the chosen apps are started through the VPN from here (the Mac's "Open with VPN").
        if (_store.AppsOnly && _store.VpnAppPaths.Count > 0)
        {
            Items.Children.Add(Separator());
            Items.Children.Add(Note("Open with VPN", "FlyoutAppsHeader"));
            var a = 0;
            foreach (var path in _store.VpnAppPaths)
            {
                var app = path;
                var row = Row(VpnApps.Name(app), null, () => OpenApp(app), null, $"FlyoutApp{a++}");
                row.IsEnabled = _vpn.AppProxyReady;
                ToolTipService.SetToolTip(row, _vpn.AppProxyReady ? app : "Connect a V2Ray or Outline VPN first");
                Items.Children.Add(row);
            }
        }

        Items.Children.Add(Separator());

        if (_vpn.KillSwitchActive)
        {
            Items.Children.Add(Row("Internet Blocked by Kill Switch: Unblock Internet", null, _vpn.ReleaseKillSwitch, "StateBusyBrush", "FlyoutUnblock"));
            Items.Children.Add(Separator());
        }
        // Errors belong to whichever tunnel failed, so show each one rather than only the newest.
        var failed = _vpn.Sessions.Where(x => x.LastError != null).ToList();
        foreach (var f in failed)
        {
            // One short line here (Mac 1.11.1); the whole explanation is under the connection in Settings → Connections.
            var note = Note($"⚠ {(f.ConnectionName is { } fn ? fn + ": " : "")}{VpnStatus.ShortError(f.LastError!)}", "FlyoutError");
            ToolTipService.SetToolTip(note, f.LastError);
            Items.Children.Add(note);
        }
        // A gateway certificate that waits for the user's decision (CertReview), one row per connection.
        var reviews = conns.Where(c => c.HasPendingReview).ToList();
        var r = 0;
        foreach (var c in reviews)
        {
            var id = c.Id;
            Items.Children.Add(Row(c.PendingCertFirst ? $"Review Certificate for {c.Name}…" : $"Review New Certificate for {c.Name}…",
                null, () => CertReview.Present(id), "StateBusyBrush", $"FlyoutReview{r++}"));
        }
        if (_vpn.Sessions.Any(x => x.NeedsSetup))
            Items.Children.Add(Row("Set Up FiveT…", null, () => _app.ShowSettings(SettingsTab.General), null, "FlyoutSetup"));
        if (failed.Count > 0 || reviews.Count > 0 || _vpn.Sessions.Any(x => x.NeedsSetup)) Items.Children.Add(Separator());

        // Plain lines at the bottom, as the Mac menu has had them since 1.4.1.
        Items.Children.Add(Row("Settings", null, () => _app.ShowSettings(SettingsTab.Connections), null, "FlyoutSettings"));
        Items.Children.Add(Row("Quit", null, _app.Quit, null, "FlyoutQuit"));
    }

    /// <summary>After the flyout has closed; what went wrong is said in a prompt (the Mac's "Could not open the app through the VPN").</summary>
    private void OpenApp(string path)
    {
        Ui.Post(async () =>
        {
            if (_vpn.OpenThroughVpn(path) is not { } problem) return;
            await PromptWindow.Ask("openapp:" + path, new PromptSpec
            {
                Title = "Could not open the app through the VPN", Message = problem, Primary = "OK", Secondary = "Close", AutomationId = "OpenAppProblem",
            });
        });
    }

    private Button Row(string text, string? trailing, Action onClick, string? dotBrushKey, string automationId)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (dotBrushKey != null)
        {
            var dot = new Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center, Fill = (Brush)Application.Current.Resources[dotBrushKey] };
            grid.Children.Add(dot);
        }
        var label = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        if (trailing != null)
        {
            var hint = new TextBlock
            {
                Text = trailing, VerticalAlignment = VerticalAlignment.Center,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            };
            Grid.SetColumn(hint, 2);
            grid.Children.Add(hint);
        }
        var b = new Button { Content = grid, Style = (Style)Application.Current.Resources["FlyoutRowStyle"] };
        AutomationProperties.SetAutomationId(b, automationId);
        AutomationProperties.SetName(b, text);
        b.Click += (_, _) => { HideFlyout(); onClick(); };
        return b;
    }

    private static TextBlock Note(string text, string automationId)
    {
        var t = new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 7, 10, 7),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        AutomationProperties.SetAutomationId(t, automationId);
        return t;
    }

    private Border Separator() => new() { Style = (Style)Application.Current.Resources["FlyoutSeparatorStyle"] };
}
