using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace FiveT;

/// <summary>What a prompt asks. Only <see cref="Title"/>, <see cref="Message"/> and <see cref="Primary"/> are required.</summary>
public sealed record PromptSpec
{
    public string Title { get; init; } = "";
    public string Message { get; init; } = "";
    /// <summary>Monospace, selectable lines under the message (a certificate fingerprint).</summary>
    public string? Detail { get; init; }
    public string? CheckboxText { get; init; }
    public string Primary { get; init; } = "OK";
    public string Secondary { get; init; } = "Cancel";
    /// <summary>A caution icon and no default button, for a decision that should be read (trusting a certificate).</summary>
    public bool Warning { get; init; }
    /// <summary>The secondary answer (Cancel) takes the focus, so Enter does the safe thing.</summary>
    public bool DefaultSecondary { get; init; }
    public string AutomationId { get; init; } = "Prompt";
}

public sealed record PromptResult(bool Accepted, bool Checked);

/// <summary>
/// A small modal-looking window for the questions FiveT has to ask when no Settings window is open —
/// "Trust the certificate of Office's gateway?", "Connect to Office?". The tray app has no main window
/// to hang a ContentDialog on, so this is its own top-level window, centred and always on top.
/// Prompts with the same key share one window, so a double click never stacks two of them.
/// </summary>
public sealed class PromptWindow : Window
{
    private const double WidthDip = 460;

    private static readonly Dictionary<string, Task<PromptResult>> Open = new();

    private readonly TaskCompletionSource<PromptResult> _done = new();
    private readonly CheckBox? _check;
    private readonly StackPanel _panel;

    public static Task<PromptResult> Ask(string key, PromptSpec spec)
    {
        if (Open.TryGetValue(key, out var pending))
            return pending;
        var w = new PromptWindow(spec);
        var task = w._done.Task;
        Open[key] = task;
        _ = task.ContinueWith(_ => Ui.Post(() => Open.Remove(key)));
        w.ShowCentered();
        return task;
    }

    private PromptWindow(PromptSpec spec)
    {
        Title = "FiveT";
        SystemBackdrop = new MicaBackdrop();
        var res = Application.Current.Resources;

        _panel = new StackPanel { Padding = new Thickness(24, 20, 24, 20), Spacing = 12, VerticalAlignment = VerticalAlignment.Top };
        var head = new Grid { ColumnSpacing = 12 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.Children.Add(new FontIcon
        {
            Glyph = spec.Warning ? "" : "", FontSize = 28, VerticalAlignment = VerticalAlignment.Top,
            Foreground = (Brush)res[spec.Warning ? "SystemFillColorCautionBrush" : "AccentFillColorDefaultBrush"],
        });
        var title = new TextBlock { Text = spec.Title, Style = (Style)res["SubtitleTextBlockStyle"], TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(title, 1);
        head.Children.Add(title);
        _panel.Children.Add(head);
        _panel.Children.Add(new TextBlock { Text = spec.Message, TextWrapping = TextWrapping.Wrap });
        if (spec.Detail is { Length: > 0 } detail)
        {
            var box = new TextBlock
            {
                Text = detail, FontFamily = new FontFamily("Consolas"), FontSize = 12, IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap, Foreground = (Brush)res["TextFillColorSecondaryBrush"],
            };
            AutomationProperties.SetAutomationId(box, spec.AutomationId + "Detail");
            _panel.Children.Add(new Border
            {
                Child = box, Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(4),
                Background = (Brush)res["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Brush)res["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
            });
        }
        if (spec.CheckboxText is { } cb)
        {
            _check = new CheckBox { Content = cb };
            AutomationProperties.SetAutomationId(_check, spec.AutomationId + "Check");
            _panel.Children.Add(_check);
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        var secondary = new Button { Content = spec.Secondary, MinWidth = 110 };
        var primary = new Button { Content = spec.Primary, MinWidth = 110, Style = (Style)res["AccentButtonStyle"] };
        AutomationProperties.SetAutomationId(primary, spec.AutomationId + "Primary");
        AutomationProperties.SetAutomationId(secondary, spec.AutomationId + "Secondary");
        primary.Click += (_, _) => Finish(true);
        secondary.Click += (_, _) => Finish(false);
        buttons.Children.Add(secondary);
        buttons.Children.Add(primary);
        _panel.Children.Add(buttons);

        var root = new Grid();
        root.Children.Add(_panel);
        root.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { Finish(false); e.Handled = true; }
        };
        Content = root;

        // A warning gets no default: Enter must not trust a certificate by accident. Otherwise the
        // primary button takes the focus, so Enter answers the common case.
        root.Loaded += (_, _) => (spec.Warning || spec.DefaultSecondary ? secondary : primary).Focus(FocusState.Programmatic);
        // The prompt pops up on its own, possibly right under a click or a key press meant for
        // something else. Like a browser's permission prompt, the risky answer only becomes
        // clickable once the window has been on screen for a moment.
        if (spec.Warning)
        {
            primary.IsEnabled = false;
            root.Loaded += (_, _) => Ui.After(1.0, () => primary.IsEnabled = true);
        }
        Closed += (_, _) => _done.TrySetResult(new PromptResult(false, false));
    }

    private void Finish(bool accepted)
    {
        _done.TrySetResult(new PromptResult(accepted, _check?.IsChecked == true));
        Close();
    }

    private void ShowCentered()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
            p.IsAlwaysOnTop = true;
        }
        try { AppWindow.SetIcon(Path.Combine(FiveT.Core.Paths.ExeDir, "Resources", "AppIcon.ico")); } catch { }
        var scale = NativeUi.Scale(hwnd);
        _panel.Measure(new Windows.Foundation.Size(WidthDip, double.PositiveInfinity));
        var client = new SizeInt32((int)Math.Round(WidthDip * scale), (int)Math.Ceiling(_panel.DesiredSize.Height * scale));
        AppWindow.ResizeClient(client);
        var size = AppWindow.Size;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 3));
        // Text measured before the window is live can come out short: fit again after the real layout.
        _panel.SizeChanged += (_, e) =>
        {
            var h = (int)Math.Ceiling(e.NewSize.Height * NativeUi.Scale(hwnd));
            if (Math.Abs(h - AppWindow.ClientSize.Height) < 2) return;
            AppWindow.ResizeClient(new SizeInt32(AppWindow.ClientSize.Width, h));
        };
        Activate();
        NativeUi.SetForegroundWindow(hwnd);
    }
}
