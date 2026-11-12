using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FiveT.Core;

/// <summary>JSON helpers shared by the app, the bridge and the CLI.</summary>
public static class Json
{
    // A resolver is required: JsonNode.ToJsonString(options) refuses options without one when the
    // tree contains values created through JsonValue.Create<T> / JsonArray.Add<T>.
    public static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
    public static readonly JsonSerializerOptions Compact = new()
    {
        WriteIndented = false,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
    };

    public static string ToPretty(JsonNode? node) => node?.ToJsonString(Pretty) ?? "null";
    public static string ToCompact(JsonNode? node) => node?.ToJsonString(Compact) ?? "null";

    public static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text); } catch { return null; }
    }

    public static JsonArray Array(IEnumerable<string> items)
    {
        var a = new JsonArray();
        foreach (var s in items) a.Add(JsonValue.Create(s));   // primitive node, no serializer needed
        return a;
    }

    public static string Iso(DateTime d) =>
        d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public static int? Int(JsonNode? v)
    {
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<int>(out var i)) return i;
            if (jv.TryGetValue<long>(out var l)) return (int)l;
            if (jv.TryGetValue<double>(out var d)) return (int)d;
            if (jv.TryGetValue<string>(out var s) && int.TryParse(s, out var p)) return p;
        }
        return null;
    }

    public static bool? Bool(JsonNode? v)
    {
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<bool>(out var b)) return b;
            if (jv.TryGetValue<string>(out var s) && bool.TryParse(s, out var p)) return p;
        }
        return null;
    }

    public static string? Str(JsonNode? v) => v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : null;
}

public sealed class RpcException : Exception
{
    public int Code { get; }
    public RpcException(int code, string message) : base(message) => Code = code;
}

/// <summary>Writes whole lines to a stream, serialised so concurrent replies never interleave.</summary>
public sealed class LineWriter
{
    private readonly Stream _s;
    private readonly object _lock = new();

    public LineWriter(Stream s) => _s = s;

    public void Send(JsonNode obj) => Write(Encoding.UTF8.GetBytes(Json.ToCompact(obj) + "\n"));

    public void Write(byte[] data)
    {
        lock (_lock)
        {
            try { _s.Write(data, 0, data.Length); _s.Flush(); }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
    }
}

/// <summary>Reads newline-delimited JSON objects from a stream.</summary>
public sealed class LineReader
{
    /// <summary>
    /// The longest line accepted. A peer that never sends a newline would otherwise make this buffer
    /// grow until the process runs out of memory; the biggest honest line is a diagnostics text.
    /// </summary>
    public const int MaxLineBytes = 4 * 1024 * 1024;

    private readonly Stream _s;
    private readonly byte[] _chunk = new byte[65536];
    private readonly MemoryStream _buf = new();
    private bool _first = true;

    public LineReader(Stream s) => _s = s;

    /// <summary>True when <see cref="NextLine"/> returned null because a line passed <see cref="MaxLineBytes"/> (not EOF).</summary>
    public bool TooLong { get; private set; }

    /// <summary>Next complete line, or null at EOF / error / a line that is too long (see <see cref="TooLong"/>).</summary>
    public string? NextLine()
    {
        while (true)
        {
            var bytes = _buf.GetBuffer();
            var len = (int)_buf.Length;
            var nl = System.Array.IndexOf(bytes, (byte)'\n', 0, len);
            if ((nl >= 0 ? nl : len) > MaxLineBytes)
            {
                TooLong = true;
                _buf.SetLength(0);
                return null;
            }
            if (nl >= 0)
            {
                var line = Encoding.UTF8.GetString(bytes, 0, nl).TrimEnd('\r');
                // Windows tools (PowerShell's pipe, Notepad) put a byte-order mark in front of the first
                // line; JSON does not allow one, so without this the first message would fail to parse.
                if (_first) line = line.TrimStart('﻿');
                _first = false;
                var rest = len - nl - 1;
                var tail = new byte[rest];
                Buffer.BlockCopy(bytes, nl + 1, tail, 0, rest);
                _buf.SetLength(0);
                _buf.Write(tail, 0, rest);
                return line;
            }
            int n;
            try { n = _s.Read(_chunk, 0, _chunk.Length); }
            catch (IOException) { return null; }
            catch (ObjectDisposedException) { return null; }
            if (n <= 0) return null;
            _buf.Write(_chunk, 0, n);
        }
    }
}
