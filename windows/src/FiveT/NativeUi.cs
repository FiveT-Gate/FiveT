using System.Runtime.InteropServices;

namespace FiveT;

/// <summary>Win32 calls the WinUI windows need (DPI, DWM corners, foreground, the classic file dialog).</summary>
internal static class NativeUi
{
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public static double Scale(IntPtr hwnd) => GetDpiForWindow(hwnd) / 96.0;

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, uint attr, ref int value, int size);
    private const uint DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUND = 2;

    /// <summary>Asks DWM for rounded corners (Windows 11; ignored on Windows 10).</summary>
    public static void RoundCorners(IntPtr hwnd)
    {
        var v = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref v, sizeof(int));
    }

    // ---- GetOpenFileName: the UWP FileOpenPicker refuses to run in an elevated process, this one does not. ----

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OPENFILENAMEW
    {
        public uint lStructSize;
        public IntPtr hwndOwner, hInstance;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpstrFilter;
        public IntPtr lpstrCustomFilter;
        public uint nMaxCustFilter, nFilterIndex;
        public IntPtr lpstrFile;
        public uint nMaxFile;
        public IntPtr lpstrFileTitle;
        public uint nMaxFileTitle;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpstrInitialDir;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpstrTitle;
        public uint Flags;
        public ushort nFileOffset, nFileExtension;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpstrDefExt;
        public IntPtr lCustData, lpfnHook;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpTemplateName;
        public IntPtr pvReserved;
        public uint dwReserved, FlagsEx;
    }

    [DllImport("comdlg32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetOpenFileNameW(ref OPENFILENAMEW ofn);

    private const uint OFN_NOCHANGEDIR = 0x8, OFN_PATHMUSTEXIST = 0x800, OFN_FILEMUSTEXIST = 0x1000, OFN_EXPLORER = 0x80000;

    /// <summary>Modal "open file" dialog. <paramref name="filter"/> uses the classic "Name|pattern|Name|pattern" form.</summary>
    public static string? OpenFile(IntPtr owner, string title, string filter)
    {
        const int max = 32768;
        var buffer = Marshal.AllocHGlobal(max * 2);
        try
        {
            Marshal.WriteInt16(buffer, 0);
            var ofn = new OPENFILENAMEW
            {
                lStructSize = (uint)Marshal.SizeOf<OPENFILENAMEW>(),
                hwndOwner = owner,
                lpstrFilter = filter.Replace('|', '\0') + "\0\0",
                nFilterIndex = 1,
                lpstrFile = buffer,
                nMaxFile = max,
                lpstrTitle = title,
                Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR,
            };
            return GetOpenFileNameW(ref ofn) ? Marshal.PtrToStringUni(buffer) : null;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
