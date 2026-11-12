#!/bin/sh
# Builds the OpenVPN that ships inside FiveT.app (Contents/Helpers/openvpn), the way its openfortivpn is
# built: one self-contained program, the same static OpenSSL plus LZO and LZ4 linked in, nothing loaded
# from outside macOS. build.sh runs this when build/openvpn is missing or older than this file.
#
#   Tools/build-openvpn.sh      -> build/openvpn/{openvpn, VERSION, licenses/, NOTICE.txt}
#
# It runs as root (through FiveT's helper), so it is built without plug-ins (a profile cannot load code)
# and without the management interface (no control socket): FiveT hands it the profile, credentials
# included, on stdin. Run from the repository folder (build.sh does).
set -eu
[ -f Tools/build-openvpn.sh ] || { echo "✗ run from the repository folder" >&2; exit 1; }

OVPN_VERSION=2.6.23
# Checked on 2026-10-12 against the release's GPG signature (OpenVPN security key
# F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7, signing subkey 33DA8C9EAE0EAE8C73172C10822F6DF096D04874).
OVPN_SHA256=4041c709162bec1325abf5aa8cf27a255cc477c634b15ee310411c701fc40a96
OVPN_URL=https://github.com/OpenVPN/openvpn/releases/download/v$OVPN_VERSION/openvpn-$OVPN_VERSION.tar.gz
# Compression, for servers that still use it (comp-lzo, compress lz4); the SHA-256s are Homebrew's.
LZO_VERSION=2.10
LZO_SHA256=c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072
LZO_URL=https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VERSION.tar.gz
LZ4_VERSION=1.11.1
LZ4_SHA256=683fed08a844ad012196381e40badf80c0bbe4962959761416d41c9e67d77ec7
LZ4_URL=https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz

# OpenSSL: the static build Tools/build-openfortivpn.sh makes (same version, options and tree).
SSL_VERSION=$(sed -n 's/^SSL_VERSION=//p' Tools/build-openfortivpn.sh)
ARCH=arm64
export MACOSX_DEPLOYMENT_TARGET=13.0
DEPS=$PWD/build/deps
OUT=$PWD/build/openvpn
SSL_TREE=$DEPS/openssl-$SSL_VERSION-$ARCH
JOBS=$(sysctl -n hw.ncpu)
if [ ! -f "$SSL_TREE/libssl.a" ] || [ ! -f "$SSL_TREE/.fivet-recipe" ]; then
  Tools/build-openfortivpn.sh
fi

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
fetch $OVPN_SHA256 $OVPN_URL openvpn-$OVPN_VERSION.tar.gz
fetch $LZO_SHA256 $LZO_URL lzo-$LZO_VERSION.tar.gz
fetch $LZ4_SHA256 $LZ4_URL lz4-$LZ4_VERSION.tar.gz

CF="-Os -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
LOG=$DEPS/openvpn-build.log
: > "$LOG"

echo "▸ building LZO $LZO_VERSION and LZ4 $LZ4_VERSION (static, $ARCH)"
LZO_SRC=$DEPS/lzo-$LZO_VERSION
LZO_TREE=$DEPS/lzo-$LZO_VERSION-$ARCH
LZ4_SRC=$DEPS/lz4-$LZ4_VERSION
rm -rf "$LZO_SRC" "$LZO_TREE" "$LZ4_SRC"
tar -xzf "$DEPS/lzo-$LZO_VERSION.tar.gz" -C "$DEPS"
tar -xzf "$DEPS/lz4-$LZ4_VERSION.tar.gz" -C "$DEPS"
(
  cd "$LZO_SRC"
  ./configure --disable-shared --enable-static --prefix="$LZO_TREE" CFLAGS="$CF" && make -j"$JOBS" && make install
  cd "$LZ4_SRC/lib"
  make -j"$JOBS" liblz4.a CFLAGS="$CF"
) >> "$LOG" 2>&1 || { tail -n 30 "$LOG" >&2; echo "✗ LZO or LZ4 did not build (log: build/deps/openvpn-build.log)" >&2; exit 1; }

echo "▸ building OpenVPN $OVPN_VERSION ($ARCH, OpenSSL $SSL_VERSION linked in)"
SRC=$DEPS/openvpn-$OVPN_VERSION
rm -rf "$SRC"
tar -xzf "$DEPS/openvpn-$OVPN_VERSION.tar.gz" -C "$DEPS"
(
  cd "$SRC"
  # The *_CFLAGS/*_LIBS stand in for pkg-config: the static libraries above, never Homebrew's (configure
  # checks them with -l, so they are given as folders, which hold only the .a files).
  # No plug-ins, no management interface, no DCO (not on macOS), no PKCS#11 (it loads modules).
  ./configure --prefix=/usr/local --disable-plugins --disable-management --disable-dco --disable-unit-tests \
    --disable-debug --disable-plugin-auth-pam --disable-plugin-down-root \
    OPENSSL_CFLAGS="-I$SSL_TREE/include" OPENSSL_LIBS="$SSL_TREE/libssl.a $SSL_TREE/libcrypto.a" \
    LZO_CFLAGS="-I$LZO_TREE/include" LZO_LIBS="-L$LZO_TREE/lib -llzo2" \
    LZ4_CFLAGS="-I$LZ4_SRC/lib" LZ4_LIBS="-L$LZ4_SRC/lib -llz4" \
    CFLAGS="$CF -ffile-prefix-map=$DEPS=." \
    LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wl,-dead_strip" \
    && make -j"$JOBS"
) >> "$LOG" 2>&1 || { tail -n 30 "$LOG" >&2; echo "✗ OpenVPN did not build (log: build/deps/openvpn-build.log)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
cp "$SRC/src/openvpn/openvpn" "$OUT/openvpn"
strip -x "$OUT/openvpn"
codesign --force --sign - "$OUT/openvpn"   # strip drops the linker's signature; arm64 runs nothing unsigned
cp "$SRC/COPYING" "$OUT/licenses/OpenVPN-COPYING.txt"
cp "$SRC/COPYRIGHT.GPL" "$OUT/licenses/OpenVPN-COPYRIGHT.GPL.txt"
cp "$LZO_SRC/COPYING" "$OUT/licenses/LZO-COPYING.txt"
cp "$LZ4_SRC/lib/LICENSE" "$OUT/licenses/LZ4-LICENSE.txt"
tar -xzOf "$DEPS/openssl-$SSL_VERSION.tar.gz" "openssl-$SSL_VERSION/LICENSE.txt" > "$OUT/licenses/OpenSSL-LICENSE.txt"
# GPL: the scripts that control the build are part of the source, and FiveT's repository is private.
cp Tools/build-openvpn.sh "$OUT/licenses/build-openvpn.sh"
cp Tools/build-openfortivpn.sh "$OUT/licenses/build-openfortivpn.sh"   # it builds the OpenSSL used here
echo "$OVPN_VERSION (OpenSSL $SSL_VERSION)" > "$OUT/VERSION"   # build.sh puts it in Info.plist for Settings
cat > "$OUT/NOTICE.txt" <<EOF
FiveT includes OpenVPN $OVPN_VERSION (GNU GPL v2, with an exception for linking OpenSSL), built
unmodified without plug-ins and without the management interface, with OpenSSL $SSL_VERSION (Apache
License 2.0), LZO $LZO_VERSION (GNU GPL v2) and LZ4 $LZ4_VERSION (BSD 2-Clause) linked in. The licenses
are in this folder.

Source code:
  OpenVPN  $OVPN_URL
  LZO      $LZO_URL
  LZ4      $LZ4_URL
  OpenSSL  see build-openfortivpn.sh
Build scripts (every step and option used): build-openvpn.sh and build-openfortivpn.sh in this folder.
EOF
rm -rf "$SRC" "$LZO_SRC" "$LZ4_SRC" "$LZO_TREE"

# The whole point: nothing outside macOS. A library from anywhere else would be loaded as root.
BIN="$OUT/openvpn"
FOREIGN=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -vE '^/(usr/lib|System)/' || true)
if [ -n "$FOREIGN" ]; then
  echo "✗ openvpn loads libraries from outside macOS:" $FOREIGN >&2; rm -rf "$OUT"; exit 1
fi
if strings "$BIN" | grep -qF "$PWD"; then
  echo "✗ the build folder's path ended up inside openvpn" >&2; rm -rf "$OUT"; exit 1
fi
[ "$(lipo -archs "$BIN")" = "$ARCH" ] || { echo "✗ unexpected architectures: $(lipo -archs "$BIN")" >&2; rm -rf "$OUT"; exit 1; }
VERSION_OUT=$("$BIN" --version 2>&1 || true)
echo "$VERSION_OUT" | head -1 | grep -q "^OpenVPN $OVPN_VERSION " || { echo "✗ openvpn --version says '$(echo "$VERSION_OUT" | head -1)'" >&2; rm -rf "$OUT"; exit 1; }
echo "$VERSION_OUT" | grep -q "^library versions: OpenSSL $SSL_VERSION " || { echo "✗ openvpn is not linked with OpenSSL $SSL_VERSION: '$(echo "$VERSION_OUT" | grep '^library versions')'" >&2; rm -rf "$OUT"; exit 1; }
for off in enable_management=no enable_plugins=no enable_pkcs11=no; do
  echo "$VERSION_OUT" | grep -q "$off" || { echo "✗ openvpn was not built with $off" >&2; rm -rf "$OUT"; exit 1; }
done
for on in "\[LZO\]" "\[LZ4\]"; do
  echo "$VERSION_OUT" | head -1 | grep -q "$on" || { echo "✗ openvpn lacks $on" >&2; rm -rf "$OUT"; exit 1; }
done
echo "✓ built: $BIN ($OVPN_VERSION, OpenSSL $SSL_VERSION, $(( $(stat -f %z "$BIN") / 1024 )) KB)"
