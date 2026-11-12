namespace FiveT;

/// <summary>
/// Review Certificate… / Review New Certificate…: the user's decision about a gateway certificate
/// Windows could not vouch for — a changed one, or the first one of a gateway FiveT has not logged
/// in to (VpnManager.Unverified saves it on the connection). The Mac app's CertReview (1.8).
/// Only a person can make it: assistants (MCP), the command line and fivet:// links cannot trust a
/// certificate.
/// </summary>
public static class CertReview
{
    public static async void Present(Guid id)
    {
        var store = ConnectionStore.Shared;
        if (store.Get(id) is not { HasPendingReview: true } c) return;
        // What the user is shown is what gets trusted: if the question changes while the prompt is up
        // (another attempt met yet another certificate), Trust does nothing.
        var pending = c.PendingCert;
        var pendingPin = c.PendingCertPin;
        var first = c.PendingCertFirst;
        var oldCert = c.TrustedCert;
        var oldPin = c.TrustedCertPin;
        var gateway = c.GatewayKey;
        var spec = new PromptSpec
        {
            Title = first ? $"Trust the certificate of {c.Name}'s gateway?" : $"The certificate of {c.Name}'s gateway has changed",
            Message = first
                ? "FiveT has not connected to this gateway before, and Windows cannot confirm the certificate belongs to it. "
                  + "FiveT did not log in, so your password was not sent.\n\n"
                  + "Trust it if you are on a network you trust and this is the gateway your IT team gave you. "
                  + "After that, FiveT checks the gateway against it every time."
                : "FiveT did not log in, so your password was not sent.\n\n"
                  + "Gateways get a new certificate when the old one is renewed. A different certificate can also mean "
                  + "someone is intercepting the connection, for example on hotel or café Wi-Fi. Trust it only if your IT team confirms the change.\n\n"
                  + "On hotel, café or airport Wi-Fi, sign in to the Wi-Fi in your browser first, then connect again: "
                  + "if the old certificate comes back, FiveT connects without asking.",
            Detail = c.PendingCertInfo,
            Primary = first ? "Trust and Connect" : "Trust New Certificate",
            Secondary = first ? "Don't Connect" : "Keep Blocked",
            Warning = true,   // the safe answer has the focus; the risky one waits a second
            AutomationId = "TrustPrompt",
        };
        var r = await PromptWindow.Ask("cert:" + id, spec);
        if (!r.Accepted)
        {
            Log.Shared.Write($"[{c.Name}] {(first ? "gateway certificate not trusted" : "new gateway certificate kept blocked")}");
            return;
        }
        if (store.Get(id) is not { } now || now.PendingCert != pending || now.GatewayKey != gateway)
        {
            Log.Shared.Write($"[{c.Name}] the certificate question changed while it was on screen; nothing trusted", LogLevel.Error);
            return;
        }
        var isPin = pending.StartsWith("pin-sha256:", StringComparison.Ordinal);
        var sha = isPin ? "" : pending;
        var pin = isPin ? pending : pendingPin;
        // Other connections to the same gateway that trusted the same certificate follow along.
        foreach (var other in store.Connections.ToList())
        {
            var follows = other.Id == id || (!first && other.GatewayKey == gateway
                          && ((oldCert.Length > 0 && other.TrustedCert == oldCert) || (oldCert.Length == 0 && oldPin.Length > 0 && other.TrustedCertPin == oldPin)));
            if (follows) store.Mutate(other.Id, x => x.Trust(sha, pin, new List<string>()));   // names: read at the next check
        }
        Log.Shared.Write($"[{c.Name}] you trusted the gateway certificate {(isPin ? pending[..Math.Min(24, pending.Length)] : pending[..12])}…; connecting");
        if (store.Get(id) is { } updated) VpnManager.Shared.Connect(updated, ConnectOrigin.User);
    }
}
