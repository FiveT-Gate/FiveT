<p align="center">
  <img src="docs/fivet.jpg" alt="FiveT: a ceramic figure in a hat and sunglasses with a finger to its lips" width="300">
</p>

<h1 align="center">FiveT</h1>

<p align="center"><b>Your VPN, one click away. Quiet, native, and out of your way.</b></p>

FiveT is a small shield in the macOS menu bar and in the Windows notification area. Click a connection's name and you are connected. Click it again and you are not. No FortiClient, and nothing else to install: the VPN programs come inside the app.

## What it does

- **FortiGate SSL-VPN.** Fills in the one-time code for you, keeps several tunnels up at once, and checks the gateway's certificate before any password leaves your computer.
- **OpenVPN, V2Ray, VLESS, VMess, Trojan, Hysteria2, Shadowsocks and Outline.** Paste a link or a key, or import from OpenVPN Connect or the Outline app.
- **Kill switch.** If a full-tunnel VPN drops, nothing leaves the computer until it is back.
- **Chosen apps only.** Send just the apps you pick (Chrome, Slack, VS Code and other Chromium or Electron apps) through a V2Ray or Outline VPN.
- **Reconnects by itself** after sleep, a Wi-Fi change or a tunnel that quietly stopped answering, and can switch to the next VPN in your list when one stays down.
- **Easy to automate.** Ask an AI assistant to connect (FiveT is an MCP server), run it from a shell script, or open a `fivet://connect/Office` link from Raycast, Shortcuts or a bookmark.
- **Backup.** Export all connections and settings to a `.fivet` file and import them on another computer.
- **Updates itself** in the background. Every release is signed, and a copy only installs updates signed with FiveT's own key.

Only on the Mac: **Smart Connect** tests every VPN you switched on and keeps the best one connected, **Windscribe Max** and **Express Max** drive the Windscribe and ExpressVPN apps you already have, and the **SSO** tab types a one-time code into any app when you press its keyboard shortcut.

## Install

### macOS

1. Download the latest `FiveT-x.y.z.dmg` from [Releases](https://github.com/FiveT-Gate/FiveT/releases/latest) and drag FiveT to Applications.
2. Open it. macOS will say it cannot verify the developer (the app is not notarized): go to System Settings → Privacy & Security and click **Open Anyway**, once.
3. Click **Set Up FiveT** and type your Mac password. That is the whole setup.

Needs an Apple silicon Mac on macOS 13 or newer.

### Windows

1. Download `FiveT-Setup-x.y.z.exe` (Intel/AMD PCs) or `FiveT-Setup-x.y.z-arm64.exe` (ARM PCs) from the newest **FiveT for Windows** release on the [Releases](https://github.com/FiveT-Gate/FiveT/releases?q=windows) page.
2. Run it and accept the administrator prompt. That is the whole setup.

Needs Windows 10 (1809) or newer. The setup files are not code-signed, so Windows SmartScreen may warn. More in [windows/README.md](windows/README.md).

## Why it is safe to trust

**macOS.** Starting a tunnel needs root. FiveT does not give that to the app: it installs one small root helper and a sudoers rule that allows that helper and nothing else. The helper runs root-owned copies of the VPN programs and passes on only options from a short allow-list. When a tunnel starts, the password goes to the helper through a pipe, never into a file.

**Windows.** Creating a tunnel needs administrator rights, so FiveT runs as administrator from `C:\Program Files\FiveT`. It starts only its own bundled VPN programs, and only from folders that ordinary programs cannot change. Saved passwords are encrypted with Windows DPAPI.

The source is all here, so you can check.

## Build it yourself

macOS:

```sh
./build.sh --install
```

Needs the Xcode Command Line Tools. The first build also builds the bundled VPN programs; see `build.sh` for what it expects.

Windows: see [windows/README.md](windows/README.md#build) (the .NET 8 SDK and `windows\build.ps1`).

## More

Everything else about the Mac app (certificate review, the failed-login limit, split DNS, the MCP tools, the command line, file locations, releasing, uninstalling) is in [docs/TECHNICAL.md](docs/TECHNICAL.md). The Windows app has the same kind of documentation in [windows/README.md](windows/README.md).
