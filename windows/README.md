# FiveT for Windows

One-click FortiGate SSL-VPN from the Windows notification area. Native C# / .NET 8 (WinUI 3), no FortiClient needed.
This is the Windows version of the macOS menu bar app that lives in the root of this repository; the behaviour, settings file,
MCP tools and command line are the same wherever Windows allows it.

Click the shield icon in the notification area (bottom right, maybe behind the `^` arrow), click a
connection name, and you are connected. Click it again to disconnect. The icon shows the state:

| Icon | Meaning |
|------|---------|
| outline shield | not connected |
| animated shield | connecting / disconnecting |
| shield with check mark | connected |
| red shield with ! | last attempt failed (open the menu to read why) |

## Install

Download **FiveT-Setup-\<version\>.exe** and double-click it. Accept the UAC prompt and that is all:
FiveT lands in `C:\Program Files\FiveT`, gets a Start Menu entry and an Add/Remove Programs entry,
and (unless you clear the checkbox) registers the logon task so every later start is elevated with
no prompt. The same file installs over an existing copy and keeps your connections.

FiveT updates itself, like the Mac app (Settings → General → *Install updates automatically*, on by
default). Once a day it looks for a new version, downloads it quietly and installs it when no VPN is connected, with
no dialog. Only a setup file signed with FiveT's release key is installed, and your connections in
`%LOCALAPPDATA%\FiveT` are untouched. You can also run a newer setup file by hand over the old copy.
See [Updates](#updates).

Nothing else to install: the setup file brings its own **OpenConnect** (in
`C:\Program Files\FiveT\openconnect`), the way the Mac app brings its own openfortivpn since 1.7.
`build.ps1` copies it from the OpenConnect on the build PC (see [Build](#build)).

The first start opens Settings on **General**, which says *FiveT is ready* and offers
**Add Your VPN…**. If something is missing it shows **Set Up FiveT** instead, which fixes what it can
in one click.

## How it works

- The VPN itself is handled by **OpenConnect** (`openconnect.exe --protocol=fortinet`), the open-source
  client that speaks the FortiGate SSL-VPN protocol. (openfortivpn, which the Mac app uses, needs `pppd`
  and has no Windows build.) The tunnel adapter comes from the **Wintun** driver that ships with OpenConnect.
- The tunnel runs over **TLS, not DTLS**, the same as the Mac app. Gateways that offer DTLS but do not
  actually pass traffic over it drop the connection about ten seconds after it comes up. Add an option
  mentioning `dtls` to a connection's *Extra openconnect options* if you want to let openconnect choose.
- Wintun sometimes fails to remove its adapter when the tunnel closes and leaves a dead one behind, which
  would stop the next connection. FiveT clears those by itself — if it happens mid-connect, it retries.
- For **Office**, the app generates the 6-digit TOTP code from your secret and appends it to the static
  password automatically. The Connections tab in Settings shows the current code with a Copy button.
  If a login with a code is rejected, FiveT tries the other code mode once and keeps the one that works.
  It never sends a code with 4 seconds or less left, or one already used; it waits for the next one (as the Mac does).
- Creating a tunnel needs administrator rights, so FiveT runs elevated: the first start shows one UAC prompt.
  The **login task** (Settings → General → *Start FiveT at login*) then starts it at logon as administrator
  with no prompt at all, and also lets `fivetctl` / AI assistants start it silently. This is the Windows
  counterpart of the Mac's helper.
- **The gateway certificate is checked before every login** (see [Gateway certificate](#gateway-certificate)).
- A **watchdog** checks every 20 seconds that each tunnel still answers, and reconnects one that went
  quiet. When the network comes back, waiting reconnects go at once; after a sleep the tunnels are checked.
- Passwords and TOTP secrets are stored encrypted with Windows DPAPI, readable only by your account on
  this PC. Settings keeps them masked until **Windows Hello** (or your Windows password) confirms it's you.
  The log and the diagnostics never contain passwords, one-time codes, TOTP secrets or session cookies.

## What is different from the Mac app

| macOS | Windows |
|-------|---------|
| `openfortivpn` + `/etc/sudoers.d/fivet` | `openconnect.exe --protocol=fortinet`, app runs elevated (UAC once, or the login task) |
| Menu bar icon, "name next to the icon" | Notification-area icon; the option became "Show a notification when the state changes" |
| `FiveT --mcp`, `FiveT status` (same binary) | `fivetctl.exe --mcp`, `fivetctl status` (separate console program next to `FiveT.exe`) |
| Unix socket `mcp.sock` | Named pipe `\\.\pipe\fivet-mcp-<your SID>`, DACL = your account only |
| `/etc/resolver/<domain>` split DNS | NRPT rules (`Add-DnsClientNrptRule`), comment `FiveT`, removed on disconnect |
| `~/Library/Application Support/fivet` | `%LOCALAPPDATA%\FiveT` |
| Touch ID, or the Mac password, before Show… | Windows Hello (face, fingerprint, PIN), or the Windows password |
| Built-in openfortivpn, "Install Helper…" | Bundled OpenConnect in the setup file; "Set Up FiveT" restarts elevated / installs the login task |
| `fivet://` registered by the app bundle | `fivet://` registered for your account at every start (`HKCU\Software\Classes\fivet`) |
| FortiClient import from vpn.plist or a backup | from its registry keys or a backup file; IPsec listed, not imported |
| Only certificate authorities that come with macOS | Only roots on Microsoft's root program list (authroot.stl) |
| Paste Screenshot after ⌃⇧⌘4 | Paste Screenshot after Win+Shift+S |
| plaintext passwords, mode 0600 | DPAPI-encrypted passwords (a `connections.json` copied from the Mac still loads) |
| self-update from `latest.json`, "Check for Updates…" in the app menu | the same idea with its own signed feed, `latest-windows.json`; Settings → General → Updates (see [Updates](#updates)) |
| several tunnels at once, "Connect All" (1.3) | the same: each tunnel gets its own Wintun adapter (see [Several connections at once](#several-connections-at-once)) |

## Build

Needs the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). In PowerShell:

```powershell
cd windows
.\build.ps1            # → .\dist\FiveT.exe + fivetctl.exe (self-contained, no runtime needed)
.\build.ps1 -Install   # also copies to C:\Program Files\FiveT (elevated shell) or %LOCALAPPDATA%\Programs\FiveT
.\build.ps1 -Installer # also packages .\release\FiveT-Setup-<version>.exe (Inno Setup)
```

Every build bundles OpenConnect: the files of `C:\Program Files\OpenConnect` on the build PC
(`openconnect.exe`, its DLLs, `wintun.dll`, `vpnc-script-win.js`, about 9 MB) go to `dist\openconnect\`,
which FiveT looks in first. `-OpenConnectDir <folder>` takes them from elsewhere, `-NoOpenConnect`
leaves them out. OpenConnect is LGPL 2.1; `dist\openconnect\README.txt` says where its source is.

`-FrameworkDependent` makes a small build that needs the ".NET 8 Desktop Runtime" on the PC instead.
The solution also builds on macOS/Linux (`dotnet build FiveT.sln`) for compile checks; it only runs on Windows.

The published folder is about 160 MB and the setup file about 45 MB. A stock self-contained WinUI 3
publish is 220 MB: `Directory.Build.targets` leaves out what this app never loads — framework strings
for 88 languages, the Windows AI runtime (onnxruntime + DirectML), Widgets, Search, WebView2 and the
managed-debugger files. Publish with `-p:FiveTFullPayload=true` to put them all back if you ever need
to rule that out. (`-p:PublishTrimmed=true` reaches about 80 MB, but ILLink flags the JSON code that
writes `connections.json` and the generated XAML type table, so it is deliberately not the default.)

## First-time setup

With the setup file there is nothing to do: install, and Settings opens on General with
**Add Your VPN…**. Then Settings → Connections → **+**, or the import button under the list to copy
FortiClient's connections (you add only the passwords).

For a copy built without OpenConnect, or run from `dist\` on a PC without it:

1. **Install OpenConnect.** Open the [OpenConnect download page](https://www.infradead.org/openconnect/download.html)
   and follow the Windows link to the MinGW64 build (an installer, `openconnect-installer.exe`, produced by the
   project's GitLab CI). It installs `openconnect.exe`, `vpnc-script-win.js` and `wintun.dll` into
   `C:\Program Files\OpenConnect`. Alternative: [MSYS2](https://www.msys2.org) and
   `pacman -S mingw-w64-x86_64-openconnect` (FiveT looks in `C:\msys64\mingw64\bin`).
   Any other location works too: Settings → General → Requirements → **Choose openconnect.exe…**.
2. Start **FiveT.exe** and accept the UAC prompt. A shield icon appears in the notification area.
3. Click the shield → **Settings** → **General**. It should say *FiveT is ready*; otherwise click **Set Up FiveT**.
4. Turn on **Start FiveT at login**. From now on FiveT starts at logon as administrator without a prompt.

## Test runbook (your personal VPN must be OFF)

FortiGate gateways do not answer while the personal VPN is on, so Claude will be offline during this part.

1. Turn your personal VPN off.
2. Click the shield → click **Office**. The icon animates for a few seconds, then shows a check mark.
   The menu line reads `Office — Connected 0:05` and keeps counting.
3. Open something that only works on the Office network to confirm.
4. Click the shield → click **Office** again. The icon returns to the outline shield.
5. Repeat steps 2–4 for **Lab**.
6. Whatever happened, open shield → **Settings** → **General** → **Copy Diagnostics**. Turn your personal VPN back on and
   paste the clipboard into the chat. It contains the setup checks and the last log lines, never the passwords.

Clicking the other connection while one is connected brings up a **second** tunnel next to it,
so check both are listed and that the first keeps working; use **Disconnect All** to stop them together.

New in 1.4, worth one look on the first run:

- **Certificate check.** Connecting should *not* ask anything for a gateway whose certificate is
  already trusted (a 1.4.0 pin is upgraded silently). A
  gateway FiveT has never seen whose certificate Windows cannot vouch for (after *Forget* under
  Advanced, say) asks *Trust the certificate of …?* with the fingerprint.
- **Watchdog.** Once connected the log says `watchdog: watching the tunnel via <DNS server> (<domain>)`,
  and only more when the tunnel stops answering.
- **Sleep.** Put the PC to sleep while connected, wake it: the tunnel should be back within a minute.

Two things in this port could only be verified against a real gateway, so check them on the first run:

- **Realm (Lab).** OpenConnect takes the FortiGate realm from the URL path (`https://<gateway>:10443/labrealm`).
  If Lab fails with a login error while Office works, add `--authgroup=labrealm` as an extra option
  under the connection's Advanced section and clear the Realm field.
- **"Send TOTP code as second step".** FiveT answers OpenConnect's second prompt with the code from stdin.
  Office uses "append to password", which does not depend on this.

## Several connections at once

Clicking a second connection **adds** a tunnel; it does not replace the first. Each one gets its own
openconnect process, its own Wintun adapter (`FiveT`, then `FiveT-2`, `FiveT-3` — the lowest free
name is reused when a tunnel ends), its own NRPT rules and its own auto-reconnect schedule, so one
dropping or failing never disturbs the others. Every row in the menu and in Settings → Connections
shows only its own state and time (`Office — Connected 0:42`). The menu has **Connect All** when
there is more than one connection and one is down, and **Disconnect All** once more than one is up —
the same as the Mac app since 1.3.

Whether two tunnels are *useful* together is up to the gateways, and FiveT cannot fix that:

- **Split DNS always works.** NRPT rules are per-domain, so `corp.example` over one tunnel and another
  company's domain over a second resolve correctly side by side. If both connections list the same
  domain, the one that connected last owns it.
- **Routes are first-come.** Two split-tunnel FortiGates that push different internal subnets coexist
  fine. If both push a default route only one can win, and the second tunnel then carries nothing but
  its own subnets — check `fivetctl status`, which lists the route count per tunnel.

## If the connection drops

When a connected VPN drops on its own (Wi-Fi change, sleep, gateway hiccup), FiveT reconnects in the
background: first after 2 seconds, then every 10, 20, 30 … up to 60 seconds, until it is back. The
menu line reads `Office — Connection lost, retrying in 10s (try 2)…` meanwhile and the icon animates.
It stops retrying if the login is rejected (so a changed password can never lock the account) or when
you click the connection to disconnect. A manual disconnect never reconnects by itself. A gateway that
does not answer at all is *not* a rejected login: it reads "Could not reach the gateway" (never "Login
failed"), keeps being retried, and never makes FiveT try the other one-time-code mode.
Clicking a connection that is only waiting for its next retry connects at once.
The switch is in Settings → General → "Reconnect when the connection drops".
(OpenConnect also has its own short internal retry; FiveT limits it to 30 s so the two do not fight.)

**Without a network** a reconnect waits for one (and still tries every two minutes, in case Windows'
report is wrong). **When the network comes back or changes** (Wi-Fi to another network, cable in),
FiveT waits 2 seconds for DHCP and DNS, then reconnects what was waiting — each tunnel at most once
per 10 seconds — and probes the tunnels that are up. FiveT's own tunnel adapters coming and going do
not count as a network change. These are the Mac app's rules and numbers.

**The watchdog** (Settings → General → "Reconnect when the tunnel stops answering", on by default)
catches the tunnel that still looks connected but carries nothing (the gateway dropped the session,
a NAT timed out, the PC slept). Every 20 seconds FiveT asks the tunnel's DNS server — the first one
inside the tunnel's routes — about one of the connection's DNS domains, or the gateway's pushed
search domain, or the root `.`: one try, 2 seconds. Any answer, NXDOMAIN and REFUSED included, proves
the path works. Three misses in a row and the tunnel is restarted like a drop, so the reconnect above
brings it back — also when "Reconnect when the connection drops" is off, since the tunnel did not end
by your choice. While it misses, the tunnel shows `not answering for 40s` in the menu, `fivetctl status`
and the diagnostics. It pauses while the PC sleeps; after waking up it resets the count and probes once
Wi-Fi has had 8 seconds. It does not probe while the PC has no network, and a tunnel with no DNS
server inside it is not watched.

## Gateway certificate

Before every login FiveT makes its own TLS connection to the gateway (nothing is sent) and judges the
certificate, with the Mac app's rules (1.8):

- **The certificate this connection trusts** for this gateway: it connects.
- **A gateway met for the first time** (never logged in to, or its host or port was edited): trusted
  without asking only when Windows vouches for the certificate for exactly the host name FiveT
  connects to, as a browser would. A gateway reached by IP address therefore always asks the first time.
- **A known gateway showing another certificate**: a renewal, trusted without asking, when Windows
  vouches for it for the host name — or, for a gateway reached by IP address, when its chain is good
  and it is made out to a name the old certificate had. Once per attempt: a second change right
  after an automatic renewal always asks.
- **Anything else** becomes a review saved on the connection: **Review Certificate for Office…**
  (first time) or **Review New Certificate for Office…** (changed) in the menu, and **Review…** in
  Settings → Connections → Advanced. A click on the connection asks at once. An AI assistant, the
  command line or a fivet:// link fails with "Choose Review New Certificate for Office… in FiveT's
  menu". An automatic reconnect keeps retrying on its schedule without ever logging in, because a
  hotel Wi-Fi sign-in page that intercepts the connection goes away by itself; if the old
  certificate comes back, it connects.

"Windows vouches" means a chain to a root that **comes with Windows** (Microsoft's root program list,
which Windows keeps as `authroot.stl`), not expired, made out to the host name. A root that an
administrator, an antivirus or a TLS-inspecting proxy added to this PC does not count — the Mac only
counts the authorities that come with macOS, for the same reason.

The review shows what the certificate says it is, its SHA-256 fingerprint, the one trusted until now
and why FiveT did not accept it by itself. The safe answer (*Don't Connect* / *Keep Blocked*) has the
focus, and *Trust and Connect* / *Trust New Certificate* becomes clickable a second later so a stray
click cannot answer it. Other connections to the same gateway that trusted the old certificate follow
along. *Forget* (not offered while a review waits) makes the next connect a first meeting.

What is stored is the Mac's format, so a `connections.json` copied between the two apps keeps its
meaning: `trustedCert` (lowercase hex SHA-256 of the certificate), `trustedCertHost` (`host:port`),
`trustedCertNames`, and `pendingCert…` for a review. openconnect itself needs its own `pin-sha256:`
of the public key for `--servercert`; FiveT computes it from the certificate it just checked (and
keeps a copy in the Windows-only `trustedCertPin`), so openconnect refuses any other certificate.
A pin saved by Windows 1.4.0 is recognised and upgraded on the next connect, without a question.

## fivet:// links

The same links as the Mac app. Put one in a browser bookmark, a Start-menu shortcut, a Stream Deck
button, AutoHotkey, or a chat:

| Link | Does |
|------|------|
| `fivet://connect/Office` (or `up`) | connects Office; already up: nothing happens |
| `fivet://toggle/Lab` | connects Lab, or disconnects it if it is up |
| `fivet://disconnect` (or `down`) | disconnects every tunnel; `fivet://disconnect/Office` just that one |
| `fivet://settings` (or `open`) | opens Settings on Connections (Windows also takes `/general` and `/mcp`) |

`fivet:connect/Office` and `fivet://connect?name=Office` work too. Use the name exactly as it appears
in the menu; capitals don't matter; a space is `%20`. The first time a link connects, FiveT asks
**Connect to Office?** (Cancel is the default); tick *Always allow fivet:// links to connect* to skip
that — Settings → General → *Let fivet:// links connect without asking* turns it off again. The same
link repeated within 3 seconds is ignored. Links can only connect and disconnect: they never change
settings, trust a certificate or show a password, and FiveT never shows a link's text back to you.

Windows starts a second `FiveT.exe` for a link; it hands the link to the running app over a named
pipe only your account can open (`\\.\pipe\fivet-link-<SID>`), starting FiveT first if needed.

## One-time codes from a QR code

Settings → Connections → the connection → **One-time code from a QR code** (the row is always there,
even before a one-time-code mode is chosen). Take a screenshot of the setup QR code with **Win+Shift+S**,
then click **Paste Screenshot**; or **Choose Image…** for a saved picture; or drop a picture on the row.
All the QR codes in the picture are read. Both `otpauth://totp/…` and Google Authenticator's export code
(`otpauth-migration://`) work. A code that holds several accounts (an export) asks **Which account is
X's?**, with the one that looks like this connection preselected. A secret with no mode chosen yet sets
"Append TOTP code to password" (a gateway that wants it as a second step gets it that way on the
automatic retry). The clipboard is emptied after an import, but only if nothing else was copied meanwhile.
Check that the *Current code* matches your authenticator app.

FiveT makes 6-digit, 30-second, SHA-1 codes, like FortiGate expects. A code asking for anything else
(SHA-256, 8 digits, 60 s, HOTP) is **refused with the reason** rather than imported: it would give codes
the gateway rejects, which looks exactly like a wrong password. A FortiToken Mobile *activation* code is
not a TOTP secret and cannot be used this way.

You can also paste an `otpauth://` link straight into the TOTP secret box, as on the Mac: into an
*empty* box it is read (the link itself is never saved); next to an existing secret nothing is guessed,
the old secret stays and you are told to empty the box first.

## Import from FortiClient

The import button under the connection list (next to **+** and **−**) lists FortiClient's VPN
profiles and copies the ones you tick: name, gateway, port, realm (from `host:port/realm`) and user
name. Never passwords; add each one's password afterwards. Two sources, as on the Mac:

- this PC's FortiClient: `HKLM` and `HKCU\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels`;
- **Choose Backup File…**: a FortiClient configuration backup (`.conf`/`.xml`, from FortiClient →
  Settings → Backup) saved *without* a password — an encrypted backup is refused with that advice.

Only the first of several gateways joined by `;` is used. IPsec profiles are listed but cannot be
ticked (openconnect's FortiGate mode is SSL-VPN). A profile FiveT already has (same host, port, realm
and user) is shown but not ticked; a new one whose name is taken gets " (FortiClient)" added.

## Backup: export and import settings

Settings → General → **Backup** has **Export Settings…** and **Import Settings…**, the Mac's two buttons. Export writes a
`.fivet` file with every connection and the settings; import reads one, from this PC, another PC or a Mac. The file has the
layout of the Mac's `connections.json`, so it opens on both.

- **The secrets are in the file in plain text** (passwords, one-time-code secrets, OpenVPN profiles, V2Ray links). The copy
  in `connections.json` is DPAPI-encrypted and only opens for the same Windows account on the same PC, which is no use in a
  backup. Keep the file private. FiveT limits it to your Windows account where the drive allows (a USB stick with FAT cannot)
  and says so when it cannot.
- **Import adds and replaces.** A connection with the id of a saved one replaces it where it stands; the others are added. The
  settings in the file replace this PC's; a setting the file does not hold stays. What was saved before is kept once as
  `connections.json.before-import` (it is encrypted like `connections.json`). A file that is not a FiveT file is refused and
  changes nothing.
- **Only settings that mean the same on both apps travel.** The Mac's menu-bar name and automatic install, and this app's
  openconnect.exe path and update check, are left alone. The list of chosen apps holds programs of the app that wrote it: a Mac's apps
  are dropped on import, and apps-only is only switched on by a file that leaves at least one program for this PC (an empty list would
  take the rest of the PC off the VPN).

## Switch to Another VPN if One Stops Working

Settings → General → **Switch to Another VPN if One Stops Working** (off by default; the Mac's 1.20). If a V2Ray, Outline or OpenVPN
connection stays down after **3** failed reconnect tries, FiveT connects the **next VPN in the list** (Settings → VPN, top to bottom) and
goes round to the first at the end, until one works. Only VPNs take part, never Forti connections. One VPN runs at a time, so the next
one stops the failed one first, with the kill switch still blocking in between. Each new VPN gets the same three tries.

## Use the VPN for Chosen Apps Only ("Open with VPN")

Settings → General → **Use the VPN for Chosen Apps Only** (V2Ray and Outline; off by default; the Mac's 1.21). Instead of a tunnel that
takes all of the PC's traffic, FiveT runs Xray as a **local SOCKS proxy on `127.0.0.1`** (a free port chosen at random for each launch of
FiveT), and only the apps you choose use it. The rest of the PC stays on its normal connection.

- **Add App…** takes the program's `.exe` file (full path). With the switch on, FiveT's tray menu has an **Open with VPN** section with
  one row per app, enabled while a V2Ray or Outline VPN is connected. The app is started with `--proxy-server=socks5://127.0.0.1:<port>`
  (and `ALL_PROXY` in its environment).
- **Works for Chromium and Electron apps** (Chrome, Edge, Claude, Slack, VS Code, Discord…), not for most other programs, which ignore the
  switch. An app that is already open ignores it too: FiveT says so; quit the app (also from the tray), then start it from the menu.
- **No internet while the VPN is down.** The app has no other way out, and while Xray is away (a reconnect, a disconnect) FiveT holds the
  port itself and closes every connection at once, so no other program can take the port and receive what the app sends. "Connected" is only
  said once the listener on the port is FiveT's own Xray (the owner of the port is checked) and a web request gets through it.
- **Started with your own rights.** FiveT runs as administrator, but the app is started with the rights of your desktop (a copy of the
  shell's token), never with FiveT's. On a PC with UAC that is an unelevated app. If that is not possible nothing is started.
- Switching the mode restarts a V2Ray or Outline tunnel that is up. A kill switch block held for a full tunnel that dropped stays when you
  connect in this mode: only Unblock Internet or Disconnect lifts it.
- Xray runs as administrator, so FiveT's config check allows this one extra way in and nothing else: a SOCKS proxy on `127.0.0.1`, exactly
  that port, no login, no UDP, no tunnel next to it.

## AI assistants (MCP)

FiveT is also an **MCP server** (Model Context Protocol), so an AI assistant such as Claude Desktop,
Claude Code or Cursor can check the VPN status, connect, disconnect, read the log and diagnose
DNS/reachability problems, for example "connect to Office and tell me when it is up".

Shield → **Settings** → **MCP** tab:

- The switch **Let AI assistants control FiveT** turns the server on or off (on by default).
- **Add to Claude Desktop / Claude Code / Cursor** registers FiveT in that assistant with one click.
  Restart the assistant afterwards. Any other MCP client can run the command shown on that tab:
  `"C:\Program Files\FiveT\fivetctl.exe" --mcp`.

| Tool | What it does |
|------|--------------|
| `get_status` | state, connection, uptime, last error, `health` (the watchdog's verdict) and once connected: adapter, tunnel IP, DNS servers, search domains, pushed routes, split-DNS state. With several tunnels the top level is the one changing state (else the newest connected one); `sessions` has every active tunnel the same way and `active_connections` the connected names (`connections` and `connected_count` are kept from 1.3 to 1.4) |
| `list_connections` | saved connections with gateway, user, OTP mode, DNS domains, last connected time and last error, `certificate_trusted`, `certificate_review_needed` (never passwords) |
| `connect` | `{name, timeout_seconds=60, wait=true}` — idempotent (`already_connected` with uptime); waits until the tunnel is up or failed; `wait:false` returns `started`; `certificate_review_needed` (an error) when the gateway's certificate waits for Review Certificate… in the menu |
| `disconnect` | `{name}` stops that one tunnel and leaves the others up (`"X disconnected; Y still connected."`); without a name it stops them all; also stops a reconnect loop; waits until it is down |
| `get_log` | `{lines, level=info, connection, since, grep}` — event lines by default, `level:"debug"` for openconnect chatter |
| `get_diagnostics` | the same text as Copy Diagnostics |
| `resolve` | `{host}` — answer from the tunnel's DNS servers *and* from the system resolver |
| `check_reachability` | `{host, port=443}` — DNS both ways, route check, TCP connect, plain-language diagnosis |
| `get_settings` | the switches: `kill_switch`, `bypass_iranian_websites`, `failover`, `apps_only`, `vpn_apps`, `auto_reconnect`, `watchdog`, `notify_on_change` |
| `set_settings` | only the switches given; `vpn_apps` replaces the whole list (full `.exe` paths). **Lowering protection asks you first** (below) |
| `unblock_internet` | lifts a kill switch block, **after you say yes in a dialog** |

**Lowering protection needs your yes.** When an assistant or `fivetctl` asks to turn the Kill Switch off, put only the chosen apps on the
VPN, send Iranian websites around the VPN, or lift a kill switch block, FiveT shows its own dialog, "Allow this change?", with
*Don't Allow* as the safe answer (nothing is pre-selected, *Allow* only works after a second, and no answer in five minutes is a no).
Each request has its own dialog. If a setting moved while the dialog was open, a change you did not see is refused, and the assistant is
told nothing changed. Turning protection on, or changing the other switches, needs no question.

`connect` and `disconnect` report the real outcome (or the error). Every call is written to the log.
`resolve` and `check_reachability` look at *every* connected tunnel (their DNS servers and routes
together), not just one. `fivetctl --mcp` also answers requests that were sent just before its input
closed (`echo '{…}' | fivetctl --mcp` works), and a byte-order mark in front of the first line is ignored.

How it works: FiveT.exe listens on a named pipe, `\\.\pipe\fivet-mcp-<SID>`, whose security descriptor
admits only your account. `fivetctl --mcp` is a small bridge that the assistant launches; it forwards
stdin/stdout to that pipe and starts FiveT.exe first if it is not running (through the login task when
it exists, otherwise with a UAC prompt).

## Command line

Shell scripts do not need JSON-RPC; `fivetctl.exe` is a CLI (exit code 0 on success, 1 when the
action failed or the host is unreachable, 2 for a usage error, 3 when FiveT.exe cannot be reached):

```powershell
$F = "C:\Program Files\FiveT\fivetctl.exe"
& $F status                 # "connected to Office since … (up 0:42)" + tunnel/DNS/routes
& $F list                   # saved connections
& $F connect Office         # waits until the tunnel is up; already connected → exit 0 immediately
& $F connect Lab --timeout 90 --no-wait
& $F disconnect              # one tunnel:  & $F disconnect Office
& $F log --lines 50 --level info --connection Office --since 2026-09-05T19:00:00Z --grep auth
& $F resolve admin.corp.example
& $F check admin.corp.example 443
& $F settings               # the switches
& $F set failover on        # one switch (on|off); lowering protection asks you in a dialog first
& $F set vpn_apps "C:\Program Files\Slack\slack.exe,C:\Program Files\Google\Chrome\Application\chrome.exe"   # or: set vpn_apps none
& $F unblock                # lift a kill switch block (asks you first)
& $F status --json          # any command: the same JSON the MCP tools return
& $F --help
```

Tip: add the install folder to your PATH, then `fivetctl status` works from anywhere.

## Split DNS (internal host names while another VPN is on)

When another VPN owns the default route, Windows may never ask the tunnel's DNS servers for internal names
such as `admin.corp.example`, while `nslookup admin.corp.example 192.0.2.53` works.

Fix: Settings → Connections → the connection → **DNS domains**, e.g. `corp.example, lab.example`. While that
connection is up, FiveT adds NRPT rules (Name Resolution Policy Table) that send look-ups for those domains
to the pushed DNS servers, and removes them on disconnect (also on quit, and stale ones at the next launch).
`get_status` reports `split_dns.state` (`active`, `helper_needed`, `failed`); `check_reachability` tells you
when a host fails only because of this. You can inspect the rules with `Get-DnsClientNrptRule`.

## Log levels

The log keeps three levels: `ERROR`, `INFO` (connect, auth, tunnel up, DNS, routes, MCP calls) and `DEBUG`
(openconnect's verbose chatter, only produced when "Verbose openconnect logging" is on). Per-packet traces
are dropped unless "Keep per-packet traces" is also on in Settings → General.
Diagnostics and `get_log` show INFO and above by default.

## Editing connections

Shield → **Settings** → Connections tab. Select a connection to edit its name, gateway, port, realm,
username, password and one-time-code mode. Press **+** to add one, **−** to remove (it asks first), or
the import button to copy FortiClient's. Changes save immediately.
The password and TOTP secret stay masked; **Show…** (there only when something is saved) asks
Windows Hello, or your Windows password when Hello is not set up, then shows both until you pick
another connection or click **Hide**. You can always type a new one without showing the old.
"Extra openconnect options" are passed to `openconnect.exe` one per line, e.g. `--no-dtls` or
`--servername=vpn.example.com`. Options that could run a program, write a file, replace the certificate
FiveT just checked, or replace one of FiveT's own arguments (`--script`, `--csd-wrapper`, `--servercert`,
`--cookie`, `--config`, `--external-browser`, `--pid-file`, `--interface`, `--user`, the client-certificate
options, and their short forms) are left out and named once in the log: FiveT runs as administrator, and
any program of yours can edit `connections.json`. A line that does not start with `-` is ignored too.
Values are never written to the log or the diagnostics, only the option names.

The **General** tab has the setup status (*Set Up FiveT* / *Add Your VPN…*, and Requirements),
"Start FiveT at login" (the login task), auto-reconnect, notifications, the fivet:// question,
the VPN switches (Kill Switch, chosen apps only, switch to another VPN, Bypass Iranian Websites), Backup (export and import settings),
Copy Diagnostics and the log switches.

## Files

| What | Where |
|------|-------|
| Connections and settings | `%LOCALAPPDATA%\FiveT\connections.json` (passwords DPAPI-encrypted) |
| Log | `%LOCALAPPDATA%\FiveT\Logs\fivet.log` (moved to `fivet.log.1` at 5 MB, one line per entry) |
| A `.fivet` backup | wherever you save it (Settings → General → Backup); passwords and secrets in plain text |
| Your connections before an import | `connections.json.before-import` next to `connections.json` |
| A `connections.json` FiveT could not read | kept as `connections.json.bad-<date-time>` next to it; FiveT will not save over the original until that copy exists, and says so on Settings → General |
| Login task | Task Scheduler → `FiveT` |
| Split-DNS rules (while connected) | NRPT rules with comment `FiveT` (`Get-DnsClientNrptRule`) |
| MCP pipe (AI assistants) | `\\.\pipe\fivet-mcp-<SID>` |
| fivet:// links | `HKCU\Software\Classes\fivet`; hand-off pipe `\\.\pipe\fivet-link-<SID>` |
| Program | `C:\Program Files\FiveT` (or `%LOCALAPPDATA%\Programs\FiveT`), OpenConnect in its `openconnect\` |

## Security notes

- FiveT runs as administrator. Install it under `C:\Program Files` (the setup file does; or run `build.ps1 -Install`
  from an elevated PowerShell) so standard-user programs cannot replace the executable the login task starts.
  FiveT checks this itself: **it only runs `openconnect.exe` (and its `vpnc-script-win.js`) from a folder that
  only SYSTEM, Administrators and TrustedInstaller can change** (its own `openconnect\` folder, or Program
  Files), never from the PATH or `%LOCALAPPDATA%`, and a path chosen in Settings counts only if its folder passes
  the same test. The login task is only registered for a FiveT that sits in such a folder. Settings → General
  says so in plain words when it refuses one. (Developer builds, `FIVET_DEV=1`, skip the check while not elevated.)
- `connections.json` is writable by any program you run, so nothing in it is trusted to run code: see the extra
  options rule under [Editing connections](#editing-connections). A damaged file is never replaced by the seeded
  connections: it is copied to a `.bad-…` file first. A password that cannot be decrypted (a file copied from
  another Windows account) is kept as it is until you type a new one, not erased.
- The MCP pipe and `fivetctl` are reachable only by your own account (and not over the network); they never expose
  passwords or secrets. The log and the diagnostics hold no secrets and no way to add a forged line: line breaks
  from outside text become ` ⏎ `.
- A developer can seed connections with their own credentials in `src/FiveT/LocalSeeds.cs`, which is git-ignored.
  A fresh clone has no such file, builds with no connections; add them in Settings → Connections.
  **`build.ps1 -Installer` (and `release.ps1`) build with `-p:Distribution=true`, which leaves `LocalSeeds.cs` out
  of `FiveT.dll`** and refuses to package a `dist\FiveT.dll` that still carries it; a plain build or `-Install` keeps
  the seeds for this PC only.

## Changing the app icon

The artwork is `Resources/AppIcon-source.png` in the root of this repository. Resize it to 16, 24, 32, 48, 64, 128 and
256 px PNGs (on macOS: `sips -z N N in.png --out icon_N.png`) and pack them with
`python3 Tools/make-ico.py src/FiveT/Resources/AppIcon.ico icon_*.png`, then rebuild. The notification-area
shield is drawn by the app (flat, white on dark taskbars, black on light ones).

## Uninstall

If it came from the setup file: **Settings → Apps → Installed apps → FiveT → Uninstall**. That
removes the logon task, the fivet:// link registration and the program folder (with its OpenConnect). Your connections stay in `%LOCALAPPDATA%\FiveT` so a
reinstall finds them; delete that folder as well to remove them too.

For a copy put in place by `build.ps1 -Install`, or to clear everything by hand:

```powershell
schtasks /Delete /TN FiveT /F
Remove-Item -Recurse -Force "HKCU:\Software\Classes\fivet" -ErrorAction SilentlyContinue
Get-DnsClientNrptRule | Where-Object Comment -eq FiveT | Remove-DnsClientNrptRule -Force
Remove-Item -Recurse -Force "C:\Program Files\FiveT", "$env:LOCALAPPDATA\FiveT"
```

Then remove the `fivet` entry from the assistants you registered it with, and uninstall OpenConnect if you want.

## 2.0.0: the Mac's 1.9 to 1.17.1

Built from the Mac source in the root of this repository (1.17.1 at the time; the Mac's 1.18 and 1.19 are not ported yet).

**Connection kinds.** Settings has four tabs, as on the Mac: Forti, VPN, MCP, General.

| Kind | Engine (bundled) | Added by |
|------|------------------|----------|
| Forti (FortiGate SSL-VPN) | OpenConnect 9.21 | Forti tab: +, FortiClient import |
| OpenVPN | OpenVPN 2.6.23 | VPN tab: + → From a File (.ovpn), Paste, From OpenVPN Connect on This PC |
| V2Ray: VLESS, VMess, Trojan, Shadowsocks, Hysteria2 | Xray 26.10.31 | VPN tab: + → Paste (links, subscription address, Xray JSON), From a File |
| Outline (ss://, ssconf://) | Xray | VPN tab: + → Paste, From Outline on This PC |

Imports say what they added, skip what is already there, name duplicates apart ("Office 2"), and explain what
they could not read without showing an ID or password. OpenVPN Connect profiles keep the names they have there.
TOTP secrets still come in by QR picture or `otpauth://` link, and `fivet://` links still work.

**What runs together.** Any number of Forti connections, plus at most one VPN. Clicking a second VPN stops the
first ("Switching from X…") and starts the new one half a second after the old one is gone. Forti connections
are never touched by a switch. "Connect All" means the Forti connections.

**Failed-login limit.** After 2 failed logins in a row to one gateway (counted per gateway address, shared by
all connections to it, kept in `%LOCALAPPDATA%\FiveT\login-failures.json`, forgotten 3 hours after the last
one, cleared by a login that gets through) FiveT stops: reconnects, assistants, the command line and links are
refused (`login_limit_reached`); a click asks first, and **Try Anyway** allows exactly one more login. The other
way of sending the one-time code is only tried when the gateway never accepted the saved way.

**Kill Switch** (General → VPN Settings, off by default). For a VPN that carries all traffic (V2Ray, Outline,
OpenVPN with redirect-gateway); never for Forti. When such a VPN ends by itself, everything leaving the PC is
blocked except the PC itself, the local network, the VPN's server and the PC's DNS servers. Lifted when the
VPN is back, when you disconnect it, by **Unblock Internet** in FiveT's menu, by switching the setting off, or
by quitting FiveT. It uses Windows Filtering Platform filters in a session of FiveT's own: Windows removes
them by itself if FiveT exits or crashes, your firewall rules are never touched, and nothing is left for the
uninstaller. Recovery if the internet stays blocked: FiveT's menu → Unblock Internet, or quit FiveT.

**Bypass Iranian Websites** (General → VPN Settings, on by default; V2Ray and Outline). `.ir` names and Iranian
addresses go direct. `.ir` names are asked of the PC's own DNS; names the world's DNS does not know are asked
there too, and the answer counts only if it is an Iranian address. Takes effect at the next connect.

**V2Ray/Outline details, as on the Mac.** A server given by name is looked up with the PC's DNS before the
tunnel exists and handed to Xray. Only DNS is carried over UDP; **any other UDP is dropped** (browsers fall
back from QUIC to TCP; voice calls and games that need UDP do not work through these connections). A
connection counts as up only after a web request got through the server. While up, every name goes to the
tunnel's DNS (an NRPT rule for `.`, removed on disconnect).

**Security.** OpenVPN and Xray run as administrator, and `connections.json` can be changed by any program of
the user, so: both run only from FiveT's install folder; an OpenVPN profile may only use an allow-list of
options (no scripts, plug-ins, management socket, files outside the profile; checked at import and again on
the text that is passed on); an Xray config is built by FiveT and checked before use (only the TUN in, no file
names, no extra ports). Profiles, links and server IDs are stored with DPAPI and kept out of the log and of
Copy Diagnostics. `fivet://` links always ask before connecting ("Always allow" is gone, Mac 1.15.1).

**Storage.** Pasted gateway, realm and user names are cleaned as they land, and connections saved with blank
lines or a leading `remote` are repaired once at start. A copy of the last `connections.json` that loaded
whole is kept as `connections.json.bak`; if the file is damaged, FiveT restores from that copy, keeps the
damaged file as `.bad-<time>`, and says so on General. A save that fails leaves the previous file in place.

**Different from the Mac, on purpose.** OpenVPN's adapter is created once ("FiveT
OpenVPN", kernel driver ovpn-dco; "FiveT OpenVPN TAP" for profiles with compression or old ciphers). Outline's
saved servers are read from the Outline client's storage files; when Windows has compacted them, copy the key
and paste it. Files cannot be dragged onto FiveT (it runs elevated): use + → From a File. Xray is 26.10.31
(the Mac pins 26.10.29).

**Build.** `.\build.ps1 -Installer` → `release\FiveT-Setup-<ver>.exe` (x64) and `-arm64.exe`. The engines are
fetched once by `Tools\fetch-engines.ps1` into `engines\` (git-ignored), each checked against a pinned
SHA-256; OpenVPN comes from the OpenVPN project's CI build of the 2.6.23 release commit (needs `gh`). Tests:
`dotnet test tests\FiveT.Tests` (115 checks). Windows 10 1809 or later, x64 or ARM64, administrator rights at
install; nothing else to install. The setup files are **not code-signed** (Windows SmartScreen will warn).

**Measured on this ARM64 laptop** (launch = start to "FiveT launched" in the log, 3 runs; memory = private
bytes 12 s after start):

| | 1.5.0 (x64, emulated) | 2.0.0 (ARM64) |
|---|---|---|
| Setup file | 46.4 MB | 55.0 MB (x64: 57.7 MB) |
| Installed | 176.7 MB | 227.3 MB (x64: 213.4 MB) |
| Launch to tray, warm | 1.27 s | 0.52 to 0.64 s |
| Memory | 70 MB | 22 MB |
| Idle CPU | not measured | 0.06 s in 30 s |

The size went up by the two new engines (Xray 30.5 MB, OpenVPN 7.5 MB); no further safe reduction was found
(trimming breaks WinUI; the removable framework files left are about 5 MB). The speed and memory gain is the
native ARM64 build, which 1.5.0's build script could already make but which was not the one installed.

**Verified for 2.0.0.** 54 automated checks (72 in 2.1.0, with the update-feed rules); upgrade 1.5.0 → 2.0.0 (both saved connections, IDs and login
task kept); uninstall (program folder, task, link registration, adapter, DNS rules gone; data kept; internet
fine); fresh install; Settings tabs; OpenVPN engine path with a synthetic profile (adapter created, program
started, error reported, nothing left running); Xray TUN on a reserved test range; kill-switch filter on a
reserved test address; no seeded credential in either build.

**Not run (pending, needs a real server and any other VPN on the PC switched off):** a real OpenVPN, V2Ray or Outline
connection; switching between two live VPNs; a Forti connection next to a live VPN; the kill switch blocking
for real; Bypass Iranian Websites against Iranian sites; reconnect after sleep with a VPN up; the Outline and
OpenVPN Connect imports against real app data; the x64 setup file on an Intel/AMD PC.

## Updates

New in 2.1.0 (the first release published here): the update check below, and a reproducible build (no .pdb, no local
paths inside the binaries).

FiveT reads `latest-windows.json` from the rolling GitHub release tagged `windows-feed`
(https://github.com/FiveT-Gate/FiveT/releases/download/windows-feed/latest-windows.json), once a day and from
Settings → General → Updates → *Check Now*. The file names one setup file per architecture:

```json
{ "version": "2.1.0", "notes": "…",
  "assets": { "x64":   { "url": "https://github.com/FiveT-Gate/FiveT/releases/download/windows-v2.1.0/FiveT-Setup-2.1.0.exe",
                         "sha256": "<64 hex digits>", "signature": "<Base64>" },
              "arm64": { "…": "…" } } }
```

- The signature is ECDSA P-256 / SHA-256 over the text `FiveT Windows update`, `version=…`, `arch=…`, `sha256=…`
  (one per line). The public key is in `src/FiveT/UpdateFeed.cs`; the private key is held by whoever publishes. FiveT
  refuses a feed entry without a valid signature, a URL outside `https://github.com/FiveT-Gate/FiveT/releases/download/`,
  or a version that is not newer than the running one.
- When a newer release is found FiveT downloads the setup file into `updates\` inside its install folder in the
  background and checks the SHA-256. It waits until no tunnel is in use (two looks 3 minutes apart), then quits, runs
  the setup silently and starts again. *Install and Restart* in Settings → General → Updates does it at once. With the
  switch off FiveT makes no automatic check; *Check Now* still works. Nothing installs when FiveT is quit by hand.
  A copy that does not run elevated from an administrator-only folder (a developer build, a per-user install) only
  reports that an update exists, because FiveT never runs a file that an ordinary program could have replaced.
- The Mac app's feed is a different file (`releases/latest/download/latest.json`). Windows releases are therefore
  never marked "latest" on GitHub.