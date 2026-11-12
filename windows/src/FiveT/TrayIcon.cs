using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace FiveT;

public enum TrayGlyph { Outline, HalfFilled, Filled, Check, Error }

/// <summary>
/// The notification-area icon: Shell_NotifyIcon on a hidden top-level window that receives the
/// click callbacks, the "TaskbarCreated" broadcast (Explorer restarted) and theme changes.
/// The shield glyphs are drawn with System.Drawing and cached as HICONs.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    /// <summary>Left click, Enter or Space on the icon. Arguments: anchor point in screen pixels.</summary>
    public event Action<int, int>? Selected;
    /// <summary>Right click or Shift+F10 on the icon. Arguments: anchor point in screen pixels.</summary>
    public event Action<int, int>? ContextRequested;
    /// <summary>The system switched between light and dark.</summary>
    public event Action? ThemeChanged;
    /// <summary>The PC woke from sleep or hibernation.</summary>
    public event Action? Resumed;
    /// <summary>The PC is about to sleep or hibernate.</summary>
    public event Action? Suspending;

    private const string ClassName = "FiveT.TrayWindow";
    private const uint IconId = 1;
    private const uint WM_TRAY = 0x0400 + 1;      // WM_USER + 1
    private const uint WM_SETTINGCHANGE = 0x001A;
    private const uint WM_CONTEXTMENU = 0x007B;
    private const uint WM_POWERBROADCAST = 0x0218;
    private const uint PBT_APMRESUMEAUTOMATIC = 0x0012;   // sent on every resume, with or without a user present
    private const uint PBT_APMSUSPEND = 0x0004;
    private const uint NIN_SELECT = 0x0400;
    private const uint NIN_KEYSELECT = 0x0401;

    private readonly WndProcDelegate _proc;
    private readonly IntPtr _hwnd;
    private readonly uint _taskbarCreated;
    private readonly Dictionary<string, IntPtr> _iconCache = new();
    private IntPtr _currentIcon;
    private string _tip = "FiveT";
    private bool _added;

    public TrayIcon()
    {
        _proc = WndProc;
        var hInstance = GetModuleHandleW(null);
        var cls = new WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = hInstance,
            lpszClassName = ClassName,
        };
        RegisterClassExW(ref cls);
        // A real (never shown) top-level window, not a message-only one: broadcasts such as
        // TaskbarCreated and WM_SETTINGCHANGE only reach top-level windows.
        _hwnd = CreateWindowExW(0, ClassName, "FiveT", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        _taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        // Top-level windows get WM_POWERBROADCAST anyway; on Modern Standby PCs this also delivers it
        // for the S0 low-power idle that replaces classic sleep.
        _powerNotify = RegisterSuspendResumeNotification(_hwnd, 0 /* DEVICE_NOTIFY_WINDOW_HANDLE */);
    }

    private readonly IntPtr _powerNotify;

    /// <summary>Adds the icon to the notification area (call after the first SetIcon).</summary>
    public void Show()
    {
        var d = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        d.uCallbackMessage = WM_TRAY;
        d.hIcon = _currentIcon;
        d.szTip = _tip;
        Shell_NotifyIconW(NIM_ADD, ref d);
        d.uTimeoutOrVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, ref d);
        _added = true;
    }

    public void SetIcon(TrayGlyph glyph, string tooltip)
    {
        var icon = MakeIcon(glyph);
        var tip = tooltip.Length > 127 ? tooltip[..126] + "…" : tooltip;
        // Icons are cached, so the same glyph is the same handle: a status line that changes nothing
        // visible (a login prints dozens) does not need a call into Explorer.
        if (_added && icon == _currentIcon && tip == _tip) return;
        _currentIcon = icon;
        _tip = tip;
        if (!_added) return;
        var d = Data(NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        d.hIcon = _currentIcon;
        d.szTip = _tip;
        Shell_NotifyIconW(NIM_MODIFY, ref d);
    }

    /// <summary>Balloon notification; Windows 10/11 show it as a toast.</summary>
    public void ShowBalloon(string title, string text, bool isError)
    {
        if (!_added) return;
        var d = Data(NIF_INFO);
        d.szInfoTitle = title.Length > 63 ? title[..63] : title;
        d.szInfo = text.Length > 255 ? text[..255] : text;
        d.dwInfoFlags = isError ? NIIF_ERROR : NIIF_INFO;
        d.uTimeoutOrVersion = 4000;
        Shell_NotifyIconW(NIM_MODIFY, ref d);
    }

    /// <summary>Screen rectangle of the icon (empty when hidden in the overflow area).</summary>
    public RECT GetRect()
    {
        var id = new NOTIFYICONIDENTIFIER { cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = _hwnd, uID = IconId };
        return Shell_NotifyIconGetRect(ref id, out var rect) == 0 ? rect : default;
    }

    public void Dispose()
    {
        if (_added)
        {
            var d = Data(0);
            Shell_NotifyIconW(NIM_DELETE, ref d);
            _added = false;
        }
        if (_powerNotify != IntPtr.Zero) UnregisterSuspendResumeNotification(_powerNotify);
        if (_hwnd != IntPtr.Zero) DestroyWindow(_hwnd);
        foreach (var h in _iconCache.Values) DestroyIcon(h);
        _iconCache.Clear();
    }

    private NOTIFYICONDATAW Data(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
        hWnd = _hwnd,
        uID = IconId,
        uFlags = flags,
        szTip = "",
        szInfo = "",
        szInfoTitle = "",
    };

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_TRAY)
        {
            var ev = (uint)(lParam.ToInt64() & 0xFFFF);
            int x = (short)(wParam.ToInt64() & 0xFFFF), y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            switch (ev)
            {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    Selected?.Invoke(x, y);
                    break;
                case WM_CONTEXTMENU:
                    ContextRequested?.Invoke(x, y);
                    break;
            }
            return IntPtr.Zero;
        }
        if (msg == _taskbarCreated && _added)
        {
            _added = false;
            Show();   // Explorer restarted: the icon is gone, add it again
            return IntPtr.Zero;
        }
        if (msg == WM_SETTINGCHANGE && lParam != IntPtr.Zero && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            ThemeChanged?.Invoke();
        }
        if (msg == WM_POWERBROADCAST && (uint)wParam.ToInt64() == PBT_APMSUSPEND)
        {
            Suspending?.Invoke();
            return new IntPtr(1);
        }
        if (msg == WM_POWERBROADCAST && (uint)wParam.ToInt64() == PBT_APMRESUMEAUTOMATIC)
        {
            Resumed?.Invoke();
            return new IntPtr(1);   // TRUE
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    // MARK: Drawing

    private IntPtr MakeIcon(TrayGlyph g)
    {
        var light = Native.TaskbarIsLight();
        var size = Native.SmallIconSize();
        var key = $"{g}-{light}-{size}";
        if (_iconCache.TryGetValue(key, out var cached)) return cached;
        var fg = light ? Color.Black : Color.White;
        using var bmp = new Bitmap(size, size);
        using (var gr = Graphics.FromImage(bmp))
        {
            gr.SmoothingMode = SmoothingMode.AntiAlias;
            gr.Clear(Color.Transparent);
            var s = size;
            using var shield = ShieldPath(s);
            var stroke = Math.Max(1.2f, s / 12f);
            switch (g)
            {
                case TrayGlyph.Outline:
                    using (var pen = new Pen(fg, stroke)) gr.DrawPath(pen, shield);
                    break;
                case TrayGlyph.HalfFilled:
                    using (var pen = new Pen(fg, stroke)) gr.DrawPath(pen, shield);
                    gr.SetClip(new RectangleF(0, 0, s / 2f, s));
                    using (var b = new SolidBrush(fg)) gr.FillPath(b, shield);
                    gr.ResetClip();
                    break;
                case TrayGlyph.Filled:
                    using (var b = new SolidBrush(fg)) gr.FillPath(b, shield);
                    break;
                case TrayGlyph.Check:
                    using (var b = new SolidBrush(fg)) gr.FillPath(b, shield);
                    using (var pen = new Pen(light ? Color.White : Color.Black, Math.Max(1.5f, s / 8f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                        gr.DrawLines(pen, new[] { new PointF(s * 0.30f, s * 0.50f), new PointF(s * 0.45f, s * 0.65f), new PointF(s * 0.70f, s * 0.36f) });
                    break;
                case TrayGlyph.Error:
                    using (var b = new SolidBrush(Color.FromArgb(230, 60, 50))) gr.FillPath(b, shield);
                    using (var pen = new Pen(Color.White, Math.Max(1.5f, s / 8f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    {
                        gr.DrawLine(pen, s * 0.5f, s * 0.28f, s * 0.5f, s * 0.55f);
                        gr.DrawLine(pen, s * 0.5f, s * 0.70f, s * 0.5f, s * 0.71f);
                    }
                    break;
            }
        }
        var icon = bmp.GetHicon();
        _iconCache[key] = icon;
        return icon;
    }

    /// <summary>A shield: flat top, straight sides that curve into a point at the bottom.</summary>
    private static GraphicsPath ShieldPath(int s)
    {
        var p = new GraphicsPath();
        float l = s * 0.14f, r = s * 0.86f, t = s * 0.10f, mid = s * 0.52f, bottom = s * 0.94f, cx = s * 0.5f;
        p.StartFigure();
        p.AddLine(l, t, r, t);
        p.AddLine(r, t, r, mid);
        p.AddBezier(r, mid, r, s * 0.74f, s * 0.66f, s * 0.86f, cx, bottom);
        p.AddBezier(cx, bottom, s * 0.34f, s * 0.86f, l, s * 0.74f, l, mid);
        p.CloseFigure();
        return p;
    }

    // MARK: Win32

    private const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    private const uint NIF_MESSAGE = 0x01, NIF_ICON = 0x02, NIF_TIP = 0x04, NIF_INFO = 0x10, NIF_SHOWTIP = 0x80;
    private const uint NIIF_INFO = 0x01, NIIF_ERROR = 0x03;
    private const uint NOTIFYICON_VERSION_4 = 4;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEXW
    {
        public uint cbSize, style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public bool IsEmpty => Right <= Left || Bottom <= Top;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassExW(ref WNDCLASSEXW cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? name);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);
    [DllImport("shell32.dll")] private static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr RegisterSuspendResumeNotification(IntPtr recipient, uint flags);
    [DllImport("user32.dll")] private static extern bool UnregisterSuspendResumeNotification(IntPtr handle);
}
