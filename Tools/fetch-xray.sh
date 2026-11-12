#!/bin/sh
# Fetches the Xray that ships inside FiveT.app (Contents/Helpers/xray), which runs V2Ray connections
# (VLESS, VMess, Trojan, Shadowsocks, Hysteria2), and the small list of Iranian and private addresses
# its routing sends direct. build.sh runs this when build/xray is missing or older than this file.
#
#   Tools/fetch-xray.sh      -> build/xray/{xray, geoip-lite.dat, VERSION, licenses/, NOTICE.txt}
#
# Xray is the project's own release build (XTLS/Xray-core on GitHub, built by its CI with Go), pinned
# here by SHA-256: the same file every time, checked before use. FiveT re-signs it ad-hoc like its
# openvpn. Run from the repository folder (build.sh does).
set -eu
[ -f Tools/fetch-xray.sh ] || { echo "✗ run from the repository folder" >&2; exit 1; }

XRAY_VERSION=26.10.29
# The SHA2-256 line of the release's Xray-macos-arm64-v8a.zip.dgst, checked on 2026-10-30 (the download
# and GitHub's own digest agree). 26.10.10 and 26.10.17 were withdrawn by the project: their built-in
# root certificate list held three roots with cracked intermediates; 26.10.21 removed them.
XRAY_SHA256=57755127d38c0c4357e667761c78b257cf617f05015bad5060bf2dae75fcd00b
XRAY_URL=https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-macos-arm64-v8a.zip
# Iranian and private address ranges (categories "ir" and "private"), 38 KB, from Chocolate4U's
# Iran-v2ray-rules (GPL-3.0), which publishes a new list every day; this one is from 2026-11-10.
GEO_RELEASE=202611101256
GEO_SHA256=1f443cc645af8d77d371546bb0dfb21dbd5260fda40a11549b44a2b08c28ec5d
GEO_URL=https://github.com/Chocolate4U/Iran-v2ray-rules/releases/download/$GEO_RELEASE/geoip-lite.dat

DEPS=$PWD/build/deps
OUT=$PWD/build/xray

# Downloads $2 to build/deps/$3 (kept for next time) and checks it against $1.
fetch() {
  mkdir -p "$DEPS"
  if [ ! -f "$DEPS/$3" ] || [ "$(shasum -a 256 "$DEPS/$3" | cut -d' ' -f1)" != "$1" ]; then
    echo "▸ downloading $3"
    rm -f "$DEPS/$3.part"
    curl -fL --retry 3 -o "$DEPS/$3.part" "$2" || { rm -f "$DEPS/$3.part"; echo "✗ could not download $2" >&2; exit 1; }
    mv "$DEPS/$3.part" "$DEPS/$3"
  fi
  if [ "$(shasum -a 256 "$DEPS/$3" | cut -d' ' -f1)" != "$1" ]; then
    rm -f "$DEPS/$3"
    echo "✗ $3 does not match its SHA-256; deleted, run again" >&2
    exit 1
  fi
}
fetch $XRAY_SHA256 $XRAY_URL xray-$XRAY_VERSION-macos-arm64.zip
fetch $GEO_SHA256 $GEO_URL geoip-lite-$GEO_RELEASE.dat

rm -rf "$OUT" "$OUT.tmp"
mkdir -p "$OUT.tmp/unzip" "$OUT.tmp/licenses"
# Only the program and its license: the zip's own geoip.dat and geosite.dat (28 MB) are not used.
unzip -q -o "$DEPS/xray-$XRAY_VERSION-macos-arm64.zip" xray LICENSE -d "$OUT.tmp/unzip"
mv "$OUT.tmp/unzip/xray" "$OUT.tmp/xray"
mv "$OUT.tmp/unzip/LICENSE" "$OUT.tmp/licenses/Xray-core-LICENSE.txt"
rmdir "$OUT.tmp/unzip"
cp "$DEPS/geoip-lite-$GEO_RELEASE.dat" "$OUT.tmp/geoip-lite.dat"
chmod 755 "$OUT.tmp/xray"

# What it is: an arm64 program that reports this version and loads nothing from outside macOS.
[ "$(lipo -archs "$OUT.tmp/xray")" = "arm64" ] || { echo "✗ xray is not an arm64 program" >&2; exit 1; }
"$OUT.tmp/xray" version | head -1 | grep -q "^Xray $XRAY_VERSION " || { echo "✗ xray does not report version $XRAY_VERSION" >&2; exit 1; }
if otool -L "$OUT.tmp/xray" | tail -n +2 | grep -v -E '^\s*/(usr/lib|System/Library)/' | grep -q .; then
  echo "✗ xray loads libraries from outside macOS:" >&2
  otool -L "$OUT.tmp/xray" >&2
  exit 1
fi
# The routing FiveT gives it needs the two categories of the address list.
cat > "$OUT.tmp/check.json" <<'EOF'
{"log":{"loglevel":"none"},"outbounds":[{"protocol":"freedom","tag":"direct"}],
 "routing":{"rules":[{"ip":["ext:geoip-lite.dat:ir","ext:geoip-lite.dat:private"],"outboundTag":"direct"}]}}
EOF
XRAY_LOCATION_ASSET="$OUT.tmp" "$OUT.tmp/xray" run -test -c "$OUT.tmp/check.json" > "$OUT.tmp/check.log" 2>&1 \
  || { cat "$OUT.tmp/check.log" >&2; echo "✗ xray cannot read geoip-lite.dat" >&2; exit 1; }
rm -f "$OUT.tmp/check.json" "$OUT.tmp/check.log"

echo "$XRAY_VERSION" > "$OUT.tmp/VERSION"
cat > "$OUT.tmp/NOTICE.txt" <<EOF
Xray-core $XRAY_VERSION (https://github.com/XTLS/Xray-core), Mozilla Public License 2.0: the
unmodified release build Xray-macos-arm64-v8a.zip, whose source is at the link above (tag v$XRAY_VERSION).

geoip-lite.dat (release $GEO_RELEASE of https://github.com/Chocolate4U/Iran-v2ray-rules), GNU GPL 3.0:
Iranian and private IP address ranges, read by Xray to send those addresses direct.
EOF
mv "$OUT.tmp" "$OUT"
echo "✓ xray $XRAY_VERSION ($(du -h "$OUT/xray" | cut -f1)) and geoip-lite.dat in $OUT"
