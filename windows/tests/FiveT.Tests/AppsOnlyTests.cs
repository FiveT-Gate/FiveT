using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace FiveT.Tests;

/// <summary>The Mac's 1.20 and 1.21 features that need no window: which programs may be chosen, which VPN takes over, and the failover order.</summary>
public class VpnAppRules
{
    [Theory]
    [InlineData(@"C:\Program Files\Slack\slack.exe", true)]
    [InlineData(@"d:\tools\chrome.EXE", true)]
    [InlineData(@"\\server\share\app\tool.exe", true)]
    [InlineData(@"C:\Program Files\Some App (x86)\app.exe", true)]
    [InlineData(@"slack.exe", false)]                       // not a full path
    [InlineData(@"C:\Users\x\..\y\app.exe", false)]         // no way up the tree
    [InlineData(@"C:\tools\.\app.exe", false)]
    [InlineData(@"C:\tools\app.bat", false)]                // a program, not a script
    [InlineData(@"C:\tools\app", false)]
    [InlineData(@"C:/tools/app.exe", false)]                // Windows paths with backslashes only
    [InlineData(@"\\?\C:\tools\app.exe", false)]            // a device path
    [InlineData(@"/Applications/Claude.app", false)]        // a Mac app (from a Mac's .fivet file)
    [InlineData("C:\\tools\\app.exe\r\n", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Only_full_paths_of_programs_may_be_chosen(string? path, bool expected) => Assert.Equal(expected, VpnApps.IsAppPath(path));

    [Fact]
    public void The_list_keeps_each_program_once_in_order_and_drops_the_rest()
    {
        var list = VpnApps.Clean(new[] { @" C:\a\one.exe ", @"C:\A\ONE.exe", "/Applications/Two.app", null, @"C:\b\three.exe", "junk" });
        Assert.Equal(new[] { @"C:\a\one.exe", @"C:\b\three.exe" }, list);
        Assert.Empty(VpnApps.Clean(null));
        Assert.Equal(50, VpnApps.Clean(Enumerable.Range(0, 80).Select(i => $@"C:\apps\a{i}.exe")).Count);
    }

    [Fact]
    public void An_app_is_started_with_the_proxy_as_a_switch_and_in_the_environment()
    {
        Assert.Equal("chrome", VpnApps.Name(@"C:\Program Files\Google\Chrome\Application\chrome.exe"));
        Assert.Equal("--proxy-server=socks5://127.0.0.1:41234", VpnApps.ProxyArguments(41234));
        Assert.Equal("socks5h://127.0.0.1:41234", VpnApps.ProxyEnvironment(41234)["ALL_PROXY"]);
    }

    private static Connection C(string name, VpnKind kind) => new() { Name = name, Kind = kind };

    [Fact]
    public void Failover_goes_to_the_next_VPN_and_round_to_the_first()
    {
        var office = C("Office", VpnKind.Fortinet);
        var a = C("A", VpnKind.V2Ray);
        var b = C("B", VpnKind.OpenVpn);
        var c = C("C", VpnKind.V2Ray);
        var all = new[] { office, a, b, c };
        Assert.Equal(b, VpnApps.NextVpn(all, a.Id));
        Assert.Equal(c, VpnApps.NextVpn(all, b.Id));
        Assert.Equal(a, VpnApps.NextVpn(all, c.Id));   // round to the first; Forti connections are never part of it
    }

    [Fact]
    public void Failover_has_nowhere_to_go_with_one_VPN_or_for_a_Forti_connection()
    {
        var office = C("Office", VpnKind.Fortinet);
        var only = C("Only", VpnKind.V2Ray);
        Assert.Null(VpnApps.NextVpn(new[] { office, only }, only.Id));
        Assert.Null(VpnApps.NextVpn(new[] { office, only, C("B", VpnKind.OpenVpn) }, office.Id));
        Assert.Null(VpnApps.NextVpn(new[] { only, C("B", VpnKind.OpenVpn) }, Guid.NewGuid()));
    }
}

/// <summary>What an assistant or the command line may only change with the user's yes (the Mac's 1.21.1 and 1.21.2).</summary>
public class ProtectionRules
{
    private static List<(string Key, string Text)> L(params (string Key, bool Current, bool Wanted)[] changes) => Protection.Lowering(changes);

    [Fact]
    public void Switching_the_kill_switch_off_or_apps_only_or_Iran_bypass_on_asks_the_user()
    {
        Assert.Equal("kill_switch", Assert.Single(L(("kill_switch", true, false))).Key);
        Assert.Equal("apps_only", Assert.Single(L(("apps_only", false, true))).Key);
        Assert.Equal("bypass_iranian_websites", Assert.Single(L(("bypass_iranian_websites", false, true))).Key);
        Assert.Equal(3, L(("kill_switch", true, false), ("apps_only", false, true), ("bypass_iranian_websites", false, true)).Count);
    }

    [Fact]
    public void Turning_protection_on_or_changing_other_switches_asks_nothing()
    {
        Assert.Empty(L(("kill_switch", false, true)));
        Assert.Empty(L(("apps_only", true, false)));
        Assert.Empty(L(("bypass_iranian_websites", true, false)));
        Assert.Empty(L(("failover", true, false), ("failover", false, true), ("auto_reconnect", true, false), ("watchdog", true, false), ("notify_on_change", false, true)));
    }

    [Fact]
    public void A_value_that_is_already_so_changes_and_asks_nothing()
    {
        Assert.Empty(L(("kill_switch", false, false), ("apps_only", true, true), ("bypass_iranian_websites", true, true)));
    }

    [Fact]
    public void Each_question_names_what_is_lowered_in_plain_words()
    {
        Assert.Equal("turn the Kill Switch off", L(("kill_switch", true, false))[0].Text);
        Assert.Contains("only the chosen apps", L(("apps_only", false, true))[0].Text);
        Assert.Contains("Iranian websites around the VPN", L(("bypass_iranian_websites", false, true))[0].Text);
    }

    [Fact]
    public void A_setting_that_moved_while_the_dialog_was_open_is_not_in_what_was_allowed()
    {
        // The user allowed "turn the Kill Switch off" while it was on. Meanwhile apps-only was switched off by someone else, so
        // the same request now also lowers apps-only: that was never asked about, and the caller refuses (the Mac's 1.21.2).
        var asked = L(("kill_switch", true, false)).Select(a => a.Key).ToHashSet();
        var now = L(("kill_switch", true, false), ("apps_only", false, true)).Select(a => a.Key);
        Assert.False(now.ToHashSet().IsSubsetOf(asked));
        Assert.True(L(("kill_switch", true, false)).Select(a => a.Key).ToHashSet().IsSubsetOf(asked));
    }
}

/// <summary>The Xray config of apps-only mode, and the check that keeps it from opening anything else while Xray runs as administrator.</summary>
public class AppsOnlyConfig
{
    private const int Port = 41234;

    private static Connection Server() =>
        V2RayConfig.ConnectionFrom(V2RayConfig.Parse("vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?security=tls&sni=vpn.example.com#s"), Array.Empty<string>());

    private static string Launch(string? tun, int? appPort) =>
        V2RayConfig.ForLaunch(Server(), tun, new[] { "192.168.1.1" }, new[] { "203.0.113.10/32" },
            new Dictionary<string, List<string>> { ["vpn.example.com"] = new() { "198.51.100.20" } }, verbose: false, bypassIran: true, appPort);

    [Fact]
    public void The_apps_only_config_is_one_loopback_proxy_with_no_tunnel_and_passes_its_check()
    {
        var text = Launch(null, Port);
        var (problems, rewritten) = XrayConfigCheck.Check(text, Port);
        Assert.Empty(problems);
        var c = JsonNode.Parse(rewritten!)!;
        var inbound = Assert.Single(c["inbounds"]!.AsArray())!;
        Assert.Equal("socks", (string?)inbound["protocol"]);
        Assert.Equal("127.0.0.1", (string?)inbound["listen"]);
        Assert.Equal(Port, (int?)inbound["port"]);
        Assert.Equal("noauth", (string?)inbound["settings"]!["auth"]);
        Assert.False((bool?)inbound["settings"]!["udp"]);
        Assert.DoesNotContain("\"tun\"", text);
        var rules = c["routing"]!["rules"]!.AsArray().Select(r => r!.ToJsonString()).ToList();
        Assert.DoesNotContain(rules, r => r.Contains("\"inboundTag\""));      // no rule is about a tunnel
        Assert.DoesNotContain(rules, r => r.Contains("dns-out"));             // and no PC DNS to answer
        Assert.DoesNotContain(rules, r => r.Contains("\"network\":\"udp\""));
        Assert.Contains(rules, r => r.Contains("private") && r.Contains("direct"));
        Assert.Contains(rules, r => r.Contains("\"outboundTag\":\"proxy\""));
        Assert.Contains(rules, r => r.Contains("domain:ir") && r.Contains("direct"));   // Bypass Iranian Websites still applies
    }

    [Fact]
    public void The_tunnel_config_is_what_it_was_and_still_has_no_proxy()
    {
        var text = Launch(V2RayConfig.TunName, null);
        Assert.Empty(XrayConfigCheck.Check(text).Problems);
        Assert.DoesNotContain("\"socks\"", text);
        Assert.Contains("\"tun\"", text);
    }

    [Fact]
    public void A_config_needs_either_a_tunnel_or_a_proxy_port()
    {
        Assert.Throws<ArgumentException>(() => Launch(null, null));
        Assert.Throws<ArgumentException>(() => Launch(V2RayConfig.TunName, Port));
    }

    [Fact]
    public void The_proxy_is_refused_unless_apps_only_asked_for_exactly_this_port()
    {
        var text = Launch(null, Port);
        Assert.NotEmpty(XrayConfigCheck.Check(text).Problems);          // a tunnel run has no proxy
        Assert.NotEmpty(XrayConfigCheck.Check(text, Port + 1).Problems);
    }

    [Theory]
    [InlineData("listen", "0.0.0.0")]            // reachable from the network
    [InlineData("listen", "::1")]
    [InlineData("tag", "other")]
    [InlineData("port", 80)]
    public void A_proxy_that_is_not_the_one_FiveT_builds_is_refused(string key, object value)
    {
        var c = JsonNode.Parse(Launch(null, Port))!;
        c["inbounds"]![0]![key] = JsonValue.Create(value);
        Assert.NotEmpty(XrayConfigCheck.Check(c.ToJsonString(), Port).Problems);
    }

    [Fact]
    public void A_proxy_with_a_login_udp_or_a_second_inbound_is_refused()
    {
        var withAuth = JsonNode.Parse(Launch(null, Port))!;
        withAuth["inbounds"]![0]!["settings"]!["auth"] = "password";
        Assert.NotEmpty(XrayConfigCheck.Check(withAuth.ToJsonString(), Port).Problems);

        var withUdp = JsonNode.Parse(Launch(null, Port))!;
        withUdp["inbounds"]![0]!["settings"]!["udp"] = true;
        Assert.NotEmpty(XrayConfigCheck.Check(withUdp.ToJsonString(), Port).Problems);

        var extra = JsonNode.Parse(Launch(null, Port))!;
        extra["inbounds"]!.AsArray().Add(JsonNode.Parse("{\"protocol\":\"tun\",\"settings\":{\"name\":\"FiveT-VPN\"}}"));   // a tunnel next to the proxy
        Assert.NotEmpty(XrayConfigCheck.Check(extra.ToJsonString(), Port).Problems);

        var file = JsonNode.Parse(Launch(null, Port))!;
        file["inbounds"]![0]!["settings"]!["keyFile"] = "C:/k";
        Assert.NotEmpty(XrayConfigCheck.Check(file.ToJsonString(), Port).Problems);
    }
}

/// <summary>The local port the apps use: held shut while Xray is away, owned by Xray while it runs, and the check that it carries traffic.</summary>
public class AppProxyPorts
{
    [Fact]
    public void A_listener_is_found_by_its_port()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        try
        {
            var port = ((IPEndPoint)l.LocalEndpoint).Port;
            Assert.Equal(Environment.ProcessId, TcpOwner.ListenerPid(port));
        }
        finally { l.Stop(); }
        Assert.Null(TcpOwner.ListenerPid(AppProxyHold.PickFreePort()));
    }

    [Fact]
    public void The_hold_shuts_the_port_to_everyone_else_and_closes_every_connection_until_released()
    {
        var hold = new AppProxyHold();
        var port = AppProxyHold.PickFreePort();
        hold.Take(port);
        try
        {
            Assert.True(hold.IsHolding);
            Assert.Equal(Environment.ProcessId, TcpOwner.ListenerPid(port));
            Assert.Throws<SocketException>(() => new TcpListener(IPAddress.Loopback, port).Start());   // nobody else can take it
            using var client = new TcpClient { ReceiveTimeout = 3000 };
            client.Connect(IPAddress.Loopback, port);
            Assert.Equal(0, client.GetStream().Read(new byte[1], 0, 1));   // accepted and closed at once: the app gets nothing
        }
        finally { hold.Release(); }
        Assert.False(hold.IsHolding);
        var after = new TcpListener(IPAddress.Loopback, port);
        after.Start();   // free again for Xray
        after.Stop();
    }

    [Fact]
    public void Taking_a_port_that_another_program_holds_does_not_throw()
    {
        var other = new TcpListener(IPAddress.Loopback, 0) { ExclusiveAddressUse = true };
        other.Start();
        try
        {
            var hold = new AppProxyHold();
            hold.Take(((IPEndPoint)other.LocalEndpoint).Port);
            Assert.False(hold.IsHolding);
        }
        finally { other.Stop(); }
    }

    /// <summary>A SOCKS5 proxy that says yes to every CONNECT and answers the web request with 204, and notes which host it was asked for.</summary>
    private sealed class FakeSocks : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        public readonly List<string> Hosts = new();
        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

        public FakeSocks()
        {
            _listener.Start();
            _ = Task.Run(async () =>
            {
                try { while (true) { var c = await _listener.AcceptTcpClientAsync(); _ = Task.Run(() => Serve(c)); } }
                catch (Exception) { }
            });
        }

        private void Serve(TcpClient client)
        {
            try
            {
                using var c = client;
                var s = c.GetStream();
                var b = new byte[300];
                s.ReadExactly(b, 0, 2); s.ReadExactly(b, 0, b[1]);   // greeting: version, number of methods, the methods
                s.Write(new byte[] { 5, 0 });
                s.ReadExactly(b, 0, 4);                              // request: version, command, reserved, address type
                string host;
                if (b[3] == 3) { s.ReadExactly(b, 0, 1); var n = b[0]; s.ReadExactly(b, 0, n); host = Encoding.ASCII.GetString(b, 0, n); }
                else if (b[3] == 1) { s.ReadExactly(b, 0, 4); host = new IPAddress(b[..4]).ToString(); }
                else return;
                s.ReadExactly(b, 0, 2);                              // port
                lock (Hosts) Hosts.Add(host);
                s.Write(new byte[] { 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
                var seen = new StringBuilder();
                while (!seen.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) { var one = s.ReadByte(); if (one < 0) return; seen.Append((char)one); }
                s.Write(Encoding.ASCII.GetBytes("HTTP/1.1 204 No Content\r\n\r\n"));
            }
            catch (Exception) { }
        }

        public void Dispose() => _listener.Stop();
    }

    [Fact]
    public void The_check_goes_through_the_proxy_to_a_name_only_the_proxy_looks_up_when_the_listener_is_Xray()
    {
        using var proxy = new FakeSocks();
        var before = TrafficCheck.Addresses;
        TrafficCheck.Addresses = new[] { "http://check.example.com/generate_204" };
        try
        {
            Assert.True(TrafficCheck.Carries(5, proxy.Port, Environment.ProcessId));
            Assert.Equal(new[] { "check.example.com" }, proxy.Hosts);   // the name went to the proxy, not to this PC's DNS
        }
        finally { TrafficCheck.Addresses = before; }
    }

    [Fact]
    public void The_check_refuses_a_proxy_that_is_not_the_one_FiveT_started_and_sends_it_nothing()
    {
        using var proxy = new FakeSocks();
        var before = TrafficCheck.Addresses;
        TrafficCheck.Addresses = new[] { "http://check.example.com/generate_204" };
        try
        {
            Assert.False(TrafficCheck.Carries(5, proxy.Port, ownerPid: 1));                       // another program's listener
            Assert.False(TrafficCheck.Carries(5, AppProxyHold.PickFreePort(), Environment.ProcessId));   // nobody listens
            lock (proxy.Hosts) Assert.Empty(proxy.Hosts);
        }
        finally { TrafficCheck.Addresses = before; }
    }
}
