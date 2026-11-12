using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace FiveT;

/// <summary>The few Win32 calls the app needs that .NET does not wrap.</summary>
internal static class Native
{
    // ---- Console control (graceful stop of openconnect, which has no SIGTERM on Windows) ----

    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
    public const uint CTRL_C_EVENT = 0;

    /// <summary>
    /// Sends Ctrl+C to a console child process (started with CreateNoWindow, so it owns a hidden
    /// console). openconnect treats it like SIGINT: it runs the vpnc-script "disconnect" step,
    /// which restores routes and DNS, then exits. Returns false when the console could not be reached.
    /// </summary>
    public static bool SendCtrlC(int pid)
    {
        FreeConsole();
        if (!AttachConsole((uint)pid)) return false;
        try
        {
            SetConsoleCtrlHandler(IntPtr.Zero, true);   // do not let the event kill *us*
            return GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
        }
        finally
        {
            FreeConsole();
            // The event is delivered asynchronously (a thread the console host injects), so the
            // ignore flag must stay on until it has arrived: clearing it at once lets the default
            // handler terminate this process. The flag is per process and inherited by children,
            // which is why AllowCtrlC() runs before every openconnect launch.
            _ = Task.Delay(3000).ContinueWith(_ => SetConsoleCtrlHandler(IntPtr.Zero, false));
        }
    }

    /// <summary>Stops ignoring Ctrl+C (before starting a child process that must react to it).</summary>
    public static void AllowCtrlC() => SetConsoleCtrlHandler(IntPtr.Zero, false);

    // ---- DPAPI ----

    [StructLayout(LayoutKind.Sequential)]
    private struct DATA_BLOB { public int cbData; public IntPtr pbData; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref DATA_BLOB dataIn, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr promptStruct, uint flags, out DATA_BLOB dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(ref DATA_BLOB dataIn, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr promptStruct, uint flags, out DATA_BLOB dataOut);

    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr h);

    private const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    public static byte[] DpapiProtect(byte[] plain)
    {
        var inBlob = new DATA_BLOB { cbData = plain.Length, pbData = Marshal.AllocHGlobal(Math.Max(plain.Length, 1)) };
        try
        {
            Marshal.Copy(plain, 0, inBlob.pbData, plain.Length);
            if (!CryptProtectData(ref inBlob, "FiveT", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var outBlob))
                throw new System.ComponentModel.Win32Exception();
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally { LocalFree(outBlob.pbData); }
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); }
    }

    public static byte[] DpapiUnprotect(byte[] cipher)
    {
        var inBlob = new DATA_BLOB { cbData = cipher.Length, pbData = Marshal.AllocHGlobal(Math.Max(cipher.Length, 1)) };
        try
        {
            Marshal.Copy(cipher, 0, inBlob.pbData, cipher.Length);
            if (!CryptUnprotectData(ref inBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var outBlob))
                throw new System.ComponentModel.Win32Exception();
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally { LocalFree(outBlob.pbData); }
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); }
    }

    // ---- IPv4 routing table ----

    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_IPFORWARDROW
    {
        public uint dwForwardDest, dwForwardMask, dwForwardPolicy, dwForwardNextHop, dwForwardIfIndex, dwForwardType,
                    dwForwardProto, dwForwardAge, dwForwardNextHopAS, dwForwardMetric1, dwForwardMetric2,
                    dwForwardMetric3, dwForwardMetric4, dwForwardMetric5;
    }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern int GetIpForwardTable(IntPtr table, ref int size, bool order);

    /// <summary>All IPv4 routes (destination, mask, next hop, interface index).</summary>
    public static List<MIB_IPFORWARDROW> IpForwardTable()
    {
        var rows = new List<MIB_IPFORWARDROW>();
        var size = 0;
        GetIpForwardTable(IntPtr.Zero, ref size, false);
        if (size <= 0) return rows;
        var buf = Marshal.AllocHGlobal(size);
        try
        {
            if (GetIpForwardTable(buf, ref size, false) != 0) return rows;
            var count = Marshal.ReadInt32(buf);
            var rowSize = Marshal.SizeOf<MIB_IPFORWARDROW>();
            for (var i = 0; i < count; i++)
                rows.Add(Marshal.PtrToStructure<MIB_IPFORWARDROW>(buf + 4 + i * rowSize));
        }
        finally { Marshal.FreeHGlobal(buf); }
        return rows;
    }

    public static string Ipv4(uint networkOrder)
    {
        var b = BitConverter.GetBytes(networkOrder);
        return $"{b[0]}.{b[1]}.{b[2]}.{b[3]}";
    }

    public static int PrefixLength(uint maskNetworkOrder)
    {
        var b = BitConverter.GetBytes(maskNetworkOrder);
        var mask = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
        var n = 0;
        while (n < 32 && (mask & (0x80000000u >> n)) != 0) n++;
        return n;
    }

    // ---- Taskbar theme (for the tray icon colour) ----

    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    private const int SM_CXSMICON = 49;

    public static int SmallIconSize() => Math.Max(16, GetSystemMetrics(SM_CXSMICON));

    /// <summary>True when the taskbar is light (so the tray glyph must be dark).</summary>
    public static bool TaskbarIsLight()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch { return false; }
    }
}

/// <summary>DPAPI (current user) round trips as base64 strings.</summary>
public static class Dpapi
{
    public static string Protect(string plain) =>
        Convert.ToBase64String(Native.DpapiProtect(System.Text.Encoding.UTF8.GetBytes(plain)));

    public static string Unprotect(string base64) =>
        System.Text.Encoding.UTF8.GetString(Native.DpapiUnprotect(Convert.FromBase64String(base64)));
}
