using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FiveT.Pages;

/// <summary>One entry of the connection list (name + state dot).</summary>
public sealed class ConnectionRow : INotifyPropertyChanged
{
    public Guid Id { get; }
    private string _name = "";
    private Brush _dot;

    public ConnectionRow(Guid id, string name, Brush dot)
    {
        Id = id;
        _name = name;
        _dot = dot;
    }

    public string Name { get => _name; set { if (_name != value) { _name = value; Notify(nameof(Name)); } } }
    public Brush Dot { get => _dot; set { if (!ReferenceEquals(_dot, value)) { _dot = value; Notify(nameof(Dot)); } } }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Notify(string p) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p));
}

/// <summary>
/// The Forti tab and the VPN tab (OpenVPN, V2Ray, Outline): one page over the two halves of the list
/// (<see cref="ShowTab"/>). Not two classes: a class derived from a XAML page has no type data in WinUI
/// and crashed the app when it was navigated to.
/// </summary>
public sealed partial class ConnectionsPage : Page, IDetachable
{
    private bool Vpn { get; set; }
    private MenuFlyout? _vpnMenu;

    /// <summary>Switches the page between the Forti list and the VPN list.</summary>
    public void ShowTab(bool vpn)
    {
        if (vpn == Vpn && TitleText.Text.Length > 0) return;
        Vpn = vpn;
        TitleText.Text = vpn ? "VPN" : "Forti";
        FortiImportButton.Visibility = vpn ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(AddButton, vpn ? "Add OpenVPN profiles, V2Ray links or Outline keys" : "Add a connection");
        Empty.Text = vpn ? "Press + to add an OpenVPN profile (.ovpn), V2Ray links, or Outline keys." : "Select a connection, or press + to add one.";
        AddButton.Flyout = vpn ? _vpnMenu ??= BuildVpnMenu() : null;
        ShowImport("");
        _selection = Mine.FirstOrDefault()?.Id;
        Sync();
    }

    /// <summary>The connections this tab lists.</summary>
    private List<Connection> Mine => _store.Connections.Where(c => c.IsOtherVpn == Vpn).ToList();

    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private readonly VpnManager _vpn = VpnManager.Shared;
    private Guid? _selection;
    private bool _syncing;

    public ObservableCollection<ConnectionRow> Rows { get; } = new();

    public ConnectionsPage()
    {
        InitializeComponent();
        _selection = Mine.FirstOrDefault()?.Id;
    }

    private MenuFlyout BuildVpnMenu()
    {
        // Windows does not let a non-elevated Explorer drag onto an elevated window, and FiveT runs elevated:
        // files come in through + → From a File, text through + → Paste.
        var menu = new MenuFlyout();
        void Item(string text, string id, RoutedEventHandler click)
        {
            var item = new MenuFlyoutItem { Text = text };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, id);
            item.Click += click;
            menu.Items.Add(item);
        }
        Item("From a File…", "VpnFromFile", async (_, _) =>
        {
            var hwnd = XamlRoot?.ContentIslandEnvironment is { } env ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(env.AppWindowId) : IntPtr.Zero;
            var file = NativeUi.OpenFile(hwnd, "Choose an OpenVPN profile, an Xray config or a file of links", "VPN configs|*.ovpn;*.conf;*.json;*.txt|All files|*.*");
            if (file != null) await ImportAsync(() => VpnImport.AddFilesAsync(_store, new[] { file }));
        });
        Item("Paste Links, Keys, Profile or Subscription", "VpnPaste", async (_, _) =>
        {
            string text;
            try
            {
                var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
                text = content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text) ? await content.GetTextAsync() : "";
            }
            catch (Exception ex) { ShowImport($"Could not read the clipboard: {ex.Message}", InfoBarSeverity.Warning); return; }
            if (text.Trim().Length == 0) { ShowImport("The clipboard holds no text. Copy a link (vless://, vmess://, trojan://, ss://, hysteria2://), an Outline key, a subscription address or an OpenVPN profile first.", InfoBarSeverity.Warning); return; }
            await ImportAsync(() => VpnImport.AddPastedAsync(_store, text));
        });
        Item("From OpenVPN Connect on This PC", "VpnFromOpenVpnConnect", async (_, _) => await ImportAsync(() => Task.FromResult(VpnImport.AddOpenVpnConnect(_store))));
        Item("From Outline on This PC", "VpnFromOutline", async (_, _) => await ImportAsync(() => VpnImport.AddOutlineAsync(_store)));
        return menu;
    }

    private void ShowImport(string text, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        ImportMessage.Message = text;
        ImportMessage.Severity = severity;
        ImportMessage.IsOpen = text.Length > 0;
    }

    /// <summary>Runs one import, says what it did (always: a silent import looks like nothing was clicked) and selects what it added.</summary>
    private async Task ImportAsync(Func<Task<VpnImport.Outcome>> import)
    {
        try
        {
            ShowImport("Importing…");
            var o = await import();
            ShowImport(o.Message, o.Added.Count > 0 ? InfoBarSeverity.Success : InfoBarSeverity.Warning);
            if (o.Added.Count > 0) _selection = o.Added[0].Id;
            Sync();
        }
        catch (Exception e)
        {
            Log.Shared.Write($"import failed: {e.Message}", LogLevel.Error);
            ShowImport($"The import failed: {e.Message}", InfoBarSeverity.Error);
        }
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        _store.Changed -= OnStoreChanged;   // never subscribe twice
        _vpn.StatusChanged -= OnStatus;
        _store.Changed += OnStoreChanged;
        _vpn.StatusChanged += OnStatus;
        Sync();
        Editor.Resume();   // whichever of the page and the editor raises Loaded first, the clock runs after both
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e) => Detach();

    /// <summary>Also called when the Settings window closes: a closing window does not reliably raise Unloaded.</summary>
    public void Detach()
    {
        _store.Changed -= OnStoreChanged;
        _vpn.StatusChanged -= OnStatus;
        Editor.Suspend();
    }

    private void OnStoreChanged() { Sync(); Editor.RefreshStatus(); }

    private void OnStatus(VpnStatus _)
    {
        foreach (var r in Rows) r.Dot = DotBrush(r.Id);
        Editor.RefreshStatus();
    }

    private Brush DotBrush(Guid id)
    {
        // Each connection has its own tunnel now, so the dot comes from that connection.
        var st = _vpn.StatusFor(id);
        var key = st.Phase switch
        {
            VpnPhase.Connected => "StateConnectedBrush",
            VpnPhase.Connecting or VpnPhase.Disconnecting => "StateBusyBrush",
            _ => "StateIdleBrush",
        };
        return (Brush)Application.Current.Resources[key];
    }

    private static string DisplayName(Connection c) => c.Name.Length == 0 ? "Untitled" : c.Name;

    /// <summary>Brings the list in line with the store, keeping the selection.</summary>
    private void Sync()
    {
        var conns = Mine;
        _syncing = true;
        if (!Rows.Select(r => r.Id).SequenceEqual(conns.Select(c => c.Id)))
        {
            Rows.Clear();
            foreach (var c in conns) Rows.Add(new ConnectionRow(c.Id, DisplayName(c), DotBrush(c.Id)));
        }
        else
        {
            foreach (var (row, c) in Rows.Zip(conns)) { row.Name = DisplayName(c); row.Dot = DotBrush(c.Id); }
        }
        if (_selection is not { } sel || conns.All(c => c.Id != sel)) _selection = conns.FirstOrDefault()?.Id;
        List.SelectedItem = Rows.FirstOrDefault(r => r.Id == _selection);
        _syncing = false;
        ShowSelected();
    }

    private void ShowSelected()
    {
        RemoveButton.IsEnabled = _selection is { } sel && _store.Get(sel) != null;
        if (_selection is { } id && _store.Get(id) != null)
        {
            if (Editor.Id != id) Editor.Load(id);
            EditorScroller.Visibility = Visibility.Visible;
            Empty.Visibility = Visibility.Collapsed;
        }
        else
        {
            Editor.Unload();
            EditorScroller.Visibility = Visibility.Collapsed;
            Empty.Visibility = Visibility.Visible;
        }
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing) return;
        if (List.SelectedItem is ConnectionRow r && r.Id != _selection)
        {
            _selection = r.Id;
            ShowSelected();
        }
    }

    private void Add_Click(object sender, RoutedEventArgs e) { if (!Vpn) AddNew(); }   // the VPN tab's + opens its menu instead

    /// <summary>Adds a connection and selects it (the + button, and General's "Add Your VPN…").</summary>
    public void AddNew()
    {
        var c = _store.Add();   // Changed → Sync()
        _selection = c.Id;
        Sync();
    }

    /// <summary>
    /// Copies FortiClient's SSL-VPN profiles (names, gateways, realms, user names, never passwords),
    /// from this PC's FortiClient or from a backup file, as the Mac app does. IPsec profiles are shown
    /// but cannot be ticked; ones FiveT already has (same host, port, realm and user) are not ticked.
    /// </summary>
    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        var profiles = await Task.Run(FortiClientImport.ReadRegistry);
        var source = "this PC's FortiClient";
        while (true)
        {
            var panel = new StackPanel { Spacing = 4 };
            panel.Children.Add(new TextBlock
            {
                Text = profiles.Count == 0
                    ? $"FiveT found no FortiClient connections in {source}. A FortiClient backup (Settings → Backup in FortiClient, saved without a password) works too."
                    : $"From {source}. Choose the connections to copy. FortiClient's passwords stay behind: add each one's password afterwards.",
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
            });
            var boxes = new List<(CheckBox Box, FortiClientProfile Profile)>();
            foreach (var p in profiles)
            {
                var c = FortiClientImport.ToConnection(p);
                var same = FortiClientImport.AlreadySaved(p, _store.Connections);
                var note = !p.IsSsl ? " · IPsec: FiveT speaks SSL-VPN only"
                    : c.Host.Length == 0 ? " · no gateway address"
                    : same != null ? $" · already in FiveT as {same.Name}" : "";
                var box = new CheckBox
                {
                    IsChecked = p.IsSsl && c.Host.Length > 0 && same == null,
                    IsEnabled = p.IsSsl && c.Host.Length > 0,
                    Content = new StackPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = p.Name },
                            new TextBlock
                            {
                                Text = (c.Host.Length > 0 ? c.GatewayDescription : p.Server) + (p.Username.Length > 0 ? $" · {p.Username}" : "") + note,
                                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                            },
                        },
                    },
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, p.Name);
                boxes.Add((box, p));
                panel.Children.Add(box);
            }
            var dialog = new ContentDialog
            {
                Title = "Import from FortiClient",
                Content = new ScrollViewer { Content = panel, MaxHeight = 360 },
                PrimaryButtonText = profiles.Any(p => p.IsSsl) ? "Import" : "",
                SecondaryButtonText = "Choose Backup File…",
                CloseButtonText = "Cancel",
                DefaultButton = profiles.Any(p => p.IsSsl) ? ContentDialogButton.Primary : ContentDialogButton.Secondary,
                XamlRoot = XamlRoot,
            };
            var answer = await dialog.ShowAsync();
            if (answer == ContentDialogResult.Secondary)
            {
                var hwnd = XamlRoot?.ContentIslandEnvironment is { } env ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(env.AppWindowId) : IntPtr.Zero;
                var file = NativeUi.OpenFile(hwnd, "Choose a FortiClient backup", "FortiClient backup|*.conf;*.xml|All files|*.*");
                if (file == null) continue;
                try
                {
                    profiles = FortiClientImport.ReadBackup(file);
                    source = Path.GetFileName(file);
                }
                catch (InvalidDataException ex)
                {
                    await new ContentDialog { Title = "Import from FortiClient", Content = ex.Message, CloseButtonText = "OK", XamlRoot = XamlRoot }.ShowAsync();
                }
                continue;
            }
            if (answer != ContentDialogResult.Primary) return;
            var added = FortiClientImport.Merge(boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Profile), _store.Connections);
            if (added.Count == 0)
            {
                // Always say what happened, as the Mac does: a silent close looks like nothing was clicked.
                await new ContentDialog
                {
                    Title = "Import from FortiClient",
                    Content = "Nothing was added: none of the connections were chosen, or they are already in FiveT.",
                    CloseButtonText = "OK",
                    XamlRoot = XamlRoot,
                }.ShowAsync();
                return;
            }
            _store.AddRange(added);
            Log.Shared.Write($"imported from FortiClient: {string.Join(", ", added.Select(c => $"{c.Name} → {c.GatewayDescription}"))}");
            _selection = added[0].Id;
            Sync();
            return;
        }
    }

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (_selection is not { } id || _store.Get(id) is not { } c) return;
        var dialog = new ContentDialog
        {
            Title = $"Remove \"{c.Name}\"?",
            Content = (c.IsV2Ray ? "Its server settings are deleted with it." : c.IsOpenVpn ? "Its profile, keys and password are deleted with it." : "Its password and one-time-code secret are deleted with it.") + (_vpn.IsActive(id) ? " It is connected now and will be disconnected." : ""),
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,   // Enter must not delete a connection and its password
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (_vpn.IsActive(id)) _vpn.Disconnect(id);
        _store.Remove(id);
        _selection = Mine.FirstOrDefault()?.Id;
        Sync();
    }
}
