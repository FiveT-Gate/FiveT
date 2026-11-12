using System.Text;

namespace FiveT;

/// <summary>
/// Replaces a file so that it always holds either the old content or the new one, never half of either:
/// the new content is written to a ".tmp" file next to it, flushed to disk, and moved over the original
/// in one step. A save that fails (disk full, access denied, power cut) leaves the original as it was.
/// </summary>
public static class SafeFile
{
    public static void Replace(string path, string text) => Replace(path, new UTF8Encoding(false).GetBytes(text));

    public static void Replace(string path, byte[] bytes)
    {
        var tmp = path + ".tmp";
        try
        {
            using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                fs.Write(bytes, 0, bytes.Length);
                fs.Flush(flushToDisk: true);
            }
            File.Move(tmp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }
}
