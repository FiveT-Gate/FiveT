using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Xunit;

namespace FiveT.Tests;

/// <summary>The update feed's signature rules, with a key made for the test (the real private key is never in the tests).</summary>
public class UpdateTests
{
    private const string Sha = "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12";
    private const string Url = UpdateFeed.UrlPrefix + "windows-v9.9.9/FiveT-Setup-9.9.9.exe";

    private static (string pub, ECDsa key) NewKey()
    {
        var k = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return (Convert.ToBase64String(k.ExportSubjectPublicKeyInfo()), k);
    }

    private static string Sign(ECDsa k, string version, string arch, string sha) =>
        Convert.ToBase64String(k.SignData(UpdateFeed.Message(version, arch, sha), HashAlgorithmName.SHA256));

    private static string Feed(ECDsa k, string version = "9.9.9", string url = Url, string sha = Sha, string? sig = null) =>
        new JsonObject
        {
            ["version"] = version,
            ["notes"] = "Fixes.",
            ["assets"] = new JsonObject { ["x64"] = new JsonObject { ["url"] = url, ["sha256"] = sha, ["signature"] = sig ?? Sign(k, version, "x64", sha) } },
        }.ToJsonString();

    [Fact]
    public void A_signed_release_is_accepted()
    {
        var (pub, k) = NewKey();
        var r = UpdateFeed.Parse(Feed(k), "x64", new[] { pub }, out var problem);
        Assert.Null(problem);
        Assert.Equal(("9.9.9", "x64", Sha), (r!.Version, r.Arch, r.Sha256));
    }

    [Fact]
    public void A_release_signed_by_another_key_is_refused()
    {
        var (pub, _) = NewKey();
        var (_, other) = NewKey();
        Assert.Null(UpdateFeed.Parse(Feed(other), "x64", new[] { pub }, out var problem));
        Assert.Contains("not signed", problem);
    }

    [Theory]
    [InlineData("version")]   // an old signed installer relabelled as a newer one
    [InlineData("sha")]       // another file under the same signature
    [InlineData("arch")]      // the x64 installer offered as arm64
    public void Changing_anything_that_is_signed_breaks_the_signature(string what)
    {
        var (pub, k) = NewKey();
        var sig = Sign(k, "9.9.9", "x64", Sha);
        var json = what switch
        {
            "version" => Feed(k, version: "10.0.0", sig: sig),
            "sha" => Feed(k, sha: new string('0', 64), sig: sig),
            _ => Feed(k, sig: sig).Replace("\"x64\"", "\"arm64\""),
        };
        Assert.Null(UpdateFeed.Parse(json, what == "arch" ? "arm64" : "x64", new[] { pub }, out _));
    }

    [Theory]
    [InlineData("http://github.com/FiveT-Gate/FiveT/releases/download/windows-v9.9.9/x.exe")]
    [InlineData("https://example.com/FiveT-Setup.exe")]
    [InlineData("https://github.com/FiveT-Gate/FiveT/releases/download.evil.example/x.exe")]
    public void A_download_outside_the_projects_releases_is_refused(string url)
    {
        var (pub, k) = NewKey();
        Assert.Null(UpdateFeed.Parse(Feed(k, url: url), "x64", new[] { pub }, out var problem));
        Assert.Contains("outside", problem);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{\"version\":\"9.9.9\"}")]
    public void A_broken_feed_is_refused_without_throwing(string json)
    {
        var (pub, _) = NewKey();
        Assert.Null(UpdateFeed.Parse(json, "x64", new[] { pub }, out var problem));
        Assert.False(string.IsNullOrEmpty(problem));
    }

    [Fact]
    public void The_compiled_in_key_is_a_valid_public_key()
    {
        foreach (var k in UpdateFeed.ReleaseKeys)
        {
            using var e = ECDsa.Create();
            e.ImportSubjectPublicKeyInfo(Convert.FromBase64String(k), out _);
        }
    }

    [Theory]
    [InlineData("2.1.1", "2.1.0", true)]
    [InlineData("2.10.0", "2.9.0", true)]
    [InlineData("2.1.0", "2.1.0", false)]
    [InlineData("2.0.9", "2.1.0", false)]
    [InlineData("2.1.0", "dev", false)]
    public void Only_a_newer_version_counts(string candidate, string current, bool newer) =>
        Assert.Equal(newer, UpdateFeed.IsNewer(candidate, current));
}
