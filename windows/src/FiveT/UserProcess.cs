using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace FiveT;

/// <summary>
/// Starts a program with the rights of the user's own desktop, not FiveT's administrator rights. FiveT runs elevated, and a
/// child of an elevated process is elevated too: Chrome or Slack started that way would run as administrator even though
/// the user's desktop does not. Windows has no call for "start this unelevated", so the program is started with a copy of the
/// token of the desktop's shell: the rights a double click would give it (unelevated on a PC with UAC; on a PC whose desktop
/// itself runs as administrator, as elevated as everything else there). If that is not possible nothing is started: never
/// FiveT's own elevated rights as a fallback.
/// </summary>
public static class UserProcess
{
    // A console program gets a console of its own: it cannot join FiveT's, which has more rights than it does. A program with a window ignores the flag.
    private const uint CreateUnicodeEnvironment = 0x00000400, CreateNewConsole = 0x00000010;
    private const uint ProcessQueryLimitedInformation = 0x1000, TokenAssignPrimary = 0x1, TokenDuplicate = 0x2, TokenQuery = 0x8;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int impersonationLevel, int tokenType, out IntPtr duplicate);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string? application, StringBuilder commandLine, uint flags,
        IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInformation info);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int tokenClass, out int info, int length, out int returned);

    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);

    /// <summary>The process that draws this user's desktop (the owner of the shell window), or null when there is none. Not just any explorer.exe: another one may have been started elevated.</summary>
    public static int? ShellProcessId()
    {
        var window = GetShellWindow();
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out var pid) != 0 && pid != 0 ? pid : null;
    }

    /// <summary>Starts <paramref name="exe"/> unelevated, with <paramref name="arguments"/> and the environment of this process plus <paramref name="environment"/>. Its process id, or why it could not start.</summary>
    public static (int? Pid, string? Problem) Start(string exe, string arguments, IReadOnlyDictionary<string, string> environment)
    {
        IntPtr process = IntPtr.Zero, token = IntPtr.Zero, primary = IntPtr.Zero, env = IntPtr.Zero;
        try
        {
            if (ShellProcessId() is not { } shell) return (null, "Windows has no desktop shell running, so there is no desktop user to start the app for.");
            process = OpenProcess(ProcessQueryLimitedInformation, false, shell);
            if (process == IntPtr.Zero || !OpenProcessToken(process, TokenDuplicate | TokenQuery | TokenAssignPrimary, out token))
                return (null, $"could not read the desktop user's rights (error {Marshal.GetLastWin32Error()})");
            // SecurityImpersonation (2), a primary token (1).
            if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary))
                return (null, $"could not copy the desktop user's rights (error {Marshal.GetLastWin32Error()})");
            return StartWithToken(primary, exe, arguments, environment);
        }
        finally
        {
            if (primary != IntPtr.Zero) CloseHandle(primary);
            if (token != IntPtr.Zero) CloseHandle(token);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }

    /// <summary>Starts the program with <paramref name="primary"/>, a primary token, and nothing from FiveT's own rights.</summary>
    internal static (int? Pid, string? Problem) StartWithToken(IntPtr primary, string exe, string arguments, IReadOnlyDictionary<string, string> environment)
    {
        var env = IntPtr.Zero;
        try
        {
            var vars = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) vars[(string)e.Key] = (string?)e.Value ?? "";
            foreach (var (k, v) in environment) vars[k] = v;
            env = Marshal.StringToHGlobalUni(string.Concat(vars.Select(kv => $"{kv.Key}={kv.Value}\0")) + "\0");

            var startup = new StartupInfo { lpDesktop = @"winsta0\default" };
            startup.cb = Marshal.SizeOf<StartupInfo>();
            var command = new StringBuilder($"\"{exe}\"" + (arguments.Length > 0 ? " " + arguments : ""));
            if (!CreateProcessWithTokenW(primary, 0, null, command, CreateUnicodeEnvironment | CreateNewConsole, env, Path.GetDirectoryName(exe), ref startup, out var info))
                return (null, new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
            return (info.dwProcessId, null);
        }
        finally { if (env != IntPtr.Zero) Marshal.FreeHGlobal(env); }
    }

    private static bool? IsElevatedToken(IntPtr token) =>
        GetTokenInformation(token, 20, out var elevated, sizeof(int), out _) ? elevated != 0 : null;   // TokenElevation

    /// <summary>True when the process with this id runs elevated (administrator rights in force); null when that cannot be read.</summary>
    public static bool? IsElevated(int pid)
    {
        var process = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (process == IntPtr.Zero) return null;
        try
        {
            if (!OpenProcessToken(process, TokenQuery, out var token)) return null;
            try { return IsElevatedToken(token); }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
