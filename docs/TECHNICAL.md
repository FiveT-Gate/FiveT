# FiveT

One-click FortiGate SSL-VPN from the macOS menu bar. Native Swift app, no FortiClient needed.

Click the shield icon in the menu bar, click a connection name, and you are connected.
Click it again to disconnect. The icon shows the state:

| Icon | Meaning |
|------|---------|
| outline shield | not connected |
| animated shield | connecting / disconnecting |
| shield with check mark | connected |
| red shield with ! | last attempt failed (open the menu to read why) |

## How it works

- The VPN itself is handled by `openfortivpn`, the open-source Fortinet SSL-VPN client. FiveT ships its
  own copy inside the app (`Contents/Helpers/openfortivpn`, OpenSSL linked in, built by
  `Tools/build-openfortivpn.sh`), so a new Mac needs neither Homebrew nor Terminal.
- For **Office**, the app generates the 6-digit TOTP code from your secret and appends it to the static
  password automatically ("Append TOTP code to password" under One-time code; a gateway that asks for the
  code in a second step takes the other setting, and a login rejected in one mode is retried once in the
  other, which is then kept, as long as that retry cannot reach the failed-login limit: see
  [Failed logins](#failed-logins)). The Forti tab in Settings shows the current code with a Copy button if
  you ever need it; the secret itself stays masked until you pass Touch ID or type your Mac password (on a
  Mac without Touch ID, FiveT asks for the Mac password itself).
  A code is valid for one login per 30-second window, so reconnecting inside the window in which you last
  logged in waits for the next code (the menu line says `Waiting 12s for a fresh code…`); a code with only a
  few seconds left is skipped for the next one; and a login the gateway rejects is retried once with a fresh
  code before an error is shown (unless that would be the failed-login limit). Lab has no code and connects in about 3 seconds.
- Starting a tunnel needs root, so a one-time "helper" installs a sudoers rule that allows exactly one
  command without a password: FiveT's small root script, which starts and stops tunnels and manages
  split-DNS files. It never runs the openfortivpn inside FiveT.app (or Homebrew's): those files belong to
  your user, so any program running as you could swap them. It runs a root-owned copy, made when you
  click Set Up FiveT (or Install Helper…), and passes on only a list of harmless openfortivpn options.
  The password goes to it through a pipe and is never written to disk.
- The gateway's certificate is checked before any password or code is sent. See "Gateway certificates".

## First-time setup (works while your personal VPN is ON)

1. Open **/Applications/FiveT.app**. A shield icon appears in the menu bar (top right). On a Mac where
   FiveT was never set up, Settings opens by itself on the **General** tab.
2. Click **Set Up FiveT** and type your Mac password. That is all: openfortivpn comes with the app.

Closed Settings first? The shield menu shows **Set Up FiveT…**, and clicking a connection sets FiveT up
(one password prompt) and then connects. Updating from 1.4.3 or older: the helper needs the same one-time
step (security update); until then the menu shows **Set Up FiveT…** and connecting says so.

**Updates need no click (helper v6 and newer).** The helper can replace itself and the root-owned copies of
openfortivpn, OpenVPN and Xray from the FiveT.app it is updated with: FiveT runs `refresh <path of FiveT.app>`
at launch (and when a connect finds the helper outdated), from an Applications folder only. The helper copies
the app to a folder only root can enter, checks THERE that its code signature carries FiveT's own certificate
(`certificate leaf = H"…"`, `Setup.releaseCertHash`; the signature seals every file, the programs and
`Contents/Resources/fivet-helper.sh` included, so a changed, added or removed file fails), refuses a build
older than the installed one (`app.fivet.build`, so an old release cannot bring back a bug), and
only then installs, the new helper last. The sudoers rule is never touched. The first time, on a Mac whose
helper is older than v6 (or after the certificate changes), the Setup section still says
**Install Helper…**: that click (one password prompt) is the last one.
Tested by running the shipped script with its folders redirected: the genuine app installs; another
certificate, a re-signed binary, an edited helper, an added or removed file, a symlink, a faked build number,
an older build and a second run at once are all refused.

The root-owned copy otherwise stays as it is when FiveT updates itself. On a Mac first set up with
Homebrew's openfortivpn, the Setup section says so; click **Install Helper…** to copy FiveT's. After that,
`brew upgrade` does not matter: Homebrew's openfortivpn is used only by a build that has none inside (a
plain `swift build`).

Building: `./build.sh` also builds the bundled openfortivpn the first time (about a minute; needs
`brew install autoconf automake pkgconf oxipng` on the build Mac, and downloads the pinned openfortivpn
and OpenSSL sources once into `build/deps`, checked against their SHA-256). OpenSSL is built without the
parts a VPN client never uses, and the app's binary is stripped, so FiveT.app is 5.1 MB (8.3 MB in 1.7.2);
`./build.sh --dmg` keeps the unstripped binary in `build/symbols` for reading crash logs.

## Test runbook (your personal VPN must be OFF)

FortiGate gateways do not answer while the personal VPN is on, so Claude will be offline during this part.

1. Turn your personal VPN off.
2. Click the shield → click **Office**. The icon animates for a few seconds, then shows a check mark.
   The menu line reads `Office — Connected 0:05` and keeps counting.
3. Open something that only works on the Office network to confirm.
4. Click the shield → click **Office** again. The icon returns to the outline shield.
5. Repeat steps 2–4 for **Lab**.
6. Whatever happened, open shield → **Settings** → **General** tab → **Copy Diagnostics**. Turn your personal VPN back on and
   paste the clipboard into the chat. It contains the setup checks and the last log lines, never the passwords.

## One VPN at a time, next to Forti

Forti connections run next to a VPN (OpenVPN, V2Ray, Outline) and next to each other; a Forti connect
never stops anything and a VPN connect never stops a Forti connection. Two VPNs never run together:
clicking another VPN while one is up switches (the one that is up is disconnected, then the clicked one
connects: `Switching from outline-2…`). Clicking the connected one disconnects it. The kill switch is the
VPN's: connecting, disconnecting or losing a Forti connection never lifts or sets it.

## Kill switch

**Settings → General → Kill switch** (off by default) covers connections that carry all of the Mac's
traffic: V2Ray, Outline, and OpenVPN profiles that redirect the gateway. When such a connection goes down
without having been switched off (a drop, a tunnel that stopped answering, a network change), the helper
loads packet filter rules (`ks-on`, anchor `com.apple/100.fivet`) that let nothing leave the Mac except to
the local network, the VPN's server and the Mac's DNS servers, so FiveT can reconnect. The block is lifted
(`ks-off`) when the tunnel is back, on Disconnect, on **Unblock Internet** in the menu, when FiveT quits,
and by a restart of the Mac. While the tunnel is up nothing is filtered: its routes carry everything, and
"Iranian sites go direct" keeps working. A program that ends by itself is blocked about 0.1 s after its
routes went. Disconnecting by hand, or switching to a Forti connection, never blocks.

Split DNS: FiveT installs `/etc/resolver/<domain>` for the DNS suffixes the gateway pushes (Lab pushes
`corp.example`, `intranet.example`)
plus whatever you list under the connection's **DNS domains** (Office pushes none, so `corp.example` is
listed by hand; add any other Office domains you use there).

## Gateway certificates

openfortivpn checks the gateway's certificate before it logs in. When it does not accept one, it says so
the same way for a gateway met for the first time and for a certificate that changed, and stops before
sending the password. FiveT decides what happens next, and only a person can decide to trust:

- **First connection to a gateway** (or after its host or port was edited, or after Forget): FiveT opens
  its own TLS connection and asks macOS. If macOS vouches for the certificate for the exact host name
  (as a browser would), FiveT trusts it. A gateway reached by IP address (Office, Lab) cannot pass that
  check, so FiveT asks once: **Trust the certificate of Office's gateway?** with the certificate's names,
  issuer, expiry and fingerprint. That is the step FortiClient calls "accept this certificate".
- **A known gateway shows another certificate:** a renewal, or someone intercepting the connection
  (hotel or café Wi-Fi), and openfortivpn cannot tell which. FiveT trusts it without asking only when
  macOS vouches for it (only the certificate authorities that come with macOS, no added ones) and it is
  made out to a name the previous certificate had (Office's Certum certificate for `*.vpn.example`,
  renewed every year, passes). Anything else waits for a review: **Review New Certificate for Office…**
  in the menu, and Review… in Settings → Forti → Advanced. Keep Blocked is the default.
- Who is asked: after a click (menu, Settings) the review opens at once. After a connect from an AI
  assistant, the command line or a `fivet://` link, the connect fails with
  `certificate_review_needed` and the review waits in the menu; no tool can trust a certificate. An
  automatic reconnect keeps retrying meanwhile (a Wi-Fi sign-in page that intercepts the connection goes
  away by itself), and no password goes to a certificate that is not trusted.
- FiveT believes only the fingerprint line of openfortivpn's refusal. The lines after it are text from
  the certificate itself, which whoever made it chose, and go to the debug log only.
- Settings → Forti → Advanced shows the trusted fingerprint (or "Verified by a certificate
  authority"). Forget makes the next connect a first meeting; it is hidden while a review waits.

## Import from FortiClient

Settings → Forti → the import button (arrow into a tray, bottom of the list):

- **From FortiClient on this Mac** reads the profiles FortiClient keeps in
  `/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist`: name, gateway, port, realm and
  user name. Only SSL-VPN profiles are taken; IPsec ones are listed as ignored.
- **From a FortiClient backup file…** reads a backup made in FortiClient → Settings → Backup. Make it
  *without* a password; an encrypted backup cannot be read.

A profile whose gateway, port, realm and user name already exist is skipped. FortiClient never hands out
passwords, so enter the password (and the TOTP secret, if the login needs one) for each imported connection.

## If the connection drops

When a connected VPN drops on its own (Wi-Fi change, sleep, gateway hiccup), FiveT reconnects in the
background: first after 2 seconds, then every 10, 20, 30 … up to 60 seconds, until it is back. The
menu line reads `Office — Connection lost, retrying in 10s (try 2)…` meanwhile; the icon holds still
during that wait (a half shield when no other tunnel is up) and animates only while an attempt is running.
It stops retrying if the login is rejected (so a changed password can never lock the account), when the
gateway reaches the failed-login limit (below), or when you click the connection to disconnect. A manual
disconnect never reconnects by itself. FiveT always runs openfortivpn with `persistent = 0`: openfortivpn's
own reconnects would log in behind FiveT's back, past the limit and with a used one-time code.

FiveT watches the Mac's network. With no Wi-Fi, Ethernet or cellular network, a reconnect waits (the menu
line reads `Office — Connection lost, waiting for the network…` and the icon holds still) instead of
failing every minute, with one try every two minutes in case macOS's report is wrong. The moment a
network is back, or the Mac moves to another network (Wi-Fi to a phone hotspot), waiting reconnects start
at once.

A tunnel that is up when the Mac moves to another network (Wi-Fi 1 to Wi-Fi 2, the cable unplugged, a
personal VPN it ran through switched off) is reconnected at once, about two seconds after the new network
is up. FiveT notes which of the Mac's own addresses each tunnel runs over (`get_status` shows it as
`outer_interface` and `outer_ip`, `FiveT status` as `over: en0 192.168.1.20`). When that address is gone
the tunnel cannot come back by itself: openfortivpn pinned its route to the gateway through the old
network's router, and would go on saying "connected" for minutes. The menu line reads
`Office — Network changed, retrying in 2s (try 1)…` meanwhile. A short Wi-Fi drop that keeps the
address, or a roam to another access point of the same network, leaves the tunnel alone; tunnels whose
address is still there get one watchdog probe instead, since they rode on the old network.
The switch is in Settings → General → "Reconnect when the connection drops". With it off, a tunnel whose
network is gone is disconnected instead, and the menu says why.

A tunnel can also die quietly: after a sleep or a network change, pppd keeps saying "connected" while
nothing gets through, until the gateway times the session out many minutes later. The watchdog catches
this: every 20 seconds it sends one DNS question to the gateway's own DNS server *through the tunnel*
(any reply counts, even "no such name"; when DNS gets no answer, a ping to that server counts too, since
some Macs filter every DNS question, e.g. NordVPN Threat Protection). Three silent probes in a row, about a minute, and the tunnel is
torn down and reconnected. The menu line shows `Office — Connected 12:03 · not answering for 40s` while
it is deciding, and `get_status` reports `health`. Switch: Settings → General → "Reconnect when the tunnel
stops answering".

Sleep (a closed lid, or a locked Mac that goes to sleep) is where this happens most: the gateway drops a
session that has been idle for a few minutes, and the network on the way discards the Mac's packets
instead of refusing them, so openfortivpn never notices. So after a wake the first check decides alone:
8 seconds after the wake (time for Wi-Fi to come back) FiveT asks each tunnel's DNS server once, and a
tunnel that does not answer is reconnected at once (`Office — Woke from sleep, retrying in 2s (try 1)…`)
instead of after three rounds. A reconnect that comes due while the Mac goes to sleep waits for the wake,
then starts 8 seconds after it or as soon as the network is back, whichever is first. Without that, its
timer would fire the instant the Mac wakes, before Wi-Fi is up, and the attempt would hang for 20 seconds.

## OpenVPN connections

FiveT also runs OpenVPN connections: same menu (click to switch on
or off; once one is saved, the menu has a **Forti** section and a **VPN** section), reconnects, sleep handling, watchdog, failed-login limit, split DNS, CLI and assistants. It ships
its own OpenVPN (2.6, built by `Tools/build-openvpn.sh` with the same OpenSSL, LZO and LZ4, **without
plug-ins and without the management interface**, licenses in `Contents/Resources/openvpn-licenses`).

- **Add one:** Settings → **VPN** tab (next to Forti) → **+** picks a profile file (.ovpn); the import
  button also offers **From OpenVPN Connect on this Mac** (its saved profiles, under the names they have there: OpenVPN Connect keeps them in its `config.json`, not in the profile files, which are named by number). Certificate and key files a profile names are read and kept
  inside it; a login file fills Username and Password. Windows-only lines and Linux scripts (`up`, `down`,
  `script-security`…) are left out with a note: FiveT sets DNS itself. An encrypted private key (`askpass`)
  is not supported yet.
- **Login:** a profile with `auth-user-pass` gets Username and Password fields; one with a certificate
  only needs nothing. A one-time code (TOTP secret) is sent appended to the password, or as OpenVPN's
  static-challenge answer (`SCRV1:…`), which FiveT picks when the profile has `static-challenge`. The login
  goes to OpenVPN inline through the helper's pipe, never to disk.
- **Safety:** the root helper (v4) refuses any option outside an allow-list: nothing that runs a program,
  reads or writes a file as root, opens a control socket or drops root, including `setenv opt` forms. It
  always adds `--script-security 1 --auth-retry none --remap-usr1 SIGTERM`: no scripts, no login retries of
  OpenVPN's own (FiveT counts failed logins), and an exit instead of OpenVPN's own restart (FiveT reconnects,
  with a fresh one-time code).
- **DNS:** the domains the server pushes (`dhcp-option DOMAIN`) get split DNS like FortiGate. When all
  traffic goes through the tunnel (`redirect-gateway`), its DNS server answers every name while it is up
  (helper `dns-set`: the tunnel is the Mac's primary network service, as pppd does), so the local
  network's resolver, which may answer differently, is not asked. Removed at disconnect, at quit, and at
  the next launch after a crash.
- FiveT leaves other VPN apps alone: connecting a FortiGate connection does not touch an OpenVPN that is up.

## V2Ray and Outline connections

The **VPN** tab also runs V2Ray-family servers (VLESS, VMess, Trojan, Hysteria2) and **Shadowsocks, which is
what Outline's access keys are**, all through FiveT's own Xray (`Tools/fetch-xray.sh`, pinned by SHA-256,
`Contents/Helpers/xray`; helper v5 `xray-run`). It is a full VPN: one TUN takes all of the Mac's traffic and
its DNS, `.ir` sites and Iranian addresses go direct (a toggle on each connection), and only one VPN
runs at a time (clicking another switches to it; Forti connections can stay up next to it). A connection is *up* only once a web request
gets through the server.

- **How names are looked up:** a server given by name (`upload.example.com`, as most keys are) is looked up
  once with the Mac's own DNS *before* the tunnel starts, and Xray is given the answer. Left to Xray it
  asked through the tunnel, which needs the server it is looking for, and never connected. The Mac's other
  names are asked of Xray's DNS over **TCP** through the server (`tcp://1.1.1.1`, `tcp://8.8.8.8`), because
  Xray 26.10 on macOS 27 cannot bind a UDP socket to the Wi-Fi (`falied to set interface`).
- **UDP:** apart from DNS, UDP from the Mac is dropped inside the tunnel (the log says `[tun -> block]`):
  with that same limit it would loop back into the TUN. Web, mail and chat use TCP and are unaffected;
  browsers fall back from QUIC to TCP; calls that need UDP do not work through a V2Ray connection yet.

- **Add one:** Settings → **VPN** → **+** → **Paste Links, Keys or Subscription** (or drop text or a file
  on the tab, or ⌘V). Accepted: `vless://` `vmess://` `trojan://` `hysteria2://` links, Xray JSON files,
  subscription addresses, and Outline keys: `ss://…` (one server; the `?outline=1` and `#name` parts are read)
  and `ssconf://…` (a *dynamic* key: the address is fetched and answers with the server, so **Refresh** on
  the connection asks it again).
- **From the Outline app:** **+** → **From Outline on this Mac** reads the servers saved in Outline
  (`servers_v1` in its web storage, inside `~/Library/Containers/org.outline.macos.client`), under the names
  they have there. macOS lets another app read those folders only after the user agrees; when it did not,
  FiveT first asks for a one-click way: the system's folder dialog, already at Outline's folder (click
  **Allow**); failing that, **Open Full Disk Access** opens that System Settings page and shows FiveT in
  Finder to drag into the list. Outline's data is copied first and read from the copy; nothing of Outline's
  is changed. (V2Box has no import button: copy its links and paste them.)
- **Outline's `prefix`:** a key with `&prefix=…` makes Outline start the connection with chosen bytes so a
  firewall does not recognise Shadowsocks (they are the first bytes of the connection's salt). Xray does not
  send them, so such a key is an ordinary Shadowsocks connection: it should connect on networks that allow
  Shadowsocks and not on one that blocks it, and the import says so. Not tested against a real prefixed key.
- **Safety:** a connection keeps only its server (an Xray outbound); FiveT builds the rest of the config, and
  the root helper re-checks it with the JavaScript that ships with macOS (only a TUN in, only servers,
  direct, block and DNS out, no file names, no ports) and hands Xray the re-written text.
- **Debug:** `FiveT --check-outline [file]` lists what an import would read (names and kinds, never a key),
  with a JSON list of `{name, accessKey}` standing in for Outline's storage; `FiveT --check-v2ray <file|link|->`
  prints the parsed server.

## Failed logins

FortiGates ban the Mac's internet address after a few failed logins in a row (Office's gateway: after 3,
for a couple of hours), and in an office that address is shared by everyone. So FiveT never makes that
third failed login by itself:

- A failed login is one the gateway saw: openfortivpn said "Connected to gateway." (the password goes out
  right after) and never "Authenticated.". A try that never reaches the gateway (no network, a timeout, a
  refused certificate) does not count, so reconnects after a drop still go on as long as it takes. A login
  stopped after its password went out counts.
- FiveT counts per gateway address, for every connection that logs in there (two connections to the same gateway share
  one count) and for every copy of FiveT on the Mac. A login that gets through clears the count; else
  it is forgotten 3 hours after the last failure.
- After **2** failed logins in a row FiveT stops: reconnects, watchdog, wake and network restarts, the
  one-time-code retry, assistants (`connect` returns `login_limit_reached`), the CLI and `fivet://` links
  are refused, and the menu says why. Clicking the connection asks first. **Try Anyway** allows exactly one
  more login, at the count the question showed; Open Settings is the default. One question per gateway at a time.
- Logins to one gateway go one at a time while any failure is on record: a connection whose login would be
  the one that can reach the limit waits (`Waiting for another login to the same gateway…`) until the other
  one has got through or failed.
- When only the saved way of sending the one-time code was refused, the next login (Try Anyway included)
  sends it the other way, and keeps that way if it logs in.

The count is in `~/Library/Application Support/fivet/login-failures.json`. Deleting it while FiveT is
not running resets it (only do that when you are sure the gateway has not banned the address).

## Signing and notarization

Builds are signed ad-hoc unless `signing.env` exists next to `build.sh`. Copy `signing.env.example` to
`signing.env` and follow its two steps (an Apple Developer Program membership, USD 99 per year, plus a
one-time `notarytool store-credentials`). From then on `./build.sh --dmg` signs the app
with the Developer ID and hardened runtime, notarize the app and the DMG with Apple, and staple the
tickets, so a download opens with no "cannot verify the developer" step. `signing.env` holds only the
certificate name and the keychain profile name; the secrets stay in the keychain. Once signing is active,
drop the "Open Anyway" step from `Resources/ReadMe-DMG.txt`, the disk image window's artwork
(`Resources/dmg/background.html`).

## AI assistants (MCP)

FiveT is also an **MCP server** (Model Context Protocol), so an AI assistant such as Claude Desktop,
Claude Code or Cursor can check the VPN status, connect, disconnect, read the log and diagnose
DNS/reachability problems, for example "connect to Office and tell me when it is up".

Shield → **Settings** → **MCP** tab:

- The switch **Let AI assistants control FiveT** turns the server on or off (on by default).
- **Add FiveT to: Claude Desktop / Claude Code / Cursor** registers FiveT in that assistant with one
  click. Restart the assistant afterwards. For any other MCP client, **Copy JSON** copies the entry to
  paste into its settings; the command it runs is `/Applications/FiveT.app/Contents/MacOS/FiveT --mcp`.

| Tool | What it does |
|------|--------------|
| `get_status` | state, connection, uptime, last error, and once connected: interface, tunnel IP, DNS servers, search domains, pushed routes, split-DNS state; `sessions` lists every active tunnel, `active_connections` their names |
| `list_connections` | saved connections with gateway, user, OTP mode, DNS domains, last connected time, last error, `failed_logins` / `login_limit_reached` (see [Failed logins](#failed-logins)) and each one's state (never passwords) |
| `connect` | `{name, timeout_seconds=60, wait=true}` — adds a tunnel next to the ones already up; idempotent (`already_connected` with uptime); waits until the tunnel is up or failed; `wait:false` returns `started`; `certificate_review_needed` when the gateway's certificate needs the user's review in FiveT's menu (no tool can trust one); `login_limit_reached` after failed logins to that gateway: nothing was sent, never retry |
| `disconnect` | `{name}` stops that one tunnel and leaves the others up; without `name` stops them all; waits until down |
| `get_log` | `{lines, level=info, connection, since, grep}` — event lines by default, `level:"debug"` for openfortivpn chatter |
| `get_diagnostics` | the same text as Copy Diagnostics |
| `resolve` | `{host}` — answer from the tunnel's DNS servers *and* from the system resolver |
| `check_reachability` | `{host, port=443}` — DNS both ways, route check, TCP connect, plain-language diagnosis |

`connect` and `disconnect` report the real outcome (or the error). Every call is written to the log.

How it works: FiveT.app listens on a Unix socket, `~/Library/Application Support/fivet/mcp.sock`
(mode 0600, so only your own account can use it). `FiveT --mcp` is a small bridge that the assistant
launches; it forwards stdin/stdout to that socket and starts FiveT.app first if it is not running.

## Command line

Shell scripts do not need JSON-RPC; the same binary is a CLI (exit code 0 on success, 1 when the
action failed or the host is unreachable, 2 for a usage error, 3 when FiveT.app cannot be reached):

```sh
F=/Applications/FiveT.app/Contents/MacOS/FiveT
$F status                 # "connected to Office since … (up 0:42)" + tunnel/DNS/routes
$F list                   # saved connections
$F connect Office         # waits until the tunnel is up; already connected → exit 0 immediately
$F connect Lab --timeout 90 --no-wait
$F disconnect
$F log --lines 50 --level info --connection Office --since 2026-09-05T19:00:00Z --grep auth
$F resolve wiki.corp.example
$F check wiki.corp.example 443
$F status --json          # any command: the same JSON the MCP tools return
$F --help
```

Tip: `alias fivet=/Applications/FiveT.app/Contents/MacOS/FiveT` in your shell profile.

## Split DNS (internal host names while another VPN is on)

macOS installs the FortiGate's DNS servers as a resolver *scoped* to the tunnel interface. When another
VPN (a `utun`) owns the default route, normal apps (curl, Python, browsers) never ask that resolver, so
internal names such as `wiki.corp.example` fail while `nslookup name 10.0.0.53` works.

Fix: Settings → Forti (or OpenVPN) → the connection → **DNS domains**, e.g. `corp.example, intranet.example`. While that
connection is up, FiveT writes `/etc/resolver/<domain>` for those domains and for the DNS suffixes the
gateway pushes, pointing at the pushed DNS servers, and removes the files on disconnect (also on quit, and
at the next launch any a crash left behind, found by the `# managed by FiveT` first line). This needs the
root helper from the Setup section.
`get_status` reports `split_dns.state` (`active`, `helper_needed`, `failed`); `check_reachability` tells you
when a host fails only because of this.

## Log levels

The log keeps three levels: `ERROR`, `INFO` (connect, auth, tunnel up, DNS, routes, MCP calls) and `DEBUG`
(openfortivpn's chatter, only produced when "Detailed log" is on). Per-packet traces
(`pppd ---> gateway`) are dropped unless "Include packet traces" is also on (Settings → General →
Troubleshooting).
Diagnostics and `get_log` show INFO and above by default.

Secrets stay out of the log: openfortivpn's session cookie (`Cookie: SVPNCOOKIE=…`, written with "Detailed
log" on) and one-time codes are hidden before a line is written, and so is a config line openfortivpn
cannot read (it would repeat it, and it may be a password pasted in the wrong place; such lines are not
sent to it any more). The first start of 1.8 hides those values in older log lines too. Diagnostics show
the connection's extra options with the values of anything that could be a secret hidden.

## Editing connections

Shield → **Settings** → **Forti** tab (OpenVPN connections are on the **VPN** tab next to it). Select a connection to edit its name, gateway, port, realm,
username, password and one-time-code mode. Press **+** to add one, **−** to remove. Changes save immediately.

Text pasted into these fields is cleaned as it lands: blank lines go (a field shows only the first line of a
paste, so they used to hide, and openfortivpn's one-setting-per-line config cannot hold them), and so does a
leading “remote” when a gateway was copied from an OpenVPN profile line. Connections saved that way by an older
FiveT are repaired when it starts (`Connection.cleanPastedFields`). A line break inside a password is left alone:
the connect then refuses it and says so.

**One-time-code secret from a QR code:** Login → **Import QR Code** → **Paste Screenshot** (take one of
the QR code with ⌃⇧⌘4 first) or **Choose Image…**, or drop the picture on that row, or paste the
`otpauth://` link into the secret field. A Google Authenticator export ("Transfer accounts") works too;
with several accounts in it, FiveT asks which one. FiveT makes 6-digit, 30-second SHA-1 codes (FortiToken's
kind) and says so when a code needs other settings. After a clipboard import the clipboard is emptied,
since it held the secret. Compare the code FiveT shows with your authenticator app.

## Links (`fivet://`)

Shortcuts, Raycast, Alfred, a Stream Deck, a bookmark or a link in a chat can switch a VPN on or off:

| Link | Does |
|------|------|
| `fivet://connect/Office` | connects Office (like clicking it in the menu) |
| `fivet://disconnect/Office` | disconnects Office; `fivet://disconnect` disconnects all |
| `fivet://toggle/Office` | connects or disconnects |
| `fivet://settings` | opens Settings |

The name must be exactly the one in the menu (upper/lower case does not matter; spaces as `%20`). Any web
page can open a link too (browsers ask first), so a link that would connect always asks **Connect to Office?**
(there is no "always allow"). Links
never change settings, start FiveT's setup, trust a certificate or show a secret; a wrong name turns the
shield red with a fixed message, and the log says which name was asked for.

The **General** tab has "Start FiveT at login", the reconnect switches, "Show the connection name in the
menu bar", updates, setup status and troubleshooting.

## Files

| What | Where |
|------|-------|
| Connections and settings | `~/Library/Application Support/fivet/connections.json` (mode 0600) |
| Failed-login count per gateway (shared by every copy of FiveT) | `~/Library/Application Support/fivet/login-failures.json` (mode 0600) |
| Log | `~/Library/Logs/fivet/FiveT.log` |
| Helper rule (allows the root helper only) | `/etc/sudoers.d/fivet` |
| Root helper (start/stop tunnels, split DNS, `refresh`) | `/Library/PrivilegedHelperTools/app.fivet.resolver` |
| Build number the copies came from (`refresh` never goes back) | `/Library/PrivilegedHelperTools/app.fivet.build` |
| openfortivpn shipped with FiveT (licenses in `Contents/Resources/openfortivpn-licenses`) | `FiveT.app/Contents/Helpers/openfortivpn` |
| FiveT's root-owned copy of openfortivpn | `/Library/PrivilegedHelperTools/app.fivet.openfortivpn/` |
| OpenVPN shipped with FiveT (licenses in `Contents/Resources/openvpn-licenses`) | `FiveT.app/Contents/Helpers/openvpn` |
| FiveT's root-owned copy of OpenVPN | `/Library/PrivilegedHelperTools/app.fivet.openvpn/` |
| Xray shipped with FiveT (V2Ray, Outline; licenses in `Contents/Resources/xray-licenses`) | `FiveT.app/Contents/Helpers/xray` |
| FiveT's root-owned copy of Xray and its address list | `/Library/PrivilegedHelperTools/app.fivet.xray/` |
| A full tunnel's DNS (while connected) | dynamic store `State:/Network/Service/app.fivet.ovpn-…` |
| Split-DNS files (while connected) | `/etc/resolver/<domain>` |
| MCP socket (AI assistants) | `~/Library/Application Support/fivet/mcp.sock` |
| Release key (release Mac only) | login keychain: "FiveT update signing key", "FiveT update test key" |

## Changing the app icon

The artwork lives at `Resources/AppIcon-source.png` (a square image, 1024x1024 or larger).
Replace that file and run `./build.sh --install`. The build reshapes it to Apple's macOS icon
grid automatically: it scales the art to 824/1024 of the canvas, masks it with the system's
continuous-corner squircle, adds a soft shadow, and writes every size from 16 to 1024.
The two smallest sizes are cropped in on the upper part of the art so they stay readable in
Finder lists. The menu bar keeps its own shield symbol, which has to stay a flat one-colour
shape so it adapts to light and dark menu bars.

## The install window (disk image)

Opening the DMG shows a designed Finder window: the artwork is `Resources/dmg/background.html` (660x440,
drawn around the icon positions in `Resources/dmg/settings.py`), rendered to the committed
`background.png` and `background@2x.png` by `Tools/make-dmg-background.sh` (needs Google Chrome).
`./build.sh --dmg` lays out the window with dmgbuild, which it installs into `build/dmgtools` the first
time. Finder writes the icon names itself, white in Dark Mode and black in Light Mode, so the artwork puts
them on mid-tone brass plates that read either way.

## Rebuilding after code changes

```sh
./build.sh --install
```

That compiles, builds the `.app` with its icon, signs it (ad-hoc) and copies it to `/Applications`.
Requires the Xcode Command Line Tools (already installed). The first build also builds the bundled
openfortivpn (see "First-time setup" above for what that needs).

## Releasing an update

FiveT updates itself, silently. Every copy checks `https://github.com/FiveT-Gate/FiveT/releases/latest/download/latest.json`
a minute after launch and then once a day; a failed check or download is tried again once after
five hours, then it is back to once a day. A newer version is
downloaded in the background (low-priority traffic), its SHA-256 verified and the app unpacked to
`~/Library/Caches/fivet/update`. FiveT then waits until no tunnel is up, connecting or reconnecting
and neither the menu nor Settings is open (two checks in a row, 3 minutes apart), swaps
`/Applications/FiveT.app` in one rename and relaunches. A Mac that always has a tunnel up gets the
update when FiveT quits (Quit, logout, shutdown), without a relaunch. There are no dialogs or
notifications; the log records each step. Settings → General can turn automatic installs off and
has **Check for Updates** / **Install Update** / **Restart Now**.

Users on 1.5.0 or older still click **Install Update** once to get the version that does this.

Every release is signed. The checksum in `latest.json` only proves the download is the file the feed
names; whoever controlled the server (or the account behind it) could name any file. So FiveT installs
only a release signed with **FiveT's release key** (Ed25519, `Sources/fivet/UpdateSignature.swift`), and
checks that before downloading anything. The private half lives only in the release Mac's login keychain
("FiveT update signing key"), made so that every use shows the macOS keychain prompt: click **Allow**,
never Always Allow. `Tools/update-signing/main.swift` explains the tool.

- **Back it up once** (in Terminal, it asks for a passphrase):
  `build/tools/update-signing backup ~/Documents/FiveT-release-key.backup`, then keep that file and the
  passphrase off this Mac (password manager). Without the key, no update can reach existing copies.
- A new release Mac: `build/tools/update-signing restore <backup file>`.
- Replacing the key: add the new public key to `UpdateSignature.releaseKeys`, release once signed with
  the old key, then sign with the new one.
- Test builds accept fake releases signed with a separate test key, which only builds that are
  never shipped (no `DISTRIBUTION`) accept.

Releases are published on this repository's Releases page: the installer and `latest.json`, the signed
feed every copy reads.

Version control: the project is a git repository (`git log` for history). The seeded connections
live in `Sources/fivet/LocalSeeds.swift`, which is git-ignored so the credentials never enter history;
`build.sh` creates an empty one on a fresh clone.

## Uninstall

```sh
sudo rm -rf /etc/sudoers.d/fivet /Library/PrivilegedHelperTools/app.fivet.resolver /Library/PrivilegedHelperTools/app.fivet.openfortivpn /Library/PrivilegedHelperTools/app.fivet.openvpn /Library/PrivilegedHelperTools/app.fivet.xray /Library/PrivilegedHelperTools/app.fivet.build
rm -rf /Applications/FiveT.app ~/Library/Application\ Support/fivet ~/Library/Logs/fivet ~/Library/Caches/fivet
brew uninstall openfortivpn   # only if you installed it for an older FiveT
```
