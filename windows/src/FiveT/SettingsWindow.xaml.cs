using FiveT.Core;
using FiveT.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using WinRT.Interop;

namespace FiveT;

/// <summary>The Settings window: Connections, General (with setup) and MCP pages.</summary>
public sealed partial class SettingsWindow : Window
{
    // A SettingsCard moves its control onto a second line below the header once the card is narrower
    // than 476 px. The Connections page spends 220 px of the content area on the connection list, so
    // the window has to stay wide enough to leave more than that for the cards themselves.
    // 200 (nav pane) + 48 (padding) + 220 (list) + 20 (gap) + 492 leaves a card just over 476 px.
    private const double WidthDip = 1120, HeightDip = 760, MinWidthDip = 980, MinHeightDip = 560, ScreenMarginDip = 24;

    /// <summary>The open Settings window, if any (WinUI 3 has no Window.Current for pages to ask).</summary>
    public static SettingsWindow? Instance { get; private set; }

    public SettingsWindow()
    {
        InitializeComponent();
        Instance = this;
        Closed += (_, _) =>
        {
            if (ReferenceEquals(Instance, this)) Instance = null;
            // Pages unsubscribe from the store / VPN manager when XAML says they unloaded, which a
            // closing window does not reliably do: tell the visible one to let go explicitly.
            (ContentFrame.Content as IDetachable)?.Detach();
        };
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Title = "FiveT";
        try { AppWindow.SetIcon(Path.Combine(Paths.ExeDir, "Resources", "AppIcon.ico")); } catch { }

        var hwnd = WindowNative.GetWindowHandle(this);
        var scale = NativeUi.Scale(hwnd);
        // Never larger than the screen's work area: on a 1366x768 screen, or a 1080p one at 150 %,
        // the title bar would otherwise sit above the top edge and the bottom of the page be cut off.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var margin = (int)(ScreenMarginDip * scale);
        var size = new SizeInt32(Math.Min((int)(WidthDip * scale), Math.Max(area.Width - margin, 1)),
                                 Math.Min((int)(HeightDip * scale), Math.Max(area.Height - margin, 1)));
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.PreferredMinimumWidth = Math.Min((int)(MinWidthDip * scale), size.Width);
            p.PreferredMinimumHeight = Math.Min((int)(MinHeightDip * scale), size.Height);
        }
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2, size.Width, size.Height));
    }

    public void Select(SettingsTab tab)
    {
        var tag = tab switch
        {
            SettingsTab.General => "General",
            SettingsTab.Mcp => "Mcp",
            SettingsTab.Vpn => "Vpn",
            _ => "Connections",
        };
        var item = Nav.MenuItems.OfType<NavigationViewItem>().First(i => (string)i.Tag == tag);
        if (ReferenceEquals(Nav.SelectedItem, item)) Navigate(tag);
        else Nav.SelectedItem = item;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item) Navigate((string)item.Tag);
    }

    private void Navigate(string tag)
    {
        var type = tag switch
        {
            "General" => typeof(GeneralPage),
            "Mcp" => typeof(AssistantsPage),
            _ => typeof(ConnectionsPage),
        };
        if (ContentFrame.CurrentSourcePageType != type) ContentFrame.Navigate(type);
        if (ContentFrame.Content is ConnectionsPage list) list.ShowTab(tag == "Vpn");
    }

    /// <summary>General's "Add Your VPN…": switch to Connections with a new, selected connection.</summary>
    public void AddConnection()
    {
        Select(SettingsTab.Connections);
        if (ContentFrame.Content is ConnectionsPage page) page.AddNew();
    }

    private void CloseAccelerator_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Close();
    }
}
