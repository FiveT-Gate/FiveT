namespace FiveT;

/// <summary>
/// A connection's "Extra openconnect options" (one per line) turned into openconnect arguments.
///
/// FiveT runs elevated, and connections.json is writable by any program of the user, so a line there
/// must never be able to run a program, plant a file, swap the certificate FiveT just checked, or
/// replace one of FiveT's own arguments. Those options are refused (and logged by name); everything
/// else is passed through as before. The Mac app does the same with an allowlist of openfortivpn keys.
/// </summary>
public static class ExtraOptions
{
    /// <summary>Long option names (without "--") that are never passed on.</summary>
    private static readonly HashSet<string> RefusedLong = new(StringComparer.OrdinalIgnoreCase)
    {
        // run a program or write a file as administrator
        "script", "script-tun", "csd-wrapper", "external-browser", "pid-file", "config", "syslog", "background",
        // would replace the certificate FiveT checked, or the login FiveT performs itself
        "servercert", "cookie", "cookie-on-stdin", "passwd-on-stdin", "non-inter", "no-passwd", "authenticate",
        // FiveT's own arguments
        "interface", "user", "protocol", "setuid",
        // client certificates and their keys: a file path read as administrator, not something FiveT supports
        "certificate", "sslkey", "key-password", "mca-certificate", "mca-key", "mca-key-password",
    };

    /// <summary>Short options (with their dash) that stand for the refused long ones.</summary>
    private static readonly HashSet<string> RefusedShort = new(StringComparer.Ordinal)
    {
        "-s", "-b", "-l", "-C", "-i", "-u", "-U", "-c", "-k", "-p",
    };

    public sealed record Result(List<string> Args, List<string> Ignored);

    /// <summary>Splits the text into arguments. <see cref="Result.Ignored"/> holds what was left out, as short log text.</summary>
    public static Result Parse(string? text)
    {
        var args = new List<string>();
        var ignored = new List<string>();
        foreach (var raw in (text ?? "").Replace("\r", "").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var name = FlagName(line);
            if (!line.StartsWith('-'))
            {
                // Not echoed: a line without a leading dash may be a password pasted into the wrong box.
                ignored.Add("a line that is not an openconnect option (options start with -)");
                continue;
            }
            if (IsRefused(name))
            {
                ignored.Add($"{name} (not allowed here)");
                continue;
            }
            // "--name value" is two arguments; "--name=value" and bare flags are one.
            var split = line.IndexOfAny(new[] { ' ', '\t' });
            if (line.IndexOf('=') < 0 && split > 0) { args.Add(line[..split]); args.Add(line[(split + 1)..].Trim()); }
            else args.Add(line);
        }
        return new Result(args, ignored);
    }

    /// <summary>The option names only (never their values, which can be secrets), for logs and diagnostics.</summary>
    public static string Describe(string? text)
    {
        var r = Parse(text);
        var names = new List<string>();
        for (var i = 0; i < r.Args.Count; i++)
        {
            var a = r.Args[i];
            if (!a.StartsWith('-')) continue;   // the value of the option before it
            names.Add(FlagName(a));
        }
        var s = names.Count == 0 ? "none" : string.Join(" ", names);
        return r.Ignored.Count == 0 ? s : $"{s} ({r.Ignored.Count} ignored)";
    }

    private static bool IsRefused(string name) =>
        name.StartsWith("--") ? RefusedLong.Contains(name[2..]) : RefusedShort.Contains(name);

    /// <summary>"--servername=x" → "--servername"; "-s foo" → "-s". Only meaningful for a line that starts with a dash.</summary>
    private static string FlagName(string line)
    {
        if (!line.StartsWith('-')) return "";
        if (!line.StartsWith("--")) return line[..Math.Min(2, line.Length)];
        var end = line.IndexOfAny(new[] { '=', ' ', '\t' });
        return end < 0 ? line : line[..end];
    }
}
