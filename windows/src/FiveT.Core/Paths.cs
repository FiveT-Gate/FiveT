using System.Diagnostics;
using System.Reflection;
using System.Security.Principal;

namespace FiveT.Core;

/// <summary>Where FiveT keeps its files on Windows, and how its processes find each other.</summary>
public static class Paths
{
    public const string GuiExe = "FiveT.exe";
    public const string CliExe = "fivetctl.exe";

    /// <summary>
    /// FIVET_DEV=1: developer mode for UI work while the real app is running. The app then keeps its
    /// data in %LOCALAPPDATA%\FiveT-dev, does not elevate, uses its own single-instance mutex and
    /// does not start the MCP server (see Program.cs / TrayApp.cs).
    /// </summary>
    public static bool IsDev { get; } = Environment.GetEnvironmentVariable("FIVET_DEV") == "1";

    /// <summary>The logon task. A developer build gets its own name so installing the task from a test
    /// run can never repoint the real one at a build folder that will not exist tomorrow.</summary>
    public static string TaskName => IsDev ? "FiveT-dev" : "FiveT";

    /// <summary>%LOCALAPPDATA%\FiveT — connections.json, Logs\, run\ (per-user, not roamed).</summary>
    public static string DataDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), IsDev ? "FiveT-dev" : "FiveT");

    public static string ConnectionsFile => Path.Combine(DataDir, "connections.json");
    public static string LogDir => Path.Combine(DataDir, "Logs");
    public static string LogFile => Path.Combine(LogDir, "fivet.log");

    /// <summary>
    /// The MCP pipe name. Named pipes share one namespace per machine, so the user's SID is part of
    /// the name; the server also puts a DACL on it that admits only that user.
    /// FIVET_PIPE=name overrides it (used to test a second copy side by side).
    /// </summary>
    public static string PipeName
    {
        get
        {
            var o = Environment.GetEnvironmentVariable("FIVET_PIPE");
            if (!string.IsNullOrWhiteSpace(o)) return o;
            var sid = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
            return "fivet-mcp-" + sid;
        }
    }

    public static string PipeDisplayPath => @"\\.\pipe\" + PipeName;

    /// <summary>Directory the running executable lives in.</summary>
    public static string ExeDir { get; } = AppContext.BaseDirectory.TrimEnd('\\', '/');

    public static string GuiExePath => Path.Combine(ExeDir, GuiExe);
    public static string CliExePath => Path.Combine(ExeDir, CliExe);

    public static string AppVersion { get; } =
        (Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly())
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "dev";

    public static bool IsElevated
    {
        get
        {
            using var id = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    /// <summary>True when a FiveT.exe GUI process is running in this session.</summary>
    public static bool GuiRunning()
    {
        var me = Environment.ProcessId;
        foreach (var p in Process.GetProcessesByName("FiveT"))
        {
            try { if (p.Id != me && p.SessionId == Process.GetCurrentProcess().SessionId) return true; }
            catch { }
            finally { p.Dispose(); }
        }
        return false;
    }
}
