using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using ZXing;
using ZXing.Common;

namespace FiveT;

/// <summary>One TOTP account found in a link or QR code (the Mac's OTPAuthImport.Account).</summary>
public sealed record QrAccount(string Secret, string Issuer, string Name, string? ExportPart = null)
{
    public string Label
    {
        get
        {
            if (Issuer.Length == 0) return Name.Length == 0 ? "unnamed account" : Name;
            // Google Authenticator exports often repeat the issuer inside the name ("Example:alice").
            var bare = Name.StartsWith(Issuer + ":", StringComparison.Ordinal) ? Name[(Issuer.Length + 1)..].Trim() : Name;
            return bare.Length == 0 ? Issuer : $"{Issuer}: {bare}";
        }
    }
}

/// <summary>Why a link or picture could not be used, in words for the person at the keyboard.</summary>
public sealed class QrImportException(string message) : Exception(message);

/// <summary>The accounts an import found, or the reason it found none. ClipboardSequence is set when it came from the clipboard.</summary>
public sealed record QrImportResult(IReadOnlyList<QrAccount> Accounts, string? Error, uint ClipboardSequence = 0)
{
    public static QrImportResult Fail(string message, uint clipboard = 0) => new(Array.Empty<QrAccount>(), message, clipboard);
}

/// <summary>
/// Reads one-time-code secrets from what authenticator setups hand out, like the Mac app's
/// OTPAuthImport (1.8): an <c>otpauth://totp/…</c> link (the text inside a setup QR code), a Google
/// Authenticator export (<c>otpauth-migration://offline?data=…</c>), or a picture of either QR code
/// (clipboard screenshot, image file, drop).
///
/// FiveT makes 6-digit, 30-second, SHA-1 codes (Totp.cs), the kind FortiGate and most VPN gateways
/// use. A secret meant for other settings would give codes the gateway rejects (which looks exactly
/// like a wrong password, and repeated wrong logins can lock the account), so it is refused with a
/// reason instead of imported.
/// </summary>
public static class QrImport
{
    /// <summary>True when <paramref name="text"/> looks like something <see cref="AccountsIn(string)"/> reads, so a
    /// paste into the secret field can be taken apart instead of stored as the secret.</summary>
    public static bool LooksLikeLink(string text) => text.Trim().StartsWith("otpauth", StringComparison.OrdinalIgnoreCase);

    // MARK: Pictures

    /// <summary>Reads the clipboard: a screenshot, a copied image file, or text (a link). Call on the UI thread.</summary>
    public static async Task<QrImportResult> FromClipboardAsync()
    {
        var seq = ClipboardSequence();
        try
        {
            var content = Clipboard.GetContent();
            QrImportResult result;
            if (content.Contains(StandardDataFormats.Bitmap))
            {
                var reference = await content.GetBitmapAsync();
                using var stream = await reference.OpenReadAsync();
                result = await FromStreamAsync(stream);
            }
            else if (content.Contains(StandardDataFormats.StorageItems)
                     && (await content.GetStorageItemsAsync()).OfType<StorageFile>().FirstOrDefault() is { } file)
            {
                result = await FromFileAsync(file.Path);
            }
            else if (content.Contains(StandardDataFormats.Text))
            {
                result = FromText(await content.GetTextAsync());
            }
            else
            {
                return QrImportResult.Fail("The clipboard holds no picture. Take a screenshot of the QR code with Win+Shift+S (it copies the picture), then choose Paste Screenshot.");
            }
            return result with { ClipboardSequence = seq };
        }
        catch (Exception e)
        {
            // A busy clipboard owner, or one whose delayed-render data is gone (0x800401D0), throws from
            // any of the reads above; say so instead of letting the click do nothing.
            return QrImportResult.Fail($"Could not read the clipboard: {e.Message}");
        }
    }

    /// <summary>An image file, or the first file of a drop.</summary>
    public static async Task<QrImportResult> FromFileAsync(string path)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenReadAsync();
            return await FromStreamAsync(stream);
        }
        catch (Exception)
        {
            return QrImportResult.Fail($"{Path.GetFileName(path)} is not a picture FiveT can read.");
        }
    }

    /// <summary>A picture or image file dragged onto the secret row.</summary>
    public static async Task<QrImportResult> FromDroppedAsync(DataPackageView view)
    {
        try
        {
            if (view.Contains(StandardDataFormats.StorageItems)
                && (await view.GetStorageItemsAsync()).OfType<StorageFile>().FirstOrDefault() is { } file)
                return await FromFileAsync(file.Path);
            if (view.Contains(StandardDataFormats.Bitmap))
            {
                var reference = await view.GetBitmapAsync();
                using var stream = await reference.OpenReadAsync();
                return await FromStreamAsync(stream);
            }
        }
        catch (Exception) { }
        return QrImportResult.Fail("That is not a picture FiveT can read. Drop a screenshot or photo of the QR code.");
    }

    private static async Task<QrImportResult> FromStreamAsync(IRandomAccessStream stream)
    {
        byte[] pixels;
        int width, height;
        try
        {
            var decoder = await BitmapDecoder.CreateAsync(stream);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            width = bitmap.PixelWidth;
            height = bitmap.PixelHeight;
            pixels = new byte[width * height * 4];
            bitmap.CopyToBuffer(pixels.AsBuffer());
        }
        catch (Exception)
        {
            return QrImportResult.Fail("This picture could not be read.");
        }
        var texts = await Task.Run(() => QrTexts(pixels, width, height));
        if (texts.Count == 0)
            return QrImportResult.Fail("No QR code found in the picture. Take a screenshot of just the QR code (Win+Shift+S) and try again.");
        return FromTexts(texts);
    }

    /// <summary>The text of every QR code in the picture.</summary>
    private static List<string> QrTexts(byte[] bgra, int width, int height)
    {
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions
            {
                TryHarder = true,
                TryInverted = true,   // QR codes on a dark-mode page are light on dark
                PossibleFormats = new[] { BarcodeFormat.QR_CODE },
            },
        };
        var source = new RGBLuminanceSource(bgra, width, height, RGBLuminanceSource.BitmapFormat.BGRA32);
        var texts = new List<string>();
        // DecodeMultiple does not try inverted pictures (TryInverted only applies to a single decode), so
        // look at the picture both ways: a dark-mode page can hold light-on-dark and dark-on-light codes.
        foreach (var s in new LuminanceSource[] { source, source.invert() })
            foreach (var r in reader.DecodeMultiple(s) ?? Array.Empty<Result>())
                if (r?.Text is { } t && !texts.Contains(t)) texts.Add(t);
        if (texts.Count == 0 && reader.Decode(source)?.Text is { } single) texts.Add(single);
        return texts;
    }

    private static QrImportResult FromText(string text)
    {
        try { return new QrImportResult(AccountsIn(text), null); }
        catch (QrImportException e) { return QrImportResult.Fail(e.Message); }
    }

    /// <summary>The accounts in a picture of one or more QR codes: every usable one; the first error when none is.</summary>
    private static QrImportResult FromTexts(List<string> texts)
    {
        var accounts = new List<QrAccount>();
        string? firstError = null;
        foreach (var t in texts)
        {
            try { accounts.AddRange(AccountsIn(t)); }
            catch (QrImportException e) { firstError ??= e.Message; }
        }
        return accounts.Count > 0 ? new QrImportResult(accounts, null) : QrImportResult.Fail(firstError ?? NotASecret(texts[0]).Message);
    }

    // MARK: Clipboard

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public static uint ClipboardSequence() => GetClipboardSequenceNumber();

    /// <summary>Empties the clipboard, but only if nothing else was put there since <paramref name="sequence"/>
    /// (the secret is as good as a password; a copy the user made meanwhile is theirs). True when it was emptied.</summary>
    public static bool ClearClipboardIfUnchanged(uint sequence)
    {
        if (sequence == 0 || GetClipboardSequenceNumber() != sequence) return false;
        try { Clipboard.Clear(); return true; }
        catch { return false; }
    }

    // MARK: Links

    /// <summary>What a QR code that holds no secret holds, for the message ("a web link (https://)").</summary>
    private static QrImportException NotASecret(string text)
    {
        var t = text.Trim();
        var what = "text";
        var colon = t.IndexOf(':');
        if (colon is > 0 and <= 20)
        {
            var scheme = t[..colon].ToLowerInvariant();
            if (scheme.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '+' or '.'))
                what = scheme is "http" or "https" ? $"a web link ({scheme}://)" : $"a {scheme}: link";
        }
        return new QrImportException($"This QR code holds {what}, not a one-time-code secret (that starts with otpauth://). "
            + "A FortiToken Mobile activation code cannot be used here: ask your IT team for the TOTP secret or its QR code.");
    }

    /// <summary>Every usable account in <paramref name="text"/>. Throws when there is none, saying why.</summary>
    public static IReadOnlyList<QrAccount> AccountsIn(string text)
    {
        var t = text.Trim();
        if (Encoding.UTF8.GetByteCount(t) > 16_384) throw new QrImportException("This is too long to be a one-time-code setup code.");
        var link = Link.Parse(t) ?? throw NotASecret(t);
        return link.Scheme switch
        {
            "otpauth" => new[] { FromOtpauth(link) },
            "otpauth-migration" => FromMigration(link),
            _ => throw NotASecret(t),
        };
    }

    /// <summary>scheme://host/path?query, taken apart by hand: labels hold spaces and colons that Uri would mangle.</summary>
    private sealed record Link(string Scheme, string Host, string Path, Dictionary<string, string> Query)
    {
        public static Link? Parse(string text)
        {
            var sep = text.IndexOf("://", StringComparison.Ordinal);
            if (sep <= 0) return null;
            var scheme = text[..sep].ToLowerInvariant();
            var rest = text[(sep + 3)..];
            var hash = rest.IndexOf('#');
            if (hash >= 0) rest = rest[..hash];
            var q = rest.IndexOf('?');
            var query = q >= 0 ? rest[(q + 1)..] : "";
            var authorityAndPath = q >= 0 ? rest[..q] : rest;
            var slash = authorityAndPath.IndexOf('/');
            var host = (slash >= 0 ? authorityAndPath[..slash] : authorityAndPath).ToLowerInvariant();
            var path = slash >= 0 ? authorityAndPath[slash..] : "";
            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = part.IndexOf('=');
                var name = Uri.UnescapeDataString(eq < 0 ? part : part[..eq]);
                if (name.Length == 0) continue;
                dict[name] = eq < 0 ? "" : Uri.UnescapeDataString(part[(eq + 1)..]);
            }
            return new Link(scheme, host, path, dict);
        }
    }

    // otpauth://totp/Issuer:name?secret=…&issuer=…&algorithm=SHA1&digits=6&period=30
    private static QrAccount FromOtpauth(Link link)
    {
        if (link.Host == "hotp")
            throw new QrImportException("This is a counter-based (HOTP) code. FiveT makes time-based (TOTP) codes only, the kind VPN gateways use.");
        if (link.Host != "totp")
            throw new QrImportException($"This is a \"{link.Host}\" code. FiveT makes time-based (TOTP) codes only, the kind VPN gateways use.");
        var q = link.Query;
        CheckSupported(q.GetValueOrDefault("algorithm"),
            q.TryGetValue("digits", out var d) ? (int.TryParse(d, out var di) ? di : -1) : null,
            q.TryGetValue("period", out var p) ? (int.TryParse(p, out var pi) ? pi : -1) : null);
        if (!q.TryGetValue("secret", out var raw) || Normalized(raw) is not { } secret)
            throw new QrImportException("The link has no valid secret in it (secret= must be Base32).");
        // The label is "Issuer:name" or just "name"; the issuer parameter, when present, wins.
        var label = Uri.UnescapeDataString(link.Path.TrimStart('/'));
        string issuer = "", name = label;
        var colon = label.IndexOf(':');
        if (colon >= 0) { issuer = label[..colon].Trim(); name = label[(colon + 1)..].Trim(); }
        if (q.TryGetValue("issuer", out var i) && i.Trim().Length > 0) issuer = i.Trim();
        return new QrAccount(secret, issuer, name);
    }

    /// <summary>Refuses settings FiveT's TOTP cannot produce. null means "not given" (the defaults apply).</summary>
    private static void CheckSupported(string? algorithm, int? digits, int? period)
    {
        var odd = new List<string>();
        if (!string.IsNullOrEmpty(algorithm) && !algorithm.Equals("SHA1", StringComparison.OrdinalIgnoreCase)) odd.Add(algorithm.ToUpperInvariant());
        if (digits is { } d && d != 6) odd.Add(d > 0 ? $"{d} digits" : "an unknown number of digits");
        if (period is { } p && p != 30) odd.Add(p > 0 ? $"{p}-second steps" : "an unknown time step");
        if (odd.Count > 0)
            throw new QrImportException($"This code uses {string.Join(", ", odd)}. FiveT makes 6-digit, 30-second SHA-1 codes, "
                + "the standard for FortiToken and most VPN gateways, so it cannot import this one.");
    }

    /// <summary>Upper case, without spaces, dashes or padding; null unless it is valid, non-empty Base32.</summary>
    public static string? Normalized(string secret)
    {
        var s = new string(secret.ToUpperInvariant().Where(ch => ch is not (' ' or '-' or '=')).ToArray());
        return s.Length > 0 && Totp.Base32Decode(s) is { Length: > 0 } ? s : null;
    }

    // MARK: Google Authenticator export

    /// <summary>
    /// <c>otpauth-migration://offline?data=&lt;base64 MigrationPayload&gt;</c>: a protocol buffer holding one
    /// OtpParameters message (field 1) per account: 1 secret (bytes), 2 name, 3 issuer, 4 algorithm
    /// (1 = SHA-1), 5 digits (1 = six, 2 = eight), 6 type (1 = HOTP, 2 = TOTP). No period: always 30 s.
    /// </summary>
    private static IReadOnlyList<QrAccount> FromMigration(Link link)
    {
        if (link.Host != "offline" || !link.Query.TryGetValue("data", out var raw) || Base64(raw) is not { } data)
            throw new QrImportException("This Google Authenticator export could not be read.");
        var fields = Protobuf.Fields(data);
        // batch_size (3) and batch_index (4): an export too big for one QR code comes in several.
        long size = 0, index = 0;
        foreach (var (number, value) in fields)
        {
            if (value is not long v) continue;
            if (number == 3) size = v; else if (number == 4) index = v;
        }
        // Both numbers come from the export: a crafted one must not be trusted.
        var part = size > 1 ? (index >= 0 && index < size ? $"QR code {index + 1} of {size}" : $"part of a {size}-code export") : null;
        var accounts = new List<QrAccount>();
        var skipped = new List<string>();
        foreach (var (number, value) in fields)
        {
            if (number != 1 || value is not byte[] message) continue;
            byte[] secret = Array.Empty<byte>();
            string name = "", issuer = "";
            long algorithm = 0, digits = 0, type = 0;
            foreach (var (f, v) in Protobuf.Fields(message))
            {
                switch (f, v)
                {
                    case (1, byte[] b): secret = b; break;
                    case (2, byte[] b): name = Encoding.UTF8.GetString(b); break;
                    case (3, byte[] b): issuer = Encoding.UTF8.GetString(b); break;
                    case (4, long n): algorithm = n; break;
                    case (5, long n): digits = n; break;
                    case (6, long n): type = n; break;
                }
            }
            var account = new QrAccount(Base32Encode(secret), issuer, name, part);
            // 0 means "unspecified", which Google Authenticator treats as the default.
            if (type == 1 || !(algorithm is 0 or 1) || !(digits is 0 or 1) || secret.Length == 0)
            {
                skipped.Add(account.Label);
                continue;
            }
            accounts.Add(account);
        }
        if (accounts.Count > 0) return accounts;
        if (skipped.Count > 0)
            throw new QrImportException($"None of the accounts in this export makes 6-digit, 30-second SHA-1 codes ({string.Join(", ", skipped)}), so FiveT cannot use them."
                + (part != null ? $" This is {part} of the export: your VPN account may be in another one." : ""));
        throw new QrImportException("This Google Authenticator export has no accounts in it.");
    }

    /// <summary>Standard or URL-safe Base64, with or without padding.</summary>
    private static byte[]? Base64(string s)
    {
        var t = s.Trim().Replace('-', '+').Replace('_', '/').Replace(' ', '+');   // a '+' that became a space on the way
        while (t.Length % 4 != 0) t += "=";
        try { return Convert.FromBase64String(t); }
        catch (System.FormatException) { return null; }
    }

    private static string Base32Encode(byte[] data)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var sb = new StringBuilder();
        int buffer = 0, bits = 0;
        foreach (var x in data)
        {
            buffer = (buffer << 8) | x;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
            buffer &= (1 << bits) - 1;
        }
        if (bits > 0) sb.Append(alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    /// <summary>Just enough of the protocol buffer wire format to read a Google Authenticator export.</summary>
    private static class Protobuf
    {
        private const string Damaged = "This Google Authenticator export is damaged.";

        public static List<(int Number, object Value)> Fields(byte[] b)
        {
            var pos = 0;
            var output = new List<(int, object)>();
            long Varint()
            {
                long v = 0;
                for (var shift = 0; ; shift += 7)
                {
                    if (pos >= b.Length || shift >= 64) throw new QrImportException(Damaged);
                    var x = b[pos++];
                    v |= (long)(x & 0x7f) << shift;
                    if ((x & 0x80) == 0) return v;
                }
            }
            while (pos < b.Length)
            {
                var key = Varint();
                var number = (int)(key >> 3);
                switch (key & 7)
                {
                    case 0: output.Add((number, Varint())); break;
                    case 1: pos += 8; break;
                    case 2:
                        var n = Varint();
                        if (n < 0 || n > b.Length - pos) throw new QrImportException(Damaged);
                        output.Add((number, b[pos..(pos + (int)n)]));
                        pos += (int)n;
                        break;
                    case 5: pos += 4; break;
                    default: throw new QrImportException(Damaged);
                }
                if (pos > b.Length) throw new QrImportException(Damaged);
            }
            return output;
        }
    }
}
