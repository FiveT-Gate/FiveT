using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace FiveT;

/// <summary>
/// Apps-only mode: the chosen apps are started with one local port as their proxy. While FiveT's Xray is not listening on
/// it (a reconnect, a disconnect), FiveT holds the port itself and closes every connection at once, so the apps get no
/// internet and no other program can take the port and receive what they send (the Mac's AppProxyHold, 1.21.2).
/// <see cref="Release"/> hands the port to Xray just before it starts; the gap between the two is covered by
/// <see cref="TcpOwner.ListenerPid"/>, which the "connected" check uses.
/// </summary>
public sealed class AppProxyHold
{
    public static AppProxyHold Shared { get; } = new();

    private readonly object _lock = new();
    private TcpListener? _listener;

    public bool IsHolding { get { lock (_lock) return _listener != null; } }

    public void Take(int port)
    {
        lock (_lock)
        {
            if (_listener != null) return;
            try
            {
                // Exclusive: no other program can bind this port too (not even with SO_REUSEADDR).
                var l = new TcpListener(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
                l.Start(16);
                _listener = l;
                _ = Task.Run(async () =>
                {
                    try { while (true) { using var c = await l.AcceptTcpClientAsync(); } }   // accepted and closed at once
                    catch (Exception) { }                                                      // Stop() ends the loop
                });
            }
            catch (SocketException e)
            {
                Log.Shared.Write($"apps-only: another program holds port {port}; FiveT cannot keep it shut ({e.Message})", LogLevel.Error);
            }
        }
    }

    public void Release()
    {
        TcpListener? l;
        lock (_lock) { l = _listener; _listener = null; }
        try { l?.Stop(); } catch (Exception) { }
    }

    /// <summary>A free loopback port, for this launch of FiveT: unpredictable, so no program can sit on a well-known port first.</summary>
    public static int PickFreePort()
    {
        try
        {
            var l = new TcpListener(IPAddress.Loopback, 0);
            l.Start();
            var port = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
            return port;
        }
        catch (Exception) { return Random.Shared.Next(20000, 60000); }
    }
}

/// <summary>The check that decides a V2Ray or Outline run is up: does a web request get out?</summary>
public static class TrafficCheck
{
    /// <summary>The addresses asked: plain HTTP to two well-known "generate_204" servers, so no certificate gets in the way.</summary>
    internal static string[] Addresses { get; set; } = { "http://cp.cloudflare.com/generate_204", "http://www.gstatic.com/generate_204" };

    /// <summary>
    /// A small web request through whatever carries the PC's traffic: any HTTP answer counts. With <paramref name="socksPort"/> (apps-only
    /// mode) it goes through FiveT's local SOCKS proxy, since nothing else goes through the server, and only when that port belongs to
    /// <paramref name="ownerPid"/>, FiveT's own Xray: another program on the port would answer just as well and then see everything
    /// the apps send.
    /// </summary>
    public static bool Carries(double timeoutSeconds, int? socksPort = null, int? ownerPid = null)
    {
        if (socksPort is { } port && TcpOwner.ListenerPid(port) != ownerPid) return false;
        var handler = new SocketsHttpHandler { UseProxy = socksPort != null, UseCookies = false, AllowAutoRedirect = false };
        if (socksPort is { } p) handler.Proxy = new WebProxy($"socks5://127.0.0.1:{p}");
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(timeoutSeconds) };
        foreach (var address in Addresses)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Head, address);
                using var response = client.Send(req);
                return true;
            }
            catch (Exception) { }
        }
        return false;
    }
}

/// <summary>Which process listens on a port.</summary>
public static class TcpOwner
{
    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);

    /// <summary>The process that listens on 127.0.0.1:<paramref name="port"/> (an exact match first, then a listener on every address), or null.</summary>
    public static int? ListenerPid(int port)
    {
        const int AfInet = 2, TcpTableOwnerPidListener = 3;
        var size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, AfInet, TcpTableOwnerPidListener, 0);   // asks for the size
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                var rc = GetExtendedTcpTable(buffer, ref size, false, AfInet, TcpTableOwnerPidListener, 0);
                if (rc == 122) continue;   // the table grew meanwhile: ask again with the new size
                if (rc != 0) return null;
                int? any = null;
                var rows = Marshal.ReadInt32(buffer);
                for (var i = 0; i < rows; i++)
                {
                    // MIB_TCPROW_OWNER_PID: state, local address, local port (network order), remote address, remote port, pid.
                    var row = buffer + 4 + i * 24;
                    var address = (uint)Marshal.ReadInt32(row, 4);
                    var raw = (uint)Marshal.ReadInt32(row, 8);
                    var p = (int)(((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF));
                    if (p != port) continue;
                    var pid = Marshal.ReadInt32(row, 20);
                    if (address == 0x0100007F) return pid;
                    if (address == 0) any ??= pid;
                }
                return any;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        return null;
    }
}
