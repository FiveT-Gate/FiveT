#!/bin/sh
# Installs (or with --remove, removes) the daily check of FiveT's bundled programs: a LaunchAgent that runs
# Tools/cores-watch.sh at 10:15 every day (a Mac that was asleep runs it when it wakes). It lives in this
# user's login session only, needs no password, and does nothing but look things up and notify.
# macOS does not let a background job read ~/Documents (where this repository lives), so the agent runs a COPY
# of cores.py and cores-watch.sh from ~/Library/Application Support/fivet-cores/bin with the pinned versions
# mirrored in pins.json (every run of cores.py in the repository refreshes it). Run this again after editing
# either script. Preparing an update needs the repository, so it happens when asked (Tools/cores-prepare.sh).
#   Tools/cores-watch-install.sh            install (safe to run again)
#   Tools/cores-watch-install.sh --remove   uninstall
#   Tools/cores-watch-install.sh --now      run it once right now (what the 10:15 run does)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
LABEL=app.fivet.cores-watch
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

case "${1:-}" in
  --remove)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"; echo "✓ removed"; exit 0;;
  --now)
    launchctl kickstart "$DOMAIN/$LABEL"; echo "started; the log is ~/Library/Logs/fivet/cores-watch.log"; exit 0;;
esac

STATE="$HOME/Library/Application Support/fivet-cores"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/fivet" "$STATE/bin"
cp "$REPO/Tools/cores.py" "$REPO/Tools/cores-watch.sh" "$STATE/bin/"
python3 -I "$REPO/Tools/cores.py" sync-pins >/dev/null
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$STATE/bin/cores-watch.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>FIVET_REPO</key><string>$REPO</string>
    <key>FIVET_CORES_PY</key><string>$STATE/bin/cores.py</string>
    <key>FIVET_CORES_PINS</key><string>$STATE/pins.json</string>
  </dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>15</integer></dict>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/fivet/cores-watch.err</string>
  <key>Nice</key><integer>10</integer>
</dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "✓ installed: runs every day at 10:15 ($PLIST)"
