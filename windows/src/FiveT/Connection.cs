using System.Text.Json.Serialization;

namespace FiveT;

public enum OtpMode
{
    None,
    AppendToPassword,
    Separate,
}

public static class OtpModeExt
{
    public static string Label(this OtpMode m) => m switch
    {
        OtpMode.None => "None (static password only)",
        OtpMode.AppendToPassword => "Append TOTP code to password",
        OtpMode.Separate => "Send TOTP code as second step",
        _ => m.ToString(),
    };

    /// <summary>The wire names used in connections.json (same as the macOS app).</summary>
    public static string Wire(this OtpMode m) => m switch
    {
        OtpMode.None => "none",
        OtpMode.AppendToPassword => "appendToPassword",
        OtpMode.Separate => "separate",
        _ => "none",
    };

    public static OtpMode FromWire(string? s) => s switch
    {
        "appendToPassword" => OtpMode.AppendToPassword,
        "separate" => OtpMode.Separate,
        _ => OtpMode.None,
    };
}

/// <summary>
/// What a connection logs in to: a FortiGate SSL-VPN (openconnect), an OpenVPN server, or a V2Ray server
/// (VLESS, VMess, Trojan, Shadowsocks/Outline, Hysteria2; run by Xray). The wire names are the Mac's.
/// </summary>
public enum VpnKind { Fortinet, OpenVpn, V2Ray }

public static class VpnKindExt
{
    public static string Wire(this VpnKind k) => k switch { VpnKind.OpenVpn => "openvpn", VpnKind.V2Ray => "v2ray", _ => "fortinet" };
    public static VpnKind FromWire(string? s) => s switch { "openvpn" => VpnKind.OpenVpn, "v2ray" => VpnKind.V2Ray, _ => VpnKind.Fortinet };
}

public sealed class Connection
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "New connection";
    public VpnKind Kind { get; set; } = VpnKind.Fortinet;
    /// <summary>OpenVPN: the profile as imported, with every certificate and key inline (OpenVpnProfile).
    /// <see cref="Host"/> and <see cref="Port"/> hold its first server, for display and the failed-login count.
    /// Kept in memory in the clear; stored DPAPI-encrypted (it holds a private key).</summary>
    public string OvpnProfile { get; set; } = "";
    /// <summary>V2Ray: the server as one Xray outbound (JSON), from a link or a JSON config (V2RayConfig).
    /// Stored DPAPI-encrypted (it holds the user id or password).</summary>
    public string V2RayOutbound { get; set; } = "";
    /// <summary>The share link it was imported from (empty for a JSON config), for Copy Link. Stored encrypted.</summary>
    public string V2RayLink { get; set; } = "";
    /// <summary>The subscription address it came from, if any: Refresh replaces what it lists. Stored encrypted (it carries a token).</summary>
    public string V2RaySubscription { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 10443;
    public string Realm { get; set; } = "";
    public string Username { get; set; } = "";
    /// <summary>Kept in memory in the clear; stored DPAPI-encrypted (see ConnectionStore).</summary>
    public string Password { get; set; } = "";
    public string TotpSecret { get; set; } = "";
    public OtpMode OtpMode { get; set; } = OtpMode.None;

    // Gateway certificate, stored exactly as the Mac app stores it (1.8), so a connections.json
    // copied between the two keeps its meaning. See VpnManager.CertChecked for how they are used.

    /// <summary>Lowercase hex SHA-256 of the trusted certificate (DER), the digest openfortivpn prints.
    /// Empty for a gateway trusted before this was kept (then <see cref="TrustedCertPin"/> may hold it).</summary>
    public string TrustedCert { get; set; } = "";
    /// <summary>The gateway ("host:port", <see cref="GatewayKey"/>) FiveT logged in to with that certificate.
    /// After the host or port is edited the gateway is a new one, met for the first time.</summary>
    public string TrustedCertHost { get; set; } = "";
    /// <summary>Common name and DNS names of the trusted certificate: a changed certificate Windows vouches
    /// for is a renewal when it carries one of these (the only test for a gateway reached by IP address).</summary>
    public List<string> TrustedCertNames { get; set; } = new();
    /// <summary>Windows only: openconnect's "pin-sha256:…" (public key) of the trusted certificate, which is
    /// what --servercert takes. A cache: the check before each login recomputes it from the certificate.</summary>
    public string TrustedCertPin { get; set; } = "";
    /// <summary>A certificate FiveT did not trust by itself, waiting for Review Certificate… (hex SHA-256,
    /// or "pin-sha256:…" when only openconnect saw it). Empty when nothing waits.</summary>
    public string PendingCert { get; set; } = "";
    public string PendingCertHost { get; set; } = "";
    /// <summary>True when the pending certificate is from a gateway never logged in to (not a change).</summary>
    public bool PendingCertFirst { get; set; }
    /// <summary>What the review shows: names, issuer, expiry, fingerprint, why it was not trusted.</summary>
    public string PendingCertInfo { get; set; } = "";
    /// <summary>Windows only: the openconnect pin of the pending certificate, so trusting it needs no refetch.</summary>
    public string PendingCertPin { get; set; } = "";
    /// <summary>Extra openconnect command-line options, one per line (advanced).</summary>
    public string ExtraConfig { get; set; } = "";
    /// <summary>Split DNS: domains (comma/space separated) resolved through the tunnel's DNS via NRPT rules.</summary>
    public string DnsDomains { get; set; } = "";
    public DateTime? LastConnectedAt { get; set; }
    public string? LastError { get; set; }
    /// <summary>The gateway and the way of sending the one-time code that last got a login through
    /// (<see cref="OtpAcceptedKey"/> as it was then). Editing the gateway or the way makes it stale again.</summary>
    public string AcceptedOtp { get; set; } = "";

    [JsonIgnore] public bool UsesTotp => OtpMode != OtpMode.None;
    /// <summary>"host:port" and the way the code is sent, as they are set now.</summary>
    [JsonIgnore] public string OtpAcceptedKey => $"{GatewayKey} {OtpMode.Wire()}";
    /// <summary>The gateway has taken a login with the code sent this way before: one refusal after that is
    /// more likely the password, the account or the gateway than the way the code goes out.</summary>
    [JsonIgnore] public bool OtpModeAccepted => UsesTotp && AcceptedOtp == OtpAcceptedKey;
    [JsonIgnore] public bool IsOpenVpn => Kind == VpnKind.OpenVpn;
    [JsonIgnore] public bool IsV2Ray => Kind == VpnKind.V2Ray;
    /// <summary>Listed on the VPN tab (OpenVPN, V2Ray, Outline), not the Forti tab. One of these runs at a time.</summary>
    [JsonIgnore] public bool IsOtherVpn => Kind != VpnKind.Fortinet;
    /// <summary>The gateway as <see cref="LoginGuard"/> counts it: its address alone, lowercase. A FortiGate counts
    /// failed logins per client address, whichever of its ports they went to (the Mac's loginGuardKey).</summary>
    [JsonIgnore] public string LoginGuardKey => Host.Trim().ToLowerInvariant();

    /// <summary>Cleaned list of split-DNS domains by the Mac's rules (<see cref="CleanDomains"/>): lowercase, no leading dot,
    /// valid host characters, at least one dot (a single-label name such as "corp" is not accepted).</summary>
    [JsonIgnore]
    public List<string> DnsDomainList => CleanDomains(DnsDomains, Array.Empty<string>());

    /// <summary>
    /// The Mac's Connection.cleanDomains: free text (commas, spaces, semicolons, newlines) into unique,
    /// valid domain names with at least one dot. Also used for the DNS suffixes a gateway pushes.
    /// </summary>
    public static List<string> CleanDomains(string text, IEnumerable<string> more)
    {
        var seen = new HashSet<string>();
        return more.Prepend(text)
            .SelectMany(t => t.Split(new[] { ',', ' ', '\n', ';', '\r' }, StringSplitOptions.RemoveEmptyEntries))
            .Select(d => d.Trim().ToLowerInvariant())
            .Select(d => d.StartsWith('.') ? d[1..] : d)
            .Where(d => d.Length > 0 && !d.Contains("..") && d.Contains('.') && !d.EndsWith('.')
                        && d.All(ch => char.IsLetterOrDigit(ch) || ch == '.' || ch == '-'))
            .Where(seen.Add)
            .ToList();
    }

    [JsonIgnore]
    public string GatewayDescription => Realm.Length == 0 ? $"{Host}:{Port}" : $"{Host}:{Port}/{Realm}";

    /// <summary>How many line breaks the text fields hold (a paste with blank lines raises it, cleaning lowers it).</summary>
    [JsonIgnore]
    public int LineBreakCount => new[] { Name, Host, Realm, Username, Password, TotpSecret }.Sum(t => t.Count(FieldCleaner.IsNewline));

    /// <summary>
    /// Takes the line breaks out of what was pasted into the fields (the Mac's cleanPastedFields, 1.13.3). A value
    /// with a line break can never be used (the launch refuses it), and a one-line box hides all but a paste's
    /// first line. Only a value that needs it changes, so typing (a space inside a user name, say) is left
    /// alone. A line break inside a password is ambiguous and stays for the launch to refuse; only line
    /// breaks at its ends go. Returns the labels of what changed, never a value.
    /// </summary>
    public List<string> CleanPastedFields()
    {
        var changed = new List<string>();
        string Clean(string label, string value, string cleaned)
        {
            if (cleaned != value) changed.Add(label);
            return cleaned;
        }
        static string OneLine(string v) => v.Any(FieldCleaner.IsNewline) ? FieldCleaner.Line(v) : v;
        Name = Clean("name", Name, OneLine(Name));
        Host = Clean("gateway", Host, FieldCleaner.CleanedHost(Host));
        Realm = Clean("realm", Realm, OneLine(Realm));
        Username = Clean("username", Username, OneLine(Username));
        Password = Clean("password", Password, Password.Trim('\n', '\r', '\u0085', '\u2028', '\u2029'));
        // A pasted otpauth:// link is read by the secret field itself (Settings), as it came.
        if (!TotpSecret.Contains("otpauth", StringComparison.OrdinalIgnoreCase))
        {
            var secret = TotpSecret.Any(FieldCleaner.IsNewline)
                ? new string(TotpSecret.Where(ch => !FieldCleaner.IsNewline(ch)).ToArray()).Trim(' ', '	') : TotpSecret;
            TotpSecret = Clean("TOTP secret", TotpSecret, secret);
        }
        return changed;
    }

    /// <summary>The gateway a certificate belongs to: "host:port", lowercase (the Mac's gatewayKey).</summary>
    [JsonIgnore] public string GatewayKey => $"{Host.Trim().ToLowerInvariant()}:{Port}";
    /// <summary>FiveT has logged in to this gateway, as it is set now.</summary>
    [JsonIgnore] public bool KnowsGateway => TrustedCertHost.Length > 0 && TrustedCertHost == GatewayKey;
    [JsonIgnore] public bool HasPinForGateway => KnowsGateway && (TrustedCert.Length > 0 || TrustedCertPin.Length > 0);
    [JsonIgnore] public bool HasPendingReview => PendingCert.Length > 0 && PendingCertHost == GatewayKey;

    /// <summary>Trusts a certificate for the current gateway (a renewal Windows vouched for, or the user's review).</summary>
    public void Trust(string sha256, string pin, List<string> names)
    {
        TrustedCert = sha256.ToLowerInvariant();
        TrustedCertPin = pin;
        TrustedCertHost = GatewayKey;
        TrustedCertNames = names.ToList();
        ClearPendingReview();
    }

    public void SetPendingReview(string cert, string pin, bool first, string info)
    {
        PendingCert = cert.StartsWith("pin-sha256:", StringComparison.Ordinal) ? cert : cert.ToLowerInvariant();
        PendingCertPin = pin;
        PendingCertHost = GatewayKey;
        PendingCertFirst = first;
        PendingCertInfo = info;
    }

    public void ClearPendingReview()
    {
        PendingCert = PendingCertHost = PendingCertInfo = PendingCertPin = "";
        PendingCertFirst = false;
    }

    /// <summary>Settings → Forget: the next connect meets the gateway as for the first time.</summary>
    public void ForgetCertificate()
    {
        TrustedCert = TrustedCertHost = TrustedCertPin = "";
        TrustedCertNames = new List<string>();
        ClearPendingReview();
    }

    public Connection Clone()
    {
        var c = (Connection)MemberwiseClone();
        c.TrustedCertNames = TrustedCertNames.ToList();
        return c;
    }

    /// <summary>Seeded into connections.json on first launch.
    /// Real seeds live in LocalSeeds.cs, which is git-ignored (build.ps1 creates an empty one). A distribution build
    /// (<c>-p:Distribution=true</c>, build.ps1 -Installer) compiles LocalSeedsEmpty.cs instead, so no credential reaches a shared setup file.</summary>
    public static List<Connection> Seeds() => LocalSeeds.Connections();
}
