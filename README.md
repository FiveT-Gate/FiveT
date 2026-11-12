<p align="center">
  <img src="docs/fivet.jpg" alt="FiveT: a ceramic figure in a hat and sunglasses with a finger to its lips" width="300">
</p>

<h1 align="center">FiveT</h1>

<p align="center"><b>Your VPN, one click away. Quiet, native, and out of your way.</b></p>

FiveT lives in the macOS menu bar as a small shield. Click a connection's name and you are connected. Click it again and you are not. No FortiClient, no Homebrew, no Terminal.

## What it does

- **FortiGate SSL-VPN.** Fills in the one-time code for you, keeps several tunnels up at once, and checks the gateway's certificate before any password leaves your Mac.
- **OpenVPN, V2Ray, VLESS, Trojan, Hysteria2, Shadowsocks and Outline.** Paste a link or a key, or import from OpenVPN Connect or the Outline app.
- **Kill switch.** If a full-tunnel VPN drops, nothing leaves the Mac until it is back.
- **Reconnects by itself** after sleep, a Wi-Fi change or a tunnel that quietly stopped answering.
- **Easy to automate.** Ask an AI assistant to connect (FiveT is an MCP server), run it from a shell script, or open a `fivet://connect/Office` link from Raycast, Shortcuts or a bookmark.
- **Updates itself** in the background. Every release is signed, and a copy only installs updates signed with FiveT's own key.

## Install

1. Download the latest `FiveT-x.y.z.dmg` from [Releases](https://github.com/FiveT-Gate/FiveT/releases/latest) and drag FiveT to Applications.
2. Open it. macOS will say it cannot verify the developer (the app is not notarized): go to System Settings → Privacy & Security and click **Open Anyway**, once.
3. Click **Set Up FiveT** and type your Mac password. That is the whole setup.

Needs an Apple silicon Mac on macOS 13 or newer.

## Why it is safe to trust

Starting a tunnel needs root. FiveT does not give that to the app: it installs one small root helper and a sudoers rule that allows that helper and nothing else. The helper runs root-owned copies of the VPN programs and passes on only options from a short allow-list. Passwords go through a pipe and never touch the disk. The source is all here, so you can check.

## Build it yourself

```sh
./build.sh --install
```

Needs the Xcode Command Line Tools. The first build also builds the bundled VPN programs; see `build.sh` for what it expects.

## More

Everything else (certificate review, the failed-login limit, split DNS, the MCP tools, the command line, file locations, releasing, uninstalling) is in [docs/TECHNICAL.md](docs/TECHNICAL.md).
