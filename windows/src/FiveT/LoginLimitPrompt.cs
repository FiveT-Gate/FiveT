namespace FiveT;

/// <summary>
/// A click on a connection whose last logins failed (LoginGuard) asks before one more: the next failure
/// gets this network's internet address banned at the gateway for hours, for everyone on the network.
/// Cancel is the default; Try Anyway allows exactly one login, at the count the question showed. Only a
/// person can answer: assistants (MCP), the command line and fivet:// links are refused. The Mac's
/// askToLogInAgain (AppDelegate.swift).
/// </summary>
public static class LoginLimitPrompt
{
    public static async void Present(Guid id)
    {
        // async void: nothing may escape onto the UI thread.
        try
        {
            var store = ConnectionStore.Shared;
            if (store.Get(id) is not { } c) return;
            var key = c.LoginGuardKey;
            var failed = LoginGuard.Shared.Count(key);
            if (failed < LoginGuard.Limit)
            {
                VpnManager.Shared.Connect(c, ConnectOrigin.User);   // a login got through meanwhile: nothing to ask
                return;
            }
            var sharing = store.Connections.Where(x => x.LoginGuardKey == key).Select(x => x.Name).ToList();
            var info = $"One more failed login and the gateway ({c.Host.Trim()}) bans this network's internet address for a few hours: "
                       + "nobody on this network can connect to it then, on any computer. "
                       + $"Check the password and the one-time code in Settings → {(c.IsOpenVpn ? "VPN" : "Forti")} first.";
            if (sharing.Count > 1)
                info += $"\n\n{string.Join(", ", sharing)} all log in to this gateway: a wrong password or code in any of them counts.";
            if (VpnManager.UntriedOtpMode(c) is { } other)
                info += $"\n\nThose logins had the one-time code {VpnManager.Describe(c.OtpMode)}. With Try Anyway it is {VpnManager.Describe(other)}.";
            if (LoginGuard.Shared.ClearsAt(key) is { } until)
                info += $"\n\nFiveT stops asking at {until.ToLocalTime():HH:mm}, three hours after the last failure, or after a login that gets through.";
            // One question per gateway at a time (the key of the window), so two connections to it (Connect
            // All) cannot each get their extra login.
            var r = await PromptWindow.Ask("loginlimit:" + key, new PromptSpec
            {
                Title = $"The last {failed} logins to {c.Name}'s gateway failed",
                Message = info,
                Primary = "Try Anyway",
                Secondary = "Cancel",
                Warning = true,   // Cancel has the focus; Try Anyway waits a second
                AutomationId = "LoginLimitPrompt",
            });
            if (!r.Accepted)
            {
                Log.Shared.Write($"[{c.Name}] not logging in again after {failed} failed login(s)");
                return;
            }
            // At the count the question showed: if it changed while it was open, the launch asks anew.
            if (store.Get(id) is { } latest) VpnManager.Shared.TryAnyway(latest, failed);
        }
        catch (Exception e)
        {
            Log.Shared.Write($"login limit prompt failed: {e.Message}", LogLevel.Error);
        }
    }
}
