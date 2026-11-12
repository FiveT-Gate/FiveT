using System.ComponentModel;
using System.Diagnostics;
using FiveT.Core;
using Microsoft.UI.Xaml;

namespace FiveT;

internal static class Program
{
    /// <summary>
    /// Entry point. FiveT is a tray-only app (no taskbar button). It needs administrator rights to
    /// create the tunnel, so it relaunches itself elevated once (a UAC prompt) unless the login task
    /// started it that way. Flags: --setup / --settings open the Settings window directly.
    /// The CLI and the MCP bridge live in fivetctl.exe, see that project.
    ///
    /// FIVET_DEV=1 (developer mode, see Paths.IsDev): no elevation, own mutex, no MCP server and a
    /// separate data folder, so a build under test can run next to the installed app.
    /// </summary>
    [STAThread]
    private static int Main(string[] args)
    {
        // A fivet:// link: Windows starts a new FiveT.exe with the URL. Hand it to the copy that is
        // already running (never elevated for this, and never a second tray icon).
        var link = args.FirstOrDefault(Links.IsLink);
        if (link != null && Paths.GuiRunning())
        {
            if (Links.Forward(link)) return 0;
            Ui.MessageBox("FiveT is running but did not answer the link. Try again in a moment.", Ui.MessageIcon.Warning);
            return 1;
        }

        if (!Paths.IsDev && !Paths.IsElevated)
        {
            // A plain double-click while the (elevated) app is already up: just say so.
            if (Paths.GuiRunning()) { AlreadyRunning(); return 0; }
            return Relaunch(args, link) ? 0 : 1;
        }

        // The installer and uninstaller call these (already elevated) so a fresh install starts at
        // logon as administrator without the user having to visit Settings first. No window opens.
        if (args.Contains("--install-login-task") || args.Contains("--remove-login-task"))
        {
            var removing = args.Contains("--remove-login-task");
            var err = removing ? Setup.RemoveLoginTask() : Setup.InstallLoginTask();
            if (err != null) Log.Shared.Write($"installer: login task {(removing ? "removal" : "install")} failed: {err}", LogLevel.Error);
            if (removing)
            {
                // The uninstaller: fivet:// must not point at a deleted exe, and what FiveT made in Windows goes
                // with it: its DNS rules and its two OpenVPN adapters. (Kill-switch filters cannot be left over:
                // Windows removes them when FiveT exits.) Never anything FiveT did not make.
                Links.Unregister();
                try { SplitDns.RemoveAll(); } catch { }
                try { Setup.RemoveOpenVpnAdapters(); } catch { }
            }
            return err == null ? 0 : 1;
        }

        // One instance per session: the mutex is only compared between elevated instances, so the
        // non-elevated launcher that started us can never be mistaken for a running copy.
        Mutex? mutex = null;
        try
        {
            mutex = new Mutex(true, Paths.IsDev ? @"Local\FiveT.tray.dev" : @"Local\FiveT.tray", out var first);
            if (!first)
            {
                if (link != null) return Links.Forward(link, 10_000) ? 0 : 1;
                AlreadyRunning();
                return 0;
            }
        }
        catch (Exception e)
        {
            Log.Shared.Write($"single-instance check failed: {e.Message}", LogLevel.Error);
        }
        using var _ = mutex;

        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Shared.Write($"unhandled: {e.ExceptionObject}", LogLevel.Error);
        TaskScheduler.UnobservedTaskException += (_, e) => { Log.Shared.Write($"unobserved: {e.Exception}", LogLevel.Error); e.SetObserved(); };

        // Self-contained Windows App SDK: no bootstrapper call needed, the runtime sits next to the exe.
        WinRT.ComWrappersSupport.InitializeComWrappers();
        try
        {
            Application.Start(_ =>
            {
                Ui.Install();
                new App(args);
            });
        }
        catch (Exception e)
        {
            // A XAML or Windows App SDK failure here surfaces as an opaque COM error with no window and
            // nothing in the log, which is impossible to diagnose on someone else's PC. Write it down.
            Log.Shared.Write($"fatal: the user interface could not start: {e}", LogLevel.Error);
            Ui.MessageBox($"FiveT could not start its user interface.\n\n{e.Message}\n\nDetails are in the log:\n{Paths.LogFile}",
                Ui.MessageIcon.Error);
            return 1;
        }
        return 0;
    }

    private static void AlreadyRunning() =>
        Ui.MessageBox("FiveT is already running. Look for the shield icon in the notification area (it may be hidden behind the ^ arrow).");

    /// <summary>Starts a new elevated copy of this exe (UAC). Returns false when the user cancelled.</summary>
    private static bool Relaunch(string[] args, string? link)
    {
        // Prefer the login task: it starts the app elevated without a prompt and is owned by this user.
        // It cannot pass arguments, so a link is handed over once the new copy is listening.
        var onlyLink = args.Length == 0 || (link != null && args.Length == 1);
        if (onlyLink && Setup.LoginTaskCommand() is { } cmd && cmd.Contains(Paths.GuiExePath, StringComparison.OrdinalIgnoreCase))
        {
            var r = Setup.Run("schtasks.exe", new[] { "/Run", "/TN", Paths.TaskName });
            if (r.Status == 0) return link == null || Links.Forward(link, 20_000);
        }
        try
        {
            var psi = new ProcessStartInfo(Paths.GuiExePath) { UseShellExecute = true, Verb = "runas" };
            foreach (var a in args) psi.ArgumentList.Add(a);
            Process.Start(psi);
            return true;
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223)   // ERROR_CANCELLED
        {
            Ui.MessageBox("FiveT needs administrator rights to create the VPN tunnel.\n\nStart it again and accept the prompt, or turn on \"Start FiveT at login\" in Settings → General so it starts without one.",
                Ui.MessageIcon.Warning);
            return false;
        }
        catch (Exception e)
        {
            Ui.MessageBox("Could not start FiveT as administrator: " + e.Message, Ui.MessageIcon.Error);
            return false;
        }
    }
}
