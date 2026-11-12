#!/bin/sh
# Builds the openfortivpn that ships inside FiveT.app (Contents/Helpers/openfortivpn), so a new Mac
# needs neither Homebrew nor Terminal: one self-contained program, OpenSSL linked in, nothing loaded
# from outside macOS. build.sh runs this when build/openfortivpn is missing or older than this file.
#
#   Tools/build-openfortivpn.sh      -> build/openfortivpn/{openfortivpn, VERSION, licenses/, NOTICE.txt}
#
# Needs: Command Line Tools, autoconf + automake + pkg-config (brew install autoconf automake pkgconf),
# and the internet once (sources are cached in build/deps and checked against the SHA-256s below).
set -eu
cd "$(dirname "$0")/.."

OFV_VERSION=1.24.1
OFV_SHA256=c40d33acd97b89c2e943bfd839c19b69e5a7a5997052e2fc9a595602745c0465
OFV_URL=https://github.com/adrienverge/openfortivpn/archive/refs/tags/v$OFV_VERSION.tar.gz
# 3.5 is OpenSSL's long-term-support line (security fixes until April 2030).
SSL_VERSION=3.5.9
SSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
SSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$SSL_VERSION/openssl-$SSL_VERSION.tar.gz
# FiveT itself is arm64 and runs on macOS 13 or newer: the same for its openfortivpn.
ARCH=arm64
export MACOSX_DEPLOYMENT_TARGET=13.0
# OpenSSL writes a "built on" date into the binary. A fixed one makes a rebuild of the same versions
# byte-identical, so Settings does not tell every Mac to reinstall an unchanged openfortivpn.
export SOURCE_DATE_EPOCH=1767225600   # 2026-01-01 00:00 UTC

DEPS=$PWD/build/deps
OUT=$PWD/build/openfortivpn
SSL_TREE=$DEPS/openssl-$SSL_VERSION-$ARCH   # OpenSSL's build tree: headers and the two .a files
JOBS=$(sysctl -n hw.ncpu)

for tool in autoreconf automake pkg-config; do
  command -v $tool >/dev/null || { echo "✗ $tool is missing: brew install autoconf automake pkgconf" >&2; exit 1; }
done

# Downloads $2 to build/deps/$3 (kept for next time) and checks it against $1. With $4 = resume,
# a broken download continues where it stopped (the 50 MB OpenSSL release file; slow links time
# out). GitHub's source archives ignore byte ranges, so those start over on every try.
fetch() {
  mkdir -p "$DEPS"
  if [ ! -f "$DEPS/$3" ] || [ "$(shasum -a 256 "$DEPS/$3" | cut -d' ' -f1)" != "$1" ]; then
    echo "▸ downloading $3"
    tries=0
    while :; do
      rc=0
      if [ "${4:-}" = resume ]; then
        curl -fL --retry 3 -C - -o "$DEPS/$3.part" "$2" || rc=$?
      else
        rm -f "$DEPS/$3.part"
        curl -fL --retry 3 -o "$DEPS/$3.part" "$2" || rc=$?
      fi
      [ $rc -ne 0 ] || break
      [ $rc -ne 33 ] || rm -f "$DEPS/$3.part"   # 33: the server cannot resume, start over
      tries=$((tries + 1))
      [ $tries -lt 5 ] || { rm -f "$DEPS/$3.part"; echo "✗ could not download $2" >&2; exit 1; }
      sleep 2
    done
    mv "$DEPS/$3.part" "$DEPS/$3"
  fi
  if [ "$(shasum -a 256 "$DEPS/$3" | cut -d' ' -f1)" != "$1" ]; then
    rm -f "$DEPS/$3"
    echo "✗ $3 does not match its SHA-256; deleted, run again" >&2
    exit 1
  fi
}
fetch $SSL_SHA256 $SSL_URL openssl-$SSL_VERSION.tar.gz resume
fetch $OFV_SHA256 $OFV_URL openfortivpn-$OFV_VERSION.tar.gz

# OpenSSL as static libraries only. The copy runs as root, so it must not load code from anywhere:
# no DSO/module/engine loading at all. Its CA list is macOS's own (root-owned) /etc/ssl/cert.pem;
# the helper runs it with OPENSSL_CONF=/dev/null, so no config file is read. The compiled-in engine
# and module folders (unused) point into FiveT's root-owned folder rather than this build folder.
#
# Size: OpenSSL's algorithm tables reference every algorithm built, so the linker cannot drop unused
# ones; only these no-* options can. openfortivpn is a TLS 1.2/1.3 client over TCP that checks the
# gateway's certificate (CA or SHA-256 pin) and may present a client certificate from PEM files
# (user-cert/user-key in a connection's extra lines, keys possibly encrypted: AES, 3DES, PBKDF2,
# scrypt). Kept: AES, ChaCha20, RSA, EC P-256/384/521, X25519/X448, Ed25519, ML-KEM (post-quantum
# key exchange), DH, DES, SHA-1/2/3. Dropped: other transports (QUIC, DTLS, SCTP, SRTP), password
# and pre-shared-key TLS (SRP, PSK), certificate-management protocols (CMS, TS, CMP, CT, OCSP and
# their HTTP client), the legacy provider, national and obsolete ciphers and hashes (IDEA, MDC2,
# RC2/4/5, MD4, SEED, Blowfish, CAST, Whirlpool, RIPEMD, SM2/3/4, GOST, ARIA, Camellia), binary
# curves, SipHash, AES-SIV/OCB, Argon2, post-quantum signatures (no CA issues such certificates),
# RFC 3779, DSA, integrity-only TLS ciphers, async jobs and thread pools. -Os: compiled for size;
# the bulk crypto (AES-GCM, ChaCha20, SHA) is hand-written assembly and runs just as fast.
# Tested 2026-09-24 against both gateways: TLS 1.3 and 1.2, same certificate digests as before.
SSL_OPTIONS="darwin64-$ARCH-cc no-shared no-module no-dso no-engine no-tests no-docs
  no-quic no-dtls no-sctp no-srtp no-srp no-psk no-cms no-ts no-cmp no-ct no-ocsp no-http
  no-legacy no-idea no-mdc2 no-rc2 no-rc4 no-rc5 no-md4 no-seed no-bf no-cast no-whirlpool no-rmd160
  no-sm2 no-sm3 no-sm4 no-gost no-aria no-camellia no-ec2m no-siphash no-siv no-ocb no-argon2
  no-ml-dsa no-slh-dsa no-rfc3779 no-dsa no-integrity-only-ciphers no-async no-thread-pool
  no-default-thread-pool
  --prefix=/Library/PrivilegedHelperTools/app.fivet.openfortivpn --libdir=lib
  --openssldir=/private/etc/ssl -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Os"
# The built tree is reused only when it was made with exactly this recipe. It is built under a
# temporary name and renamed when complete, so an interrupted build is never picked up.
SSL_RECIPE="$SSL_OPTIONS SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
if [ "$(cat "$SSL_TREE/.fivet-recipe" 2>/dev/null)" != "$SSL_RECIPE" ]; then
  echo "▸ building OpenSSL $SSL_VERSION (static, $ARCH; takes a minute)"
  rm -rf "$DEPS/openssl-$SSL_VERSION" "$SSL_TREE" "$SSL_TREE.tmp"
  tar -xzf "$DEPS/openssl-$SSL_VERSION.tar.gz" -C "$DEPS"
  mv "$DEPS/openssl-$SSL_VERSION" "$SSL_TREE.tmp"
  (
    cd "$SSL_TREE.tmp"
    # Unquoted on purpose: one word per option (no option contains a space).
    ./Configure $SSL_OPTIONS && make -j"$JOBS" build_libs
  ) > "$DEPS/openssl-build.log" 2>&1 || {
    tail -n 30 "$DEPS/openssl-build.log" >&2; rm -rf "$SSL_TREE.tmp"
    echo "✗ OpenSSL did not build (log: build/deps/openssl-build.log)" >&2; exit 1
  }
  printf '%s' "$SSL_RECIPE" > "$SSL_TREE.tmp/.fivet-recipe"
  mv "$SSL_TREE.tmp" "$SSL_TREE"
fi

echo "▸ building openfortivpn $OFV_VERSION ($ARCH, OpenSSL $SSL_VERSION linked in)"
SRC=$DEPS/openfortivpn-$OFV_VERSION
rm -rf "$SRC"
tar -xzf "$DEPS/openfortivpn-$OFV_VERSION.tar.gz" -C "$DEPS"
(
  cd "$SRC"
  ./autogen.sh
  # OPENSSL_CFLAGS/OPENSSL_LIBS stand in for pkg-config: the static OpenSSL above, never Homebrew's.
  # macOS ships pppd 2.4, hence legacy-pppd (Homebrew builds it the same way). The helper always
  # passes -c, so the default config path is never read; /etc keeps it root-owned regardless.
  ./configure --prefix=/usr/local --sysconfdir=/etc --enable-legacy-pppd --with-pppd=/usr/sbin/pppd \
    OPENSSL_CFLAGS="-I$SSL_TREE/include" OPENSSL_LIBS="$SSL_TREE/libssl.a $SSL_TREE/libcrypto.a" \
    CFLAGS="-Os -arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Wl,-dead_strip" \
    && make -j"$JOBS"
) > "$DEPS/openfortivpn-build.log" 2>&1 || {
  tail -n 30 "$DEPS/openfortivpn-build.log" >&2
  echo "✗ openfortivpn did not build (log: build/deps/openfortivpn-build.log)" >&2; exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
cp "$SRC/openfortivpn" "$OUT/openfortivpn"
strip -x "$OUT/openfortivpn"
codesign --force --sign - "$OUT/openfortivpn"   # strip drops the linker's signature; arm64 runs nothing unsigned
cp "$SRC/LICENSE" "$OUT/licenses/openfortivpn-LICENSE.txt"
cp "$SRC/LICENSE.OpenSSL" "$OUT/licenses/openfortivpn-LICENSE.OpenSSL.txt"
# GPL: the scripts that control the build are part of the source, and FiveT's repository is private.
cp Tools/build-openfortivpn.sh "$OUT/licenses/build-openfortivpn.sh"
tar -xzOf "$DEPS/openssl-$SSL_VERSION.tar.gz" "openssl-$SSL_VERSION/LICENSE.txt" > "$OUT/licenses/OpenSSL-LICENSE.txt"
echo "$OFV_VERSION (OpenSSL $SSL_VERSION)" > "$OUT/VERSION"   # build.sh puts it in Info.plist for Settings
cat > "$OUT/NOTICE.txt" <<EOF
FiveT includes openfortivpn $OFV_VERSION (GNU GPL v3, with an exception for linking OpenSSL),
built unmodified with OpenSSL $SSL_VERSION (Apache License 2.0) linked in. The licenses are in this folder.

Source code:
  openfortivpn  $OFV_URL
  OpenSSL       $SSL_URL
Build script (every step and option used): build-openfortivpn.sh in this folder.
EOF
rm -rf "$SRC"

# The whole point: nothing outside macOS. A library from anywhere else would be loaded as root.
BIN="$OUT/openfortivpn"
FOREIGN=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -vE '^/(usr/lib|System)/' || true)
if [ -n "$FOREIGN" ]; then
  echo "✗ openfortivpn loads libraries from outside macOS:" $FOREIGN >&2; rm -rf "$OUT"; exit 1
fi
if strings "$BIN" | grep -qF "$PWD"; then
  echo "✗ the build folder's path ended up inside openfortivpn" >&2; rm -rf "$OUT"; exit 1
fi
[ "$(lipo -archs "$BIN")" = "$ARCH" ] || { echo "✗ unexpected architectures: $(lipo -archs "$BIN")" >&2; rm -rf "$OUT"; exit 1; }
VERSION_OUT=$("$BIN" --version 2>&1 || true)
[ "$VERSION_OUT" = "$OFV_VERSION" ] || { echo "✗ openfortivpn --version says '$VERSION_OUT'" >&2; rm -rf "$OUT"; exit 1; }
echo "✓ built: $BIN ($OFV_VERSION, OpenSSL $SSL_VERSION, $(( $(stat -f %z "$BIN") / 1024 )) KB)"
