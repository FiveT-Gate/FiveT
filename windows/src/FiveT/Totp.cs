using System.Security.Cryptography;

namespace FiveT;

/// <summary>
/// RFC 6238 time-based one-time passwords (the same algorithm FortiToken, Google Authenticator,
/// etc. use): HMAC-SHA1, 30 second steps, 6 digits.
/// </summary>
public static class Totp
{
    public const int Period = 30;

    public static byte[]? Base32Decode(string input)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var cleaned = new string(input.ToUpperInvariant().Where(ch => ch != '=' && ch != ' ' && ch != '-').ToArray());
        if (cleaned.Length == 0) return null;
        var outBytes = new List<byte>();
        int bits = 0, value = 0;
        foreach (var ch in cleaned)
        {
            var v = alphabet.IndexOf(ch);
            if (v < 0) return null;
            value = (value << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                outBytes.Add((byte)((value >> (bits - 8)) & 0xff));
                bits -= 8;
                value &= (1 << bits) - 1;
            }
        }
        return outBytes.ToArray();
    }

    public static string? Code(string secret, int digits = 6, DateTime? at = null)
    {
        var key = Base32Decode(secret);
        if (key == null || key.Length == 0) return null;
        var t = (at ?? DateTime.UtcNow);
        var counter = (ulong)(new DateTimeOffset(t.ToUniversalTime()).ToUnixTimeSeconds() / Period);
        var msg = new byte[8];
        for (var i = 7; i >= 0; i--) { msg[i] = (byte)(counter & 0xff); counter >>= 8; }
        var mac = HMACSHA1.HashData(key, msg);
        var offset = mac[^1] & 0x0f;
        var binary = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
        var modulo = (int)Math.Pow(10, digits);
        return (binary % modulo).ToString().PadLeft(digits, '0');
    }

    /// <summary>
    /// Whole seconds left in the current 30 s window, counted from the exact moment (milliseconds), as
    /// the Mac does: at 25.9 s this is 4, not 5, so the "never send a code with ≤ 4 s left" rule has
    /// the same edge on both platforms.
    /// </summary>
    public static int SecondsRemaining(DateTime? at = null)
    {
        var ms = new DateTimeOffset((at ?? DateTime.UtcNow).ToUniversalTime()).ToUnixTimeMilliseconds();
        return (int)(Period - (ms / 1000.0) % Period);
    }
}
