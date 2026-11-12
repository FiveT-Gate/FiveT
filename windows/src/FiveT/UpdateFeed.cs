using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace FiveT;

/// <summary>One installer the feed offers for this PC's architecture, already checked against the release key.</summary>
public sealed record UpdateRelease(string Version, string Arch, Uri Url, string Sha256, string? Notes);

/// <summary>
/// The Windows update feed: <c>latest-windows.json</c> on a rolling GitHub release (tag <c>windows-feed</c>).
///
/// <code>{ "version": "2.1.0", "notes": "...", "assets": { "x64": { "url": "...", "sha256": "...", "signature": "..." }, "arm64": { ... } } }</code>
///
/// The SHA-256 proves the download is the file the feed names, but the feed and the file come from the same
/// place, so whoever controls that place could name any file. FiveT therefore installs only a release whose
/// signature (ECDSA P-256 over version, architecture and checksum together) verifies with a key compiled in
/// here. The private half never leaves the person who publishes. Version and architecture are inside the
/// signed text, so an old signed installer cannot be passed off as a newer one or as another architecture.
/// To replace a key: add the new one to <see cref="ReleaseKeys"/>, ship a release signed with the old key,
/// sign later releases with the new one, then drop the old one.
/// </summary>
public static class UpdateFeed
{
    public static readonly Uri DefaultUrl = new("https://github.com/FiveT-Gate/FiveT/releases/download/windows-feed/latest-windows.json");

    /// <summary>Installers are only ever downloaded from this project's own releases.</summary>
    public const string UrlPrefix = "https://github.com/FiveT-Gate/FiveT/releases/download/";

    /// <summary>Public halves of the release keys (SubjectPublicKeyInfo, Base64).</summary>
    public static readonly string[] ReleaseKeys =
    {
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAESJPGRYIBXqzOHU5BVuEV4d/kBIia6d1OIInuvzxODBlrtrwdH1IZz+ZrUBa/vYGEZT6JXrZVkFJpaTV+/9k7RA==",
    };

    /// <summary>The exact bytes that are signed.</summary>
    public static byte[] Message(string version, string arch, string sha256) =>
        Encoding.UTF8.GetBytes($"FiveT Windows update\nversion={version}\narch={arch}\nsha256={sha256.ToLowerInvariant()}\n");

    public static bool IsValid(string? signature, string version, string arch, string sha256, IEnumerable<string> keys)
    {
        if (string.IsNullOrEmpty(signature) || version.Length == 0 || !IsSha256(sha256)) return false;
        byte[] sig;
        try { sig = Convert.FromBase64String(signature); } catch (FormatException) { return false; }
        var message = Message(version, arch, sha256);
        foreach (var k in keys)
        {
            try
            {
                using var key = ECDsa.Create();
                key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(k), out _);
                if (key.VerifyData(message, sig, HashAlgorithmName.SHA256)) return true;
            }
            catch (Exception e) when (e is CryptographicException or FormatException) { }
        }
        return false;
    }

    /// <summary>The release for <paramref name="arch"/>, or null with the reason when the feed is unusable or unsigned.</summary>
    public static UpdateRelease? Parse(string json, string arch, IEnumerable<string> keys, out string? problem)
    {
        problem = null;
        try
        {
            if (JsonNode.Parse(json) is not JsonObject root) { problem = "the update feed is not a JSON object"; return null; }
            var version = (string?)root["version"] ?? "";
            if (root["assets"]?[arch] is not JsonObject asset) { problem = $"the update feed has no {arch} installer"; return null; }
            var url = (string?)asset["url"] ?? "";
            var sha = ((string?)asset["sha256"] ?? "").ToLowerInvariant();
            if (!Version.TryParse(version, out _)) { problem = "the update feed names no valid version"; return null; }
            if (!IsValid((string?)asset["signature"], version, arch, sha, keys)) { problem = "the update is not signed with FiveT's release key"; return null; }
            if (!url.StartsWith(UrlPrefix, StringComparison.Ordinal) || !Uri.TryCreate(url, UriKind.Absolute, out var uri))
            { problem = "the update feed points outside FiveT's releases"; return null; }
            return new UpdateRelease(version, arch, uri, sha, (string?)root["notes"]);
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidCastException or FormatException)
        {
            problem = "the update feed could not be read";
            return null;
        }
    }

    public static bool IsNewer(string candidate, string current) =>
        Version.TryParse(candidate, out var c) && Version.TryParse(current, out var cur) && c > cur;

    private static bool IsSha256(string s) => s.Length == 64 && s.All(Uri.IsHexDigit);
}
