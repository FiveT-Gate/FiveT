using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Windows.ApplicationModel.DataTransfer;

namespace FiveT;

/// <summary>A one-shot timer on the UI thread (what Ui.After returns). Stop or Dispose to cancel.</summary>
public sealed class UiTimer : IDisposable
{
    private readonly DispatcherQueueTimer _timer;
    private bool _done;

    internal UiTimer(DispatcherQueue queue, TimeSpan interval, Action action)
    {
        _timer = queue.CreateTimer();
        _timer.Interval = interval;
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) =>
        {
            if (_done) return;
            _done = true;
            _timer.Stop();
            action();
        };
        _timer.Start();
    }

    public void Stop()
    {
        _done = true;
        _timer.Stop();
    }

    public void Dispose() => Stop();
}

/// <summary>
/// The UI thread is the app's "main thread": VpnManager and ConnectionStore are only touched there,
/// like the macOS app does with DispatchQueue.main. Background work hops back with Post/Invoke.
/// Backed by the WinUI DispatcherQueue of the XAML thread.
/// </summary>
public static class Ui
{
    public static DispatcherQueue Queue { get; private set; } = null!;
    public static SynchronizationContext Context { get; private set; } = null!;
    private static int _threadId;

    /// <summary>Call once on the XAML thread (inside Application.Start).</summary>
    public static void Install()
    {
        Queue = DispatcherQueue.GetForCurrentThread();
        Context = new DispatcherQueueSynchronizationContext(Queue);
        SynchronizationContext.SetSynchronizationContext(Context);
        _threadId = Environment.CurrentManagedThreadId;
    }

    public static bool IsUiThread => Environment.CurrentManagedThreadId == _threadId;

    public static void Post(Action a) => Queue.TryEnqueue(() => a());

    public static void Invoke(Action a)
    {
        if (IsUiThread) { a(); return; }
        Invoke<object?>(() => { a(); return null; });
    }

    /// <summary>Runs <paramref name="f"/> on the UI thread and waits for the result.</summary>
    public static T Invoke<T>(Func<T> f)
    {
        if (IsUiThread) return f();
        T result = default!;
        Exception? error = null;
        using var done = new ManualResetEventSlim(false);
        var queued = Queue.TryEnqueue(() =>
        {
            try { result = f(); }
            catch (Exception e) { error = e; }
            finally { done.Set(); }
        });
        if (!queued) throw new InvalidOperationException("the UI thread is gone");
        done.Wait();
        if (error != null) throw new AggregateException(error);
        return result;
    }

    /// <summary>Runs <paramref name="a"/> on the UI thread after <paramref name="seconds"/>. Stop the timer to cancel.</summary>
    public static UiTimer After(double seconds, Action a) =>
        new(Queue, TimeSpan.FromMilliseconds(Math.Max(1, seconds * 1000)), a);

    public static void Cancel(ref UiTimer? t)
    {
        if (t == null) return;
        t.Stop();
        t = null;
    }

    /// <summary>
    /// Puts text on the clipboard (from any thread). Another program (a clipboard manager, remote
    /// desktop, the clipboard history) can hold the clipboard open for a moment, which fails the call
    /// with CLIPBRD_E_CANT_OPEN: try again a few times before giving up (the caller reports that).
    /// </summary>
    public static void SetClipboardText(string text)
    {
        Invoke(() =>
        {
            var dp = new DataPackage();
            dp.SetText(text);
            for (var attempt = 0; ; attempt++)
            {
                try { Clipboard.SetContent(dp); break; }
                catch (Exception) when (attempt < 4) { Thread.Sleep(60 * (attempt + 1)); }
            }
            // Flush only keeps the text after FiveT exits; the copy itself has already worked, so a
            // busy clipboard here is not an error.
            try { Clipboard.Flush(); } catch (Exception) { }
        });
    }

    // ---- Plain Win32 message boxes (used before XAML is up, or when no window exists) ----

    public enum MessageIcon : uint { Information = 0x40, Warning = 0x30, Error = 0x10 }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private const uint MB_SETFOREGROUND = 0x10000;

    public static void MessageBox(string text, MessageIcon icon = MessageIcon.Information) =>
        MessageBoxW(IntPtr.Zero, text, "FiveT", (uint)icon | MB_SETFOREGROUND);
}
