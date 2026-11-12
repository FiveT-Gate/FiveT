FiveT — one-click FortiGate SSL-VPN from the macOS menu bar
============================================================

Requires a Mac with Apple silicon (M1 or newer) and macOS 13 or newer.
Switch colours in Settings follow System Settings > Appearance > Accent colour.

INSTALL
-------
1. Drag FiveT.app onto the Applications folder next to it.

2. Open FiveT the first time.
   macOS will say it "cannot verify the developer" because the app is not
   notarized with Apple. Click Done, then go to
   System Settings > Privacy & Security, scroll down, and click "Open Anyway".
   (Alternative, in Terminal:  xattr -dr com.apple.quarantine /Applications/FiveT.app )
   This is only needed once.

3. FiveT opens its Settings with a "Set Up FiveT" button. Click it and type your
   Mac password. That is the whole setup: FiveT brings its own openfortivpn (the
   open-source Fortinet VPN client it drives), so there is nothing else to install,
   no Homebrew and no Terminal. The helper it installs lets FiveT start and stop
   the VPN without asking for the password every time.
   (Closed Settings too soon? Click the shield in the menu bar > "Set Up FiveT...".
   Clicking a connection before setting up works too: FiveT asks for the password
   first, then connects.)

4. Click the shield > Settings > Forti tab > "+" and enter your VPN:
   gateway address, port (usually 10443), realm (if your admin gave one),
   username, password, and the one-time-code mode if you use TOTP.
   (An OpenVPN profile, V2Ray links or an Outline key go on the VPN tab instead:
   drop the file on it, or paste the link or key with Cmd+V.)

USE
---
Click the shield, click the connection name. The icon shows a check mark when
connected. Click the name again to disconnect.

If something fails: shield > Settings > General tab > "Copy Diagnostics" and
send the pasted text to whoever gave you the app. It never contains passwords.

UPDATES
-------
Click the shield > Settings > General > "Check for Updates". FiveT downloads the
new version, replaces itself and restarts. Or download the latest from
https://github.com/FiveT-Gate/FiveT/releases/latest

OPEN SOURCE
-----------
FiveT includes openfortivpn (GNU GPL v3) built with OpenSSL (Apache License 2.0).
Their licenses and source code links are in
FiveT.app/Contents/Resources/openfortivpn-licenses.

UNINSTALL
---------
    sudo rm -rf /etc/sudoers.d/fivet /Library/PrivilegedHelperTools/app.fivet.resolver /Library/PrivilegedHelperTools/app.fivet.openfortivpn /Library/PrivilegedHelperTools/app.fivet.openvpn /Library/PrivilegedHelperTools/app.fivet.xray /Library/PrivilegedHelperTools/app.fivet.build
    rm -rf /Applications/FiveT.app ~/Library/Application\ Support/fivet ~/Library/Logs/fivet ~/Library/Caches/fivet
