using System.Runtime.InteropServices;
using System.Text;
using Windows.Security.Credentials.UI;

namespace FiveT;

/// <summary>
/// Settings keeps a connection's password and one-time-code secret masked until the person at the PC
/// proves it is them, as the Mac app does with Touch ID (1.4.2) or the Mac password (1.4.3).
///
/// Windows Hello (face, fingerprint or PIN) when it is set up; otherwise Windows' own credential
/// prompt for the account's password, checked with LogonUser. The password typed there is only
/// checked and forgotten, never stored or logged.
/// </summary>
public static class SecretGate
{
    public enum Outcome { Verified, Cancelled, Failed }

    public static async Task<(Outcome Result, string? Message)> VerifyAsync(IntPtr hwnd, string reason)
    {
        try
        {
            var availability = await UserConsentVerifier.CheckAvailabilityAsync();
            if (availability == UserConsentVerifierAvailability.Available)
            {
                var r = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, reason);
                return r switch
                {
                    UserConsentVerificationResult.Verified => (Outcome.Verified, null),
                    UserConsentVerificationResult.Canceled => (Outcome.Cancelled, null),
                    UserConsentVerificationResult.RetriesExhausted => (Outcome.Failed, "Too many attempts. Try again later."),
                    UserConsentVerificationResult.DeviceBusy => (Outcome.Failed, "Windows Hello is busy. Try again."),
                    _ => (Outcome.Failed, $"Windows Hello could not check it's you ({r})."),
                };
            }
            Log.Shared.Write($"Windows Hello is not available ({availability}); asking for the Windows password instead", LogLevel.Debug);
        }
        catch (Exception e)
        {
            Log.Shared.Write($"Windows Hello failed: {e.Message}; asking for the Windows password instead", LogLevel.Debug);
        }
        return await Task.Run(() => PasswordPrompt(hwnd, reason));
    }

    // MARK: Windows password fallback (CredUIPromptForWindowsCredentials + LogonUser)

    private static (Outcome, string?) PasswordPrompt(IntPtr hwnd, string reason)
    {
        var info = new CREDUI_INFO
        {
            cbSize = Marshal.SizeOf<CREDUI_INFO>(),
            hwndParent = hwnd,
            pszCaptionText = "FiveT",
            pszMessageText = reason + "\n\nType your Windows password.",
        };
        uint package = 0;
        var save = false;
        var authError = 0;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var rc = CredUIPromptForWindowsCredentialsW(ref info, authError, ref package, IntPtr.Zero, 0,
                out var outBuf, out var outSize, ref save, CREDUIWIN_ENUMERATE_CURRENT_USER);
            if (rc == ERROR_CANCELLED) return (Outcome.Cancelled, null);
            if (rc != 0) return (Outcome.Failed, $"Windows could not show its password prompt (error {rc}).");
            try
            {
                int userLen = 514, domainLen = 338, passLen = 256;
                var user = new StringBuilder(userLen);
                var domain = new StringBuilder(domainLen);
                var pass = new StringBuilder(passLen);
                if (!CredUnPackAuthenticationBufferW(CRED_PACK_PROTECTED_CREDENTIALS, outBuf, outSize, user, ref userLen, domain, ref domainLen, pass, ref passLen))
                    return (Outcome.Failed, "Windows returned a credential FiveT cannot check. Set up Windows Hello, or use your password.");
                var (u, d) = Split(user.ToString(), domain.ToString());
                var ok = LogonUserW(u, d, pass.ToString(), LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, out var token);
                pass.Clear();
                if (ok) { CloseHandle(token); return (Outcome.Verified, null); }
                authError = Marshal.GetLastWin32Error();   // shown by the next prompt ("The password is incorrect")
            }
            finally
            {
                // The buffer holds the password: wipe it before giving it back.
                if (outBuf != IntPtr.Zero)
                {
                    for (var i = 0; i < outSize; i++) Marshal.WriteByte(outBuf, i, 0);
                    CoTaskMemFree(outBuf);
                }
            }
        }
        return (Outcome.Failed, "The password was not accepted.");
    }

    /// <summary>"DOMAIN\user", "MicrosoftAccount\me@example.com" or "me@example.com" into what LogonUser takes.</summary>
    private static (string User, string? Domain) Split(string user, string domain)
    {
        if (domain.Length > 0) return (user, domain);
        var slash = user.IndexOf('\\');
        if (slash < 0) return (user, user.Contains('@') ? null : ".");
        var d = user[..slash];
        var u = user[(slash + 1)..];
        // A Microsoft account signs in by its e-mail address; LogonUser wants it as a UPN.
        return d.Equals("MicrosoftAccount", StringComparison.OrdinalIgnoreCase) ? (u, null) : (u, d);
    }

    private const int ERROR_CANCELLED = 1223;
    private const int CREDUIWIN_ENUMERATE_CURRENT_USER = 0x200;
    private const int CRED_PACK_PROTECTED_CREDENTIALS = 0x1;
    private const int LOGON32_LOGON_INTERACTIVE = 2, LOGON32_PROVIDER_DEFAULT = 0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDUI_INFO
    {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    private static extern int CredUIPromptForWindowsCredentialsW(ref CREDUI_INFO info, int authError, ref uint authPackage,
        IntPtr inAuthBuffer, uint inAuthBufferSize, out IntPtr outAuthBuffer, out uint outAuthBufferSize, ref bool save, int flags);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredUnPackAuthenticationBufferW(int flags, IntPtr authBuffer, uint authBufferSize,
        StringBuilder userName, ref int maxUserName, StringBuilder domainName, ref int maxDomainName, StringBuilder password, ref int maxPassword);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LogonUserW(string user, string? domain, string password, int logonType, int provider, out IntPtr token);

    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("ole32.dll")] private static extern void CoTaskMemFree(IntPtr ptr);
}
