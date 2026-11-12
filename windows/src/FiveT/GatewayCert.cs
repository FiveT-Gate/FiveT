using System.Formats.Asn1;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32;

namespace FiveT;

/// <summary>What FiveT learned about the certificate the gateway showed it (the Mac's CertCheck.Leaf).</summary>
public sealed record GatewayCertInfo
{
    /// <summary>Lowercase hex SHA-256 of the certificate (DER): what the Mac stores as trustedCert.</summary>
    public string Sha256 { get; init; } = "";
    /// <summary>openconnect's "pin-sha256:&lt;base64&gt;" of the public key: what --servercert takes.</summary>
    public string Pin { get; init; } = "";
    /// <summary>Common name and DNS alternative names, lowercased, cleaned, at most 20.</summary>
    public List<string> Names { get; init; } = new();
    /// <summary>"made out to …, issued by …, valid until …".</summary>
    public string Summary { get; init; } = "";
    /// <summary>The chain leads to a root that comes with Windows (Microsoft's root program) and nothing in it expired.</summary>
    public bool ChainTrusted { get; init; }
    /// <summary>…and the certificate is made out to the host name FiveT connects to.</summary>
    public bool TrustedForHost { get; init; }
    /// <summary>Why the chain is not trusted, in FiveT's own words (never text from the certificate's issuer).</summary>
    public string? TrustError { get; init; }
}

/// <summary>
/// FiveT's own look at the gateway's certificate before openconnect gets the password, following
/// the Mac app's CertCheck (1.8). A TLS handshake only — nothing is sent, the socket closes right
/// after — then Windows is asked twice: is the chain good, and is it made out to this host name.
///
/// Only the roots that come with Windows count (Microsoft's root program list, authroot.stl), not
/// roots an administrator, an antivirus or a TLS-inspecting proxy added to the store: the Mac only
/// counts the authorities that ship with macOS, for the same reason. openconnect's GnuTLS build on
/// Windows sees no store at all, which is why it always gets --servercert.
/// </summary>
public static class GatewayCert
{
    public static string PinOf(X509Certificate2 cert) =>
        "pin-sha256:" + Convert.ToBase64String(SHA256.HashData(cert.PublicKey.ExportSubjectPublicKeyInfo()));

    public static string Sha256Of(X509Certificate2 cert) => Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant();

    /// <summary>"46b6 01ee 08b4 …", as the Mac groups a fingerprint.</summary>
    public static string GroupedHex(string hex) =>
        string.Join(" ", Enumerable.Range(0, (hex.Length + 3) / 4).Select(i => hex.Substring(i * 4, Math.Min(4, hex.Length - i * 4))));

    public static bool IsIpAddress(string host) => System.Net.IPAddress.TryParse(host.Trim('[', ']'), out _);

    /// <summary>
    /// Connects, takes the chain the gateway presents, and disconnects. Blocks; call off the UI thread.
    /// <c>Reached</c> says the TCP connection was made, so a failure after it is about TLS, not the network.
    /// </summary>
    public static (GatewayCertInfo? Info, string? Error, bool Reached) Fetch(string host, int port, int timeoutMs = 8000)
    {
        X509Certificate2? seen = null;
        var extra = new X509Certificate2Collection();
        var nameMismatch = false;
        var reached = false;
        try
        {
            using var tcp = new TcpClient();
            if (!tcp.ConnectAsync(host, port).Wait(timeoutMs)) return (null, "timed out", false);
            reached = true;
            using var ssl = new SslStream(tcp.GetStream(), false, (_, cert, chain, errors) =>
            {
                if (cert != null) seen = new X509Certificate2(cert);
                if (chain != null)
                    foreach (var e in chain.ChainElements.Skip(1)) extra.Add(new X509Certificate2(e.Certificate));
                nameMismatch = errors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch);
                return true;   // only looking: the decision is made below, and nothing is ever sent
            });
            var options = new SslClientAuthenticationOptions
            {
                // No server name for an IP address, as openfortivpn does (certificates name host names).
                TargetHost = IsIpAddress(host) ? "" : host,
                EnabledSslProtocols = SslProtocols.None,   // let Windows pick, like any other client
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
            };
            if (!ssl.AuthenticateAsClientAsync(options).Wait(timeoutMs)) return (null, "the TLS handshake timed out", true);
        }
        catch (Exception e)
        {
            var inner = e is AggregateException a ? a.InnerException ?? e : e;
            // The certificate is known as soon as the server sends it, so a handshake that fails later
            // (a cipher Schannel refuses) still tells us what we need.
            if (seen == null) return (null, inner.Message, reached);
        }
        if (seen == null) return (null, "the gateway sent no certificate", true);
        using (seen) return (Evaluate(seen, extra, host, nameMismatch), null, true);
    }

    private static GatewayCertInfo Evaluate(X509Certificate2 cert, X509Certificate2Collection extra, string host, bool nameMismatch)
    {
        var chainTrusted = false;
        string? reason = null;
        using (var chain = new X509Chain())
        {
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
            chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));   // server authentication
            chain.ChainPolicy.ExtraStore.AddRange(extra);
            var built = chain.Build(cert);
            var root = chain.ChainElements.Count > 0 ? chain.ChainElements[^1].Certificate : null;
            var shipped = root != null && RootProgram.Contains(root.Thumbprint);
            chainTrusted = built && shipped;
            if (!chainTrusted)
            {
                // Never Windows' own error text: it quotes the certificate, whose maker chose every word.
                reason = DateTime.Now > cert.NotAfter ? $"the certificate expired on {cert.NotAfter:yyyy-MM-dd}"
                    : built && !shipped ? "Windows trusts it only through a root added to this PC (by IT, an antivirus or a proxy), not one that comes with Windows"
                    : cert.Subject == cert.Issuer ? "it is self-signed"
                    : "Windows does not trust it (it is not from a certificate authority that comes with Windows, or not valid)";
            }
        }
        var names = NamesOf(cert);
        var summary = "made out to " + (names.Count == 0 ? Clean(cert.GetNameInfo(X509NameType.SimpleName, false)) : string.Join(", ", names));
        var issuer = cert.GetNameInfo(X509NameType.SimpleName, true);
        if (issuer.Length > 0) summary += $", issued by {Clean(issuer)}";
        summary += $", valid until {cert.NotAfter:yyyy-MM-dd}";
        return new GatewayCertInfo
        {
            Sha256 = Sha256Of(cert),
            Pin = PinOf(cert),
            Names = names,
            Summary = summary,
            ChainTrusted = chainTrusted,
            TrustedForHost = chainTrusted && !nameMismatch && !IsIpAddress(host),
            TrustError = reason,
        };
    }

    /// <summary>The common name and the DNS alternative names, lowercased, unique, cleaned (at most 20).</summary>
    public static List<string> NamesOf(X509Certificate2 cert)
    {
        var outList = new List<string>();
        var cn = cert.GetNameInfo(X509NameType.SimpleName, false);
        if (cn.Length > 0) outList.Add(cn.ToLowerInvariant());
        foreach (var ext in cert.Extensions)
        {
            if (ext is not X509SubjectAlternativeNameExtension san) continue;
            foreach (var dns in san.EnumerateDnsNames())
            {
                var d = dns.ToLowerInvariant();
                if (!outList.Contains(d)) outList.Add(d);
            }
        }
        return outList.Select(Clean).Take(20).ToList();
    }

    /// <summary>
    /// Text read off a certificate, fit to show and log: whoever made the certificate chose it, so no
    /// control or direction-changing characters, and at most 64 characters (as the Mac does).
    /// </summary>
    public static string Clean(string s)
    {
        var shown = new string(s.Select(ch => char.IsControl(ch) || ch is >= '‪' and <= '‮' or >= '⁦' and <= '⁩' or '‎' or '‏' ? '?' : ch).ToArray());
        return shown.Length > 64 ? shown[..64] + "…" : shown;
    }

    /// <summary>
    /// Fallback when Schannel cannot finish a handshake with this gateway at all: let openconnect connect
    /// with no password on stdin and --non-inter, so it stops at the certificate and prints the pin it
    /// would need. It never gets as far as logging in.
    /// </summary>
    public static string? PinFromOpenconnect(string openconnect, string url)
    {
        var r = Setup.Run(openconnect, new[] { "--protocol=fortinet", "--non-inter", "--passwd-on-stdin", "--no-dtls", url }, 15_000);
        foreach (var line in r.Output.Split('\n'))
            if (PinIn(line) is { } pin) return pin;
        return null;
    }

    /// <summary>The "pin-sha256:…" openconnect prints about the certificate it saw, if the line has one.</summary>
    public static string? PinIn(string line)
    {
        var i = line.IndexOf("pin-sha256:", StringComparison.Ordinal);
        if (i < 0) return null;
        var pin = line[i..].Split(' ', '\t', '\'', '"', '\r')[0].Trim();
        return pin.Length > "pin-sha256:".Length + 20 ? pin : null;
    }

    /// <summary>
    /// Microsoft's list of the root certificates that come with Windows (the Trusted Root Program),
    /// which Windows keeps up to date in the registry as authroot.stl. A root that is in the store but
    /// not on this list was put there by someone on or for this PC.
    /// </summary>
    private static class RootProgram
    {
        private static HashSet<string>? _thumbprints;
        private static bool _warned;
        private static readonly object Lock = new();

        public static bool Contains(string sha1Thumbprint)
        {
            lock (Lock)
            {
                // An empty result is not kept: the list may simply not have been downloaded yet (Windows
                // fetches it in the background), so ask again next time instead of distrusting everything until restart.
                if (_thumbprints == null)
                {
                    var loaded = Load();
                    if (loaded.Count == 0) return false;
                    _thumbprints = loaded;
                }
                return _thumbprints.Contains(sha1Thumbprint.ToUpperInvariant());
            }
        }

        /// <summary>Said once per run, however often the list is asked for again.</summary>
        private static void WarnOnce(string text)
        {
            if (_warned) return;
            _warned = true;
            Log.Shared.Write(text, LogLevel.Error);
        }

        private static HashSet<string> Load()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate");
                if (key?.GetValue("EncodedCtl") is not byte[] encoded) { WarnOnce("Windows' root program list is not on this PC (yet); no certificate is trusted without asking until it is"); return set; }
                var cms = new SignedCms();
                cms.Decode(encoded);
                Collect(cms.ContentInfo.Content, set);
                if (set.Count == 0) WarnOnce("Windows' root program list was read but holds no roots; no certificate is trusted without asking");
            }
            catch (Exception e)
            {
                set.Clear();   // half a list must not be kept either
                WarnOnce($"could not read Windows' root program list: {e.Message}");
            }
            return set;
        }

        /// <summary>
        /// The CTL's trustedSubjects are SEQUENCE { OCTET STRING (SHA-1 of the root), attributes }.
        /// Walking every constructed value and taking each SEQUENCE that starts with a 20-byte OCTET
        /// STRING finds them without depending on the rest of the CTL's layout.
        /// </summary>
        private static void Collect(ReadOnlyMemory<byte> der, HashSet<string> set)
        {
            var reader = new AsnReader(der, AsnEncodingRules.BER);
            while (reader.HasData)
            {
                var tag = reader.PeekTag();
                var encoded = reader.ReadEncodedValue();
                if (!tag.IsConstructed) continue;
                if (!AsnDecoder.TryReadEncodedValue(encoded.Span, AsnEncodingRules.BER, out _, out var offset, out var length, out _)) continue;
                var body = encoded.Slice(offset, length);
                if (tag.HasSameClassAndValue(Asn1Tag.Sequence) && SubjectId(body) is { } id)
                {
                    set.Add(id);
                    continue;
                }
                try { Collect(body, set); } catch (AsnContentException) { }
            }
        }

        /// <summary>The SHA-1 in a SEQUENCE that starts with a 20-byte OCTET STRING, else null.</summary>
        private static string? SubjectId(ReadOnlyMemory<byte> body)
        {
            try
            {
                var r = new AsnReader(body, AsnEncodingRules.BER);
                if (!r.HasData || !r.PeekTag().HasSameClassAndValue(Asn1Tag.PrimitiveOctetString)) return null;
                var id = r.ReadOctetString();
                return id.Length == 20 ? Convert.ToHexString(id) : null;
            }
            catch (AsnContentException) { return null; }
        }
    }
}
