namespace FiveT;

/// <summary>
/// The .fivet backup file (Settings → General → Backup). It has the layout of the Mac app's connections.json, so a file
/// made here opens on a Mac and the other way round; unlike connections.json on this PC its secrets are plain text,
/// because DPAPI text only opens for the same Windows account on the same PC.
/// </summary>
public static class Backup
{
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
