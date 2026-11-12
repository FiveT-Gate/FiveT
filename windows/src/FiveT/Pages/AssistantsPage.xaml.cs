using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FiveT.Pages;

public sealed partial class AssistantsPage : Page, IDetachable
{
    private readonly ConnectionStore _store = ConnectionStore.Shared;
    private readonly McpServer _mcp = McpServer.Shared;
    private bool _working, _loading;

    public AssistantsPage()
    {
        InitializeComponent();
        CommandBox.Text = $"\"{McpClientSetup.Command}\" --mcp";
        var mono = new FontFamily("Consolas");
        foreach (var t in McpTools.Summary)
        {
            Tools.Children.Add(new TextBlock { Text = t.Name, FontFamily = mono, Margin = new Thickness(1, 8, 0, 0) });
            Tools.Children.Add(new TextBlock { Text = t.Description, Style = (Style)Application.Current.Resources["SettingsCaptionStyle"], Margin = new Thickness(1, 2, 0, 0) });
        }
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        Detach();   // never subscribe twice
        _mcp.Changed += RefreshStatus;
        _store.Changed += RefreshStatus;
        _loading = true;
        EnabledSwitch.IsOn = _store.McpEnabled;
        _loading = false;
        RefreshStatus();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e) => Detach();

    /// <summary>Also called when the Settings window closes: a closing window does not reliably raise Unloaded.</summary>
    public void Detach()
    {
        _mcp.Changed -= RefreshStatus;
        _store.Changed -= RefreshStatus;
    }

    private void RefreshStatus()
    {
        var status = !_store.McpEnabled ? "Off"
            : !_mcp.IsListening ? "Not running (see the log)"
            : _mcp.ClientCount switch { 0 => "Ready, no assistant connected", 1 => "Ready, 1 assistant connected", var n => $"Ready, {n} assistants connected" };
        EnabledCard.Description = "Status: " + status;
    }

    private void EnabledSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        if (_store.McpEnabled != EnabledSwitch.IsOn) _store.McpEnabled = EnabledSwitch.IsOn;
    }

    private void ShowMessage(string text)
    {
        Message.Message = text;
        Message.IsOpen = text.Length > 0;
    }

    private void Run(Func<string> action)
    {
        if (_working) return;
        _working = true;
        ShowMessage("Working…");
        Task.Run(() =>
        {
            string m;
            try { m = action(); }
            catch (Exception e) { m = "Could not change the assistant's settings: " + e.Message; }   // else the buttons stay dead on "Working…"
            Ui.Post(() => { ShowMessage(m); _working = false; });
        });
    }

    private void AddClaudeDesktop_Click(object sender, RoutedEventArgs e) => Run(() => McpClientSetup.Add(McpClientSetup.ClaudeDesktopConfig, "Claude Desktop"));
    private void AddClaudeCode_Click(object sender, RoutedEventArgs e) => Run(McpClientSetup.AddToClaudeCode);
    private void AddCursor_Click(object sender, RoutedEventArgs e) => Run(() => McpClientSetup.Add(McpClientSetup.CursorConfig, "Cursor"));

    private void CopyJson_Click(object sender, RoutedEventArgs e)
    {
        Ui.SetClipboardText(McpClientSetup.Snippet);
        ShowMessage("JSON snippet copied. Paste it into the client's mcpServers config.");
    }
}
