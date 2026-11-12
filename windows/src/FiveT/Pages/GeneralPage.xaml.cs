using System.Diagnostics;
using FiveT.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FiveT.Pages;

/// <summary>
/// General: setup status (the Setup page until 1.4.1, as on the Mac), behaviour switches and
/// troubleshooting. On the first start FiveT opens here, so this is where "Set Up FiveT" and
/// "Add Your VPN…" live.
/// </summary>
public sealed partial class GeneralPage : Page, IDetachable
{
    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private bool _loading, _checking;
    private List<SetupCheck> _checks = new();

    private enum NextStep { None, SetUp, AddVpn }
    private NextStep _next;

    public GeneralPage()
    {
        InitializeComponent();
        ConnectionsFileCard.Description = _store.FilePath;
        LogFileCard.Description = Log.Shared.FilePath;
        AboutText.Text = $"FiveT {Paths.AppVersion} — FortiGate SSL-VPN (OpenConnect), OpenVPN, and V2Ray and Outline (Xray), one click each. Passwords stay on this PC, encrypted with Windows DPAPI for your account.";
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        _store.Changed -= OnStoreChanged;   // never subscribe twice
        _store.Changed += OnStoreChanged;
        Updater.Shared.Changed -= ShowUpdate;
        Updater.Shared.Changed += ShowUpdate;
        ShowUpdate();
        Reload();
        RefreshChecks();
        // connections.json that could not be read at start: say so where the person is looking, with where the copy went.
        if (_store.LoadProblem is { } problem) ShowMessage(problem, InfoBarSeverity.Warning);
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e) => Detach();

    /// <summary>Also called when the Settings window closes: a closing window does not reliably raise Unloaded.</summary>
    public void Detach()
    {
        _store.Changed -= OnStoreChanged;
        Updater.Shared.Changed -= ShowUpdate;
    }

    private void ShowUpdate()
    {
        var u = Updater.Shared;
        var busy = u.Phase is UpdatePhase.Checking or UpdatePhase.Downloading;
        UpdateCard.Description = u.Phase switch
        {
            UpdatePhase.Checking => "Checking…",
            UpdatePhase.Downloading => "Downloading FiveT " + u.Release?.Version + "…",
            UpdatePhase.Available when Updater.CanInstall => $"FiveT {u.Release?.Version} is available (you have {Paths.AppVersion}). Installing restarts FiveT and briefly disconnects the VPN.",
            UpdatePhase.Ready => $"FiveT {u.Release?.Version} is ready to install. " + (_store.AutoUpdateCheck ? "It installs by itself when no VPN is connected." : "Installing restarts FiveT and briefly disconnects the VPN."),
            UpdatePhase.Available => $"FiveT {u.Release?.Version} is available (you have {Paths.AppVersion}). This copy cannot update itself: install the new setup from FiveT's GitHub releases page.",
            UpdatePhase.UpToDate => $"FiveT {Paths.AppVersion} is up to date" + (u.LastChecked is { } t ? $" (checked {t:HH:mm})." : "."),
            UpdatePhase.Failed => u.Problem ?? "The update check failed.",
            _ => $"FiveT {Paths.AppVersion}. Not checked yet.",
        };
        CheckUpdateButton.IsEnabled = !busy && u.Phase != UpdatePhase.Ready;
        InstallUpdateButton.Visibility = u.Phase is UpdatePhase.Available or UpdatePhase.Ready && Updater.CanInstall ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e) => await Updater.Shared.CheckAsync();

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e) => await Updater.Shared.InstallAsync();

    private void OnStoreChanged()
    {
        ShowSetupState();                              // a first connection added: "Add Your VPN…" is done
        // A save that failed is said here, once per failure; it clears itself when a later save works.
        if (_store.SaveProblem is { } problem && Message.Message != problem) ShowMessage(problem, InfoBarSeverity.Error);
    }

    public void Reload()
    {
        _loading = true;
        ReconnectSwitch.IsOn = _store.AutoReconnect;
        NotifySwitch.IsOn = _store.NotifyOnChange;
        WatchdogSwitch.IsOn = _store.Watchdog;
        UpdateSwitch.IsOn = _store.AutoUpdateCheck;
        KillSwitchSwitch.IsOn = _store.KillSwitch;
        AppsOnlySwitch.IsOn = _store.AppsOnly;
        FailoverSwitch.IsOn = _store.AutoFailover;
        BypassIranSwitch.IsOn = _store.BypassIran;
        VerboseSwitch.IsOn = _store.VerboseLogging;
        PacketsSwitch.IsOn = _store.VerbosePackets;
        PacketsCard.IsEnabled = VerboseSwitch.IsOn;
        _loading = false;
        ShowApps();
    }

    // MARK: Apps only (the Mac's "Use the VPN for Chosen Apps Only")

    private void ShowApps()
    {
        AppsPanel.Visibility = _store.AppsOnly ? Visibility.Visible : Visibility.Collapsed;
        AppsList.Children.Clear();
        foreach (var path in _store.VpnAppPaths)
        {
            var p = path;
            var remove = new Button { Content = "Remove" };
            AutomationProperties.SetAutomationId(remove, "RemoveApp");
            remove.Click += (_, _) => { _store.SetVpnAppPaths(_store.VpnAppPaths.Where(x => !string.Equals(x, p, StringComparison.OrdinalIgnoreCase))); ShowApps(); };
            AppsList.Children.Add(new CommunityToolkit.WinUI.Controls.SettingsCard { Header = VpnApps.Name(p), Description = p, Content = remove, Margin = new Thickness(32, 0, 0, 0) });
        }
    }

    private void AppsOnlySwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _store.AppsOnly = AppsOnlySwitch.IsOn;   // a V2Ray or Outline tunnel that is up starts again in the other mode
        ShowApps();
    }

    private void FailoverSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.AutoFailover = FailoverSwitch.IsOn; }

    private void AddApp_Click(object sender, RoutedEventArgs e)
    {
        var file = NativeUi.OpenFile(WindowHandle, "Choose an app to use the VPN", "Programs|*.exe|All files|*.*");
        if (file == null) return;
        if (!VpnApps.IsAppPath(file)) { ShowMessage("Choose the program's .exe file, on a drive or a network share.", InfoBarSeverity.Warning); return; }
        _store.SetVpnAppPaths(_store.VpnAppPaths.Append(file));
        ShowMessage("");
        ShowApps();
    }

    // MARK: Setup

    private bool _recheck;

    private void RefreshChecks()
    {
        // A refresh asked for while one is running (the login task just changed, say) runs again after
        // it: the running one may have read the state before the change.
        if (_checking) { _recheck = true; return; }
        _checking = true;
        Task.Run(() =>
        {
            var checks = Setup.Checks();
            Ui.Post(() =>
            {
                _checking = false;
                // Something changed while this ran: its answer may be stale, so show only the next one.
                if (_recheck) { _recheck = false; RefreshChecks(); return; }
                _checks = checks;
                ShowChecks();
                ShowSetupState();
                _loading = true;
                LoginSwitch.IsOn = checks.FirstOrDefault(c => c.Id == "task")?.Ok == true;
                _loading = false;
            });
        });
    }

    /// <summary>What a connection needs; the login task only saves UAC prompts, so it is not one of them.</summary>
    private IEnumerable<SetupCheck> Required => _checks.Where(c => c.Id != "task");

    private void ShowSetupState()
    {
        if (_checks.Count == 0) return;
        var missing = Required.Where(c => !c.Ok).ToList();
        if (missing.Count > 0)
        {
            _next = NextStep.SetUp;
            SetupBar.Severity = InfoBarSeverity.Warning;
            SetupBar.Title = "Set up FiveT";
            SetupBar.Message = string.Join(" ", missing.Select(c => c.Title + "."));
            SetupAction.Content = "Set Up FiveT";
            SetupAction.Visibility = Visibility.Visible;
            ChecksExpander.IsExpanded = true;
        }
        else if (_store.Connections.Count == 0)
        {
            _next = NextStep.AddVpn;
            SetupBar.Severity = InfoBarSeverity.Success;
            SetupBar.Title = "FiveT is ready";
            SetupBar.Message = "Next, add your VPN.";
            SetupAction.Content = "Add Your VPN…";
            SetupAction.Visibility = Visibility.Visible;
        }
        else
        {
            _next = NextStep.None;
            SetupBar.Severity = InfoBarSeverity.Success;
            SetupBar.Title = "FiveT is ready";
            SetupBar.Message = "";
            SetupAction.Visibility = Visibility.Collapsed;
        }
        OpenconnectCard.Description = _checks.FirstOrDefault(c => c.Id == "ofv") is { Ok: true } ofv ? ofv.Detail
            : _checks.FirstOrDefault(c => c.Id == "ofv")?.Title.Contains("unsafe") == true ? "Found, but in a folder ordinary programs can change: not used"
            : "Not found";
    }

    private void ShowChecks()
    {
        Checks.Children.Clear();
        foreach (var c in _checks)
        {
            var row = new InfoBar
            {
                IsOpen = true, IsClosable = false,
                Severity = c.Ok ? InfoBarSeverity.Success : c.Id == "task" ? InfoBarSeverity.Informational : InfoBarSeverity.Error,
                Title = c.Title, Message = c.Detail,
            };
            AutomationProperties.SetAutomationId(row, "Check_" + c.Id);
            Checks.Children.Add(row);
        }
    }

    private void ShowMessage(string text, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        Message.Message = text;
        Message.Severity = severity;
        Message.IsOpen = text.Length > 0;
    }

    private void SetupAction_Click(object sender, RoutedEventArgs e)
    {
        switch (_next)
        {
            case NextStep.AddVpn:
                SettingsWindow.Instance?.AddConnection();
                break;
            case NextStep.SetUp:
                SetUp();
                break;
        }
    }

    /// <summary>
    /// "Set Up FiveT": fixes whatever it can in one go. The Mac installs its helper here; on Windows the
    /// counterparts are running as administrator, OpenConnect (bundled with the setup file, otherwise
    /// chosen by hand) and the login task that saves the UAC prompt from then on.
    /// </summary>
    private void SetUp()
    {
        var missing = Required.Where(c => !c.Ok).Select(c => c.Id).ToHashSet();
        if (missing.Contains("admin"))
        {
            try
            {
                Process.Start(new ProcessStartInfo(Paths.GuiExePath, "--setup") { UseShellExecute = true, Verb = "runas" });
                // Quit properly: Application.Exit alone skips the cleanup and leaves a ghost tray icon.
                if (TrayApp.Current is { } tray) tray.Quit(); else Application.Current.Exit();
            }
            catch (Exception ex) { ShowMessage("Could not restart as administrator: " + ex.Message, InfoBarSeverity.Error); }
            return;
        }
        if (missing.Contains("ofv"))
        {
            // Found in a folder ordinary programs can change: another copy elsewhere would be refused the same way.
            if (Setup.OpenconnectRefusal is { } refusal)
            {
                ShowMessage(refusal + " Install FiveT with its setup file: it brings its own OpenConnect.", InfoBarSeverity.Warning);
                return;
            }
            ShowMessage("FiveT could not find OpenConnect. The FiveT setup file brings its own; with this copy, choose an openconnect.exe or download one.", InfoBarSeverity.Warning);
            ChooseOpenconnect();
            return;
        }
        if (missing.Count > 0)
        {
            ShowMessage("OpenConnect is incomplete: " + string.Join(" ", _checks.Where(c => missing.Contains(c.Id)).Select(c => c.Detail)), InfoBarSeverity.Error);
            return;
        }
        InstallLoginTask();
    }

    private void InstallLoginTask()
    {
        ShowLoginMessage("Creating the scheduled task…", InfoBarSeverity.Informational);
        Task.Run(() =>
        {
            var err = Setup.InstallLoginTask();
            Ui.Post(() => { ShowLoginMessage(err ?? "", InfoBarSeverity.Error); RefreshChecks(); });
        });
    }

    private void ChooseOpenconnect()
    {
        var hwnd = XamlRoot?.ContentIslandEnvironment is { } env ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(env.AppWindowId) : IntPtr.Zero;
        var file = NativeUi.OpenFile(hwnd, "Choose openconnect.exe", "openconnect.exe|openconnect.exe|Programs|*.exe");
        if (file == null) return;
        _store.OpenconnectPath = file;
        Log.Shared.Write($"openconnect path set to {file}");
        ShowMessage("");
        RefreshChecks();
    }

    private void ChooseOpenconnect_Click(object sender, RoutedEventArgs e) => ChooseOpenconnect();
    private void OpenDownloadPage_Click(object sender, RoutedEventArgs e) => Setup.OpenDownloadPage();
    private void Refresh_Click(object sender, RoutedEventArgs e) => RefreshChecks();

    // MARK: Behavior

    private void LoginSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        if (LoginSwitch.IsOn) { InstallLoginTask(); return; }
        ShowLoginMessage("Removing the scheduled task…", InfoBarSeverity.Informational);
        Task.Run(() =>
        {
            var err = Setup.RemoveLoginTask();
            Ui.Post(() => { ShowLoginMessage(err ?? "", InfoBarSeverity.Error); RefreshChecks(); });
        });
    }

    private void ShowLoginMessage(string text, InfoBarSeverity severity)
    {
        LoginMessage.Message = text;
        LoginMessage.Severity = severity;
        LoginMessage.IsOpen = text.Length > 0;
    }

    private void ReconnectSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.AutoReconnect = ReconnectSwitch.IsOn; }
    private void NotifySwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.NotifyOnChange = NotifySwitch.IsOn; }
    private void KillSwitchSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.KillSwitch = KillSwitchSwitch.IsOn; }
    // Takes effect at the next connect: the routes are part of the config Xray starts with.
    private void BypassIranSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.BypassIran = BypassIranSwitch.IsOn; }
    private void WatchdogSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.Watchdog = WatchdogSwitch.IsOn; }
    private void UpdateSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.AutoUpdateCheck = UpdateSwitch.IsOn; }
    private void PacketsSwitch_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _store.VerbosePackets = PacketsSwitch.IsOn; }

    private void VerboseSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (!_loading) _store.VerboseLogging = VerboseSwitch.IsOn;
        PacketsCard.IsEnabled = VerboseSwitch.IsOn;
    }

    // MARK: Backup (the Mac's Export Settings… and Import Settings…)

    private IntPtr WindowHandle => XamlRoot?.ContentIslandEnvironment is { } env ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(env.AppWindowId) : IntPtr.Zero;

    private void ExportSettings_Click(object sender, RoutedEventArgs e)
    {
        var file = NativeUi.SaveFile(WindowHandle, "Export FiveT settings", "FiveT settings|*.fivet|All files|*.*", Backup.DefaultFileName(DateTime.Now), "fivet");
        if (file == null) return;
        try
        {
            SafeFile.Replace(file, Backup.Seal(_store.ExportText()));
            var message = $"Saved {Path.GetFileName(file)}. It is encrypted: only FiveT can open it. Keep it private anyway.";
            if (!KeepPrivate(file)) message += " Windows could not limit who can open it on that drive.";
            if (_store.UnreadableSecretCount > 0) message += $" {_store.UnreadableSecretCount} saved secret(s) could not be read on this PC and are not in the file.";
            ShowMessage(message, InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowMessage("Could not save the file: " + ex.Message, InfoBarSeverity.Error); }
    }

    private void ImportSettings_Click(object sender, RoutedEventArgs e)
    {
        var file = NativeUi.OpenFile(WindowHandle, "Choose a .fivet file exported from FiveT", "FiveT settings|*.fivet;*.json|All files|*.*");
        if (file == null) return;
        try
        {
            if (new FileInfo(file).Length > 20 * 1024 * 1024) throw new InvalidDataException("This is not a FiveT settings file (it is far too large).");
            var result = _store.Restore(Backup.Open(File.ReadAllBytes(file)));
            Reload();
            ShowMessage(result, InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowMessage(ex.Message, InfoBarSeverity.Error); }
    }

    /// <summary>Only this Windows account may open the file (the Mac's mode 0600). False when the drive cannot hold permissions.</summary>
    private static bool KeepPrivate(string path)
    {
        try
        {
            var acl = new System.Security.AccessControl.FileSecurity();
            acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
                System.Security.Principal.WindowsIdentity.GetCurrent().User!,
                System.Security.AccessControl.FileSystemRights.FullControl, System.Security.AccessControl.AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(acl);
            return true;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or NotSupportedException or IOException or InvalidOperationException or PlatformNotSupportedException)
        {
            return false;
        }
    }

    // MARK: Troubleshooting

    private void OpenLog_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(Log.Shared.FilePath) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Shared.Write($"could not open {Log.Shared.FilePath}: {ex.Message}", LogLevel.Error); }
    }

    private async void CopyDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        // Collecting runs openconnect --version and schtasks: not on the UI thread, which would freeze Settings.
        ShowMessage("Collecting diagnostics…");
        string text;
        try { text = await Task.Run(Diagnostics.Text); }
        catch (Exception ex)
        {
            ShowMessage("Could not collect the diagnostics: " + ex.Message, InfoBarSeverity.Error);
            return;
        }
        try { Ui.SetClipboardText(text); }
        catch (Exception ex)
        {
            ShowMessage("Could not put the diagnostics on the clipboard (another program is using it): " + ex.Message, InfoBarSeverity.Error);
            return;
        }
        ShowMessage("Diagnostics copied to the clipboard. Paste them to whoever helps you.", InfoBarSeverity.Success);
    }
}
