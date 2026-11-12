using System.Security.Cryptography;
using System.Text;

namespace FiveT;

/// <summary>
/// The .fivet backup file (Settings → General → Backup). Inside it has the layout of the Mac app's connections.json,
/// with its secrets in plain text (DPAPI text only opens for the same Windows account on the same PC), but the file
/// itself is always encrypted (<see cref="Seal"/>), so only FiveT can read it. A plain file, such as the Mac's or one
/// from FiveT 2.2.0, is still accepted on import (<see cref="Open"/>).
/// </summary>
public static class Backup
{
    private static readonly byte[] Magic = "FIVETBK1"u8.ToArray();

    // shortcut: one key built into FiveT, public with the source, so it keeps the file from other programs and eyes but not from
    // someone who reads this code. A password asked at export would be real protection; upgrade then.
    private static readonly byte[] Key = Convert.FromHexString("b62e0cd9876744ab4190dfb1e748a67854b8d0e1a43e81259ffac40cbd289476");

    /// <summary>The name the save dialog offers: today's date, an underscore, the backup name (YYYY-MM-DD_FiveT.fivet).</summary>
    public static string DefaultFileName(DateTime now) => $"{now:yyyy-MM-dd}_FiveT.fivet";

    /// <summary>Encrypts the backup text (AES-256-GCM): the file is the magic, a fresh 12-byte nonce, the cipher text and the 16-byte tag.</summary>
    public static byte[] Seal(string text)
    {
        var plain = new UTF8Encoding(false).GetBytes(text);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(Key, 16)) aes.Encrypt(nonce, plain, cipher, tag, Magic);
        return [.. Magic, .. nonce, .. cipher, .. tag];
    }

    /// <summary>
    /// The text of a backup file. An encrypted file is decrypted (a damaged or foreign one throws
    /// <see cref="InvalidDataException"/>); a file without the magic is taken as plain text, as the Mac writes it.
    /// </summary>
    public static string Open(byte[] file)
    {
        if (!file.AsSpan().StartsWith(Magic))
            return new StreamReader(new MemoryStream(file), Encoding.UTF8, detectEncodingFromByteOrderMarks: true).ReadToEnd();
        if (file.Length < Magic.Length + 12 + 16) throw new InvalidDataException("This FiveT backup is damaged.");
        var body = file.AsSpan(Magic.Length);
        var plain = new byte[body.Length - 12 - 16];
        try
        {
            using var aes = new AesGcm(Key, 16);
            aes.Decrypt(body[..12], body.Slice(12, plain.Length), body[^16..], plain, Magic);
        }
        catch (CryptographicException) { throw new InvalidDataException("This FiveT backup is damaged or was not made by FiveT."); }
        return new UTF8Encoding(false).GetString(plain);
    }

    private static readonly DateTime MacEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    /// <summary>A date the way the Mac's JSONEncoder writes it: seconds since 2001-01-01 00:00:00 UTC.</summary>
    public static double MacSeconds(DateTime when) => (when.ToUniversalTime() - MacEpoch).TotalSeconds;

    /// <summary>
    /// The saved connections with the imported ones added. An imported connection with the id of a saved one replaces it
    /// where it stands (as on the Mac); the others go to the end.
    /// </summary>
    public static (List<Connection> List, int Added, int Replaced) Merge(IEnumerable<Connection> saved, IEnumerable<Connection> imported)
    {
        var list = saved.ToList();
        int added = 0, replaced = 0;
        foreach (var c in imported)
        {
            var i = list.FindIndex(x => x.Id == c.Id);
            if (i >= 0) { list[i] = c; replaced++; }
            else { list.Add(c); added++; }
        }
        return (list, added, replaced);
    }
}
