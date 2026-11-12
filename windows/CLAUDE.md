# FiveT for Windows — notes for contributors and coding assistants

Read `README.md` in this folder first; it is the full product description (how the tunnel works,
build, first-time setup, test runbook, MCP tools, CLI, split DNS, files, uninstall).

## What this is

The Windows version (C# / .NET 8, WinUI 3 tray app) of the macOS menu bar app **FiveT**, which lives in the
root of this repository (`../Sources/fivet`, Swift). The Mac app is the reference for behaviour: when unsure
how something should behave, look at the Swift file with the same role. The Windows app follows the Mac app's
rules, wording, settings file and MCP tools wherever Windows allows it; the README's "What is different from the
Mac app" table lists the accepted differences. The Windows version is at Mac 1.17.1 parity (1.18 and 1.19 are not
ported yet); "1.5.0" and "2.0.0" below record what earlier audits against the Mac source taught.

| Role | Windows file | Mac counterpart |
|------|--------------|-----------------|
| Tray icon, menu, state machine, fivet:// handling, first start | `src/FiveT/TrayApp.cs`, `TrayFlyout.xaml(.cs)` | `AppDelegate.swift` |
| Starts/stops openconnect, parses its output, auto-reconnect, watchdog, sleep/wake | `src/FiveT/VpnManager.cs` | `VPNManager.swift` |
| One tunnel's state (process, adapter, timers, NRPT rules, watchdog counters) | `src/FiveT/VpnSession.cs` | (the Mac has several tunnels since 1.3 too) |
| Gateway certificate check before login, review | `src/FiveT/GatewayCert.cs`, `VpnManager.Start/CertChecked/Unverified`, `CertReview.cs` | `CertCheck.swift`, `CertReview.swift`, `VPNManager.handleRefusedCertificate` |
| Small always-on-top question windows (trust, link) | `src/FiveT/PromptWindow.cs` | NSAlert |
| fivet:// links: parse, register (HKCU), hand-off pipe | `src/FiveT/Links.cs`, `Program.cs` | `LinkCommand.swift`, `AppDelegate.handleLink` |
| Show… behind Windows Hello / Windows password | `src/FiveT/SecretGate.cs` | Touch ID / Mac password (1.4.2, 1.4.3) |
| TOTP secret from a QR code (ZXing.Net), `otpauth://` and Google export parsing | `src/FiveT/QrImport.cs` (editor side: `Pages/ConnectionEditor.xaml.cs`) | `OTPAuthImport.swift`, `SettingsView.swift` |
| Extra openconnect options → arguments, minus the dangerous ones | `src/FiveT/ExtraOptions.cs` | `Setup.swift` option allowlist |
| Settings pages that listen to singletons must let go on close | `src/FiveT/Pages/IDetachable.cs` | — |
| FortiClient import (registry) | `src/FiveT/FortiClientImport.cs` | 1.4.0 import |
| Log redaction (passwords, codes, secrets, cookies) | `Redactor` in `src/FiveT/Log.cs` | 1.8.0 |
| Settings window (Connections / General / MCP) | `src/FiveT/SettingsWindow.xaml`, `Pages/*.xaml`, `Ui.cs` | `SettingsView.swift` |
| Saved connections, DPAPI password storage | `src/FiveT/ConnectionStore.cs`, `Connection.cs` | `ConnectionStore.swift` |
| Setup checks, login task (Task Scheduler), install openconnect path | `src/FiveT/Setup.cs` | `Setup.swift` |
| Split DNS via NRPT rules | `src/FiveT/SplitDns.cs` | `VPNManager.swift` (writes `/etc/resolver/<domain>`) |
| MCP server over named pipe | `src/FiveT/McpServer.cs`, `src/FiveT.Core/JsonRpc.cs` | `MCPServer.swift` |
| CLI + MCP stdio bridge | `src/fivetctl/Program.cs` | `FiveT status` / `--mcp` |
| TOTP | `src/FiveT/Totp.cs` | `TOTP.swift` |
| Installer packaging | `installer/FiveT.iss`, `release.ps1` | `release.sh` |
| Update check (signed feed, GitHub releases) | `src/FiveT/UpdateFeed.cs`, `Updater.cs`, General page "Updates" card | `Updater.swift`, `UpdateSignature.swift` |

`src/FiveT/LocalSeeds.cs` (git-ignored, absent in a clean clone) may hold a developer's own seeded VPN credentials. Never print, log, commit or paste them.

## Build and run (Windows only)

```powershell
cd windows
.\build.ps1              # -> .\dist\FiveT.exe + fivetctl.exe (self-contained)
.\build.ps1 -Install     # also installs to C:\Program Files\FiveT (elevated) or %LOCALAPPDATA%\Programs\FiveT
.\build.ps1 -Installer   # also packages .\release\FiveT-Setup-<version>.exe (Inno Setup, via winget if missing)
dotnet build FiveT.sln   # quick compile check without publishing
```

Needs the .NET 8 SDK and, to bundle it, OpenConnect (`C:\Program Files\OpenConnect\openconnect.exe`; without it the build warns and the app looks for OpenConnect at run time). FiveT.exe runs
elevated (one UAC prompt, or none once the login task is installed). Only one FiveT.exe may run at a time:
stop the running one (tray → Quit, or `Stop-Process -Name FiveT`) before starting a freshly built one.

Useful while debugging:

- Log: `%LOCALAPPDATA%\FiveT\Logs\fivet.log` (turn on "Verbose openconnect logging" in Settings → General for DEBUG lines).
- Settings + connections: `%LOCALAPPDATA%\FiveT\connections.json`.
- `dist\fivetctl.exe status --json`, `... log --lines 100 --level debug`, `... check <host> 443`.
- Diagnostics text: Settings → General → Copy Diagnostics (no passwords, codes, secrets or cookies in it).
- NRPT rules left behind: `Get-DnsClientNrptRule | Where-Object Comment -eq FiveT`.
- Login task: `schtasks /Query /TN FiveT /V /FO LIST`.

## Working on it

- Testing the VPN needs a real gateway and the PC's own network, so a change to the tunnel code is checked by
  building, installing and connecting by hand; copy Settings → General → Copy Diagnostics (no passwords, codes,
  secrets or cookies in it) into the bug report.
- When a bug is reported, first reproduce from the log/diagnostics, fix, `dotnet build FiveT.sln` and
  `dotnet test tests\FiveT.Tests` to make sure it compiles and the rules still hold, then `.\build.ps1 -Install`.
- Keep parity with the Mac app's behaviour and wording unless Windows makes it impossible. Update the README when behaviour changes.
- Bump `<Version>` in `Directory.Build.props` when shipping a fix people will install.
- Examples, tests and docs use neutral names (Office, Lab, corp.example, vpn.example.com, 192.0.2.x). Never put a real
  gateway, host name, address or credential in source, tests, docs or compiled strings.

## Lessons from real-gateway testing

Connect, split DNS, internal name resolution, disconnect and immediate reconnect all work end to end.
What that first day of real testing taught is now handled in code — do not "simplify" these away:

- **DTLS is off** (`--no-dtls`, unless a connection's extra options mention dtls). This gateway offers
  DTLS, completes the handshake, then carries nothing: three unanswered keepalives and openconnect
  declares a dead peer about ten seconds after connecting. The Mac app has no DTLS either (openfortivpn).
- **Wintun leaves dead adapters behind.** Its removal helper is spawned from a `C:\Windows\Temp\<hash>`
  folder that is usually already gone, so the device node survives as a ghost and the *next* connect
  fails with "Could not open Wintun adapter 'FiveT'" — this broke every second attempt. `VpnManager`
  sweeps dead `SWD\WINTUN\*` nodes at launch and after each exit, and when the failure actually bites
  it clears them and retries once on its own (~15 s, nothing for the user to do).
- **Several tunnels at once (1.3.0)**, which the Mac app also has since its 1.3.0. `VpnManager`
  keeps a `Dictionary<Guid, VpnSession>`; every field that used to be a singleton (`_process`,
  `_reconnectTimer`, `_installedDomains`, the OTP flip, …) now lives on `VpnSession`. `Status` is a
  computed summary for the tray icon and old callers; `StatusFor(id)` and `Sessions` give the truth.
  Adapter names come from `AllocateAdapterName()` (`FiveT`, `FiveT-2`, …) because two openconnects
  cannot share one Wintun adapter. Do not reintroduce a single `_process`.
- **The network facts have to be polled.** openconnect prints "Configured as <ip>" before the adapter
  exists, and vpnc-script then adds the pushed routes one at a time. Reading once gave no DNS and no
  routes (so split DNS silently never happened); stopping at the first non-empty sample gave 1 of 41.
- **"Server certificate verify failed: signer not found"** is printed on *every* connection, including
  successful ones with a pinned certificate. It must not count as an error or it masks the real cause.
- **A second auth prompt** is answered with the token code in append mode too; the gateway sometimes
  challenges even when the code is already appended.

## Mac parity (1.4.0 from the Mac's pages, 1.4.1 against its 1.8.0 source): things not to undo

- **Every connect goes `Connect(c, origin) → Start → CertChecked → Launch`.** `Start` fetches the
  gateway certificate with Schannel (`GatewayCert.Fetch`, nothing sent); only then does `Launch` give
  openconnect the password, always with `--servercert=<pin>`. The old "learn the pin from openconnect's
  error line and retry" is gone on purpose (it trusted without asking): a `pin-sha256` line in
  openconnect's output now means openconnect saw another certificate than FiveT checked → a review.
  `CheckGeneration` cancels a check the user overtook by disconnecting.
- **Stored in the Mac's format** (`Connection.cs`): `trustedCert` = lowercase hex SHA-256 of the DER,
  `trustedCertHost` = `host:port` (`GatewayKey`; editing host/port makes it a first meeting),
  `trustedCertNames`, `pendingCert/Host/First/Info`. openconnect 9.21 does NOT accept a certificate
  SHA-256 in `--servercert` (tested `sha256:<hex>`, bare hex, upper case: all refused), only its own
  `pin-sha256:` of the public key — so FiveT derives the pin from the certificate it just checked and
  caches it in the Windows-only `trustedCertPin`/`pendingCertPin`. `GatewayCert.PinOf` is byte-identical
  to openconnect's pin (verified). A 1.4.0 `trustedCert` starting `pin-sha256:` moves to
  `trustedCertPin` on load and is upgraded silently on the next matching check (verified on Office).
- **Trust rules = Mac's `CertCheck`**: first meeting → trusted without asking only if `TrustedForHost`;
  change → renewal if `TrustedForHost`, or chain trusted + a name shared with `trustedCertNames` (the
  only path for an IP gateway); once per attempt (`AutoRenewed`). "Trusted" = chain to a root on
  **Microsoft's root program list** (authroot.stl, `GatewayCert.RootProgram` parses the CTL in
  `HKLM\...\AuthRoot\AutoUpdate\EncodedCtl`), never a root someone added — the Mac counts only
  built-in macOS roots for the same reason (TLS-inspecting proxies).
- **Unverified → review saved on the connection** (`VpnManager.Unverified`): `ConnectOrigin.User`
  fails and pops `CertReview.Present` at once; `Automation` (MCP, fivet://) fails with "Choose Review
  New Certificate for X… in FiveT's menu"; `Background` (reconnect) of a *changed* cert keeps retrying
  on schedule without logging in (hotel Wi-Fi sign-in pages). Menu row "Review (New) Certificate for
  X…", Settings "Review…". MCP `connect` returns `certificate_review_needed` (isError) — the Mac's word.
  *Trust and Connect* is disabled for the first second (a real stray click accepted one in testing).
- **Watchdog = Mac's**: every 20 s, first DNS server inside the tunnel's routes (Windows also counts a
  full tunnel's default route, which `NetTools.Routes` leaves out), name = cleaned DNS domains + search
  domains, else `.`; one 2 s try; any reply counts; 3 misses → `RestartDeadTunnel` (phase stays
  Connected so `ProcessEnded` treats it as a drop). Judges servers that never answered (as the Mac).
  Setting `watchdog` (default on). Paused on PBT_APMSUSPEND; on resume misses reset, probe after 8 s.
  Not while `NetTools.HasUnderlyingNetwork()` is false (a tunnel adapter alone does not count).
- **Network changes** (`NetworkChanged`/`NetworkSettled`): compared by `UnderlyingNetworkSignature`
  (real NICs with a gateway), 2 s settle, pending reconnects go now, each ≤ once per 10 s; offline a
  reconnect waits (`WaitingForNetwork`) but still tries every 120 s.
- **One-time codes**: never sent with ≤ 4 s left (`TotpBoundarySeconds`, the Mac's value) or reused.
- **Log redaction** happens in `Log.Write`, for everything.
- **fivet://**: key `linksConnectWithoutAsking` (1.4.0 wrote `linksAlwaysAllow`; still read). Verbs
  connect/up, toggle, disconnect/down, settings/open, also `?name=`; exact name (case-insensitive) or
  id; 3 s repeat guard; link text never shown back; Cancel is the default. Windows keeps
  `settings/general` and `settings/mcp` (the Mac may add them). Links connect as `Automation`.
- **FortiClient import = Mac's**: registry (SSL + IPsec) or a backup `.conf/.xml`; encrypted backup
  refused; first of `;`-joined servers; IPsec listed not imported; duplicate = host+port+realm+user;
  name clash → " (FortiClient)".
- Settings has the Mac's three pages (Connections, General, MCP). `welcomeShown` is Windows-only; the
  Mac drops unknown keys when it saves (then `list.Count > 0` stands in for it).
- OpenConnect is bundled by `build.ps1` into `dist\openconnect\` (first place `Setup.CandidatePaths` looks).
- Testing tip learned the hard way (2026-09-27): in Settings, confirm `NameBox` shows the intended
  connection before invoking `ConnectButton` from UI automation — a missed list click connected the
  real Office from a dev build.


## 1.5.0: audit against Mac 1.8.0, things not to undo

Four read-only audits (engine, MCP/CLI, UI, data/security) of this code against the Mac 1.8.0 source,
then fixes. What each one taught, so it is not "simplified" away:

- **An unreachable gateway is not a rejected login.** openconnect ends *every* connect failure with
  "Failed to complete authentication". `VpnSession.SawUnreachable` (set in `Handle` from
  `UnreachableMarkers`, cleared on "Connected to HTTPS on") stops that trailer from replacing
  `LastErrorLine`; `IsAuthFailure(session)` / `LoginRejected(session, code)` are false while it is set.
  Before, a pinned gateway that went away read "Login failed", stopped the background reconnect loop at the
  first attempt and flipped the one-time-code mode for nothing. Verified 2026-10-25 with a pinned
  connection to a refusing localhost port (the `!reached` → `Launch(c)` path).
- **The OTP-mode trial runs on a clone** (`OtpTrialOf`, `EndOtpTrial`): the saved mode is written only when
  the tunnel is up. **The gateway-edited guard compares a key captured in `Start`**, not the live object
  (`ConnectionStore.Get` hands out the instance the editor changes in place). **A watchdog restart
  reconnects even with Auto-reconnect off** (`RestartRequested`). Gateway-pushed DNS suffixes get NRPT rules
  too. `WaitForNetwork` keeps pending reconnects from climbing the back-off while offline.
- **`Connect` while an adopted (external) openconnect runs** queues behind it (`_pendingAfterExternal`);
  `Disconnect(id)` never kills an openconnect that is not that connection's. **Quit** waits 6 s, then
  `ForceStopAll()`, then 2 s; `_pendingRemovals` lets `ShutdownCleanup` finish NRPT removals.
- **Privilege escalation closed.** FiveT runs elevated without a UAC prompt (login task) and
  `connections.json` is writable by any program of the user. So: `Setup.IsAdminOnlyDirectory` (ACL walk to
  the volume root; junctions, UNC, untrusted owners refused) gates which `openconnect.exe` and
  `vpnc-script-win.js` FiveT runs and whether the login task may be registered; PATH and `%LOCALAPPDATA%` are
  no longer searched; `ExtraOptions` refuses `--script`, `--csd-wrapper`, `--servercert`, `--cookie`,
  `--config`, `--external-browser`, `--pid-file`, `--interface`, `--user` … The `IsDev` skip only applies
  while NOT elevated (an environment variable must not switch the check off for the login task). **Testing
  consequence:** a dev build launched from an elevated shell lives in a user-writable build folder, which fails the
  check, so it falls back to `C:\Program Files\OpenConnect` — fine.
- **`connections.json` is never replaced by the seeds when it exists** (`ReadFile`: retry on locks, copy to
  `.bad-<time>` first, `LoadProblem` shown on Settings → General). An undecryptable DPAPI value is written
  back untouched. `lastConnectedAt` reads the Mac's numeric date too; `showNameInMenuBar` is no longer read as
  `notifyOnChange`.
- **Seeds stay out of anything shared.** `-p:Distribution=true` (set by `build.ps1 -Installer`, checked by
  `release.ps1`) compiles `LocalSeedsEmpty.cs` instead of `LocalSeeds.cs` and stamps the DLL
  `FiveT.NoLocalSeeds`; both scripts refuse a dll without the stamp. Independent scan on 2026-10-25: 343 dist
  files, 0 hits for the password, TOTP secret, host, user name and DNS domain (the connection *name* appears in a
  UI caption, harmless). `build.ps1` also no longer breaks in a native ARM64 PowerShell, where
  `${env:ProgramFiles(x86)}` does not exist.
- **QR/otpauth = the Mac's rules** (`QrImport.cs`): refuses non-SHA1 / non-6-digit / non-30 s / HOTP with a
  reason; reads every QR code in a picture, normal and inverted (ZXing's `DecodeMultiple` ignores
  `TryInverted`, so both are scanned); several accounts → picker; a pasted link into the secret box is only
  read when it is the whole box, never stored; the clipboard is cleared only if its sequence number is
  unchanged; with no mode chosen yet the import sets "append". 38 checks in a throwaway harness incl. the
  pictures; the live flows were driven through the real window.
- **Several tunnels in MCP/CLI**: top level of `get_status`/`connect`/`disconnect` = the changing tunnel, else
  the newest connected one; `sessions`, `active_connections`, `health`, `waiting_for_network`; `resolve` and
  `check_reachability` use `VpnManager.MergedStatus()`. The initialize `instructions` used to say "only one
  connection at a time" — false since 1.3.
- **UI**: the "Current code" clock restarts when the Connections page comes back (`Resume`, the page is
  cached and `Load` is skipped for the same connection); pages implement `IDetachable` because a closing
  window does not reliably raise `Unloaded`; Copy Diagnostics runs `Diagnostics.Text` on a worker thread
  (it posts one read to the UI thread and gives up after 3 s); `Ui.SetClipboardText` retries and tolerates a
  busy clipboard (an unhandled `0x800401D0` from `Clipboard.Flush` was found by testing); the tray icon holds
  a half-filled shield while waiting for the network and no longer restarts its animation on every status line;
  the flyout coalesces rebuilds and never swaps buttons under a click (a press whose release never came is
  ignored after 2 s, and `ShowAt` clears it).
- **After an independent review of the UI code** (2026-10-25): every clipboard read in `QrImport.FromClipboardAsync`
  is inside one try/catch (a dead delayed-render owner threw into an async void handler: the click did
  nothing); `TrayApp.Quit` sets `VpnManager.Closing` (Connect is refused), closes the link pipe and the MCP
  pipe first, and always reaches `Application.Current.Exit()` (try/finally); the secret box accepts the same
  link pasted again over a selection (`IsOnlyCurrentSecret`) and clears the clipboard only when it holds that
  very text (`ClipboardHoldsAsync`); Copy Code reports a clipboard failure instead of leaving a stale one;
  Windows blocks OLE drags from a non-elevated Explorer/browser onto an elevated window, so the QR card
  promises a drop only when FiveT is not elevated (it normally is: use Paste Screenshot or Choose Image).
  Compiled help text must not contain a seeded connection name (the leak scan flags it): examples say
  "Office", not the real VPN names.
- **Bridge**: `fivetctl --mcp` waits for owed replies at stdin EOF (cap 310 s); a UTF-8 byte-order mark
  before the first line is ignored (PowerShell's pipe sends one).

Not done on purpose (decided 2026-10-25): writing `lastConnectedAt` in the Mac's numeric form,
translating Mac `extraConfig` keys, debounced saves, IP-SAN matching, SNI override for the certificate check,
the MCP pipe name for a different admin account's SID, MSIX Claude Desktop config path, PDF in QR import,
a scrolling flyout for very many connections.

**Never run against a real gateway** (no second gateway reachable from here): `ForceStopAll` on Quit with a
live tunnel, the network-wait reconnect, queue-behind-an-external-openconnect, `MergedStatus` with two live
tunnels, a reconnect loop against a gateway that comes back.

Testing tips from this run: `winapp ui` cannot `set-value` a ComboBox (focus it, then `send-keys "down"
--via send-input`); with two windows pass `-w <hwnd>`; InfoBar text is found with `search`, not by id; an
independent TOTP helper written in PowerShell for a cross-check failed the RFC 6238 vector while the app's
`Totp.cs` passed all five — check against the vectors, not against a hand-rolled helper.

## Updates

FiveT reads a signed feed, `latest-windows.json`, from a rolling GitHub release tagged `windows-feed`
(`https://github.com/FiveT-Gate/FiveT/releases/download/windows-feed/latest-windows.json`). Format, signature and
behaviour are in the README section "Updates"; the code is `UpdateFeed.cs` (pure rules, unit-tested) and `Updater.cs`
(download, hash check, hand-off to a hidden PowerShell that waits for FiveT to exit, runs setup /VERYSILENT and starts
FiveT again). Do not undo:

- **No Windows release may be marked "latest" on GitHub** (`gh release create --latest=false`). The Mac app's feed is
  `releases/latest/download/latest.json`; a Windows release marked latest would break it. Windows tags are `windows-v<version>`.
- **The signature covers version, architecture and SHA-256** (ECDSA P-256). The public key is in `UpdateFeed.ReleaseKeys`;
  the private key is never in the repository. To rotate: add the new public key, ship one release signed with the old key,
  then sign with the new one.
- **FiveT runs elevated, so it installs only from an admin-only folder** (`Setup.IsAdminOnlyDirectory`, `updates\` inside the
  install folder). A developer or per-user copy only reports the update. `FIVET_UPDATE_URL` is read in developer mode only.
- Download URLs must start with `UpdateFeed.UrlPrefix`.
- **Automatic, like the Mac: no dialogs.** `AutoUpdateCheck` (Settings "Install updates automatically", on by default, off = no
  automatic check) downloads the setup in the background (phase `Ready`) and installs it after two quiet looks 3 minutes
  apart (`QuietTick`; `IsBusy` = `VpnManager.IsRunning`). "Install and Restart" skips the wait. Not done (Mac installs at quit):
  nothing installs when FiveT is quit by hand or at logoff, because a setup killed by shutdown could leave a half install.

## Backup (.fivet): things not to undo

Settings → General → Backup is the Mac's Export Settings… / Import Settings…. The code is `ConnectionStore.ExportText()` and
`Restore()`, `Backup.cs` (merge rule and the Mac's date, unit-tested) and `NativeUi.SaveFile` (classic dialog: the UWP pickers
refuse to run elevated). Do not undo:

- **The text inside is the Mac's `connections.json` layout with plain secrets** (`password`, not `passwordProtected`): DPAPI text opens
  only for the same account on the same PC. `ConnectionJson(c, export)` builds both forms, so a new connection field is added once.
- **The file is ALWAYS encrypted** (user rule, 2.3.0): `Backup.Seal` = `FIVETBK1` + 12-byte nonce + AES-256-GCM cipher text + 16-byte
  tag, key built in (public with the source; a password at export is the upgrade). `Backup.Open` decrypts, and still takes a plain
  file (the Mac writes plain `.fivet`; 2.2.0 did too). Never write `ExportText()` to disk unsealed. The Mac cannot open a sealed file.
  Default name `Backup.DefaultFileName` = `YYYY-MM-DD_FiveT.fivet` (user rule).
- **`lastConnectedAt` is written as the Mac's number** (seconds since 2001-01-01 UTC), because the Mac's decoder drops a whole
  connection whose date is text. `Load` reads both forms.
- **Import follows the Mac:** settings replace, connections are added, same id replaces in place. Only settings that mean the same
  travel (not the Mac's `showNameInMenuBar` / `autoUpdate`, not `openconnectPath`, `welcomeShown`, `autoUpdateCheck`). A setting the
  file lacks stays. A file with no `connections` array is refused, changing nothing.
- **A copy of `connections.json` is made first** (`.before-import`); if it cannot be made, nothing is imported.
- `ReadConnections` is shared by `Load` and `Restore`: change the reading of a connection there once.
- Verified with a throwaway harness that compiled `ConnectionStore.cs` in `FIVET_DEV=1` mode (export, import, round trip, a Mac-style
  file, refused files); the file dialogs and the Settings buttons are not covered by automated tests.

## Mac 1.20 to 1.21.2 parity (failover, apps-only, MCP settings): things not to undo

Code: `VpnApps.cs` (pure rules: app paths, `NextVpn`, `Protection.Lowering`), `AppProxy.cs` (`AppProxyHold`, `TcpOwner`, `TrafficCheck`),
`UserProcess.cs` (start an app with the desktop's rights), `V2RayConfig.ForLaunch(..., appPort)`, `XrayConfigCheck.Check(text, appPort)`,
`VpnManager.Vpn.cs` ("Switch to another VPN" and "Apps only" sections), `McpTools` (`get_settings`, `set_settings`, `unblock_internet`).
Do not undo:

- **Apps-only has no tunnel.** `ForLaunch` gets either a tunnel name or `appPort`, never both. The one inbound is `socks` on `127.0.0.1:<port>`,
  no login, no UDP; no DNS-hijack or UDP-block rules. `XrayConfigCheck` (Xray runs as administrator) allows exactly that inbound, only when
  asked with the same `appPort`, and then no other inbound.
- **The port** is `V2RayConfig.AppProxyPort`, picked once per launch (`AppProxyHold.PickFreePort`). `AppProxyHold` holds it (exclusive bind,
  accept-and-close) whenever Xray is away, `Release()` just before Xray starts, `Take()` in `VpnProcessEnded`. "Connected" needs
  `TcpOwner.ListenerPid(port) == xray's pid` and a web request through the proxy (`TrafficCheck.Carries`). Never skip the owner check.
- **A connect never lifts a kill switch block in apps-only mode** (`VpnTunnelUp` calls `ReleaseKillSwitch` only when `AppProxyPort == null`).
- **Apps are started with the desktop's rights, never FiveT's.** `UserProcess.Start` copies the token of the shell window's process
  (`GetShellWindow`, not "the first explorer.exe") and creates the process with `CreateProcessWithTokenW`. A parent-process attribute does
  NOT change the token (tested: the child stayed elevated). On a PC whose desktop itself runs elevated (this development PC does) the app
  is as elevated as everything else there; the unelevated result was proved with a filtered token through the same code (`StartWithToken`).
  If no token can be had, nothing starts: never a fallback to FiveT's own rights.
- **Failover** = 3 failed reconnects (`FailoverAfter`), then `VpnApps.NextVpn` (VPNs only, in list order, round to the first). The next VPN
  gets `FailedOver` so its first failed try is retried and the chain goes on; `VpnTunnelUp` clears it.
- **MCP lowering needs a dialog.** `kill_switch` off, `apps_only` on, `bypass_iranian_websites` on and `unblock_internet` (when blocked) ask
  with `PromptWindow` (`Warning`, own key per request, no answer in 5 minutes = no). The change is applied in one UI-thread step that re-reads
  the settings and refuses a lowering change that was not in what was allowed (Mac 1.21.2). `Protection.Lowering` decides, and is unit-tested.
- **Import of a `.fivet` file** drops Mac app paths (`VpnApps.Clean`) and takes `appsOnly` only when the list is not empty.
- Verified: unit tests (`VpnAppRules`, `AppsOnlyConfig`, `AppProxyPorts`, `ProtectionRules`); a throwaway harness ran the REAL xray.exe with the
  apps-only config (accepted, SOCKS5 no-login, loopback only, owner check, hand-over from the hold); `UserProcess` in an elevated shell.
  NOT verified: a real V2Ray or Outline server through the proxy, an app started from the menu against one, failover with real servers, the
  MCP dialog on a running copy.

## Known unverified points

- **Two tunnels against real gateways.** The session machinery is verified: two connections start
  side by side with `--interface=FiveT` and `--interface=FiveT-2`, neither disturbs the other, each
  fails and reports on its own, and both rows show their own state. What could not be tested here is
  what two live FortiGates do to the routing table — if both push a default route only one wins.
  Check `fivetctl status`, which now lists the route count per tunnel.
- **The one-time-code mode retry** (`VpnManager.TryOtherOtpMode`): when a login the user asked for is
  rejected and the connection uses TOTP, FiveT flips "append to password" <-> "second step" and tries
  once more, keeping whichever mode gets in. Built from the Mac 1.4.3 release note, not from its source
  (that version was never pushed to this remote), and never run against a real gateway. It costs exactly
  one extra login attempt and restores the user's own setting when the second try fails too.
- **Lab realm**: OpenConnect takes the FortiGate realm from the URL path. If Lab fails to log in while
  Office works, try `--authgroup=labrealm` as an extra option and clear the Realm field.
- **"Send TOTP code as second step"**: Office uses "append to password". Note that picking this mode by
  mistake looks exactly like a wrong password — the gateway simply keeps challenging.
- Auto-reconnect after a real, unplanned drop (Wi-Fi change, sleep), the network-change reconnect and
  the wake-up probe: written and compiled, not run against a real drop. (Verified on Office
  2026-09-27: the watchdog probe itself works through the real tunnel — "watching the tunnel via
  192.0.2.53 (corp.example)".)
- **Certificate check**: verified on Office 2026-09-27 (the 1.4.0 pin → silent upgrade to the Mac
  fields, connected in under a second) and against a local self-signed test server (first meeting,
  trust, changed certificate, Keep Blocked, a link acting as automation). Not seen: a real renewal, Lab.
- **FortiClient import**: the registry layout (`...\Sslvpn\Tunnels\<name>`, `Server`, `username`) and
  the backup XML parser (ported from the Mac) are untested on a PC with FortiClient.
- **Windows Hello fallback** (CredUI + LogonUser) for PCs without Hello: compiled, not exercised.
- Tray icon rendering on light vs dark taskbars and on HiDPI (PerMonitorV2 is enabled).

## Git

This folder is the `windows/` directory of https://github.com/FiveT-Gate/FiveT. The Mac app owns everything outside it.
`src/FiveT/LocalSeeds.cs` (a developer's own credentials) is git-ignored: `build.ps1` creates an empty one, and connections
are added in Settings → Connections.

## 2.0.0: Mac 1.17.1 parity, things not to undo

The Mac source is in the repository root. README section "2.0.0" is the user-facing description. Files: `VpnManager.Vpn.cs` (OpenVPN/Xray engines, one VPN at a time, kill switch
arming, full-tunnel DNS), `OpenVpnProfile.cs`, `V2RayConfig.cs`, `XrayConfigCheck.cs`, `VpnImport.cs`,
`LoginGuard.cs`, `Wfp.cs` (kill-switch filters), `FieldCleaner.cs`, `SafeFile.cs`, `tests/FiveT.Tests`.

- **The Forti tab and the VPN tab are one page** (`ConnectionsPage.ShowTab`). A class derived from a XAML
  page crashed the app (access violation in coreclr) the moment it was navigated to.
- **Kill switch = a dynamic WFP session** (`WfpSession`). Do not replace it with `netsh advfirewall` rules or
  persistent filters: the point is that Windows removes it when FiveT dies. Test filters only with
  `BlockEverythingElse = false` on a reserved address (203.0.113.0/24), never the real block on a PC you use.
- **OpenVPN and Xray only from the install folder** (`Setup.OpenVpnPath`, `XrayPath`), profile and config on
  stdin, both re-checked on the text that is passed on. Keep the allow-list in step with the Mac's
  `Setup.openvpnAllowedOptions`.
- **Xray's TUN**: adapter `FiveT-VPN`, 198.18.0.1/30, the PC's DNS points at 198.18.0.2 (inside the /30, not
  the PC's own address, so the question enters the TUN). UDP other than port 53 is blocked on purpose (Mac
  behaviour); if that is ever lifted, do it on both platforms.
- **LoginGuard key is the host without the port**, the file is shared by every copy (dev builds too).
- **OpenVPN adapters**: `tapctl create --hwid ovpn-dco` / `root\tap0901` after `pnputil /add-driver`; from
  Git Bash, `pnputil /add-driver` is mangled into a path, so test from PowerShell.
- A `.ps1` with non-ASCII characters needs a UTF-8 byte-order mark or Windows PowerShell 5.1 misparses it.
- Never run a full-tunnel VPN test on a PC without its owner: it reroutes everything, including any VPN already running.
- Never run against a real server yet: every OpenVPN, V2Ray and Outline connection, the VPN switch, the real
  kill-switch block. See README "Not run".
