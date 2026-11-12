#!/bin/sh
# Renders the disk image window's background from Resources/dmg/background.html:
#   Resources/dmg/background.png (660 x 440) and background@2x.png (1320 x 880, Retina).
# Both PNGs are committed, so building a DMG never needs this; run it after editing the HTML.
# Needs Google Chrome.
set -eu
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "✗ needs Google Chrome" >&2; exit 1; }
HTML="$PWD/Resources/dmg/background.html"

# Headless Chrome writes the screenshot and then sometimes never exits: it is stopped once the file
# is there (30 s at most).
render() {   # render <out.png> <scale>
  profile=$(mktemp -d)
  rm -f "$1"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$profile" \
    --force-device-scale-factor="$2" --window-size=660,440 --screenshot="$1" "file://$HTML" >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ $i -lt 150 ]; do
    if [ -s "$1" ]; then sleep 0.5; break; fi
    kill -0 $pid 2>/dev/null || break
    sleep 0.2; i=$((i + 1))
  done
  kill $pid 2>/dev/null || true
  pkill -f "$profile" 2>/dev/null || true
  wait $pid 2>/dev/null || true
  rm -rf "$profile"
  [ -s "$1" ] || { echo "✗ could not render $1" >&2; exit 1; }
}

render Resources/dmg/background.png 1
render Resources/dmg/background@2x.png 2
for f in Resources/dmg/background.png Resources/dmg/background@2x.png; do
  echo "✓ $f: $(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{printf "%s ", $2}')"
done
