using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace FiveT.Tests;

internal static class Init
{
    // Before anything touches Paths: the log of a test run goes to FiveT-dev, never into the real app's log.
    [ModuleInitializer]
    internal static void Dev() => Environment.SetEnvironmentVariable("FIVET_DEV", "1");
}

/// <summary>A plain list standing in for the saved connections. Every value in these tests is made up.</summary>
internal sealed class FakeStore : IConnectionList
{
    public List<Connection> List = new();
    public IReadOnlyList<Connection> Connections => List;
    public Connection Add(Connection c) { List.Add(c); return c; }
    public void Remove(Guid id) => List.RemoveAll(c => c.Id == id);
}

internal sealed class TempDir : IDisposable
{
    public string Path { get; } = Directory.CreateTempSubdirectory("fivet tests ").FullName;   // a space in the path, on purpose
    public string File(string name, string text) { var p = System.IO.Path.Combine(Path, name); System.IO.File.WriteAllText(p, text); return p; }
    public void Dispose() { try { Directory.Delete(Path, true); } catch { } }
}

public class PastedFields
{
    [Theory]
    [InlineData("\n\nvpn.example.com\n", "vpn.example.com")]
    [InlineData("remote link1.example.com 443 udp", "link1.example.com")]
    [InlineData("  vpn.example.com  ", "vpn.example.com")]
    [InlineData("remote.example.com", "remote.example.com")]
    public void Host_is_cleaned(string pasted, string expected) => Assert.Equal(expected, FieldCleaner.CleanedHost(pasted));

    [Fact]
    public void Gateway_takes_the_port_out_of_an_address()
    {
        Assert.Equal(("vpn.example.com", 10443), FieldCleaner.Gateway("https://vpn.example.com:10443/realm"));
        Assert.Equal(("link1.example.com", 443), FieldCleaner.Gateway("remote link1.example.com 443"));
        Assert.Equal(("2001:db8::1", 8443), FieldCleaner.Gateway("[2001:db8::1]:8443"));
        Assert.Equal(("2001:db8::1", (int?)null), FieldCleaner.Gateway("2001:db8::1"));
    }

    [Fact]
    public void A_saved_connection_is_repaired_and_valid_text_is_left_alone()
    {
        var c = new Connection { Name = "Office\n", Host = "\nremote vpn.example.com 443\n", Username = "ali reza", Password = "pa ss\n", TotpSecret = "JBSW Y3DP\nEHPK 3PXP" };
        var changed = c.CleanPastedFields();
        Assert.Equal("Office", c.Name);
        Assert.Equal("vpn.example.com", c.Host);
        Assert.Equal("ali reza", c.Username);            // a space inside a user name is typing, not a paste
        Assert.Equal("pa ss", c.Password);
        Assert.Equal("JBSW Y3DPEHPK 3PXP", c.TotpSecret);
        Assert.Equal(new[] { "name", "gateway", "password", "TOTP secret" }, changed);
        Assert.Empty(c.CleanPastedFields());
    }

    [Fact]
    public void A_line_break_inside_a_password_stays_for_the_launch_to_refuse()
    {
        var c = new Connection { Password = "first\nsecond" };
        c.CleanPastedFields();
        Assert.Equal("first\nsecond", c.Password);
    }
}

public class LoginGuardRules
{
    private static readonly Guid A = Guid.NewGuid();

    [Fact]
    public void Two_failures_limit_a_gateway_and_a_success_clears_it()
    {
        using var dir = new TempDir();
        var now = new DateTime(2026, 11, 10, 9, 0, 0, DateTimeKind.Utc);
        var g = new LoginGuard(dir.Path, () => now);
        Assert.False(g.IsLimited("vpn.example.com"));
        Assert.Equal(1, g.RecordFailure("vpn.example.com", A, OtpMode.AppendToPassword, true));
        Assert.False(g.IsLimited("vpn.example.com"));
        Assert.Equal(2, g.RecordFailure("vpn.example.com", A, OtpMode.Separate, true));
        Assert.True(g.IsLimited("vpn.example.com"));
        Assert.False(g.IsLimited("other.example.com"));   // counted per gateway
        Assert.Equal(2, g.RecordSuccess("vpn.example.com"));
        Assert.False(g.IsLimited("vpn.example.com"));
    }

    [Fact]
    public void Failures_are_forgotten_three_hours_after_the_last_one()
    {
        using var dir = new TempDir();
        var now = new DateTime(2026, 11, 10, 9, 0, 0, DateTimeKind.Utc);
        var g = new LoginGuard(dir.Path, () => now);
        g.RecordFailure("vpn.example.com", A, null, false);
        g.RecordFailure("vpn.example.com", A, null, false);
        Assert.Equal(now.AddHours(3), g.ClearsAt("vpn.example.com"));
        now = now.AddHours(2.9);
        Assert.True(g.IsLimited("vpn.example.com"));
        now = now.AddHours(0.2);
        Assert.False(g.IsLimited("vpn.example.com"));
        Assert.Equal(1, g.RecordFailure("vpn.example.com", A, null, false));   // starts over
    }

    [Fact]
    public void Two_copies_of_the_app_share_one_count()
    {
        using var dir = new TempDir();
        var now = new DateTime(2026, 11, 10, 9, 0, 0, DateTimeKind.Utc);
        var first = new LoginGuard(dir.Path, () => now);
        var second = new LoginGuard(dir.Path, () => now);
        first.RecordFailure("vpn.example.com", A, OtpMode.AppendToPassword, true);
        Assert.Equal(2, second.RecordFailure("vpn.example.com", A, OtpMode.AppendToPassword, true));
        Assert.True(first.IsLimited("vpn.example.com"));
        var f = first.Failures("vpn.example.com")[0];
        Assert.Equal((A, OtpMode.AppendToPassword, true), (f.Connection!.Value, f.OtpMode!.Value, f.Rejected!.Value));
    }

    [Fact]
    public void A_damaged_count_file_does_not_forget_what_this_copy_knows()
    {
        using var dir = new TempDir();
        var g = new LoginGuard(dir.Path, () => DateTime.UtcNow);
        g.RecordFailure("vpn.example.com", A, null, true);
        g.RecordFailure("vpn.example.com", A, null, true);
        dir.File("login-failures.json", "{ not json");
        Assert.True(g.IsLimited("vpn.example.com"));
    }
}

public class SafeFiles
{
    [Fact]
    public void A_failed_save_leaves_the_previous_file_as_it_was()
    {
        using var dir = new TempDir();
        var path = dir.File("connections.json", "old");
        SafeFile.Replace(path, "new");
        Assert.Equal("new", File.ReadAllText(path));
        // The target cannot be replaced while another program holds it open without sharing.
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.ThrowsAny<Exception>(() => SafeFile.Replace(path, "newer"));
        Assert.Equal("new", File.ReadAllText(path));
        Assert.False(File.Exists(path + ".tmp"));
    }
}

public class OpenVpnProfiles
{
    private const string Ca = "<ca>\n-----BEGIN CERTIFICATE-----\nMIIBsynthetic\n-----END CERTIFICATE-----\n</ca>\n";
    private const string Basic = "client\ndev tun\nproto udp\nremote vpn.example.com 1194\nauth-user-pass\nstatic-challenge \"Enter code\" 1\n" + Ca;

    [Fact]
    public void A_profile_becomes_a_connection()
    {
        var imp = OpenVpnProfile.ImportProfile(Basic, "Office", null);
        Assert.Equal(("vpn.example.com", 1194, true), (imp.Host, imp.Port, imp.StaticChallenge));
        Assert.DoesNotContain("static-challenge", imp.Text);
        Assert.Empty(OpenVpnProfile.Problems(imp.Text));
        var c = OpenVpnProfile.ConnectionFrom(imp, new[] { "Office" });
        Assert.Equal(("Office 2", VpnKind.OpenVpn, OtpMode.Separate), (c.Name, c.Kind, c.OtpMode));
    }

    [Fact]
    public void Windscribe_style_profile_with_inline_keys_and_scripts_is_taken_without_the_scripts()
    {
        var text = "client\ndev tun\nproto udp\nremote ca.windscribe.example 443\nnobind\nauth-user-pass\nresolv-retry infinite\nauth SHA512\ncipher AES-256-GCM\n"
                   + "verb 2\nmute-replay-warnings\nremote-cert-tls server\nkey-direction 1\nscript-security 2\nup /etc/openvpn/update-resolv-conf\nblock-outside-dns\n"
                   + Ca + "<tls-auth>\n-----BEGIN OpenVPN Static key V1-----\n00ff\n-----END OpenVPN Static key V1-----\n</tls-auth>\n";
        var imp = OpenVpnProfile.ImportProfile(text, "", null);
        Assert.Equal("ca.windscribe.example", imp.Name);
        Assert.Contains("scripts: script-security, up", imp.Dropped);
        Assert.Contains("block-outside-dns", imp.Text);
        Assert.False(OpenVpnProfile.NeedsTapDriver(imp.Text));
    }

    [Theory]
    [InlineData("plugin evil.dll")]
    [InlineData("setenv opt up evil.cmd")]
    [InlineData("\"up\" evil.cmd")]
    [InlineData("config other.ovpn")]
    [InlineData("tls-verify evil.cmd")]
    [InlineData("ca C:\\\\certs\\\\ca.crt")]
    [InlineData("dev tap0")]
    [InlineData("management 127.0.0.1 7505")]
    [InlineData("<ca>\nx\n</ca>x\nup evil.cmd\n</ca>")]
    public void What_would_run_or_read_something_as_administrator_is_refused(string line)
    {
        Assert.NotEmpty(OpenVpnProfile.Problems("client\ndev tun\nremote vpn.example.com 1194\n" + line + "\n"));
    }

    [Fact]
    public void A_malformed_or_cut_off_profile_says_why()
    {
        Assert.Contains("no server", Assert.Throws<OpenVpnProfileException>(() => OpenVpnProfile.ImportProfile("client\ndev tun\n", "x", null)).Message);
        Assert.Contains("not closed", Assert.Throws<OpenVpnProfileException>(() => OpenVpnProfile.ImportProfile("remote a.example 1\n<ca>\nabc\n", "x", null)).Message);
        Assert.Contains("passphrase", Assert.Throws<OpenVpnProfileException>(() => OpenVpnProfile.ImportProfile("remote a.example 1\naskpass\n", "x", null)).Message);
    }

    [Fact]
    public void Files_are_read_only_from_next_to_the_profile()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(Path.Combine(dir.Path, "profile"));
        File.WriteAllText(Path.Combine(dir.Path, "secret.txt"), "outside\nsecret\n");
        File.WriteAllText(Path.Combine(dir.Path, "profile", "login.txt"), "\uFEFFuser\r\npass word\r\n");
        var folder = Path.Combine(dir.Path, "profile");
        var ok = OpenVpnProfile.ImportProfile("remote a.example 1194\ndev tun\nauth-user-pass login.txt\n", "x", folder);
        Assert.Equal(("user", "pass word"), (ok.Username, ok.Password));
        foreach (var path in new[] { "..\\\\secret.txt", Path.Combine(dir.Path, "secret.txt").Replace("\\", "\\\\"), "~/secret.txt" })
            Assert.Contains("outside its own folder", Assert.Throws<OpenVpnProfileException>(
                () => OpenVpnProfile.ImportProfile($"remote a.example 1194\nauth-user-pass {path}\n", "x", folder)).Message);
    }

    [Fact]
    public void The_login_goes_inline_and_a_one_time_code_as_a_static_challenge_answer()
    {
        var c = new Connection { Kind = VpnKind.OpenVpn, OvpnProfile = "remote a.example 1194\nauth-user-pass\n", Username = "user", Password = "pw", OtpMode = OtpMode.Separate };
        var text = OpenVpnProfile.ForLaunch(c, "123456");
        Assert.EndsWith("<auth-user-pass>\nuser\nSCRV1:cHc=:MTIzNDU2\n</auth-user-pass>\n", text);
        Assert.Equal(1, text.Split("auth-user-pass").Length - 2);   // the bare line is gone, the block is there once
        Assert.Empty(OpenVpnProfile.Problems(text));
        c.OtpMode = OtpMode.AppendToPassword;
        Assert.Contains("\nuser\npw123456\n", OpenVpnProfile.ForLaunch(c, "123456"));
    }

    [Fact]
    public void OpenVpn_Connect_names_are_kept()
    {
        using var dir = new TempDir();
        var inner = new JsonObject { ["status"] = new JsonObject { ["profiles"] = new JsonObject { ["1781727071873"] = new JsonObject { ["profileDisplayName"] = "دفتر تهران [Office]", ["profileName"] = "x" } }.ToJsonString() }.ToJsonString() };
        var state = dir.File("config.json", new JsonObject { ["persist:root"] = inner.ToJsonString() }.ToJsonString());
        dir.File("1781727071873.ovpn", "client\ndev tun\nremote vpn.example.com 443 tcp\n");
        var store = new FakeStore();
        var o = VpnImport.AddOpenVpnConnect(store, dir.Path, state);
        Assert.Equal("دفتر تهران [Office]", Assert.Single(o.Added).Name);
        Assert.Contains("already here", VpnImport.AddOpenVpnConnect(store, dir.Path, state).Message);
    }
}

public class V2RayLinks
{
    private const string Id = "11111111-2222-3333-4444-555555555555";

    [Fact]
    public void Vless_reality_link()
    {
        var imp = V2RayConfig.Parse($"vless://{Id}@203.0.113.10:443?type=tcp&security=reality&pbk=PUBKEY&sid=ab12&sni=www.example.com&fp=chrome&flow=xtls-rprx-vision#Tehran%20%D8%AA%D8%B3%D8%AA 🙂");
        Assert.Equal(("203.0.113.10", 443, "Tehran تست 🙂"), (imp.Host, imp.Port, imp.Name));
        var json = V2RayConfig.ToJson(imp.Outbound);
        Assert.Contains("\"flow\":\"xtls-rprx-vision\"", json);
        Assert.Contains("\"realitySettings\":{\"fingerprint\":\"chrome\",\"publicKey\":\"PUBKEY\",\"serverName\":\"www.example.com\",\"shortId\":\"ab12\"}", json);
        Assert.Equal("VLESS · Reality", V2RayConfig.Summary(json));
    }

    [Fact]
    public void Vmess_base64_trojan_hysteria2_and_shadowsocks_links()
    {
        var vmess = "vmess://" + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{{\"v\":\"2\",\"ps\":\"vm\",\"add\":\"vm.example.com\",\"port\":\"8443\",\"id\":\"{Id}\",\"aid\":0,\"net\":\"ws\",\"path\":\"/p\",\"host\":\"h.example.com\",\"tls\":\"tls\"}}"));
        var v = V2RayConfig.Parse(vmess);
        Assert.Equal(("vm.example.com", 8443, "vm"), (v.Host, v.Port, v.Name));
        Assert.Contains("\"serverName\":\"h.example.com\"", V2RayConfig.ToJson(v.Outbound));

        Assert.Equal("Trojan · TLS · grpc", V2RayConfig.Summary(V2RayConfig.ToJson(V2RayConfig.Parse("trojan://pw@t.example.com:443?type=grpc&serviceName=svc#t").Outbound)));
        Assert.Contains("\"alpn\":[\"h3\"]", V2RayConfig.ToJson(V2RayConfig.Parse("hy2://auth@h.example.com:8443/?sni=h.example.com#h").Outbound));

        var user = Convert.ToBase64String(Encoding.UTF8.GetBytes("chacha20-ietf-poly1305:secret/pw")).TrimEnd('=');
        var ss = V2RayConfig.Parse($"ss://{user}@198.51.100.7:8388/?outline=1&prefix=%16%03#Outline%20server");
        Assert.Equal(("198.51.100.7", 8388, "Outline server", true), (ss.Host, ss.Port, ss.Name, ss.Prefix));
        var whole = Convert.ToBase64String(Encoding.UTF8.GetBytes("aes-256-gcm:pw@ss.example.com:443"));
        Assert.Equal("ss.example.com", V2RayConfig.Parse($"ss://{whole}#old").Host);
    }

    [Theory]
    [InlineData("vless://203.0.113.10:443", "no user ID")]
    [InlineData("vless://id@203.0.113.10", "no server address and port")]
    [InlineData("vless://id@203.0.113.10:443?security=reality", "no public key")]
    [InlineData("vless://id@203.0.113.10:443?type=quic", "transport is not supported")]
    [InlineData("ss://bm9wZQ@203.0.113.10:443", "no method and password")]
    [InlineData("ss://YTpi@203.0.113.10:443/?plugin=obfs", "plugin")]
    public void Malformed_links_say_why(string link, string reason) =>
        Assert.Contains(reason, Assert.Throws<V2RayException>(() => V2RayConfig.Parse(link)).Message);

    [Fact]
    public void Pasted_text_is_split_into_links_subscriptions_and_problems_without_showing_secrets()
    {
        var text = $"vless://{Id}@a.example.com:443?security=tls#one two   trojan://pw@b.example.com:443#b\nhttps://sub.example.com/list?token=abc trailing words\nssconf://keys.example.com/k#My key\nvless://broken";
        var r = V2RayConfig.ImportText(text);
        Assert.Equal(new[] { "one two", "b" }, r.Configs.Select(c => c.Name));
        Assert.Equal(new[] { "https://sub.example.com/list?token=abc", "https://keys.example.com/k#My%20key" }, r.Subscriptions.Select(u => u.AbsoluteUri));
        Assert.Single(r.Problems);
        Assert.DoesNotContain(Id, string.Join(" ", r.Problems));
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes($"vless://{Id}@a.example.com:443\ntrojan://pw@b.example.com:443"));
        Assert.Equal(2, V2RayConfig.ImportText(b64).Configs.Count);
    }

    [Fact]
    public void Duplicates_are_skipped_and_names_kept_apart()
    {
        var store = new FakeStore();
        var link = $"vless://{Id}@a.example.com:443?security=tls#Server";
        Assert.Single(VpnImport.AddV2Ray(store, new[] { V2RayConfig.Parse(link) }, "test").Added);
        var again = VpnImport.AddV2Ray(store, new[] { V2RayConfig.Parse(link), V2RayConfig.Parse(link.Replace("a.example.com", "c.example.com")) }, "test");
        Assert.Equal("Server 2", Assert.Single(again.Added).Name);
        Assert.Contains("1 was already here.", again.Lines);
    }

    [Fact]
    public void Outline_saved_servers_are_read_from_its_storage_as_8_bit_and_utf16_text()
    {
        const string list = "[{\"id\":\"1\",\"name\":\"Home\",\"accessKey\":\"ss://YWVzLTI1Ni1nY206cHc@198.51.100.7:8388/?outline=1\"}]";
        foreach (var bytes in new[] { Encoding.Latin1.GetBytes("\u0001junk" + list + "tail"), new byte[] { 0 }.Concat(Encoding.Unicode.GetBytes(list)).ToArray() })
        {
            using var dir = new TempDir();
            File.WriteAllBytes(Path.Combine(dir.Path, "000003.log"), bytes);
            var e = Assert.Single(VpnImport.OutlineSavedServers(dir.Path));
            Assert.Equal("Home", e.Name);
            Assert.Equal("Outline", V2RayConfig.KindLabel(V2RayConfig.ConnectionFrom(V2RayConfig.Parse(e.Key), Array.Empty<string>())));
        }
    }
}

public class XrayConfigs
{
    private static Connection Server(string host = "vpn.example.com") =>
        V2RayConfig.ConnectionFrom(V2RayConfig.Parse($"vless://11111111-2222-3333-4444-555555555555@{host}:443?security=tls&sni=vpn.example.com#s"), Array.Empty<string>());

    private static string Launch(Connection c, bool bypassIran = true) =>
        V2RayConfig.ForLaunch(c, V2RayConfig.TunName, new[] { "192.168.1.1" }, new[] { "203.0.113.10/32" },
            new Dictionary<string, List<string>> { ["vpn.example.com"] = new() { "198.51.100.20" } }, verbose: false, bypassIran);

    [Fact]
    public void The_config_FiveT_builds_passes_its_own_check()
    {
        var (problems, rewritten) = XrayConfigCheck.Check(Launch(Server()));
        Assert.Empty(problems);
        var c = JsonNode.Parse(rewritten!)!;
        Assert.Equal("198.51.100.20", (string?)c["dns"]!["hosts"]!["full:vpn.example.com"]![0]);   // the server's name is answered from the PC's own lookup
        var rules = c["routing"]!["rules"]!.AsArray().Select(r => r!.ToJsonString()).ToList();
        Assert.Contains(rules, r => r.Contains("\"network\":\"udp\"") && r.Contains("\"port\":\"53\"") && r.Contains("dns-out"));
        Assert.Contains(rules, r => r.Contains("\"network\":\"udp\"") && r.Contains("\"outboundTag\":\"block\""));   // UDP other than DNS is dropped
        Assert.Contains(rules, r => r.Contains("domain:ir") && r.Contains("direct"));
        Assert.Contains(rules, r => r.Contains("203.0.113.10/32") && r.Contains("direct"));   // a Forti gateway stays off the server
    }

    [Fact]
    public void Bypass_Iranian_Websites_off_sends_ir_through_the_server()
    {
        var text = Launch(Server(), bypassIran: false);
        Assert.DoesNotContain("domain:ir", text);
        Assert.DoesNotContain("geoip-lite.dat:ir", text);
        Assert.Empty(XrayConfigCheck.Check(text).Problems);
    }

    [Theory]
    [InlineData("\"api\":{\"tag\":\"api\"}")]
    [InlineData("\"log\":{\"access\":\"C:/x.log\"}")]
    [InlineData("\"inbounds\":[{\"protocol\":\"socks\",\"port\":1080}]")]
    [InlineData("\"inbounds\":[{\"protocol\":\"tun\",\"settings\":{\"name\":\"other\"}}]")]
    [InlineData("\"outbounds\":[{\"protocol\":\"freedom\",\"streamSettings\":{\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"C:/k\"}]}}}]")]
    [InlineData("\"outbounds\":[{\"protocol\":\"freedom\",\"streamSettings\":{\"tlsSettings\":{\"ma\u017fterKeyLog\":\"C:/k\"}}}]")]
    [InlineData("\"outbounds\":[{\"protocol\":\"http\"}]")]
    [InlineData("\"routing\":{\"rules\":[{\"ip\":[\"geoip:ir\"]}]}")]
    [InlineData("\"routing\":{\"rules\":[{\"ip\":[\"ext:C:/evil.dat:ir\"]}]}")]
    [InlineData("\"dns\":{\"Tag\":\"a\",\"tag\":\"b\"}")]
    public void A_config_that_names_a_file_opens_a_port_or_hides_a_key_is_refused(string part)
    {
        var baseParts = new Dictionary<string, string>
        {
            ["inbounds"] = "\"inbounds\":[{\"protocol\":\"tun\",\"settings\":{\"name\":\"FiveT-VPN\"}}]",
            ["outbounds"] = "\"outbounds\":[{\"protocol\":\"freedom\"}]",
        };
        baseParts[part[1..part.IndexOf('"', 1)]] = part;
        Assert.NotEmpty(XrayConfigCheck.Check("{" + string.Join(",", baseParts.Values) + "}").Problems);
    }

    [Fact]
    public void An_imported_server_cannot_smuggle_settings_into_the_config()
    {
        var c = Server();
        var o = JsonNode.Parse(c.V2RayOutbound)!.AsObject();
        o["streamSettings"]!["sockopt"] = new JsonObject { ["interface"] = "evil" };
        o["mux"] = new JsonObject { ["enabled"] = true };
        o["streamSettings"]!["tlsSettings"]!["allowInsecure"] = true;
        c.V2RayOutbound = o.ToJsonString();
        var text = Launch(c);
        Assert.DoesNotContain("sockopt", text);
        Assert.DoesNotContain("allowInsecure", text);
        Assert.DoesNotContain("\"mux\"", text);
        o["streamSettings"]!["tlsSettings"]!["certificates"] = new JsonArray(new JsonObject { ["keyFile"] = "C:/Temp/key.pem" });
        c.V2RayOutbound = o.ToJsonString();
        Assert.Contains("keyFile", XrayConfigCheck.Check(Launch(c)).Problems);
    }
}

public class Messages
{
    [Fact]
    public void The_menu_shows_the_first_sentence_only()
    {
        Assert.Equal("Office stopped after 2 failed logins.", VpnStatus.ShortError("Office stopped after 2 failed logins. One more failed login to vpn.example.com gets this network banned."));
        Assert.Equal(90, VpnStatus.ShortError(new string('x', 300)).Length);
    }
}

public class KillSwitchFilters
{
    private static bool Elevated => new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent())
        .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);

    /// <summary>How a connection attempt to a reserved test address ends within 1.5 s: refused by a filter, or still waiting.</summary>
    private static string Try(string ip)
    {
        using var socket = new System.Net.Sockets.Socket(System.Net.Sockets.AddressFamily.InterNetwork, System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Tcp);
        try
        {
            var task = socket.ConnectAsync(System.Net.IPAddress.Parse(ip), 9);
            return task.Wait(1500) ? "connected" : "waiting";
        }
        catch (AggregateException e) when (e.InnerException is System.Net.Sockets.SocketException s) { return s.SocketErrorCode.ToString(); }
    }

    // Never "block everything else" here: this runs on a PC that must stay online. The same code path adds
    // the filters; only the list differs. 203.0.113.0/24 is reserved for documentation and leads nowhere.
    [Fact]
    public void A_block_filter_refuses_the_connection_and_goes_away_with_the_session()
    {
        if (!Elevated) return;   // adding filters needs administrator rights
        Assert.Equal("waiting", Try("203.0.113.10"));
        using (new WfpSession(new WfpSession.Rules
               {
                   BlockEverythingElse = false, Block = { "203.0.113.10" },
                   Permit = KillSwitch.LocalRanges.Append("203.0.113.77").Append("2001:db8::1").ToList(),
                   PermitInterfaceLuid = 1,
               }, "FiveT self-test"))
        {
            Assert.Equal("AccessDenied", Try("203.0.113.10"));
            Assert.Equal("waiting", Try("203.0.113.11"));   // only the named address is blocked
        }
        Assert.Equal("waiting", Try("203.0.113.10"));       // the session closed: the filter is gone
    }

    [Fact]
    public void Networks_are_parsed()
    {
        Assert.True(WfpSession.TryParseNetwork("10.0.0.0/8", out var a, out var p) && a.ToString() == "10.0.0.0" && p == 8);
        Assert.True(WfpSession.TryParseNetwork("fe80::/10", out _, out p) && p == 10);
        Assert.True(WfpSession.TryParseNetwork("203.0.113.10", out _, out p) && p == 32);
        Assert.False(WfpSession.TryParseNetwork("vpn.example.com", out _, out _));
        Assert.False(WfpSession.TryParseNetwork("10.0.0.0/40", out _, out _));
    }
}
