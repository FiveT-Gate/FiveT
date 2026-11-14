#!/bin/sh
# Builds FiveT.app into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --dmg      build a DISTRIBUTION copy (no seeded connections) and pack it as build/FiveT-<version>.dmg
set -eu -o pipefail
cd "$(dirname "$0")"

MODE="${1:-}"

# Seeded connections are kept out of git; a fresh clone gets an empty seed file.
if [ ! -f Sources/fivet/LocalSeeds.swift ]; then
  printf 'import Foundation\n\nenum LocalSeeds { static var connections: [Connection] { [] } }\n' > Sources/fivet/LocalSeeds.swift
fi
# The key for .fivet backups: random, made once, kept out of git. A new key cannot open older backups.
if [ ! -f Sources/fivet/BackupKey.swift ]; then
  printf 'enum BackupKey { static let hex = "%s" }\n' "$(openssl rand -hex 32)" > Sources/fivet/BackupKey.swift
fi
ICON_SRC=Resources/AppIcon-source.png
ICNS=build/AppIcon.icns
VOLICNS=build/VolumeIcon.icns   # the disk image's own icon: the same picture, small sizes only

# swift build (Command Line Tools 27) links through clang with --sysroot, from which clang cannot
# tell the SDK version: the binary then records the deployment target (13.0) as its SDK and macOS
# draws the app in the design from before macOS 26. -isysroot for the link lets clang read the
# version from the SDK itself; the check after the build makes sure it did.
# -Osize: optimised for size (about 12% less code); a menu bar app does not need -O's extra speed.
SDK=$(xcrun --show-sdk-path)

if [ "$MODE" = "--dmg" ]; then
  # Separate scratch path so the distribution flag never leaks into the normal build (and vice versa).
  SCRATCH=.build-dist
  echo "▸ compiling (release, DISTRIBUTION: no seeded connections)"
  swift build -c release --scratch-path "$SCRATCH" -Xswiftc -DDISTRIBUTION -Xswiftc -Osize \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK" 2>&1 | grep -vE "^\s*$" | tail -n 5
else
  SCRATCH=.build
  echo "▸ compiling (release)"
  swift build -c release -Xswiftc -Osize \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK" 2>&1 | grep -vE "^\s*$" | tail -n 5
fi

# Regenerate the icons when missing, or older than the art or the tools that make them.
if [ ! -f "$ICNS" ] || [ ! -f "$VOLICNS" ] || [ "$ICON_SRC" -nt "$ICNS" ] || [ Tools/make-icon.swift -nt "$ICNS" ] \
   || [ Tools/pack-icns.py -nt "$ICNS" ]; then
  command -v oxipng >/dev/null || { echo "✗ oxipng is missing: brew install oxipng" >&2; exit 1; }
  echo "▸ generating icon from $ICON_SRC"
  rm -rf build/AppIcon.iconset
  swift Tools/make-icon.swift "$ICON_SRC" build/AppIcon.iconset
  # Lossless: the same pixels in about 20% fewer bytes. iconutil would re-encode them, so it only
  # lays out the .icns and pack-icns.py puts these PNGs in as they are.
  oxipng -o max --strip safe -q build/AppIcon.iconset/*.png
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon-iconutil.icns
  python3 Tools/pack-icns.py build/AppIcon-iconutil.icns build/AppIcon.iconset "$ICNS"
  # The volume icon shows on the desktop, in the sidebar and in the window title: 256 pixels (a
  # desktop icon at its largest, on a Retina screen) is plenty and leaves out ~1.4 MB of download.
  python3 Tools/pack-icns.py build/AppIcon-iconutil.icns build/AppIcon.iconset "$VOLICNS" --max-px 256
  rm build/AppIcon-iconutil.icns
fi

# FiveT ships its own openfortivpn (OpenSSL linked in), so a new Mac needs no Homebrew. Built once
# and kept in build/openfortivpn; rebuilt when the recipe (versions, options) changes.
OFV=build/openfortivpn
if [ ! -x "$OFV/openfortivpn" ] || [ ! -f "$OFV/VERSION" ] || [ Tools/build-openfortivpn.sh -nt "$OFV/openfortivpn" ]; then
  Tools/build-openfortivpn.sh
fi
# And its own OpenVPN, for OpenVPN connections (same OpenSSL; no plug-ins, no management interface).
# It links the OpenSSL that build-openfortivpn.sh pins, so a new OpenSSL there rebuilds it too.
OVPN=build/openvpn
if [ ! -x "$OVPN/openvpn" ] || [ ! -f "$OVPN/VERSION" ] || [ Tools/build-openvpn.sh -nt "$OVPN/openvpn" ] \
   || [ Tools/build-openfortivpn.sh -nt "$OVPN/openvpn" ]; then
  Tools/build-openvpn.sh
fi
# And Xray, for V2Ray connections (the project's release build, pinned by SHA-256).
XRAY=build/xray
if [ ! -x "$XRAY/xray" ] || [ ! -f "$XRAY/VERSION" ] || [ Tools/fetch-xray.sh -nt "$XRAY/VERSION" ]; then
  Tools/fetch-xray.sh
fi

if [ "$MODE" = "--dmg" ]; then APP=build/dist/FiveT.app; else APP=build/FiveT.app; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$SCRATCH/release/fivet" "$APP/Contents/MacOS/FiveT"
# The symbol table (function names for debuggers, about half the file) does not run: strip it.
# --dmg keeps the full binary in build/symbols, to read a crash log from that version.
strip -no_code_signature_warning -rSTx "$APP/Contents/MacOS/FiveT"
cp "$OFV/openfortivpn" "$APP/Contents/Helpers/openfortivpn"
cp -R "$OFV/licenses" "$APP/Contents/Resources/openfortivpn-licenses"
cp "$OFV/NOTICE.txt" "$APP/Contents/Resources/openfortivpn-licenses/NOTICE.txt"
cp "$OVPN/openvpn" "$APP/Contents/Helpers/openvpn"
cp -R "$OVPN/licenses" "$APP/Contents/Resources/openvpn-licenses"
cp "$OVPN/NOTICE.txt" "$APP/Contents/Resources/openvpn-licenses/NOTICE.txt"
cp "$XRAY/xray" "$APP/Contents/Helpers/xray"
mkdir -p "$APP/Contents/Resources/xray"
cp "$XRAY/geoip-lite.dat" "$APP/Contents/Resources/xray/geoip-lite.dat"
cp -R "$XRAY/licenses" "$APP/Contents/Resources/xray-licenses"
cp "$XRAY/NOTICE.txt" "$APP/Contents/Resources/xray-licenses/NOTICE.txt"

# macOS draws an app in the design of the SDK version recorded in its binary; an older number
# means an older look. A link that could not tell the SDK version recorded "SDK 13.0" (the design
# from before macOS 26), so a binary that does not name the SDK it was built with is refused.
SDK_NOW=$(xcrun --show-sdk-version)
SDK_BUILT=$(otool -l "$APP/Contents/MacOS/FiveT" | awk '$1 == "sdk" { print $2; exit }')
if [ "$SDK_BUILT" != "$SDK_NOW" ]; then
  echo "✗ the binary records SDK ${SDK_BUILT:-?} instead of $SDK_NOW: macOS would draw FiveT with an older design" >&2
  exit 1
fi
echo "▸ built against the macOS $SDK_NOW SDK"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Settings shows the bundled openfortivpn's version from here (FiveT never runs the bundled file).
plutil -insert FiveTOpenfortivpnVersion -string "$(cat "$OFV/VERSION")" "$APP/Contents/Info.plist"
plutil -insert FiveTOpenVPNVersion -string "$(cat "$OVPN/VERSION")" "$APP/Contents/Info.plist"
plutil -insert FiveTXrayVersion -string "$(cat "$XRAY/VERSION")" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# The picture the Windscribe Max panel shows when Windscribe is not installed (the panel copes without it).
[ -f Resources/windscribe-missing.png ] && cp Resources/windscribe-missing.png "$APP/Contents/Resources/windscribe-missing.png"
# Windscribe's own logo (the icon of its app, 128 px) for the Windscribe Max row and header.
[ -f Resources/windscribe-logo.png ] && cp Resources/windscribe-logo.png "$APP/Contents/Resources/windscribe-logo.png"
[ -f Resources/expressvpn-logo.png ] && cp Resources/expressvpn-logo.png "$APP/Contents/Resources/expressvpn-logo.png"
# The root helper's own text, sealed inside the app: the installed helper's `refresh` takes the new helper
# from here, after checking the app's signature (Setup.swift), so an update needs no admin password.
"$SCRATCH/release/fivet" --print-helper > "$APP/Contents/Resources/fivet-helper.sh"
[ "$(head -n 1 "$APP/Contents/Resources/fivet-helper.sh")" = "#!/bin/sh" ] && sh -n "$APP/Contents/Resources/fivet-helper.sh" \
  || { echo "✗ the helper text printed by the build is not a shell script" >&2; exit 1; }

# Signing, by the identity signing.env names (git-ignored; see signing.env.example):
# - a Developer ID: hardened runtime and timestamp, ready for notarization;
# - FiveT's own certificate (self-signed, FIVET_SIGN_SELF=1): macOS then knows each release as the
#   same app ("identifier … and certificate leaf = H…" instead of a hash of this build), so what
#   macOS remembers per app (privacy permissions) survives updates;
# - none: ad-hoc, for a build that only runs on this Mac.
[ -f signing.env ] && . ./signing.env
if [ -n "${FIVET_SIGN_IDENTITY:-}" ] && [ "${FIVET_SIGN_SELF:-}" = "1" ]; then
  echo "▸ signing with FiveT's own certificate"
  # openfortivpn keeps its ad-hoc signature, byte for byte what the ad-hoc builds gave it: Setup
  # compares the root-owned copy with it by code hash, so a new hash would make every Mac run
  # Install Helper… again. The app's own signature seals it as it is.
  codesign --force --sign - "$APP/Contents/Helpers/openfortivpn"
  codesign --force --sign - "$APP/Contents/Helpers/openvpn"
  codesign --force --sign - "$APP/Contents/Helpers/xray"
  codesign --force --timestamp=none --sign "$FIVET_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
elif [ -n "${FIVET_SIGN_IDENTITY:-}" ]; then
  echo "▸ signing with Developer ID: $FIVET_SIGN_IDENTITY"
  # Inside out: the bundled openfortivpn first, then the app that seals it.
  codesign --force --options runtime --timestamp --sign "$FIVET_SIGN_IDENTITY" "$APP/Contents/Helpers/openfortivpn"
  codesign --force --options runtime --timestamp --sign "$FIVET_SIGN_IDENTITY" "$APP/Contents/Helpers/openvpn"
  codesign --force --options runtime --timestamp --sign "$FIVET_SIGN_IDENTITY" "$APP/Contents/Helpers/xray"
  codesign --force --options runtime --timestamp --sign "$FIVET_SIGN_IDENTITY" "$APP/Contents/MacOS/FiveT"
  codesign --force --options runtime --timestamp --sign "$FIVET_SIGN_IDENTITY" "$APP"
  codesign --verify --strict "$APP"
else
  echo "▸ signing (ad-hoc; add signing.env for a Developer ID signature)"
  codesign --force --sign - "$APP/Contents/Helpers/openfortivpn"
  codesign --force --sign - "$APP/Contents/Helpers/openvpn"
  codesign --force --sign - "$APP/Contents/Helpers/xray"
  codesign --force --deep --sign - "$APP"
fi

# Submits a file to Apple's notary service and waits for the verdict (usually 1-5 minutes).
notarize() {
  echo "▸ notarizing $(basename "$1")"
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile "$FIVET_NOTARY_PROFILE" --wait 2>&1) || true
  echo "$out" | grep -E "^\s*(id|status):" | head -2 | sed 's/^/    /'
  if ! echo "$out" | grep -q "status: Accepted"; then
    local id; id=$(echo "$out" | grep -E "^\s*id:" | head -1 | awk '{print $2}')
    echo "✗ notarization was not accepted. Details:  xcrun notarytool log $id --keychain-profile $FIVET_NOTARY_PROFILE" >&2
    exit 1
  fi
}

case "$MODE" in
--install)
  echo "▸ installing to /Applications"
  pkill -x FiveT 2>/dev/null || true
  pkill -x fivet 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/fivet.app /Applications/FiveT.app
  cp -R "$APP" /Applications/FiveT.app
  # Nudge macOS to drop the cached icon for this bundle.
  touch /Applications/FiveT.app
  killall Dock 2>/dev/null || true
  echo "✓ installed: /Applications/FiveT.app"
  ;;
--dmg)
  # Safety net: the shipped binary must not contain the developer's seeded credentials.
  # The patterns come from the git-ignored seed file, so no secret is written into this script.
  grep -E '\.(password|totpSecret) = "' Sources/fivet/LocalSeeds.swift 2>/dev/null \
    | sed -E 's/.*= "([^"]*)".*/\1/' | grep -v '^$' > build/.seed-secrets || true
  if [ -s build/.seed-secrets ] && strings "$APP/Contents/MacOS/FiveT" | grep -q -F -f build/.seed-secrets; then
    echo "✗ refusing to pack: seeded credentials found in the binary" >&2; exit 1
  fi
  rm -f build/.seed-secrets
  # Nor the names of the seeded connections (the developer's employers stay out of the public app).
  # Names of 5 letters or more, as whole words: shorter ones match unrelated text.
  grep -E '\.name = "' Sources/fivet/LocalSeeds.swift 2>/dev/null \
    | sed -E 's/.*= "([^"]*)".*/\1/' | awk 'length($0) >= 5' > build/.seed-names || true
  if [ -s build/.seed-names ] && strings "$APP/Contents/MacOS/FiveT" | grep -q -i -w -F -f build/.seed-names; then
    echo "✗ refusing to pack: the binary mentions a seeded connection's name:" >&2
    strings "$APP/Contents/MacOS/FiveT" | grep -i -w -F -f build/.seed-names | head -5 >&2
    rm -f build/.seed-names; exit 1
  fi
  rm -f build/.seed-names
  # Every release carries the same signature identity. An ad-hoc one would make each Mac forget
  # the privacy permissions it gave FiveT after the silent update, while System Settings still
  # shows them on.
  if ! codesign -d -r- "$APP" 2>&1 | grep -q "certificate"; then
    echo "✗ refusing to pack: FiveT.app is signed ad-hoc. Create signing.env (see signing.env.example)." >&2; exit 1
  fi
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
  # Same UUID as the stripped copy: atos -o build/symbols/FiveT-<version> -l <load address> <address>.
  mkdir -p build/symbols
  cp "$SCRATCH/release/fivet" "build/symbols/FiveT-$VERSION"
  NOTARIZE=""
  if [ -n "${FIVET_SIGN_IDENTITY:-}" ] && [ -n "${FIVET_NOTARY_PROFILE:-}" ] && [ "${FIVET_SIGN_SELF:-}" != "1" ]; then NOTARIZE=1; fi
  if [ -n "$NOTARIZE" ]; then
    # The app gets its own ticket (stapled) so a copy dragged out of the DMG opens offline too.
    ZIP=build/dist/FiveT-notarize.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple -q "$APP" && echo "    stapled FiveT.app"
    rm -f "$ZIP"
  fi
  DMG=build/FiveT-$VERSION.dmg
  echo "▸ packing $DMG"
  rm -rf build/dist/dmg "$DMG"
  # The designed install window (background, icon places; Resources/dmg) comes from dmgbuild, which
  # writes Finder's window settings itself. It lives in its own Python environment under build/.
  DMGBUILD=build/dmgtools/bin/dmgbuild
  if [ ! -x "$DMGBUILD" ]; then
    python3 -m venv build/dmgtools
    build/dmgtools/bin/pip install -q dmgbuild==1.6.7
  fi
  [ -f Resources/dmg/background.png ] && [ -f Resources/dmg/background@2x.png ] \
    || { echo "✗ Resources/dmg/background*.png missing: run Tools/make-dmg-background.sh" >&2; exit 1; }
  "$DMGBUILD" -s Resources/dmg/settings.py -D app="$APP" -D readme=Resources/ReadMe-DMG.txt \
    -D icon="$VOLICNS" -D background=Resources/dmg/background.png "FiveT $VERSION" "$DMG" \
    > build/dmgbuild.log 2>&1 || { tail -n 20 build/dmgbuild.log >&2; echo "✗ dmgbuild failed" >&2; exit 1; }
  # The app as a user gets it must pass the strict signature check: anything that fails it (a Finder
  # flag on the bundle, a changed file) can make macOS call a fresh download damaged.
  MNT=$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}')
  if ! codesign --verify --deep --strict "$MNT/FiveT.app" 2>build/dmg-verify.log; then
    hdiutil detach "$MNT" -quiet; cat build/dmg-verify.log >&2
    echo "✗ the app inside $DMG fails the strict signature check" >&2; exit 1
  fi
  hdiutil detach "$MNT" -quiet
  # Only a Developer ID signature means anything on a disk image (Gatekeeper checks it).
  if [ -n "${FIVET_SIGN_IDENTITY:-}" ] && [ "${FIVET_SIGN_SELF:-}" != "1" ]; then
    codesign --force --timestamp --sign "$FIVET_SIGN_IDENTITY" "$DMG"
  fi
  if [ -n "$NOTARIZE" ]; then
    notarize "$DMG"
    xcrun stapler staple -q "$DMG" && echo "    stapled $DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1 | sed 's/^/    /'
  fi
  echo "✓ built: $DMG"
  ;;
*)
  echo "✓ built: $APP"
  ;;
esac
