using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using FiveT.Core;

namespace FiveT;

public enum SetupFix { InstallOpenconnect, ChooseOpenconnect, Elevate, InstallLoginTask }

public sealed record SetupCheck(string Id, string Title, bool Ok, string Detail, SetupFix? Fix);

/// <summary>Environment checks, process helpers and the one-time privileged setup (the login task).</summary>
public static class Setup
{
    public const string AdapterName = "FiveT";

    /// <summary>
    /// Where openconnect.exe may be, in order of preference. FiveT runs as administrator and
    /// connections.json can be written by any program of the user, so nothing is searched in places an
    /// ordinary program can plant a file (the PATH, %LOCALAPPDATA%); the path chosen in Settings comes
    /// last. <see cref="FindOpenconnect"/> still runs only a copy whose folder passes
    /// <see cref="IsAdminOnlyDirectory"/>.
    /// </summary>
    public static IEnumerable<string> CandidatePaths()
    {
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        yield return Path.Combine(Paths.ExeDir, "openconnect", "openconnect.exe");
        yield return Path.Combine(pf, "OpenConnect", "openconnect.exe");
        yield return Path.Combine(pf, "OpenConnect-GUI", "openconnect.exe");
        yield return Path.Combine(pf86, "OpenConnect-GUI", "openconnect.exe");
        yield return @"C:\msys64\mingw64\bin\openconnect.exe";
        yield return @"C:\msys64\ucrt64\bin\openconnect.exe";
        yield return @"C:\msys64\clang64\bin\openconnect.exe";
        // Read from connections.json, so not to be believed: a full path to a file called openconnect.exe, and its folder has to pass the check.
        var chosen = ConnectionStore.Shared.OpenconnectPath.Trim();
        if (chosen.Length > 0 && Path.IsPathFullyQualified(chosen)
            && string.Equals(Path.GetFileName(chosen), "openconnect.exe", StringComparison.OrdinalIgnoreCase))
            yield return chosen;
    }

    /// <summary>The openconnect.exe FiveT runs, or null.</summary>
    public static string? OpenconnectPath => FindOpenconnect(out _);

    private static readonly HashSet<string> RefusalLogged = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The first usable openconnect.exe. <paramref name="refused"/> is the first one that exists but sits
    /// in a folder ordinary programs can change (and so is not used), for the setup check to explain.
    /// </summary>
    public static string? FindOpenconnect(out string? refused)
    {
        refused = null;
        foreach (var p in CandidatePaths())
        {
            try
            {
                if (!File.Exists(p)) continue;
                if (IsTrustedFolder(Path.GetDirectoryName(p))) return p;
                refused ??= p;
                bool first;
                lock (RefusalLogged) first = RefusalLogged.Add(p);
                if (first) Log.Shared.Write($"not using {p}: its folder can be changed by ordinary programs, and FiveT would run it as administrator", LogLevel.Error);
            }
            catch { }
        }
        return null;
    }

    private const string UnsafeFolderText =
        "openconnect.exe is in a folder that ordinary programs can change; FiveT only runs it from Program Files or its own install folder.";

    /// <summary>The plain-words reason openconnect.exe is refused, or null when it is usable or not found at all.</summary>
    public static string? OpenconnectRefusal => FindOpenconnect(out var refused) == null && refused != null ? UnsafeFolderText : null;

    /// <summary>
    /// Developer builds (FIVET_DEV=1) are not elevated and live in folders the user can change, so for them the check is
    /// skipped. Only while not elevated: FIVET_DEV is an environment variable, and a program that sets it for the user
    /// must not be able to switch the check off for the elevated login task.
    /// </summary>
    private static bool IsTrustedFolder(string? dir) =>
        (Paths.IsDev && !Paths.IsElevated) || (!string.IsNullOrEmpty(dir) && IsAdminOnlyDirectory(dir));

    // Who may hold write access to a folder FiveT runs code from: SYSTEM, Administrators, TrustedInstaller,
    // and the CREATOR placeholders (they only describe what gets created inside later).
    private static readonly HashSet<SecurityIdentifier> AdminSids = new()
    {
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
        new SecurityIdentifier(WellKnownSidType.CreatorOwnerSid, null),
        new SecurityIdentifier(WellKnownSidType.CreatorGroupSid, null),
        new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"),   // NT SERVICE\TrustedInstaller
    };

    private const int GenericAll = 0x10000000, GenericWrite = 0x40000000;   // still unmapped in inherit-only rules

    // For the folder itself and the files in it: anything that adds, changes, replaces or removes a file,
    // or hands out the right to. (CreateFiles = WriteData and CreateDirectories = AppendData.)
    private const int ChangesFolder = (int)(FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.DeleteSubdirectoriesAndFiles
                                            | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership)
                                      | GenericAll | GenericWrite;

    // For the folders above it: only what lets someone move or delete the folder below, or give themselves that right.
    // Creating new entries (the root of C: lets every user create folders) does not touch an existing one.
    private const int ReplacesChild = (int)(FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.Delete
                                            | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership)
                                      | GenericAll;

    /// <summary>
    /// True only when nobody but SYSTEM, Administrators and TrustedInstaller can change this folder, the files
    /// in it, or any folder above it up to the volume root. FiveT runs as administrator, so whatever it runs
    /// from a place an ordinary program can write to would be a way to administrator rights.
    /// Any failure to read the permissions counts as "not admin-only".
    /// </summary>
    public static bool IsAdminOnlyDirectory(string path)
    {
        try
        {
            var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            if (full.StartsWith(@"\\", StringComparison.Ordinal)) return false;   // a network share, or a device path
            var start = new DirectoryInfo(full);
            if (!start.Exists) return false;
            var first = true;
            for (var d = start; d != null; d = d.Parent, first = false)
            {
                // A junction or symbolic link means the folder whose permissions we read is not the one that is used.
                if ((d.Attributes & FileAttributes.ReparsePoint) != 0) return false;
                var acl = d.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
                // The owner can always rewrite the permissions.
                if (acl.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !AdminSids.Contains(owner)) return false;
                var forbidden = first ? ChangesFolder : ReplacesChild;
                foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                {
                    if (rule.AccessControlType != AccessControlType.Allow) continue;
                    if (rule.IdentityReference is SecurityIdentifier who && AdminSids.Contains(who)) continue;
                    // A rule for what is created below (InheritOnly) is not about this folder: the next one down carries it itself.
                    if (!first && rule.PropagationFlags.HasFlag(PropagationFlags.InheritOnly)) continue;
                    if (((int)rule.FileSystemRights & forbidden) != 0) return false;
                }
            }
            return true;
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not read the permissions of {path}: {e.Message}", LogLevel.Debug);
            return false;
        }
    }

    // ---- The VPN programs (OpenVPN, Xray) ----

    /// <summary>FiveT's own xray.exe (V2Ray, Outline), or null when it is missing or its folder can be changed by ordinary programs.</summary>
    public static string? XrayPath => Engine("xray", "xray.exe");
    /// <summary>FiveT's own openvpn.exe, under the same rule.</summary>
    public static string? OpenVpnPath => Engine("openvpn", "openvpn.exe");

    // Only ever the copy in FiveT's install folder: FiveT runs these as administrator.
    private static string? Engine(string folder, string exe)
    {
        var path = Path.Combine(Paths.ExeDir, folder, exe);
        return File.Exists(path) && IsTrustedFolder(Path.GetDirectoryName(path)) ? path : null;
    }

    /// <summary>
    /// OpenVPN needs a network adapter of its own, made once: "FiveT OpenVPN" on the fast kernel driver
    /// (ovpn-dco), or "FiveT OpenVPN TAP" on the older TAP driver for profiles the fast one cannot carry
    /// (compression, old ciphers). The signed drivers come with FiveT (openvpn\drivers). Returns null when
    /// the adapter is there, or why it could not be made. Takes a few seconds the first time; call off the UI thread.
    /// </summary>
    public static string? EnsureOpenVpnAdapter(bool tap)
    {
        var name = tap ? VpnManager.OpenVpnTapAdapter : VpnManager.OpenVpnAdapter;
        try
        {
            if (System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces().Any(n => n.Name == name)) return null;
            if (OpenVpnPath is not { } exe) return "OpenVPN is missing from this copy of FiveT. Install FiveT with its setup file.";
            var dir = Path.GetDirectoryName(exe)!;
            // The driver has to match Windows itself, not FiveT (an x64 FiveT on an ARM PC needs the ARM64 driver).
            var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "amd64";
            // The kernel driver comes in a Windows 10 and a Windows 11 build.
            var dco = Environment.OSVersion.Version.Build >= 22000 ? "dco-win11" : "dco-win10";
            var inf = Path.Combine(dir, "drivers", arch, tap ? "tap" : dco, tap ? "OemVista.inf" : "ovpn-dco.inf");
            if (!File.Exists(inf)) return $"The OpenVPN driver for this PC ({arch}) is missing from this copy of FiveT. Install FiveT with its setup file.";
            Log.Shared.Write($"creating the network adapter '{name}' for OpenVPN (once)");
            var pnp = Run(Path.Combine(Environment.SystemDirectory, "pnputil.exe"), new[] { "/add-driver", inf, "/install" }, 120_000);
            Log.Shared.Write($"pnputil /add-driver {Path.GetFileName(inf)}: exit {pnp.Status}", pnp.Status == 0 ? LogLevel.Debug : LogLevel.Error);
            var made = Run(Path.Combine(dir, "tapctl.exe"), new[] { "create", "--hwid", tap ? "root\\tap0901" : "ovpn-dco", "--name", name }, 120_000);
            if (made.Status == 0) return null;
            Log.Shared.Write($"tapctl create failed ({made.Status}): {Log.OneLine(made.Output)}", LogLevel.Error);
            return $"Windows could not create the network adapter OpenVPN needs ({Log.OneLine(made.Output.Trim())}). Restart the PC and try again; on an ARM PC use the ARM64 FiveT setup file.";
        }
        catch (Exception e)
        {
            return $"Windows could not create the network adapter OpenVPN needs ({e.Message}).";
        }
    }

    /// <summary>Uninstall: FiveT's two OpenVPN adapters go (the drivers stay in Windows' driver store, where other OpenVPN programs may use them).</summary>
    public static void RemoveOpenVpnAdapters()
    {
        if (OpenVpnPath is not { } exe) return;
        foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                     .Where(n => n.Name is VpnManager.OpenVpnAdapter or VpnManager.OpenVpnTapAdapter))
            Run(Path.Combine(Path.GetDirectoryName(exe)!, "tapctl.exe"), new[] { "delete", nic.Id }, 60_000);
    }

    /// <summary>vpnc-script-win.js: openconnect needs it to set routes and DNS on Windows.</summary>
    public static string? VpncScriptPath(string ofv)
    {
        var dir = Path.GetDirectoryName(ofv) ?? "";
        var parent = Path.GetDirectoryName(dir) ?? dir;
        foreach (var p in new[]
                 {
                     Path.Combine(dir, "vpnc-script-win.js"),
                     Path.Combine(parent, "etc", "vpnc", "vpnc-script-win.js"),
                     Path.Combine(parent, "share", "vpnc-scripts", "vpnc-script-win.js"),
                     Path.Combine(parent, "libexec", "openconnect", "vpnc-script-win.js"),
                 })
                 // openconnect runs this script as administrator too, so it gets the same folder check.
                 if (File.Exists(p) && IsTrustedFolder(Path.GetDirectoryName(p))) return p;
        return null;
    }

    /// <summary>wintun.dll next to openconnect.exe (preferred) — or the older TAP-Windows driver.</summary>
    public static bool HasWintun(string ofv) => File.Exists(Path.Combine(Path.GetDirectoryName(ofv) ?? "", "wintun.dll"));

    public static bool HasTapWindows()
    {
        var sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
        return File.Exists(Path.Combine(sys, "drivers", "tap0901.sys"))
               || File.Exists(Path.Combine(sys, "drivers", "tapoas.sys"))
               || Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "TAP-Windows"));
    }

    public static string OpenconnectVersion(string ofv)
    {
        var r = Run(ofv, new[] { "--version" });
        var first = r.Output.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.StartsWith("OpenConnect", StringComparison.OrdinalIgnoreCase));
        return first ?? r.Output.Trim().Split('\n').FirstOrDefault() ?? "?";
    }

    // ---- Login task (start elevated at logon, without a UAC prompt) ----

    /// <summary>Returns the command the "FiveT" scheduled task runs, or null when there is no task.</summary>
    public static string? LoginTaskCommand()
    {
        // /XML output is not localized, unlike /FO LIST.
        var r = Run("schtasks.exe", new[] { "/Query", "/TN", Paths.TaskName, "/XML" });
        if (r.Status != 0) return null;
        // Plain string search, not an XML parser: loading System.Xml for one element costs ~8 MB of
        // address space and some CPU, and this runs in the background of every start.
        const string open = "<Command>", close = "</Command>";
        var start = r.Output.IndexOf(open, StringComparison.Ordinal);
        var end = start < 0 ? -1 : r.Output.IndexOf(close, start + open.Length, StringComparison.Ordinal);
        if (start < 0 || end < 0) return "";
        return XmlText(r.Output.Substring(start + open.Length, end - start - open.Length)).Trim().Trim('"');
    }

    /// <summary>The five predefined XML entities (a path with an &amp; in it arrives as &amp;amp;).</summary>
    private static string XmlText(string s) => s.IndexOf('&') < 0 ? s
        : s.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&apos;", "'").Replace("&amp;", "&");

    public static bool LoginTaskInstalled()
    {
        var cmd = LoginTaskCommand();
        return cmd != null && cmd.Contains(Paths.GuiExePath, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Registers a scheduled task that starts FiveT.exe at logon with the highest privileges. Because the
    /// task is owned by the user, fivetctl.exe can also start the app through it without a UAC prompt.
    /// Needs elevation (which the tray app always has). Returns an error message, or null on success.
    /// </summary>
    public static string? InstallLoginTask()
    {
        // The task starts FiveT.exe as administrator at every logon. If ordinary programs can change the
        // folder it sits in, one of them could swap FiveT.exe or a DLL and be run as administrator.
        if (!IsTrustedFolder(Paths.ExeDir))
        {
            Log.Shared.Write($"login task not installed: {Paths.ExeDir} can be changed by ordinary programs", LogLevel.Error);
            return $"FiveT is running from {Paths.ExeDir}, a folder that ordinary programs can change. The login task starts FiveT as administrator, " +
                   "so it is only set up for a copy in Program Files. Install FiveT with its setup file (or run build.ps1 -Install from an elevated PowerShell), start that copy, and try again.";
        }
        var exe = Paths.GuiExePath.Replace("'", "''");
        var user = (Environment.UserDomainName + "\\" + Environment.UserName).Replace("'", "''");
        var script = $@"
$ErrorActionPreference = 'Stop'
$a = New-ScheduledTaskAction -Execute '{exe}'
$t = New-ScheduledTaskTrigger -AtLogOn -User '{user}'
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
$p = New-ScheduledTaskPrincipal -UserId '{user}' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName '{Paths.TaskName}' -Action $a -Trigger $t -Settings $s -Principal $p -Description 'Starts FiveT (FortiGate SSL-VPN) at logon as administrator.' -Force | Out-Null
";
        Log.Shared.Write("installing the login task (elevated start at logon)");
        var r = PowerShell(script);
        if (r.Status != 0)
        {
            var msg = r.Output.Trim();
            Log.Shared.Write($"login task install failed: {msg}", LogLevel.Error);
            return msg.Length == 0 ? "Could not create the scheduled task." : msg;
        }
        if (LoginTaskInstalled()) { Log.Shared.Write("login task installed OK"); return null; }
        return "The task was created but the check still fails. Copy diagnostics and share the log.";
    }

    public static string? RemoveLoginTask()
    {
        var r = Run("schtasks.exe", new[] { "/Delete", "/TN", Paths.TaskName, "/F" });
        if (r.Status == 0) { Log.Shared.Write("login task removed"); return null; }
        return r.Output.Trim();
    }

    // ---- Checks ----

    /// <summary>
    /// What Settings → General and the diagnostics show. <paramref name="full"/> false is for the check made
    /// in the background at every start, which only needs to know whether something a connection needs is
    /// missing: it leaves out the two checks that start another program (openconnect --version and
    /// schtasks.exe), which nothing there looks at.
    /// </summary>
    public static List<SetupCheck> Checks(bool full = true)
    {
        var outList = new List<SetupCheck>();
        var ofv = FindOpenconnect(out var refused);
        if (ofv != null)
        {
            outList.Add(new SetupCheck("ofv", "OpenConnect installed", true, full ? $"{ofv} ({OpenconnectVersion(ofv)})" : ofv, SetupFix.ChooseOpenconnect));
            var script = VpncScriptPath(ofv);
            outList.Add(new SetupCheck("script", script != null ? "vpnc-script-win.js found" : "vpnc-script-win.js is missing",
                script != null, script ?? "openconnect needs this script (from the same download) next to openconnect.exe to set routes and DNS.", null));
            var wintun = HasWintun(ofv);
            var tap = HasTapWindows();
            outList.Add(new SetupCheck("driver", wintun ? "Wintun driver available" : tap ? "TAP-Windows driver available" : "No virtual network driver",
                wintun || tap,
                wintun ? Path.Combine(Path.GetDirectoryName(ofv)!, "wintun.dll")
                    : tap ? "TAP-Windows (tap0901). Wintun is faster: put wintun.dll from wintun.net next to openconnect.exe."
                    : "Put wintun.dll (from https://www.wintun.net, the amd64 one) next to openconnect.exe, or install TAP-Windows.", null));
        }
        else if (refused != null)
        {
            outList.Add(new SetupCheck("ofv", "OpenConnect is in an unsafe folder", false, $"{UnsafeFolderText} ({refused})", SetupFix.InstallOpenconnect));
        }
        else
        {
            outList.Add(new SetupCheck("ofv", "OpenConnect is missing", false,
                "The FiveT setup file brings its own copy. For this one, choose an existing openconnect.exe or download OpenConnect for Windows.",
                SetupFix.InstallOpenconnect));
        }
        var admin = Paths.IsElevated;
        outList.Add(new SetupCheck("admin", admin ? "Running as administrator" : "Not running as administrator", admin,
            admin ? "Needed to create the tunnel adapter, routes and DNS rules." : "Restart FiveT and accept the UAC prompt.",
            admin ? null : SetupFix.Elevate));
        if (!full) return outList;
        var task = LoginTaskInstalled();
        outList.Add(new SetupCheck("task", task ? "Login task installed (no UAC prompts)" : "Login task not installed", task,
            task ? "Task Scheduler → FiveT: starts at logon as administrator; fivetctl and AI assistants can start the app without a prompt."
                 : "Starts FiveT at logon as administrator and lets fivetctl / AI assistants launch it without a UAC prompt. One click, no password.",
            task ? null : SetupFix.InstallLoginTask));
        return outList;
    }

    public static void OpenDownloadPage()
    {
        try { Process.Start(new ProcessStartInfo("https://www.infradead.org/openconnect/download.html") { UseShellExecute = true }); }
        catch (Exception e) { Log.Shared.Write($"could not open browser: {e.Message}", LogLevel.Error); }
    }

    // ---- Process helpers ----

    public sealed record RunResult(int Status, string Output);

    /// <summary>Runs a command to completion (hidden window) and returns exit status + combined output.</summary>
    public static RunResult Run(string path, IEnumerable<string> args, int timeoutMs = 60_000)
    {
        try
        {
            var psi = new ProcessStartInfo(path)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return new RunResult(-1, "could not start " + path);
            p.StandardInput.Close();
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs))
            {
                try { p.Kill(true); } catch { }
                return new RunResult(-1, $"{Path.GetFileName(path)} timed out after {timeoutMs / 1000}s");
            }
            p.WaitForExit();
            return new RunResult(p.ExitCode, stdout.Result + stderr.Result);
        }
        catch (Exception e)
        {
            return new RunResult(-1, e.Message);
        }
    }

    /// <summary>Runs a PowerShell script (no profile, non-interactive) and returns exit status + output.</summary>
    public static RunResult PowerShell(string script, int timeoutMs = 60_000)
    {
        // Progress records reach stderr as CLIXML ("#< CLIXML <Objs …>"), which lands in the captured
        // output, pollutes the log and confuses anything that parses the result. Turn them off.
        script = "$ProgressPreference = 'SilentlyContinue'\n" + script;
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        return Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded }, timeoutMs);
    }
}

public static class Diagnostics
{
    /// <summary>What the report reads from state that belongs to the UI thread, taken in one go.</summary>
    private sealed record Live(VpnStatus Status, IReadOnlyList<VpnStatus> Sessions, bool McpListening, int McpClients, List<Connection> Connections);

    private static Live Read() =>
        new(VpnManager.Shared.Status, VpnManager.Shared.Sessions, McpServer.Shared.IsListening, McpServer.Shared.ClientCount,
            ConnectionStore.Shared.Connections.Select(c => c.Clone()).ToList());

    /// <summary>
    /// Sessions, the MCP counters and the connection list are only changed on the UI thread, so a worker
    /// thread asks that thread for a copy (a few microseconds of work there, nothing slow, and the UI never
    /// waits on us). If the UI thread does not answer in 3 s (it is hung, which is when a report is wanted
    /// most), read from here and try again when a list changes under us.
    /// </summary>
    private static Live ReadLive()
    {
        if (Ui.IsUiThread) return Read();
        try
        {
            var done = new TaskCompletionSource<Live>(TaskCreationOptions.RunContinuationsAsynchronously);
            Ui.Post(() => { try { done.TrySetResult(Read()); } catch (Exception e) { done.TrySetException(e); } });
            if (done.Task.Wait(3000)) return done.Task.Result;
        }
        catch (Exception) { }
        for (var attempt = 0; ; attempt++)
        {
            try { return Read(); }
            catch (Exception) when (attempt < 3) { Thread.Sleep(20); }
        }
    }

    /// <summary>One line: names, errors and certificate names are free text and must not add lines to the report.</summary>
    private static string Flat(string? s) => Log.OneLine(s ?? "");

    /// <summary>
    /// The diagnostics report. Safe to call from any thread (Settings and the MCP get_diagnostics tool run it
    /// through Task.Run): it only builds text and touches no window or control. It does take a moment (it
    /// runs openconnect --version and schtasks), so keep it off the UI thread.
    /// </summary>
    public static string Text()
    {
        var live = ReadLive();
        var s = new StringBuilder();
        s.AppendLine($"FiveT diagnostics — {Log.Format(DateTime.Now)}");
        s.AppendLine($"Windows {Environment.OSVersion.Version} ({(Environment.Is64BitOperatingSystem ? "64-bit" : "32-bit")}), .NET {Environment.Version}");
        s.AppendLine($"app {Paths.AppVersion} at {Paths.ExeDir}, elevated={Paths.IsElevated}");
        foreach (var c in Setup.Checks()) s.AppendLine($"[{(c.Ok ? "OK" : "!!")}] {c.Title} — {c.Detail}");
        s.AppendLine($"status: {Flat(live.Status.Summary)}");
        // Network facts and split DNS belong to one tunnel each, so report every session, not just
        // the summary. With a single tunnel up this prints exactly the one line it always did.
        foreach (var ss in live.Sessions)
        {
            var tag = Flat(ss.ConnectionName ?? "?");
            if (live.Sessions.Count > 1) s.AppendLine($"  session '{tag}': {Flat(ss.Summary)}");
            if (ss.Network is { } n)
            {
                s.Append($"network[{tag}]: {n.Interface} (#{n.InterfaceIndex}) {n.TunnelIP} → {(n.PeerIP.Length == 0 ? "?" : n.PeerIP)}, dns [{string.Join(", ", n.DnsServers)}]");
                if (n.SearchDomains.Count > 0) s.Append($", search [{string.Join(", ", n.SearchDomains)}]");
                s.AppendLine($", {n.Routes.Count} routes via tunnel");
            }
            if (ss.SplitDns is { } sd)
                s.AppendLine($"split dns[{tag}]: {sd.State} [{string.Join(", ", sd.Domains)}]{(sd.Detail.Length == 0 ? "" : " — " + Flat(sd.Detail))}");
        }
        s.AppendLine($"vpn settings: killSwitch={(ConnectionStore.Shared.KillSwitch ? "on" : "off")}{(KillSwitch.IsActive ? " (BLOCKING now)" : "")} bypassIran={(ConnectionStore.Shared.BypassIran ? "on" : "off")}"
                     + $" xray={(Setup.XrayPath != null ? "ok" : "missing")} openvpn={(Setup.OpenVpnPath != null ? "ok" : "missing")}");
        s.AppendLine("mcp: " + (live.McpListening ? $"listening on {Paths.PipeDisplayPath}, {live.McpClients} assistant(s) connected" : "off"));
        foreach (var c in live.Connections)
        {
            s.Append($"connection '{Flat(c.Name)}': {c.Kind.Wire()} {Flat(c.GatewayDescription)} user={Flat(c.Username)} otp={c.OtpMode.Wire()}");
            // Never the profile, the link or the server's ID: only what kind of server it is.
            if (c.IsV2Ray) s.Append($" server={Flat(V2RayConfig.Summary(c.V2RayOutbound))}{(c.V2RaySubscription.Length > 0 ? " subscription=yes" : "")}");
            if (!c.IsV2Ray && LoginGuard.Shared.Count(c.LoginGuardKey) is > 0 and var failed) s.Append($" failedLogins={failed}");
            // The Mac's wording (Setup.swift): pinned = FiveT keeps to the certificate it met, ca-verified = logged in before
            // on the strength of Windows' own root list, not-yet-seen = the first meeting is still to come.
            s.Append($" cert={(c.HasPinForGateway ? "pinned" : c.KnowsGateway ? "ca-verified" : "not-yet-seen")}");
            if (c.TrustedCertNames.Count > 0) s.Append($" certNames=[{Flat(string.Join(", ", c.TrustedCertNames))}]");
            if (c.HasPendingReview) s.Append($" certReview={(c.PendingCertFirst ? "first-meeting" : "changed")} (waiting for the user)");
            s.Append($" dnsDomains=[{string.Join(", ", c.DnsDomainList)}]");
            // Names only: a --token-secret, --key-password or --proxy=user:password@host must never reach a pasted report.
            s.Append($" extra={ExtraOptions.Describe(c.ExtraConfig)}");
            if (c.LastConnectedAt is { } d) s.Append($" lastConnected={Log.Format(d)}");
            if (c.LastError is { } e) s.Append($" lastError={Flat(e)}");
            s.AppendLine();
        }
        s.AppendLine("--- recent log (info and errors) ---");
        s.AppendLine(Log.Shared.RecentText(LogLevel.Info, 200));
        return Redactor.Apply(s.ToString());
    }

    /// <summary>Builds the report on the calling thread and puts it on the clipboard. From the UI prefer <see cref="CopyToClipboardAsync"/>.</summary>
    public static void CopyToClipboard() => CopyToClipboard(Text());

    /// <summary>The clipboard part only (it moves to the UI thread by itself), for a report <see cref="Text"/> built elsewhere.</summary>
    public static void CopyToClipboard(string text) => Ui.SetClipboardText(text);

    /// <summary>Builds the report on a worker thread, then copies it from the caller's context: the UI stays free meanwhile.</summary>
    public static async Task CopyToClipboardAsync()
    {
        var text = await Task.Run(Text);
        CopyToClipboard(text);
    }
}
