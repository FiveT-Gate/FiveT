using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using FiveT.Core;

namespace FiveT;

/// <summary>Network facts and diagnosis (resolve / check_reachability), all without external tools.</summary>
public static class NetTools
{
    // ---- Tunnel adapter facts ----

    public sealed record AdapterFacts(string Name, int Index, string Ip, List<string> Dns, List<string> Search);

    /// <summary>The tunnel adapter: the one openconnect named, else any Wintun / TAP adapter that is up.</summary>
    public static AdapterFacts? FindTunnelAdapter(string preferredName)
    {
        NetworkInterface? best = null;
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (string.Equals(ni.Name, preferredName, StringComparison.OrdinalIgnoreCase)) { best = ni; break; }
            var d = ni.Description;
            if (best == null && (d.Contains("Wintun", StringComparison.OrdinalIgnoreCase)
                                 || d.Contains("TAP-Windows", StringComparison.OrdinalIgnoreCase)
                                 || d.Contains("OpenConnect", StringComparison.OrdinalIgnoreCase)))
                best = ni;
        }
        if (best == null) return null;
        var props = best.GetIPProperties();
        var ip = props.UnicastAddresses.Select(u => u.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)?.ToString() ?? "";
        var dns = props.DnsAddresses.Where(a => a.AddressFamily == AddressFamily.InterNetwork).Select(a => a.ToString()).Distinct().ToList();
        var search = new List<string>();
        if (!string.IsNullOrEmpty(props.DnsSuffix)) search.Add(props.DnsSuffix);
        int index;
        try { index = props.GetIPv4Properties().Index; } catch { index = -1; }
        return new AdapterFacts(best.Name, index, ip, dns, search);
    }

    /// <summary>Destinations routed over the interface as "a.b.c.d/nn"; default route, link-local, multicast and broadcast left out.</summary>
    public static (List<string> Routes, string Peer) Routes(int ifIndex)
    {
        var outList = new List<string>();
        var hops = new Dictionary<string, int>();
        foreach (var r in Native.IpForwardTable())
        {
            if ((int)r.dwForwardIfIndex != ifIndex) continue;
            var dest = Native.Ipv4(r.dwForwardDest);
            var prefix = Native.PrefixLength(r.dwForwardMask);
            var hop = Native.Ipv4(r.dwForwardNextHop);
            if (hop != "0.0.0.0") hops[hop] = hops.GetValueOrDefault(hop) + 1;
            if (dest == "0.0.0.0" && prefix == 0) continue;
            if (dest.StartsWith("127.") || dest.StartsWith("169.254.") || dest.StartsWith("224") || dest.StartsWith("239")
                || dest == "255.255.255.255" || dest.EndsWith(".255")) continue;
            var cidr = $"{dest}/{prefix}";
            if (!outList.Contains(cidr)) outList.Add(cidr);
        }
        var peer = hops.OrderByDescending(kv => kv.Value).Select(kv => kv.Key).FirstOrDefault() ?? "";
        return (outList, peer);
    }

    /// <summary>True when the interface has a 0.0.0.0/0 route (full tunnel).</summary>
    public static bool HasDefaultRoute(int ifIndex) =>
        Native.IpForwardTable().Any(r => (int)r.dwForwardIfIndex == ifIndex && r.dwForwardDest == 0 && r.dwForwardMask == 0);

    /// <summary>True when <paramref name="ip"/> falls inside one of <paramref name="cidrs"/>.</summary>
    public static bool Ipv4CoveredBy(string ip, IEnumerable<string> cidrs)
    {
        static uint? ToInt(string s)
        {
            var o = s.Split('.');
            if (o.Length != 4) return null;
            uint v = 0;
            foreach (var p in o) { if (!byte.TryParse(p, out var b)) return null; v = (v << 8) | b; }
            return v;
        }
        if (ToInt(ip) is not { } v2) return false;
        foreach (var c in cidrs)
        {
            var parts = c.Split('/');
            if (ToInt(parts[0]) is not { } net) continue;
            var bits = parts.Length > 1 && int.TryParse(parts[1], out var b) ? b : 32;
            var mask = bits == 0 ? 0u : ~0u << (32 - bits);
            if ((v2 & mask) == (net & mask)) return true;
        }
        return false;
    }

    public static bool IsIPv4(string s) => IPAddress.TryParse(s, out var a) && a.AddressFamily == AddressFamily.InterNetwork && s.Count(ch => ch == '.') == 3;

    // ---- The PC's own network (not the tunnels) ----

    /// <summary>A network interface that is not a VPN tunnel (FiveT's Wintun adapters, TAP, other VPNs' virtual ones).</summary>
    private static bool IsRealNetwork(NetworkInterface ni) =>
        ni.OperationalStatus == OperationalStatus.Up
        && ni.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
        && !ni.Description.Contains("Wintun", StringComparison.OrdinalIgnoreCase)
        && !ni.Description.Contains("TAP-Windows", StringComparison.OrdinalIgnoreCase)
        && !ni.Description.Contains("OpenConnect", StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<IPAddress> Gateways(NetworkInterface ni)
    {
        try
        {
            return ni.GetIPProperties().GatewayAddresses.Select(g => g.Address)
                .Where(a => !a.Equals(IPAddress.Any) && !a.Equals(IPAddress.IPv6Any)).ToList();
        }
        catch { return Array.Empty<IPAddress>(); }
    }

    /// <summary>
    /// True when the PC is on a network of its own: an interface that is up, not a tunnel, with a
    /// default gateway. A connected tunnel alone does not count (its adapter is up as well), which is
    /// why the Framework's GetIsNetworkAvailable is no use here.
    /// </summary>
    public static bool HasUnderlyingNetwork()
    {
        try { return NetworkInterface.GetAllNetworkInterfaces().Any(ni => IsRealNetwork(ni) && Gateways(ni).Any()); }
        catch { return true; }   // cannot tell: never hold a reconnect back on a guess
    }

    /// <summary>Whether there is a network, and a short description of it that changes when it does (Wi-Fi to another one, cable in).</summary>
    public static (bool Up, string Signature) UnderlyingNetworkSignature()
    {
        try
        {
            var parts = NetworkInterface.GetAllNetworkInterfaces()
                .Where(IsRealNetwork)
                .Select(ni => (ni, gw: Gateways(ni).Select(g => g.ToString()).OrderBy(x => x).ToList()))
                .Where(x => x.gw.Count > 0)
                .Select(x => $"{x.ni.Name} via {string.Join("/", x.gw)}")
                .OrderBy(x => x)
                .ToList();
            return (parts.Count > 0, string.Join(", ", parts));
        }
        catch (Exception e) { return (true, "unknown: " + e.Message); }
    }

    // ---- DNS ----

    /// <summary>Asks one DNS server directly for A records (UDP, 2 s), like nslookup does, bypassing the system resolver.</summary>
    public static (List<string> Addresses, string? Error) Query(string host, string server)
    {
        try
        {
            var id = (ushort)Random.Shared.Next(1, 65535);
            var q = new List<byte> { (byte)(id >> 8), (byte)id, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0 };
            var name = host.TrimEnd('.');
            // A name with accents or another script goes on the wire as punycode (xn--…); plain ASCII
            // with ASCII encoding alone would query "?" for every such letter.
            if (name.Any(ch => ch > 127))
            {
                try { name = new System.Globalization.IdnMapping().GetAscii(name); }
                catch (ArgumentException) { return (new List<string>(), "invalid host name"); }
            }
            // "." is the root: no labels at all (the watchdog asks that when it knows no domain).
            foreach (var label in name.Length == 0 ? Array.Empty<string>() : name.Split('.'))
            {
                var b = System.Text.Encoding.ASCII.GetBytes(label);
                if (b.Length == 0 || b.Length > 63) return (new List<string>(), "invalid host name");
                q.Add((byte)b.Length); q.AddRange(b);
            }
            q.AddRange(new byte[] { 0, 0, 1, 0, 1 });   // QTYPE A, QCLASS IN
            using var udp = new UdpClient(AddressFamily.InterNetwork);
            udp.Client.ReceiveTimeout = 2000;
            udp.Connect(IPAddress.Parse(server), 53);
            udp.Send(q.ToArray(), q.Count);
            var ep = new IPEndPoint(IPAddress.Any, 0);
            var resp = udp.Receive(ref ep);
            if (resp.Length < 12 || resp[0] != (byte)(id >> 8) || resp[1] != (byte)id) return (new List<string>(), "bad reply");
            var rcode = resp[3] & 0x0f;
            if (rcode == 3) return (new List<string>(), "NXDOMAIN");
            if (rcode != 0) return (new List<string>(), $"rcode {rcode}");
            int qd = (resp[4] << 8) | resp[5], an = (resp[6] << 8) | resp[7];
            var pos = 12;
            for (var i = 0; i < qd; i++) { pos = SkipName(resp, pos); pos += 4; }
            var addrs = new List<string>();
            for (var i = 0; i < an && pos + 10 <= resp.Length; i++)
            {
                pos = SkipName(resp, pos);
                int type = (resp[pos] << 8) | resp[pos + 1];
                int rdlen = (resp[pos + 8] << 8) | resp[pos + 9];
                pos += 10;
                if (type == 1 && rdlen == 4 && pos + 4 <= resp.Length)
                    addrs.Add($"{resp[pos]}.{resp[pos + 1]}.{resp[pos + 2]}.{resp[pos + 3]}");
                pos += rdlen;
            }
            return (addrs, addrs.Count == 0 ? "no A record" : null);
        }
        catch (SocketException e) when (e.SocketErrorCode == SocketError.TimedOut)
        {
            return (new List<string>(), "timed out");
        }
        catch (Exception e)
        {
            return (new List<string>(), e.Message);
        }
    }

    private static int SkipName(byte[] b, int pos)
    {
        while (pos < b.Length)
        {
            var len = b[pos];
            if (len == 0) return pos + 1;
            if ((len & 0xC0) == 0xC0) return pos + 2;
            pos += len + 1;
        }
        return pos;
    }

    /// <summary>The system resolver (getaddrinfo), which is what curl, Python and apps use.</summary>
    public static (List<string> Addresses, string? Error) SystemResolve(string host)
    {
        try
        {
            var addrs = Dns.GetHostAddresses(host)
                .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
                .Select(a => a.ToString()).Distinct().ToList();
            return (addrs, addrs.Count == 0 ? "no address" : null);
        }
        catch (SocketException e) { return (new List<string>(), e.Message); }
        catch (Exception e) { return (new List<string>(), e.Message); }
    }

    public static JsonObject Resolve(string host, VpnStatus st)
    {
        var d = new JsonObject { ["host"] = host };
        var servers = st.Network?.DnsServers ?? new List<string>();
        var tunnelAddrs = new List<string>();
        if (IsIPv4(host))
        {
            d["tunnel_dns"] = new JsonObject { ["addresses"] = Json.Array(new[] { host }), ["note"] = "already an IP address" };
            d["system_dns"] = new JsonObject { ["addresses"] = Json.Array(new[] { host }) };
            tunnelAddrs.Add(host);
        }
        else
        {
            if (servers.Count == 0)
            {
                d["tunnel_dns"] = new JsonObject { ["error"] = st.Phase == VpnPhase.Connected ? "the gateway pushed no DNS servers" : "VPN is not connected" };
            }
            else
            {
                JsonObject last = new();
                foreach (var s in servers)
                {
                    var q = Query(host, s);
                    last = new JsonObject { ["server"] = s, ["addresses"] = Json.Array(q.Addresses) };
                    if (q.Error is { } e) last["error"] = e;
                    if (q.Addresses.Count > 0) { tunnelAddrs = q.Addresses; break; }
                }
                d["tunnel_dns"] = last;
            }
            var sys = SystemResolve(host);
            var sd = new JsonObject { ["addresses"] = Json.Array(sys.Addresses) };
            if (sys.Error is { } se) sd["error"] = se;
            d["system_dns"] = sd;
            d["system_resolver_ok"] = sys.Addresses.Count > 0;
            if (sys.Addresses.Count == 0 && tunnelAddrs.Count > 0) d["hint"] = SplitDnsHint(host, st);
        }
        d["addresses"] = Json.Array(tunnelAddrs);
        return d;
    }

    /// <summary>TCP connect with a 3 s timeout.</summary>
    public static (bool Ok, int Ms, string? Error) TcpConnect(string ip, int port)
    {
        var t0 = DateTime.Now;
        try
        {
            using var client = new TcpClient(AddressFamily.InterNetwork);
            var task = client.ConnectAsync(IPAddress.Parse(ip), port);
            if (!task.Wait(3000)) return (false, 3000, "timed out");
            return (true, (int)(DateTime.Now - t0).TotalMilliseconds, null);
        }
        catch (AggregateException e)
        {
            return (false, (int)(DateTime.Now - t0).TotalMilliseconds, e.InnerException?.Message ?? e.Message);
        }
        catch (Exception e)
        {
            return (false, (int)(DateTime.Now - t0).TotalMilliseconds, e.Message);
        }
    }

    public static JsonObject CheckReachability(string host, int port, VpnStatus st)
    {
        var d = Resolve(host, st);
        d["port"] = port;
        d["vpn_state"] = st.StateName;
        var tunnelAddrs = (d["addresses"] as JsonArray)?.Select(n => Json.Str(n) ?? "").ToList() ?? new List<string>();
        var sysAddrs = ((d["system_dns"] as JsonObject)?["addresses"] as JsonArray)?.Select(n => Json.Str(n) ?? "").ToList() ?? new List<string>();
        var candidates = tunnelAddrs.Count == 0 ? sysAddrs.Where(IsIPv4).ToList() : tunnelAddrs;
        var diagnosis = new List<string>();
        var reachable = false;

        if (st.Phase != VpnPhase.Connected) diagnosis.Add($"The VPN is {st.StateName}.");
        if (candidates.Count == 0)
        {
            diagnosis.Add($"{host} does not resolve via the tunnel DNS or the system resolver.");
        }
        else
        {
            var ip = candidates[0];
            var (routes, ifIndexes) = ConnectedTunnels(st);
            var viaTunnel = Ipv4CoveredBy(ip, routes) || ifIndexes.Any(HasDefaultRoute);
            d["address_used"] = ip;
            d["route_via_tunnel"] = viaTunnel;
            var tcp = TcpConnect(ip, port);
            var t = new JsonObject { ["address"] = ip, ["port"] = port, ["connected"] = tcp.Ok, ["latency_ms"] = tcp.Ms };
            if (tcp.Error is { } e) t["error"] = e;
            d["tcp"] = t;
            reachable = tcp.Ok;
            if (tcp.Ok)
            {
                diagnosis.Add($"TCP {ip}:{port} is open ({tcp.Ms} ms){(viaTunnel ? ", routed through the tunnel" : "")}.");
                if (sysAddrs.Count == 0 && !IsIPv4(host))
                    diagnosis.Add($"But the system resolver cannot resolve {host}, so apps will still fail by name. " + SplitDnsHint(host, st));
            }
            else
            {
                diagnosis.Add($"TCP connect to {ip}:{port} failed: {tcp.Error ?? "timeout"}.");
                if (st.Phase == VpnPhase.Connected && !viaTunnel)
                    diagnosis.Add($"{ip} is not covered by any route the gateway pushed ({routes.Count} routes), so traffic goes out the normal interface. The gateway may not publish that subnet, or the host is not behind this VPN.");
                else if (st.Phase == VpnPhase.Connected)
                    diagnosis.Add("The address is routed through the tunnel; the service may be down, the port closed, or filtered by the FortiGate policy.");
            }
        }
        d["reachable"] = reachable;
        d["diagnosis"] = string.Join(" ", diagnosis);
        return d;
    }

    /// <summary>
    /// The routes and the adapter indexes of every connected tunnel (plus the status given), so "is this
    /// address routed through a tunnel" is asked of all of them: with two tunnels up, the merged status
    /// has one interface name but a host may sit behind the other one's full tunnel.
    /// </summary>
    private static (List<string> Routes, List<int> IfIndexes) ConnectedTunnels(VpnStatus st)
    {
        var routes = new List<string>();
        var indexes = new List<int>();
        void Add(NetworkInfo? n)
        {
            if (n == null) return;
            foreach (var r in n.Routes) if (!routes.Contains(r)) routes.Add(r);
            if (n.InterfaceIndex > 0 && !indexes.Contains(n.InterfaceIndex)) indexes.Add(n.InterfaceIndex);
        }
        Add(st.Network);
        try
        {
            // The sessions belong to the UI thread (this runs on the MCP thread); Ui.Invoke hops over.
            foreach (var s in Ui.Invoke(() => VpnManager.Shared.Sessions))
                if (s.Phase == VpnPhase.Connected) Add(s.Network);
        }
        catch (Exception) { /* the status given still counts */ }
        return (routes, indexes);
    }

    private static string SplitDnsHint(string host, VpnStatus st)
    {
        var parts = host.ToLowerInvariant().Split('.');
        var domain = parts.Length >= 2 ? string.Join(".", parts[^2..]) : host.ToLowerInvariant();
        var s = $"Split DNS needed: add \"{domain}\" to the connection's DNS domains (FiveT → Settings → Connections), then reconnect.";
        if (st.SplitDns is { } sd)
        {
            if (sd.State == "helper_needed") s = "Split DNS is configured but FiveT is not running as administrator: " + sd.Detail;
            else if (sd.Domains.Any(d => host.ToLowerInvariant().EndsWith(d)))
                s = $"Split DNS is {sd.State} for {domain}{(sd.Detail.Length == 0 ? "" : " (" + sd.Detail + ")")}; the NRPT rule may need a few seconds, or the DNS server has no record for this host.";
        }
        return s;
    }
}
