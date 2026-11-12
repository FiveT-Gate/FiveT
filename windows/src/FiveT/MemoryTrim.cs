using System.Runtime;
using System.Runtime.InteropServices;

namespace FiveT;

/// <summary>
/// Gives memory back while FiveT sits in the tray. A WinUI 3 process touches a lot of memory while it
/// starts and while a window is open (XAML parsing, composition, text shaping, JIT) and then never
/// needs most of those pages again; left alone they stay in the working set until Windows runs short
/// of RAM. Trimming moves them to the standby list: still instantly reusable (a soft page fault) but
/// no longer counted against FiveT, which is what Task Manager shows and what a 4 GB PC feels.
/// This is what Windows itself does to an app whose window is minimised.
///
/// Asked for after the start and after a window hides or closes, and never while one is on screen.
/// Nothing runs on a timer: an idle FiveT does no periodic work for this.
/// </summary>
internal static class MemoryTrim
{
    private static UiTimer? _timer;

    /// <summary>Set by TrayApp: whether the flyout or Settings is open (trimming under a visible window would only cause page faults).</summary>
    public static Func<bool> WindowOpen { get; set; } = () => false;

    /// <summary>Trims in <paramref name="seconds"/> (the timer restarts when asked again meanwhile). UI thread only.</summary>
    public static void Soon(double seconds = 5)
    {
        Ui.Cancel(ref _timer);
        _timer = Ui.After(seconds, () => { _timer = null; Now(); });
    }

    public static void Now()
    {
        if (WindowOpen()) return;   // the next hide asks again
        try
        {
            // Managed heap first (it is small, ~2 MB, but a collection also drops caches that point at
            // freed windows), then the whole working set.
            GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.WaitForPendingFinalizers();
            K32EmptyWorkingSet(GetCurrentProcess());
        }
        catch (Exception e)
        {
            Log.Shared.Write($"memory trim failed: {e.Message}", LogLevel.Debug);
        }
    }

    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool K32EmptyWorkingSet(IntPtr process);
}
