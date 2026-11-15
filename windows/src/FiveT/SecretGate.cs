using System.Runtime.InteropServices;
using Windows.Security.Credentials.UI;

namespace FiveT;

/// <summary>
/// Settings keeps a connection's password and one-time-code secret masked until the person at the PC
/// proves it is them, as the Mac app does with Touch ID (1.4.2) or the Mac password (1.4.3).
///
/// Windows Hello (face, fingerprint or PIN) when it is set up; otherwise FiveT's own prompt for the
/// account's Windows password, checked with LogonUser. The password typed there is only checked and
/// forgotten, never stored or logged. (Windows' own credential dialog is not used: on some PCs it ended
/// FiveT the moment it was asked to show, with a NullReferenceException "Invalid pointer".)
/// </summary>
public static class SecretGate
{
    public enum Outcome { Verified, Cancelled, Failed }

    // Windows' "wrong user name or password".
    private const int ERROR_LOGON_FAILURE = 1326;

    /// <summary>Never throws: anything unexpected comes back as <see cref="Outcome.Failed"/> with a message.</summary>
    public static async Task<(Outcome Result, string? Message)> VerifyAsync(IntPtr hwnd, string reason)
    {
        try
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
            return await PasswordPromptAsync(reason);
        }
        catch (Exception e)
        {
            Log.Shared.Write($"could not check the Windows password: {e}", LogLevel.Error);
            return (Outcome.Failed, "FiveT could not check your Windows password. Details are in the log.");
        }
    }

    // MARK: Windows password fallback (FiveT's prompt + LogonUser)

    private static async Task<(Outcome, string?)> PasswordPromptAsync(string reason)
    {
        var note = "";
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var answer = await PromptWindow.Ask("secretgate", new PromptSpec
            {
                Title = "Confirm it's you",
                Message = reason + "\n\nType your Windows password." + note,
                Password = true,
                Primary = "Show",
                AutomationId = "SecretGate",
            });
            if (!answer.Accepted) return (Outcome.Cancelled, null);
            var typed = answer.Text ?? "";
            var (ok, error) = await Task.Run(() =>
            {
                var good = LogonUserW(Environment.UserName, Environment.UserDomainName, typed, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, out var token);
                var err = good ? 0 : Marshal.GetLastWin32Error();
                if (good) CloseHandle(token);
                return (good, err);
            });
            if (ok) return (Outcome.Verified, null);
            if (error != ERROR_LOGON_FAILURE) return (Outcome.Failed, $"Windows could not check the password (error {error}).");
            note = "\n\nThat password was not accepted. Try again.";
        }
        return (Outcome.Failed, "The password was not accepted.");
    }

    private const int LOGON32_LOGON_INTERACTIVE = 2, LOGON32_PROVIDER_DEFAULT = 0;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LogonUserW(string user, string? domain, string password, int logonType, int provider, out IntPtr token);

    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
