using Microsoft.UI.Xaml;

namespace FiveT;

/// <summary>The XAML application object. All the work happens in TrayApp once XAML is up.</summary>
public partial class App : Application
{
    private readonly string[] _args;
    private TrayApp? _tray;

    public App(string[] args)
    {
        _args = args;
        InitializeComponent();
        // FiveT lives in the tray: windows come and go (the flyout and Settings are closed while idle to
        // free their memory) and the app only ends with Quit. The default would end it with the last window.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            Log.Shared.Write($"unhandled: {e.Exception}", LogLevel.Error);
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _tray = new TrayApp(_args);
    }
}
