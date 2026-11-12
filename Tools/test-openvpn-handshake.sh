#!/bin/sh
# Root-free smoke test of an OpenVPN build (FiveT's bundled one by default): a fresh certificate chain, then the
# program as both server and client over 127.0.0.1 on a dummy device. It must complete a TLS handshake with the
# OpenSSL it was linked with, negotiate an AEAD cipher, and keep exchanging encrypted keepalives, both with the
# right certificate and while refusing a client whose certificate is from another CA. Run by cores-prepare.sh.
#   Tools/test-openvpn-handshake.sh [path to openvpn]       exit 0 = pass
set -eu
BIN=${1:-build/openvpn/openvpn}
[ -x "$BIN" ] || { echo "✗ $BIN not found" >&2; exit 1; }
BIN=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")   # absolute: the test runs in a temp folder
D=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$D"' EXIT
cd "$D"
SSL=/usr/bin/openssl
PORT=$((20000 + $$ % 20000))

pki() {   # pki <name> <usage>: a key and a certificate for <name> from the CA in this folder (ca.crt, ca.key)
  $SSL ecparam -name prime256v1 -genkey -noout -out "$1.key"
  $SSL req -new -key "$1.key" -subj "/CN=$1" -out "$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=%s\n' "$2" > "$1.ext"
  $SSL x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 2 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}
newca() {
  $SSL ecparam -name prime256v1 -genkey -noout -out ca.key
  printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=test-ca-%s\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=keyCertSign,cRLSign\n' "$1" > ca.cnf
  $SSL req -new -x509 -key ca.key -config ca.cnf -sha256 -days 2 -out ca.crt
}
newca good; pki server serverAuth; pki client clientAuth
mkdir rogue && (cd rogue && newca rogue && pki client clientAuth)   # a client certificate from a different CA

COMMON="--dev null --ifconfig-noexec --ifconfig-nowarn --route-noexec --ifconfig 10.77.0.1 10.77.0.2 --proto udp --verb 4 --ping 1 --ping-exit 20 --tls-version-min 1.2 --data-ciphers AES-256-GCM"
run() {   # run <name> <local port> <remote port> <tls role> <ca> <cert> <key> <seconds>
  "$BIN" $COMMON --local 127.0.0.1 --lport "$2" --remote 127.0.0.1 "$3" --"$4" --ca "$5" --cert "$6" --key "$7" --dh none \
    --remote-cert-tls "$( [ "$4" = tls-server ] && echo client || echo server )" > "$1.log" 2>&1 &
}

echo "▸ $("$BIN" --version | head -2 | tr '\n' ';')"
run server "$PORT" $((PORT + 1)) tls-server ca.crt server.crt server.key
run client $((PORT + 1)) "$PORT" tls-client ca.crt client.crt client.key
sleep 7
kill $(jobs -p) 2>/dev/null || true; wait 2>/dev/null || true
for side in server client; do
  grep -q 'Initialization Sequence Completed' $side.log || {
    echo "✗ $side: no handshake"; grep -h -E 'VERIFY|rror|TLS|WARNING' server.log client.log | cut -c1-220 | head -12; exit 1; }
done
grep -q 'TLSv1.3' client.log || grep -q 'TLS_AES_256_GCM_SHA384\|TLSv1.2' client.log || { echo "✗ no TLS version in the client log"; exit 1; }
grep -q 'Data Channel: cipher .AES-256-GCM' client.log || { echo "✗ the AEAD data channel was not negotiated"; tail -n 20 client.log; exit 1; }
echo "✓ handshake and AEAD data channel: $(grep -o 'Control Channel: [^,]*, [^,]*' client.log | head -1), $(grep -o 'Data Channel: cipher [^,]*' client.log | head -1)"

# A client whose certificate comes from a different CA must be refused.
run server2 "$PORT" $((PORT + 1)) tls-server ca.crt server.crt server.key
run rogue $((PORT + 1)) "$PORT" tls-client ca.crt rogue/client.crt rogue/client.key
sleep 6
kill $(jobs -p) 2>/dev/null || true; wait 2>/dev/null || true
if grep -q 'Initialization Sequence Completed' server2.log; then echo "✗ the server accepted a certificate from another CA"; exit 1; fi
grep -qi 'certificate verify failed\|VERIFY ERROR\|TLS handshake failed\|TLS Error' server2.log || { echo "✗ the refusal left no TLS error in the log"; tail -n 8 server2.log; exit 1; }
echo "✓ a certificate from another CA is refused"
