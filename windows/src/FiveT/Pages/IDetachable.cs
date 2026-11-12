namespace FiveT.Pages;

/// <summary>
/// A Settings page that listens to the singletons (ConnectionStore, VpnManager, McpServer). It lets go
/// when it unloads, and again when the window closes, because a closing window does not reliably
/// raise Unloaded. Detach must be safe to call twice.
/// </summary>
public interface IDetachable
{
    void Detach();
}
