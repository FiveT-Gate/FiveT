namespace FiveT;

/// <summary>
/// Cleans text pasted into a connection's fields (the Mac's 1.13.3, Connection.cleanPastedFields): a
/// gateway or user name pasted with blank lines, or as a whole "remote vpn.example.com 443" line copied
/// from an OpenVPN profile, used to stop a connection from starting ("contains a line break") for no
/// reason the user could see. <see cref="Connection.CleanPastedFields"/> applies it to a connection (as
/// the text lands in Settings, and once at start for connections saved that way).
/// </summary>
public static class FieldCleaner
{
    /// <summary>Swift's Character.isNewline: LF, VT, FF, CR, NEL, line and paragraph separator.</summary>
    public static bool IsNewline(char ch) => ch is '\n' or '\r' or '\u000B' or '\u000C' or '\u0085' or '\u2028' or '\u2029';

    /// <summary>The first line that is not blank, trimmed: what a paste of "name\n\n" means (the Mac's firstLine).</summary>
    public static string Line(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var start = 0;
        for (var i = 0; i <= text.Length; i++)
        {
            if (i < text.Length && !IsNewline(text[i])) continue;
            var line = text[start..i].Trim(' ', '\t');
            if (line.Length > 0) return line;
            start = i + 1;
        }
        return "";
    }

    /// <summary>
    /// A gateway as typed or pasted: one line, and without the word "remote" in front when the text is a
    /// line copied from an OpenVPN profile ("remote link1.example.com"). The Mac's cleanedHost.
    /// </summary>
    public static string CleanedHost(string? raw)
    {
        var line = Line(raw);
        var words = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        return words.Length >= 2 && words[0].Equals("remote", StringComparison.OrdinalIgnoreCase) ? words[1] : line;
    }

    /// <summary>
    /// Windows extra, for a paste into the gateway box and for leaving it: besides <see cref="CleanedHost"/>,
    /// "remote host 443" and a pasted address such as https://host:10443/realm also give the port.
    /// <c>Port</c> is null when the text names none. Text with spaces that is no "remote" line is kept as typed.
    /// </summary>
    public static (string Host, int? Port) Gateway(string? text)
    {
        var line = Line(text);
        // Zero-width and direction marks come along when a name is copied from a web page or a PDF; DNS
        // answers "No such host is known" for them. ZWNJ/ZWJ stay: some scripts need them inside a name.
        if (line.Any(IsHidden)) line = new string(line.Where(ch => !IsHidden(ch)).ToArray()).Trim();
        // FortiClient takes "gw1.example.com;gw2.example.com" (failover) and connects to the first.
        if (line.Contains(';')) line = line[..line.IndexOf(';')].Trim();
        if (line.Length == 0) return ("", null);
        int? port = null;

        var words = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length >= 2 && words[0].Equals("remote", StringComparison.OrdinalIgnoreCase))
        {
            line = words[1];
            if (words.Length >= 3 && ParsePort(words[2]) is { } p) port = p;
        }
        else if (words.Length > 1)
        {
            // A host name has no spaces: keep what was typed rather than guess which word is the gateway.
            return (line, null);
        }

        foreach (var scheme in new[] { "https://", "http://" })
            if (line.StartsWith(scheme, StringComparison.OrdinalIgnoreCase)) { line = line[scheme.Length..]; break; }
        var slash = line.IndexOf('/');
        if (slash >= 0) line = line[..slash];

        // host:port, [v6]:port. A bare IPv6 address has several colons and is left whole.
        if (line.StartsWith('['))
        {
            var close = line.IndexOf(']');
            if (close > 0)
            {
                if (close + 1 < line.Length && line[close + 1] == ':' && ParsePort(line[(close + 2)..]) is { } p6) port = p6;
                line = line[1..close];
            }
        }
        else if (line.Count(ch => ch == ':') == 1)
        {
            var colon = line.IndexOf(':');
            if (ParsePort(line[(colon + 1)..]) is { } p4)
            {
                port = p4;
                line = line[..colon];
            }
        }
        return (line.Trim(), port);
    }

    private static bool IsHidden(char ch) =>
        ch is not ('‌' or '‍') && char.GetUnicodeCategory(ch) == System.Globalization.UnicodeCategory.Format;

    /// <summary>
    /// The name as DNS takes it: an international name (münchen.de) goes as punycode. .NET and openconnect
    /// hand the text to the resolver as it is and get "No such host is known"; FortiClient converts it.
    /// </summary>
    public static string AsciiHost(string host)
    {
        if (host.All(ch => ch < 128)) return host;
        try { return new System.Globalization.IdnMapping().GetAscii(host); }
        catch (ArgumentException) { return host; }   // not a valid name: the resolver's own error says so
    }

    private static int? ParsePort(string s) =>
        int.TryParse(s, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var p) && p is >= 1 and <= 65535 ? p : null;
}
