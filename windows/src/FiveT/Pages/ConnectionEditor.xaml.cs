using System.Text.RegularExpressions;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace FiveT.Pages;

/// <summary>The form for one connection. Every change is saved immediately (like the macOS app).</summary>
public sealed partial class ConnectionEditor : UserControl
{
    public Guid? Id { get; private set; }
    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private readonly VpnManager _vpn = VpnManager.Shared;
    private readonly DispatcherQueueTimer _codeTimer;
    private bool _loading = true;

    public ConnectionEditor()
    {
        InitializeComponent();
        foreach (var m in Enum.GetValues<OtpMode>()) OtpBox.Items.Add(m.Label());
        // Windows does not let a non-elevated Explorer, browser or Snipping Tool drag onto an elevated
        // window, and FiveT runs elevated: do not promise a drop that cannot arrive.
        if (FiveT.Core.Paths.IsElevated)
            QrCard.Description = "Screenshot the setup QR code with Win+Shift+S, then Paste Screenshot, or choose an image file.";
        _codeTimer = Ui.Queue.CreateTimer();
        _codeTimer.Interval = TimeSpan.FromSeconds(1);
        _codeTimer.IsRepeating = true;
        _codeTimer.Tick += (_, _) => TickCode();
    }

    private void UserControl_Unloaded(object sender, RoutedEventArgs e) => _codeTimer.Stop();

    // The Connections page is cached, so this control unloads and loads again when you visit another
    // tab and come back. Load() is skipped then (same connection), so the clock it started has to
    // come back here, or "Current code" stays frozen until another connection is picked.
    private void UserControl_Loaded(object sender, RoutedEventArgs e) => Resume();

    /// <summary>Starts the "Current code" clock again for the connection that is showing (no-op without one).</summary>
    public void Resume()
    {
        if (Id == null) return;
        TickCode();
        _codeTimer.Start();
    }

    /// <summary>Stops the clock without forgetting the connection (the page is letting go of the singletons).</summary>
    public void Suspend() => _codeTimer.Stop();

    public void Load(Guid id)
    {
        Id = id;
        var c = _store.Get(id);
        if (c == null) return;
        _loading = true;
        NameBox.Text = c.Name; HostBox.Text = c.Host; PortBox.Value = Math.Clamp(c.Port, 1, 65535); RealmBox.Text = c.Realm;
        UserBox.Text = c.Username; PasswordField.Password = c.Password; SecretField.Password = c.TotpSecret;
        OtpBox.SelectedIndex = (int)c.OtpMode; DnsBox.Text = c.DnsDomains; ExtraBox.Text = c.ExtraConfig;
        _lastGoodSecret = c.TotpSecret;
        _loading = false;
        ShowKind(c);
        SetRevealed(false);   // every connection starts masked again
        _shownPending = false;
        ShowEditorMessage("");
        UpdateOtpVisibility();
        RefreshStatus();
        _codeTimer.Start();
    }

    public void Unload()
    {
        Id = null;
        SetRevealed(false);
        _codeTimer.Stop();
    }

    private bool _shownPending;

    // MARK: Masked password and secret

    private bool _revealed;

    private void SetRevealed(bool on)
    {
        _revealed = on;
        var mode = on ? PasswordRevealMode.Visible : PasswordRevealMode.Hidden;
        PasswordField.PasswordRevealMode = mode;
        SecretField.PasswordRevealMode = mode;
        UpdateShowButtons();
    }

    /// <summary>Show… only when there is a saved password or secret to show (Mac 1.7.1).</summary>
    private void UpdateShowButtons()
    {
        var label = _revealed ? "Hide" : "Show…";
        ShowPasswordButton.Content = label;
        ShowSecretButton.Content = label;
        ShowPasswordButton.Visibility = PasswordField.Password.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSecretButton.Visibility = SecretField.Password.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private IntPtr WindowHandle =>
        XamlRoot?.ContentIslandEnvironment is { } env ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(env.AppWindowId) : IntPtr.Zero;

    private bool _verifying;

    private async void Show_Click(object sender, RoutedEventArgs e)
    {
        if (_revealed) { SetRevealed(false); return; }
        if (_verifying || Id is not { } id || _store.Get(id) is not { } c) return;
        _verifying = true;
        try
        {
            var (result, message) = await SecretGate.VerifyAsync(WindowHandle, $"FiveT wants to show the password and one-time-code secret of {c.Name}.");
            if (Id != id) return;   // another connection was selected meanwhile
            if (result == SecretGate.Outcome.Verified)
            {
                SetRevealed(true);
                Log.Shared.Write($"[{c.Name}] password and secret shown in Settings");
            }
            else if (message != null) ShowEditorMessage(message, InfoBarSeverity.Error);
        }
        finally { _verifying = false; }
    }

    private void ShowEditorMessage(string text, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        EditorMessage.Message = text;
        EditorMessage.Severity = severity;
        EditorMessage.IsOpen = text.Length > 0;
    }

    // MARK: QR code

    private async void PasteQr_Click(object sender, RoutedEventArgs e)
    {
        if (Id is not { } id) return;   // the connection selected now, not whichever is selected when a picker returns
        await AdoptAsync(await QrImport.FromClipboardAsync(), id);
    }

    private async void ChooseQr_Click(object sender, RoutedEventArgs e)
    {
        if (Id is not { } id) return;
        var file = NativeUi.OpenFile(WindowHandle, "Choose a picture of the QR code", "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files|*.*");
        if (file != null) await AdoptAsync(await QrImport.FromFileAsync(file), id);
    }

    private void Qr_DragOver(object sender, DragEventArgs e)
    {
        var view = e.DataView;
        if (!view.Contains(StandardDataFormats.StorageItems) && !view.Contains(StandardDataFormats.Bitmap)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Read the QR code";
    }

    private async void Qr_Drop(object sender, DragEventArgs e)
    {
        if (Id is not { } id) return;
        var deferral = e.GetDeferral();
        QrImportResult result;
        try { result = await QrImport.FromDroppedAsync(e.DataView); }
        finally { deferral.Complete(); }   // before any dialog: the app the picture came from must not wait for it
        await AdoptAsync(result, id);
    }

    /// <summary>Saves what an import found into connection <paramref name="id"/>. Several accounts in one code: the user picks one.</summary>
    private async Task AdoptAsync(QrImportResult r, Guid id)
    {
        if (r.Error != null) { ShowEditorMessage(r.Error, InfoBarSeverity.Warning); return; }
        var chosen = r.Accounts.Count == 1 ? r.Accounts[0] : await ChooseAccountAsync(r.Accounts, id);
        if (chosen != null) SaveAccount(chosen, id, r.ClipboardSequence);
    }

    private async Task<QrAccount?> ChooseAccountAsync(IReadOnlyList<QrAccount> accounts, Guid id)
    {
        var target = _store.Get(id);
        var box = new ComboBox { Width = 340, ItemsSource = accounts.Select(a => a.Label).ToList(), SelectedIndex = 0 };
        // Preselect the account that looks like this connection (its name or user name inside the label).
        var hints = new[] { target?.Name, target?.Username }.Select(h => (h ?? "").Trim().ToLowerInvariant()).Where(h => h.Length >= 3).ToList();
        for (var i = 0; i < accounts.Count; i++)
            if (hints.Any(h => accounts[i].Label.ToLowerInvariant().Contains(h))) { box.SelectedIndex = i; break; }
        var text = $"This QR code holds {accounts.Count} accounts. Choose the one whose code you use to log in to this VPN."
                   + (accounts[0].ExportPart is { } part ? $" It is {part} of a Google Authenticator export: if the VPN's account is not listed, cancel and import the next one." : "");
        var dialog = new ContentDialog
        {
            Title = $"Which account is {target?.Name}'s?",
            Content = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 360 }, box } },
            PrimaryButtonText = "Use This Account",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary && box.SelectedIndex >= 0 ? accounts[box.SelectedIndex] : null;
    }

    private void SaveAccount(QrAccount a, Guid id, uint clipboardSequence)
    {
        if (_store.Get(id) == null) return;   // removed while a picture or a dialog was open
        var modeSet = false;
        _store.Mutate(id, c =>
        {
            c.TotpSecret = a.Secret;
            // A secret means a one-time code: with none chosen yet, append it to the password. A gateway
            // that wants it as a second step gets it that way on the automatic retry.
            if (c.OtpMode == OtpMode.None) { c.OtpMode = OtpMode.AppendToPassword; modeSet = true; }
        });
        var cleared = QrImport.ClearClipboardIfUnchanged(clipboardSequence);
        Log.Shared.Write($"[{_store.Get(id)?.Name ?? "?"}] one-time-code secret imported from a QR code or otpauth link ({a.Label})");
        if (Id != id) return;   // another connection is showing now: its form stays as it is
        Load(id);
        ShowEditorMessage($"Imported the secret for {a.Label}. Check that the code below matches the one in your authenticator app."
                          + (modeSet ? " One-time code is now set to append the code to the password." : "")
                          + (cleared ? " The clipboard was emptied, since it held the secret." : ""), InfoBarSeverity.Success);
    }

    // MARK: A link pasted into the secret box

    private static readonly Regex LinkAnywhere = new(@"otpauth(-migration)?:", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex LinkAtStart = new(@"^otpauth(-migration)?:", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private string _lastGoodSecret = "";
    private bool _restoring;

    /// <summary>
    /// Pasting an otpauth:// link (what a QR code holds) into the box takes the secret out of it; a link
    /// FiveT cannot use puts the previous secret back. The link itself, which for a Google export holds
    /// every account's secret, is never saved. Same rules as the Mac's secret field.
    /// </summary>
    private void ImportPastedLink(string text)
    {
        var t = text.Trim();
        // Only a link that is the whole field is read. Pasted next to the old secret the two run
        // together ("…secret=NEWOLD") and no one could tell where the new secret ends: then the old
        // one is put back and nothing is guessed.
        // Pasting the same link again over a selection ends in the current secret too, but then it
        // reads as exactly that one secret, so it is no run-together.
        var whole = LinkAtStart.IsMatch(t) && (_lastGoodSecret.Length == 0 || !t.EndsWith(_lastGoodSecret, StringComparison.Ordinal)
                                               || IsOnlyCurrentSecret(t));
        _restoring = true;
        try { SecretField.Password = _lastGoodSecret; }
        finally { _restoring = false; }
        UpdateShowButtons();
        UpdateOtpVisibility();
        if (Id is not { } id) return;
        if (!whole)
        {
            ShowEditorMessage("To import a link, paste it into an empty secret field (select what is in it first), or use Paste Screenshot.", InfoBarSeverity.Warning);
            return;
        }
        // Only a clipboard that holds this very text is the one to clear afterwards; a link that came in
        // by typing or automation must not wipe something unrelated the person copied.
        IReadOnlyList<QrAccount> accounts;
        try { accounts = QrImport.AccountsIn(t); }
        catch (QrImportException e) { ShowEditorMessage(e.Message, InfoBarSeverity.Warning); return; }
        _ = AdoptPastedAsync(accounts, t, id);
    }

    private async Task AdoptPastedAsync(IReadOnlyList<QrAccount> accounts, string text, Guid id)
    {
        var sequence = QrImport.ClipboardSequence();
        var clipboard = await ClipboardHoldsAsync(text) && QrImport.ClipboardSequence() == sequence ? sequence : 0u;
        await AdoptAsync(new QrImportResult(accounts, null, clipboard), id);
    }

    private bool IsOnlyCurrentSecret(string link)
    {
        try
        {
            var accounts = QrImport.AccountsIn(link);
            return accounts.Count == 1 && accounts[0].Secret == _lastGoodSecret;
        }
        catch (QrImportException) { return false; }
    }

    private static async Task<bool> ClipboardHoldsAsync(string text)
    {
        try
        {
            var content = Clipboard.GetContent();
            return content.Contains(StandardDataFormats.Text) && (await content.GetTextAsync()).Trim() == text;
        }
        catch (Exception) { return false; }
    }

    private void Set(Action<Connection> change)
    {
        if (_loading || Id is not { } id) return;
        _store.Mutate(id, change);
    }

    /// <summary>
    /// Shows the fields the connection's kind has. Forti: everything. OpenVPN: the login (when its profile
    /// asks for one) and DNS domains; the server is the profile's. V2Ray and Outline: the name only; the
    /// server, its ID and its transport are the link's.
    /// </summary>
    private void ShowKind(Connection c)
    {
        static Visibility V(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
        var forti = !c.IsOtherVpn;
        _hasLogin = forti || (c.IsOpenVpn && OpenVpnProfile.NeedsLogin(c.OvpnProfile));
        GatewayHeader.Text = forti ? "Gateway" : V2RayConfig.KindLabel(c);
        HostCard.Visibility = PortCard.Visibility = RealmCard.Visibility = AdvancedExpander.Visibility = V(forti);
        LoginHeader.Visibility = UserCard.Visibility = PasswordCard.Visibility = OtpCard.Visibility = QrCard.Visibility = V(_hasLogin);
        DnsHeader.Visibility = DnsCard.Visibility = V(!c.IsV2Ray);
        VpnCard.Visibility = V(!forti);
        if (forti) return;
        VpnCard.Description = c.IsOpenVpn
            ? $"{c.Host}:{c.Port} · from its OpenVPN profile" + (_hasLogin ? "" : " · logs in with the profile's certificate")
            : $"{V2RayConfig.Summary(c.V2RayOutbound)} · {c.Host}:{c.Port}" + (c.V2RaySubscription.Length > 0 ? " · from a subscription" : "");
        CopyLinkButton.Visibility = V(c.IsV2Ray && c.V2RayLink.Length > 0);
        RefreshSubButton.Visibility = V(c.IsV2Ray && c.V2RaySubscription.Length > 0);
    }

    private bool _hasLogin = true;

    private void CopyLink_Click(object sender, RoutedEventArgs e)
    {
        if (Id is not { } id || _store.Get(id) is not { V2RayLink.Length: > 0 } c) return;
        try
        {
            Ui.SetClipboardText(c.V2RayLink);
            ShowEditorMessage("The link is on the clipboard. It holds this server's ID or password: share it only with people who may use the server.", InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowEditorMessage($"Could not copy the link: {ex.Message}", InfoBarSeverity.Warning); }
    }

    private async void RefreshSub_Click(object sender, RoutedEventArgs e)
    {
        if (Id is not { } id || _store.Get(id) is not { V2RaySubscription.Length: > 0 } c) return;
        RefreshSubButton.IsEnabled = false;
        try
        {
            ShowEditorMessage("Asking the subscription…");
            var o = await VpnImport.RefreshAsync(_store, c.V2RaySubscription, x => _vpn.StatusFor(x).Phase != VpnPhase.Idle);
            ShowEditorMessage(o.Message, InfoBarSeverity.Informational);
        }
        catch (Exception ex) { ShowEditorMessage($"Could not refresh the subscription: {ex.Message}", InfoBarSeverity.Warning); }
        finally { RefreshSubButton.IsEnabled = true; }
    }

    private void UpdateOtpVisibility()
    {
        if (!_hasLogin)
        {
            SecretCard.Visibility = CodeCard.Visibility = Visibility.Collapsed;
            return;
        }
        var uses = OtpBox.SelectedIndex > 0;
        var hasSecret = SecretField.Password.Length > 0;
        SecretCard.Visibility = uses ? Visibility.Visible : Visibility.Collapsed;
        // No code (and no "not valid Base32" warning) before a secret is entered.
        CodeCard.Visibility = uses && hasSecret ? Visibility.Visible : Visibility.Collapsed;
        // The QR row is always there (see the XAML); only its wording follows the mode.
        QrCard.Header = uses ? "Secret from a QR code" : "One-time code from a QR code";
        OtpCard.Description = uses
            ? "Gateways differ: some want the 6-digit code typed right after the password, others ask for it in a second step. When a login is rejected, FiveT retries once the other way and keeps the one that works."
            : "";
        SecretCard.Description = uses && !hasSecret ? "Type or paste the secret, or import it from the setup QR code or a Google Authenticator export." : "";
        TickCode();
    }

    private void TickCode()
    {
        if (OtpBox.SelectedIndex <= 0) return;
        var secret = SecretField.Password;
        var code = Totp.Code(secret);
        // The code itself is shown even while the secret is masked: it is what you compare with the
        // authenticator app, and it is useless half a minute later.
        CodeCard.Header = secret.Length == 0 ? "Current code"
            : code == null ? "The secret is not valid Base32."
            : $"Current code {code[..3]} {code[3..]}  ({Totp.SecondsRemaining()}s left)";
        CopyCodeButton.IsEnabled = code != null;
    }

    public void RefreshStatus()
    {
        if (Id is not { } id || _store.Get(id) is not { } c) return;
        // This connection's own tunnel: another one being up says nothing about this one.
        var st = _vpn.StatusFor(id);
        var active = st.Phase is VpnPhase.Connected or VpnPhase.Connecting;
        ConnectButton.Content = active ? "Disconnect" : "Connect now";
        ConnectButton.IsEnabled = st.Phase != VpnPhase.Disconnecting;
        var together = string.Join(", ", _vpn.Sessions
            .Where(x => x.Phase == VpnPhase.Connected && x.ConnectionId != id).Select(x => x.ConnectionName ?? "VPN").Distinct());
        StatusText.Text = st.Phase switch
        {
            VpnPhase.Connected => together.Length > 0 ? $"Connected, together with {together}" : "Connected",
            VpnPhase.Connecting => st.Detail ?? "Connecting…",
            VpnPhase.Disconnecting => "Disconnecting…",
            _ => st.LastError ?? "Not connected",
        };
        var last = "";
        if (c.LastConnectedAt is { } d) last = $"Last connected {Log.Format(d)}";
        if (!active && c.LastError is { } e) last += (last.Length > 0 ? "\n" : "") + "Last error: " + e;
        LastText.Text = last;
        LastText.Visibility = last.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var pending = c.HasPendingReview;
        CertCard.Description = pending
            ? (c.PendingCertFirst
                ? "Windows cannot confirm this gateway's certificate belongs to it. FiveT logs in once you have reviewed it."
                : "The gateway showed a different certificate than the one FiveT trusts, and Windows could not confirm it is a renewal. FiveT will not log in to it until you review it.")
            : !c.KnowsGateway ? "Checked before the first login; FiveT asks you if Windows cannot vouch for it"
            : c.TrustedCert.Length > 0 ? "Trusted: " + GatewayCert.GroupedHex(c.TrustedCert[..Math.Min(c.TrustedCert.Length, 24)]) + " …"
                                         + (c.TrustedCertNames.Count > 0 ? $" ({string.Join(", ", c.TrustedCertNames.Take(3))})" : "")
            : c.TrustedCertPin.Length > 0 ? "Trusted: " + c.TrustedCertPin[..Math.Min(c.TrustedCertPin.Length, 28)] + "…"
            : "Verified by a certificate authority for this gateway's name";
        ReviewCardButton.Visibility = pending ? Visibility.Visible : Visibility.Collapsed;
        // Not while a review waits: Forget would make the next connect a first meeting, and the
        // certificate under review would be the one met.
        ForgetButton.Visibility = c.KnowsGateway && !pending ? Visibility.Visible : Visibility.Collapsed;
        ReviewButton.Content = c.PendingCertFirst ? "Review Certificate…" : "Review New Certificate…";
        ReviewButton.Visibility = pending && !active ? Visibility.Visible : Visibility.Collapsed;
        if (pending && !_shownPending) AdvancedExpander.IsExpanded = true;   // once, when a review appears
        _shownPending = pending;
        // Nothing to say about split DNS or the tunnel until this connection has them: the rows are hidden then.
        SplitDnsCard.Visibility = st.SplitDns != null ? Visibility.Visible : Visibility.Collapsed;
        if (st.SplitDns is { } sd)
        {
            SplitDnsText.Text = $"{sd.State}{(sd.Detail.Length == 0 ? "" : " — " + sd.Detail)}";
            SplitDnsText.Foreground = (Brush)Application.Current.Resources[sd.State == "active" ? "SystemFillColorSuccessBrush" : "SystemFillColorCautionBrush"];
        }
        var hasTunnel = st.Network is { } n && n.Interface.Length > 0;
        TunnelCard.Visibility = hasTunnel ? Visibility.Visible : Visibility.Collapsed;
        if (hasTunnel && st.Network is { } net)
            TunnelText.Text = $"{net.Interface} {net.TunnelIP}   DNS {string.Join(", ", net.DnsServers)}   {net.Routes.Count} routes";
    }

    // MARK: Field events

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.Name = NameBox.Text);
    private void HostBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.Host = HostBox.Text);
    private void RealmBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.Realm = RealmBox.Text);
    private void UserBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.Username = UserBox.Text);

    /// <summary>
    /// Pasted text is cleaned as it lands (Mac 1.13.3). A one-line box keeps only what comes before the
    /// first line break, so text copied with a blank line in front used to paste as nothing at all, and a
    /// whole "remote vpn.example.com 443" line from an OpenVPN profile pasted as the gateway. The gateway
    /// box also takes the port out of what was pasted.
    /// </summary>
    private async void Field_Paste(object sender, TextControlPasteEventArgs e)
    {
        if (sender is not TextBox box) return;
        e.Handled = true;
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) return;
            var text = await content.GetTextAsync();
            if (ReferenceEquals(box, HostBox))
            {
                var (host, port) = FieldCleaner.Gateway(text);
                box.SelectedText = host;
                // Only when the paste is the whole address: a port pasted into the middle of one is not this gateway's.
                if (port is { } p && box.Text == host) PortBox.Value = p;
            }
            else box.SelectedText = FieldCleaner.Line(text);
            box.SelectionStart += box.SelectionLength;
            box.SelectionLength = 0;
        }
        catch (Exception ex)
        {
            // A busy clipboard: nothing pasted is better than half of something.
            ShowEditorMessage($"Could not paste: {ex.Message}", InfoBarSeverity.Warning);
        }
    }

    /// <summary>Leaving the gateway box: "https://vpn.example.com:10443/realm" typed in full becomes the host and the port.</summary>
    private void HostBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_loading || Id == null) return;
        var typed = HostBox.Text;
        var (host, port) = FieldCleaner.Gateway(typed);
        if (host == typed) return;
        _loading = true;
        try
        {
            HostBox.Text = host;
            if (port is { } p) PortBox.Value = p;
        }
        finally { _loading = false; }
        Set(c => { c.Host = host; if (port is { } p) c.Port = p; });
    }
    private void PasswordField_PasswordChanged(object sender, RoutedEventArgs e)
    {
        Set(c => c.Password = PasswordField.Password);
        UpdateShowButtons();
    }
    private void DnsBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.DnsDomains = DnsBox.Text);
    private void ExtraBox_TextChanged(object sender, TextChangedEventArgs e) => Set(c => c.ExtraConfig = ExtraBox.Text);

    private void PortBox_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loading) return;
        if (double.IsNaN(args.NewValue))
        {
            // The box was cleared: show the saved port again instead of an empty box that still means the old one.
            if (Id is { } id && _store.Get(id) is { } c)
            {
                _loading = true;
                try { sender.Value = c.Port; }
                finally { _loading = false; }
            }
            return;
        }
        Set(c => c.Port = (int)Math.Clamp(args.NewValue, 1, 65535));
    }

    private void SecretField_PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_restoring) return;
        var text = SecretField.Password;
        if (!_loading && LinkAnywhere.IsMatch(text))
        {
            ImportPastedLink(text);   // never stored as the secret
            return;
        }
        _lastGoodSecret = text;
        Set(c => c.TotpSecret = text.Trim());
        UpdateShowButtons();
        UpdateOtpVisibility();
    }

    private void OtpBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Set(c => c.OtpMode = (OtpMode)Math.Max(0, OtpBox.SelectedIndex));
        UpdateOtpVisibility();
    }

    private void CopyCode_Click(object sender, RoutedEventArgs e)
    {
        if (Totp.Code(SecretField.Password) is not { } code) return;
        try { Ui.SetClipboardText(code); }
        catch (Exception ex)
        {
            // Without this the person pastes whatever the clipboard held before into the gateway login.
            ShowEditorMessage($"Could not copy the code: {ex.Message}. Type it instead.", InfoBarSeverity.Warning);
        }
    }

    private void Forget_Click(object sender, RoutedEventArgs e) => Set(c => c.ForgetCertificate());

    private void Review_Click(object sender, RoutedEventArgs e)
    {
        if (Id is { } id) CertReview.Present(id);
    }

    private void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (Id is { } id && _store.Get(id) is { } c) _vpn.Toggle(c);
    }
}
