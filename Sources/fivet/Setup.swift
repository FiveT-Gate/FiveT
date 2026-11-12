import Foundation
import AppKit
import Combine
import Security

enum SetupFix { case installHelper }

struct SetupCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let ok: Bool
    /// The full story, for Copy Diagnostics.
    let detail: String
    let fix: SetupFix?
    /// The one short line Settings shows under the title; nil when the title says it all.
    var hint: String? = nil
}

/// Environment checks and the one-time privileged setup.
///
/// openfortivpn ships inside FiveT.app (Contents/Helpers, built by Tools/build-openfortivpn.sh with
/// OpenSSL linked in), so a new Mac needs no Homebrew; Homebrew's is only the fallback for a build
/// without it.
///
/// Starting a tunnel needs root. The sudoers rule FiveT installs allows exactly one command, the
/// root helper below, and the helper starts FiveT's own root-owned copy of openfortivpn. It never
/// runs the original (the one in FiveT.app or Homebrew's): those files belong to the user, so any
/// program running as the user could replace them, and root would run the replacement on the next
/// connect.
enum Setup {
    /// Where to get FiveT again when this copy is incomplete.
    static let downloadPage = "https://github.com/FiveT-Gate/FiveT/releases/latest"
    /// What installHelper() returns when the password prompt was cancelled.
    static let cancelledMessage = "Cancelled."
    /// Homebrew's openfortivpn, used when this copy of FiveT has none inside (a plain `swift build`).
    static let candidatePaths = [
        "/opt/homebrew/bin/openfortivpn",
        "/usr/local/bin/openfortivpn",
        "/opt/local/bin/openfortivpn",
    ]
    static let sudoersFile = "/etc/sudoers.d/fivet"
    /// What `ovpn-run`'s checker (and OpenVPNProfile's copy of it) refuses stdin past: the same limit
    /// the helper enforces with `head -c`, named once so the two never drift apart.
    static let ovpnMaxConfigBytes = 262_144
    /// The root helper: starts and stops openfortivpn and manages /etc/resolver/<domain> for split
    /// DNS. The only command in the sudoers rule. (The name dates from v1, which only did DNS.)
    static let resolverHelperPath = "/Library/PrivilegedHelperTools/app.fivet.resolver"
    /// FiveT's root-owned copy of openfortivpn and the libraries it loads (none for the one in
    /// FiveT.app; Homebrew's OpenSSL for Homebrew's), plus `sources`, the files it was copied from.
    static let openfortivpnCopyDir = "/Library/PrivilegedHelperTools/app.fivet.openfortivpn"
    /// FiveT's root-owned copy of its OpenVPN (one self-contained file), for OpenVPN connections.
    static let openvpnCopyDir = "/Library/PrivilegedHelperTools/app.fivet.openvpn"
    /// FiveT's root-owned copy of its Xray and the address list its routing reads, for V2Ray connections.
    static let xrayCopyDir = "/Library/PrivilegedHelperTools/app.fivet.xray"
    /// v2 added `stop <pid>`; v3 starts openfortivpn itself (`run`), from the copy, with checked options;
    /// v4 starts OpenVPN the same way (`ovpn-run`) and makes a full tunnel's DNS the Mac's (`dns-set`);
    /// v5 starts Xray for V2Ray connections (`xray-run`), its config checked the same way;
    /// v6 can replace itself and FiveT's copies of the programs (`refresh`), from a FiveT.app signed with
    /// FiveT's own certificate, so an update needs no admin password any more;
    /// v7 makes those copies APFS clones of the app's programs, so they take no disk space of their own;
    /// v8 clears the quarantine flag from what a refresh installs (an app copied out of a downloaded disk
    /// image carries it on every file, and macOS kills a flagged program when it starts);
    /// v9 has the kill switch (`ks-on`, `ks-off`): packet filter rules that block the Mac's internet;
    /// v10 lives under FiveT's new identifier (app.fivet): installed through the admin prompt once, and
    /// that install removes what earlier FiveTs kept under theirs.
    static let resolverHelperVersion = "10"
    /// Written by `ks-on`, removed by `ks-off`: there while the kill switch blocks (its pf enable token).
    static let killSwitchTokenFile = "/var/run/app.fivet.pf"
    /// The first helper that has `refresh`: older ones are replaced through the admin prompt, once.
    static let refreshMinHelperVersion = 6
    /// SHA-1 of the certificate FiveT.app is signed with (self-signed, "FiveT", valid to 2046; the login
    /// keychain of the release Mac holds its key). `refresh` installs only from an app whose signature
    /// carries exactly this certificate. A new certificate means one more Install Helper… click.
    static let releaseCertHash = "fb8d0fe2083cfa1521147ea674031ff78bd0facc"
    /// The build number of what the root-owned copies came from: `refresh` never installs an older one.
    static let buildStampFile = "/Library/PrivilegedHelperTools/app.fivet.build"
    /// Where `refresh` copies the app to, as root, to check it where no other user can change it.
    static let stageDir = "/Library/PrivilegedHelperTools/app.fivet.stage"
    /// Exit status of `stop` when no openfortivpn lives under that pid (it exited already).
    static let helperNotFoundStatus: Int32 = 3

    /// The openfortivpn inside FiveT.app. FiveT never runs it itself (a copy downloaded with a
    /// browser is quarantined, and macOS kills a quarantined unsigned tool): Install Helper… copies
    /// it into the root-owned folder, clears the flag, and the helper runs that copy.
    static var bundledOpenfortivpnPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openfortivpn").path
    }

    /// Its version, stamped into Info.plist by build.sh ("1.24.1 (OpenSSL 3.5.8)").
    static var bundledOpenfortivpnVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "FiveTOpenfortivpnVersion") as? String
    }

    /// The OpenVPN inside FiveT.app; like openfortivpn, only its root-owned copy ever runs.
    static var bundledOpenVPNPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openvpn").path
    }

    /// Its version, stamped into Info.plist by build.sh ("2.6.23 (OpenSSL 3.5.8)").
    static var bundledOpenVPNVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "FiveTOpenVPNVersion") as? String
    }

    /// The Xray inside FiveT.app, and the Iranian and private address list next to it; like
    /// openvpn, only the root-owned copies are ever used.
    static var bundledXrayPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xray").path
    }
    static var bundledXrayGeoPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/xray/geoip-lite.dat").path
    }

    /// Its version, stamped into Info.plist by build.sh ("26.10.10").
    static var bundledXrayVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "FiveTXrayVersion") as? String
    }

    /// The OpenVPN options the helper passes on; it refuses a profile with any other. Left out are
    /// the ones that, as root, run a program (up, down, route-up, ipchange, tls-verify, plugin…, and
    /// script-security, which the helper sets to 1), read a file (askpass, config, capath, and the
    /// file forms of ca, cert, key, tls-auth…: only their inline <ca>…</ca> blocks are allowed),
    /// write one (log, status, writepid, tls-export-cert), open a control socket (management), drop
    /// root before the routes come down again (user, group, chroot), or answer a one-time-code
    /// question on the console (static-challenge: FiveT sends the code with the password instead).
    static let openvpnAllowedOptions = [
        "client", "tls-client", "pull", "dev", "dev-type", "topology", "proto", "remote", "remote-random",
        "remote-random-hostname", "port", "rport", "lport", "nobind", "bind", "float", "resolv-retry",
        "connect-retry", "connect-retry-max", "connect-timeout", "server-poll-timeout", "persist-key",
        "persist-tun", "persist-remote-ip", "persist-local-ip", "remote-cert-tls", "remote-cert-ku",
        "remote-cert-eku", "verify-x509-name", "ns-cert-type", "cipher", "data-ciphers",
        "data-ciphers-fallback", "ncp-ciphers", "auth", "tls-version-min", "tls-version-max", "tls-cipher",
        "tls-ciphersuites", "tls-groups", "tls-cert-profile", "ecdh-curve", "key-direction", "tls-timeout",
        "hand-window", "tran-window", "reneg-sec", "reneg-bytes", "reneg-pkts", "auth-user-pass",
        "auth-nocache", "auth-retry", "auth-token", "auth-token-user", "comp-lzo", "compress",
        "allow-compression", "redirect-gateway", "redirect-private", "route", "route-ipv6", "route-gateway",
        "route-ipv6-gateway", "route-metric", "route-delay", "route-nopull", "pull-filter", "block-ipv6",
        "ifconfig", "ifconfig-ipv6", "tun-ipv6", "ignore-unknown-option", "setenv", "setenv-safe",
        "dhcp-option", "explicit-exit-notify", "keepalive", "ping", "ping-restart", "ping-exit",
        "ping-timer-rem", "inactive", "mute", "mute-replay-warnings", "verb", "suppress-timestamps",
        "tun-mtu", "tun-mtu-extra", "link-mtu", "mssfix", "fragment", "sndbuf", "rcvbuf", "txqueuelen",
        "fast-io", "replay-window", "push-peer-info", "peer-fingerprint", "http-proxy", "http-proxy-option",
        "http-proxy-retry", "socks-proxy", "socks-proxy-retry", "tls-exit", "single-session", "disable-occ",
        "allow-recursive-routing", "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2",
        "extra-certs", "pkcs12", "crl-verify",
    ]
    /// Inline blocks the helper accepts (<ca>…</ca>), and the options it accepts only that way.
    static let openvpnInlineBlocks = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs",
                                      "pkcs12", "crl-verify", "auth-user-pass", "peer-fingerprint", "http-proxy-user-pass"]
    static let openvpnInlineOnly = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs",
                                    "pkcs12", "crl-verify", "auth-user-pass"]

    /// The openfortivpn Install Helper… copies: FiveT's own, else Homebrew's.
    static var openfortivpnPath: String? {
        ([bundledOpenfortivpnPath] + candidatePaths).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every /etc/resolver/<domain> file the helper wrote (first line "# managed by FiveT"),
    /// whether the domain was typed under "DNS domains" or pushed by a gateway.
    static func managedResolverDomains() -> [String] {
        let dir = "/etc/resolver"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { name in
            guard !name.hasPrefix("."), let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { return false }
            return text.hasPrefix("# managed by FiveT")
        }.sorted()
    }

    /// The sudoers rule: the root helper and nothing else.
    static func sudoersContent() -> String {
        let user = NSUserName()
        return """
        # Installed by FiveT.app: lets \(user) run FiveT's root helper (start and stop FiveT's copy of openfortivpn, split-DNS resolver files) without a password.
        \(user) ALL=(root) NOPASSWD: \(resolverHelperPath)

        """
    }

    /// The openfortivpn options the helper passes on; it refuses a config with any other. Left out
    /// are the ones that, as root, run a program (pinentry), load code into pppd (pppd-plugin,
    /// pppd-call), write a file (pppd-log), feed pppd's scripts (pppd-ipparam, pppd-ifname) or
    /// read stdin (cookie-on-stdin). ca-file, user-cert and user-key must be file paths: a
    /// pkcs11: URI makes OpenSSL load a module from Homebrew's folders.
    static let allowedOptions = [
        "host", "port", "username", "password", "realm", "otp", "otp-prompt", "otp-delay", "no-ftm-push",
        "set-routes", "half-internet-routes", "set-dns", "pppd-use-peerdns", "pppd-accept-remote",
        "ifname", "sni", "trusted-cert", "ca-file", "user-cert", "user-key", "pem-passphrase",
        "insecure-ssl", "cipher-list", "min-tls", "seclevel-1", "persistent",
    ]

    /// The root helper. It validates every argument, only ever runs the root-owned copy of
    /// openfortivpn, only ever signals processes named openfortivpn, and only ever touches
    /// /etc/resolver/<domain> files it created itself. `run` reads the config (password included)
    /// from stdin and hands it to openfortivpn without writing it anywhere; it `exec`s, so
    /// openfortivpn is the child of the sudo FiveT started and `stop <that pid>` finds it.
    /// DYLD_LIBRARY_PATH makes the copy load the copied OpenSSL instead of Homebrew's, and
    /// OPENSSL_CONF=/dev/null keeps Homebrew's (user-editable) openssl.cnf from loading modules.
    static let resolverHelperScript = """
    #!/bin/sh
    # app.fivet.resolver v\(resolverHelperVersion) - installed by FiveT.app, runs as root through sudo.
    # Usage: run [-v]                  start FiveT's copy of openfortivpn; the config comes on stdin
    #        stop <pid> [TERM|KILL]    signal the openfortivpn under that sudo pid (or that pid)
    #        stopall [TERM|KILL]       signal every openfortivpn, and FiveT's openvpn and xray
    #        ovpn-run [-v]             start FiveT's copy of OpenVPN; the profile comes on stdin
    #        xray-run                  start FiveT's copy of Xray (V2Ray); the config comes on stdin
    #        dns-set <tag> <utunN> <ipv4> <nameserver>...   dns-clear <tag>   a full tunnel's DNS as the Mac's
    #        add <domain> <nameserver>...   remove <domain>      split-DNS files in /etc/resolver
    #        ks-on [utunN] <address>...   ks-off      the kill switch: block what leaves the Mac, or stop
    #        check                     print the version
    #        refresh <path of FiveT.app>   replace this helper and the copies of the programs with the ones in
    #                                  that app, if it is signed with FiveT's certificate and not older
    #        selftest                  show which libraries the copy loads
    set -eu
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    MARK="# managed by FiveT"
    OFV_DIR="\(openfortivpnCopyDir)"
    OVPN_DIR="\(openvpnCopyDir)"
    XRAY_DIR="\(xrayCopyDir)"
    HELPER_PATH="\(resolverHelperPath)"
    BUILD_FILE="\(buildStampFile)"
    STAGE_DIR="\(stageDir)"
    cmd="${1:-}"
    if [ "$cmd" = "check" ]; then echo "\(resolverHelperVersion)"; exit 0; fi
    if [ "$cmd" = "run" ]; then
      verbose=""
      case "${2:-}" in '') ;; -v) verbose="-v";; *) echo "ERROR:  invalid option for run" >&2; exit 2;; esac
      [ -x "$OFV_DIR/openfortivpn" ] || { echo "ERROR:  FiveT's copy of openfortivpn is missing. Click Install Helper... in FiveT, Settings, General."; exit 4; }
      conf=$(/usr/bin/head -c 65536)
      bad=$(printf '%s\\n' "$conf" | /usr/bin/awk -v allowed="\(allowedOptions.joined(separator: " "))" '
        BEGIN { n = split(allowed, k, " "); for (i = 1; i <= n; i++) ok[k[i]] = 1 }
        /^[[:space:]]*(#|$)/ { next }
        {
          eq = index($0, "=")
          if (eq == 0) next
          key = substr($0, 1, eq - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          val = substr($0, eq + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
          if (key == "") next
          if (!(key in ok)) { bad = bad sep key; sep = ", " }
          else if ((key == "ca-file" || key == "user-cert" || key == "user-key") && substr(val, 1, 1) != "/") { bad = bad sep key " (must be a file path)"; sep = ", " }
        }
        END { printf "%s", bad }')
      if [ -n "$bad" ]; then
        echo "ERROR:  FiveT's helper does not allow these openfortivpn options: $bad. Remove them from the connection's extra options."
        exit 2
      fi
      exec /usr/bin/env -i PATH="$PATH" OPENSSL_CONF=/dev/null DYLD_LIBRARY_PATH="$OFV_DIR" "$OFV_DIR/openfortivpn" -c /dev/stdin $verbose <<EOF
    $conf
    EOF
    fi
    if [ "$cmd" = "ovpn-run" ]; then
      verb=3
      case "${2:-}" in '') ;; -v) verb=4;; *) echo "ERROR:  invalid option for ovpn-run" >&2; exit 2;; esac
      [ -x "$OVPN_DIR/openvpn" ] || { echo "ERROR:  FiveT's copy of OpenVPN is missing. Click Install Helper... in FiveT, Settings, General."; exit 4; }
      conf=$(/usr/bin/head -c \(ovpnMaxConfigBytes))
      bad=$(printf '%s\n' "$conf" | /usr/bin/awk -v allowed="\(openvpnAllowedOptions.joined(separator: " "))" \
        -v blocks="\(openvpnInlineBlocks.joined(separator: " "))" -v inlineonly="\(openvpnInlineOnly.joined(separator: " "))" \
        -v dq='"' -v sq="'" '
        function bad(w) { if (!(w in seen)) { seen[w] = 1; out = out sep w; sep = ", " } }
        # OpenVPN strips one matching pair of quotes from a word before reading it; this check must
        # too, or a quoted option name, or a quoted "opt" right after setenv, hides from the list below.
        function unq(s,    n, c) {
          n = length(s)
          if (n >= 2) {
            c = substr(s, 1, 1)
            if ((c == dq || c == sq) && substr(s, n, 1) == c) return substr(s, 2, n - 2)
          }
          return s
        }
        BEGIN {
          n = split(allowed, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1
          n = split(blocks, a, " "); for (i = 1; i <= n; i++) blk[a[i]] = 1
          n = split(inlineonly, a, " "); for (i = 1; i <= n; i++) io[a[i]] = 1
        }
        {
          t = $0; sub(/\r$/, "", t); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
          # OpenVPN ends an inline block on any line that STARTS WITH "</name>", not only a line that
          # is exactly that: "</ca>x" closes it, with "x" discarded, the same as OpenVPN itself does.
          # Checking for an exact match here left everything up to the real last close tag unchecked.
          if (inblock != "") { if (index(t, "</" inblock ">") == 1) inblock = ""; next }
          if (t == "" || t ~ /^[#;]/) next
          if (t == "<connection>") { if (conn) bad("nested <connection>"); conn = 1; next }
          if (t == "</connection>") { if (!conn) bad("</connection>"); conn = 0; next }
          if (t ~ /^<[A-Za-z0-9-]+>$/) {
            name = substr(t, 2, length(t) - 2)
            if (!(name in blk)) bad("<" name ">")
            inblock = name; next
          }
          if (t ~ /^</) { bad("a line starting with <"); next }
          nf = split(t, w, /[[:space:]]+/)
          for (i = 1; i <= nf; i++) w[i] = unq(w[i])
          key = w[1]; sub(/^--/, "", key)
          # "setenv opt <option> ..." is <option>, applied if OpenVPN knows it: checked as that option.
          if (key == "setenv" && w[2] == "opt") {
            if (nf < 3) next
            for (i = 3; i <= nf; i++) w[i - 2] = w[i]
            nf -= 2; key = w[1]; sub(/^--/, "", key)
          }
          if (!(key in ok)) { bad(key); next }
          if ((key in io) && nf > 1) bad(key " with a file (put it inline)")
          if (key == "dev" && w[2] !~ /^tun[0-9]*$/) bad("dev " w[2])
          if (key == "dev-type" && w[2] != "tun") bad("dev-type " w[2])
          if ((key == "http-proxy" || key == "socks-proxy") && nf > 3) bad(key " with a password file")
        }
        END { if (inblock != "") bad("unclosed <" inblock ">"); if (conn) bad("unclosed <connection>"); printf "%s", out }')
      if [ -n "$bad" ]; then
        echo "ERROR:  FiveT's helper does not allow these OpenVPN options: $bad."
        exit 2
      fi
      # After the profile, so they win: no scripts, no login retries of its own (FiveT counts failed
      # logins), and an exit instead of a restart of its own (FiveT reconnects, with a fresh code).
      exec /usr/bin/env -i PATH="$PATH" OPENSSL_CONF=/dev/null "$OVPN_DIR/openvpn" --config /dev/stdin \
        --script-security 1 --auth-retry none --remap-usr1 SIGTERM --suppress-timestamps --verb "$verb" <<EOF
    $conf
    EOF
    fi
    if [ "$cmd" = "xray-run" ]; then
      [ -x "$XRAY_DIR/xray" ] || { echo "ERROR:  FiveT's copy of Xray is missing. Click Install Helper... in FiveT, Settings, General."; exit 4; }
      conf=$(/usr/bin/head -c 262144)
      # Xray runs as root, so its config may only do what a VPN needs: the TUN as the one way in,
      # servers, direct, block and DNS as the ways out, and nothing anywhere that names a file (logs,
      # certificates, TLS key logs, address lists other than FiveT's) or opens a port (api, metrics,
      # other inbounds). Checked with the JavaScript that comes with macOS, which reads JSON
      # properly. Xray (Go) matches key names ignoring case, even across some non-ASCII letters
      # ("maſterKeyLog" is masterKeyLog to it), and reads comments: so keys must be plain ASCII and
      # unique ignoring case, and Xray gets the config as the check re-wrote it, never the text
      # that came in. Only an answer starting "OK " passes: an error, a warning or none refuses it.
      verdict=$(/usr/bin/env -i FIVET_CONF="$conf" /usr/bin/osascript -l JavaScript <<'JS' 2>/dev/null || true
    function run() {
      var text = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey('FIVET_CONF'))
      var c
      try { c = JSON.parse(text) } catch (e) { return 'a config that is not JSON' }
      if (!c || typeof c !== 'object' || Array.isArray(c)) return 'a config that is not a JSON object'
      var bad = []
      function no(w) { if (bad.indexOf(w) < 0) bad.push(w) }
      function only(o, allowed, where) {
        if (o === undefined) return
        if (!o || typeof o !== 'object' || Array.isArray(o)) { no(where); return }
        Object.keys(o).forEach(function (k) { if (allowed.indexOf(k) < 0) no(where + k) })
      }
      only(c, ['log', 'inbounds', 'outbounds', 'routing', 'dns', 'policy'], '')
      only(c.log, ['loglevel', 'dnsLog', 'maskAddress'], 'log.')
      ;(Array.isArray(c.inbounds) ? c.inbounds : [null]).forEach(function (i) {
        if (!i || i.protocol !== 'tun') { no('inbound ' + (i && i.protocol)); return }
        only(i, ['tag', 'protocol', 'settings', 'sniffing'], 'tun inbound ')
        var n = (i.settings || {}).name
        if (n !== undefined && !/^utun[0-9]{1,3}$/.test(n)) no('tun name ' + n)
      })
      var outs = ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'freedom', 'blackhole', 'dns']
      ;(Array.isArray(c.outbounds) ? c.outbounds : [null]).forEach(function (o) {
        if (!o || outs.indexOf(o.protocol) < 0) no('outbound ' + (o && o.protocol))
      })
      function walk(v) {
        if (Array.isArray(v)) { v.forEach(walk); return }
        if (v && typeof v === 'object') {
          var seen = {}
          Object.keys(v).forEach(function (k) {
            if (!/^[A-Za-z0-9_.:-]+$/.test(k)) { no('the key ' + JSON.stringify(k)); return }
            var l = k.toLowerCase()
            if (seen[l]) no('two keys ' + k)
            seen[l] = true
            if (l.slice(-4) === 'file' || l === 'masterkeylog') no(k)
            walk(v[k])
          })
        } else if (typeof v === 'string') {
          // Address and site lists Xray reads from disk: only the one FiveT ships (no apostrophes in
          // this script: the old /bin/sh would read one as a quote inside the $( ) around it).
          var r = v.replace(/^!+/, '').toLowerCase()
          if (/^(ext|ext-ip|ext-domain|ext-site):/.test(r) ? r.split(':')[1] !== 'geoip-lite.dat' : /^(geoip|geosite):/.test(r)) no(v)
        }
      }
      walk(c)
      return bad.length ? bad.join(', ') : 'OK ' + JSON.stringify(c)
    }
    JS
    )
      case "$verdict" in
        "OK {"*) ;;
        *) echo "ERROR:  FiveT's helper does not allow this in a V2Ray config: ${verdict:-a config FiveT could not check}."; exit 2;;
      esac
      exec /usr/bin/env -i PATH="$PATH" XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY_DIR/xray" run -c stdin: <<EOF
    ${verdict#OK }
    EOF
    fi
    if [ "$cmd" = "dns-set" ] || [ "$cmd" = "dns-clear" ]; then
      tag="${2:-}"
      case "$tag" in ''|*[!a-z0-9-]*) echo "invalid tag" >&2; exit 2;; esac
      key="State:/Network/Service/app.fivet.$tag"
      if [ "$cmd" = "dns-clear" ]; then
        printf 'remove %s/IPv4\nremove %s/DNS\n' "$key" "$key" | /usr/sbin/scutil
        exit 0
      fi
      iface="${3:-}"; ip="${4:-}"
      case "$iface" in utun[0-9]|utun[0-9][0-9]|utun[0-9][0-9][0-9]) ;; *) echo "invalid interface" >&2; exit 2;; esac
      case "$ip" in ''|*[!0-9.]*) echo "invalid address" >&2; exit 2;; esac
      shift 4
      [ $# -ge 1 ] || { echo "no nameserver given" >&2; exit 2; }
      for ns in "$@"; do
        case "$ns" in ''|*[!0-9A-Fa-f.:]*) echo "invalid nameserver $ns" >&2; exit 2;; esac
      done
      # The tunnel as the primary service while it is up (what pppd does for a VPN): its DNS server
      # answers every name, not only the local network's resolver.
      printf 'd.init\nd.add Addresses * %s\nd.add InterfaceName %s\nd.add Router %s\nd.add OverridePrimary # 1\nset %s/IPv4\nd.init\nd.add ServerAddresses * %s\nset %s/DNS\n' \
        "$ip" "$iface" "$ip" "$key" "$*" "$key" | /usr/sbin/scutil
      exit 0
    fi
    if [ "$cmd" = "ks-on" ] || [ "$cmd" = "ks-off" ]; then
      # The kill switch. While a VPN that carried all traffic is down without its user having switched
      # it off, nothing leaves the Mac except to the Mac itself, the local network (the router, DHCP, a
      # DNS server there), the tunnel a V2Ray run is opening, and the addresses given: the VPN's server
      # and the Mac's DNS servers, so the VPN can come back. Packet filter rules in an anchor of
      # FiveT's own, under the "com.apple/*" point of macOS's main rules (nothing of macOS's is
      # touched). They do not survive a restart of the Mac.
      anchor="com.apple/100.fivet"
      token="\(killSwitchTokenFile)"
      if [ "$cmd" = "ks-off" ]; then
        /sbin/pfctl -q -a "$anchor" -F rules 2>/dev/null || true
        if [ -f "$token" ]; then
          # The reference ks-on took on the packet filter: given back, so pf goes off again if nothing else uses it.
          /sbin/pfctl -q -X "$(/usr/bin/head -c 32 "$token" | /usr/bin/tr -cd '0-9')" 2>/dev/null || true
          /bin/rm -f "$token"
        fi
        exit 0
      fi
      shift
      tun=""
      case "${1:-}" in utun[0-9]|utun[0-9][0-9]|utun[0-9][0-9][0-9]) tun="$1"; shift;; esac
      # Addresses only: pfctl would look a name up, and read other words as rule text.
      for ip in "$@"; do
        case "$ip" in
          ''|*[!0-9A-Fa-f.:]*) echo "invalid address" >&2; exit 2;;
          *:*) ;;
          *[!0-9.]*) echo "invalid address" >&2; exit 2;;
          *.*.*.*) ;;
          *) echo "invalid address" >&2; exit 2;;
        esac
      done
      /sbin/pfctl -sr 2>/dev/null | /usr/bin/grep -q 'anchor "com.apple/[*]"' || {
        echo "ERROR:  the Mac's packet filter rules have no com.apple anchor point (another program replaced them): the kill switch cannot block" >&2; exit 5; }
      rules=$(
        echo "pass out quick on lo0 all"
        [ -z "$tun" ] || echo "pass out quick on $tun all"
        echo "pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }"
        echo "pass out quick inet6 from any to { fe80::/10, ff00::/8 }"
        for ip in "$@"; do echo "pass out quick from any to $ip"; done
        echo "block return out quick all"
      )
      # All the rules or none (pfctl loads a file whole). Its warning about -f is for the main rules, not an anchor.
      printf '%s\n' "$rules" | /sbin/pfctl -q -a "$anchor" -f - 2>/dev/null || {
        echo "ERROR:  the packet filter refused the kill switch's rules" >&2; exit 5; }
      [ -s "$token" ] || /sbin/pfctl -E 2>&1 | /usr/bin/sed -n 's/^Token : //p' > "$token"
      # Believed only when the filter says so: rules that are not there, or a filter that is off, block nothing.
      /sbin/pfctl -a "$anchor" -sr 2>/dev/null | /usr/bin/grep -q "^block" && /sbin/pfctl -si 2>/dev/null | /usr/bin/grep -q "Status: Enabled" || {
        echo "ERROR:  the packet filter did not take the kill switch's rules" >&2; exit 5; }
      exit 0
    fi
    if [ "$cmd" = "refresh" ]; then
      # An update of FiveT replaces the helper and the programs it starts without an admin password,
      # but only from FiveT.app itself: the app is copied to a folder only root can enter, and checked
      # THERE (a copy in the user's reach could change between the check and the install) for a code
      # signature that carries FiveT's own certificate, sealing every file in it, the programs and the
      # helper text included. Anything else (another certificate, a changed or added file, an ad-hoc
      # signature) is refused, and so is an older build than the one installed: an old release is
      # signed too, and could bring back a bug. The sudoers rule is not touched.
      fail() { echo "ERROR:  refresh: $1" >&2; exit "${2:-2}"; }
      app="${2:-}"
      [ "$#" -eq 2 ] || fail "usage: refresh <path of FiveT.app>"
      case "$app" in /*.app) ;; *) fail "needs the full path of FiveT.app";; esac
      case "$app" in *[![:print:]]*) fail "the path has unexpected characters";; esac
      [ -d "$app" ] && [ ! -L "$app" ] || fail "no such app"
      size=$(/usr/bin/du -sk "$app" | /usr/bin/awk '{print $1}')
      case "$size" in ''|*[!0-9]*) fail "cannot read the app";; esac
      [ "$size" -le 300000 ] || fail "that is too big to be FiveT"
      umask 077
      lock="$STAGE_DIR.lock"
      if ! /bin/mkdir "$lock" 2>/dev/null; then
        # A lock left by a run that died is older than any run takes.
        if [ -n "$(/usr/bin/find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
          /bin/rm -rf "$lock"; /bin/mkdir "$lock" 2>/dev/null || fail "another refresh is running" 7
        else
          fail "another refresh is running" 7
        fi
      fi
      trap '/bin/rm -rf "$STAGE_DIR" "$lock" "${ofv_tmp:-}" "${ovpn_tmp:-}" "${xray_tmp:-}" "${hlp_tmp:-}" "${stamp_tmp:-}"' EXIT
      /bin/rm -rf "$STAGE_DIR"
      /bin/mkdir -m 0700 "$STAGE_DIR"
      /usr/bin/ditto --noqtn "$app" "$STAGE_DIR/FiveT.app" || fail "could not copy the app" 3
      /usr/sbin/chown -R root:wheel "$STAGE_DIR"
      staged="$STAGE_DIR/FiveT.app"
      req=$(printf 'identifier "app.fivet" and certificate leaf = H"%s"' "\(releaseCertHash)")
      /usr/bin/codesign --verify --strict --deep -R "=$req" "$staged" >/dev/null 2>&1 || fail "that app is not FiveT, signed with FiveT's certificate" 3
      newbuild=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$staged/Contents/Info.plist" 2>/dev/null || true)
      case "$newbuild" in ''|*[!0-9]*) fail "the app has no build number" 3;; esac
      oldbuild=0
      if [ -f "$BUILD_FILE" ]; then oldbuild=$(/usr/bin/head -c 12 "$BUILD_FILE" | /usr/bin/tr -d '\n'); fi
      case "$oldbuild" in ''|*[!0-9]*) oldbuild=0;; esac
      [ "$newbuild" -ge "$oldbuild" ] || fail "build $newbuild is older than the installed build $oldbuild" 4
      for f in Contents/Helpers/openfortivpn Contents/Helpers/openvpn Contents/Helpers/xray Contents/Resources/xray/geoip-lite.dat Contents/Resources/fivet-helper.sh; do
        [ -f "$staged/$f" ] && [ ! -L "$staged/$f" ] || fail "the app is missing $f" 3
      done
      newhelper="$staged/Contents/Resources/fivet-helper.sh"
      [ "$(/usr/bin/head -n 1 "$newhelper")" = "#!/bin/sh" ] && /bin/sh -n "$newhelper" || fail "the helper in the app is not valid" 3
      ofv_tmp="$OFV_DIR.tmp"; ovpn_tmp="$OVPN_DIR.tmp"; xray_tmp="$XRAY_DIR.tmp"; hlp_tmp="$HELPER_PATH.tmp"; stamp_tmp="$BUILD_FILE.tmp"
      /bin/rm -rf "$ofv_tmp" "$ovpn_tmp" "$xray_tmp" "$hlp_tmp" "$stamp_tmp"
      /bin/mkdir "$ofv_tmp" "$ovpn_tmp" "$xray_tmp"
      # The programs are APFS clones of the checked stage, which is itself a clone of the app's files
      # (ditto on one volume): the three root-owned copies share the app's disk blocks and cost none of
      # their own (41 MB). A clone is a separate file: a later change to the app's file never reaches it
      # (copy on write), and the stage is root's already, so nothing a user owns is cloned here. Another
      # volume, or a file system without clones, gets a plain copy.
      clonecp() { /bin/cp -c "$1" "$2" 2>/dev/null || /bin/cp "$1" "$2"; }
      clonecp "$staged/Contents/Helpers/openfortivpn" "$ofv_tmp/openfortivpn"
      printf '%s\n' "$app/Contents/Helpers/openfortivpn" > "$ofv_tmp/sources"
      clonecp "$staged/Contents/Helpers/openvpn" "$ovpn_tmp/openvpn"
      clonecp "$staged/Contents/Helpers/xray" "$xray_tmp/xray"
      /bin/cp "$staged/Contents/Resources/xray/geoip-lite.dat" "$xray_tmp/geoip-lite.dat"
      /bin/cp "$newhelper" "$hlp_tmp"
      printf '%s\n' "$newbuild" > "$stamp_tmp"
      # The quarantine flag a downloaded disk image puts on every file of FiveT.app: ditto --noqtn only
      # declines to add one, it keeps one that is there, and a clone keeps it too. macOS kills a flagged
      # program when it starts, so none of what is installed may carry it.
      for p in "$ofv_tmp" "$ovpn_tmp" "$xray_tmp" "$hlp_tmp"; do /usr/bin/xattr -dr com.apple.quarantine "$p" 2>/dev/null || true; done
      /usr/sbin/chown -R root:wheel "$ofv_tmp" "$ovpn_tmp" "$xray_tmp" "$hlp_tmp" "$stamp_tmp"
      /bin/chmod -R 0755 "$ofv_tmp" "$ovpn_tmp"
      /bin/chmod 0644 "$ofv_tmp/sources" "$xray_tmp/geoip-lite.dat" "$stamp_tmp"
      /bin/chmod 0755 "$xray_tmp" "$xray_tmp/xray" "$hlp_tmp"
      /bin/rm -rf "$OFV_DIR" "$OVPN_DIR" "$XRAY_DIR"
      /bin/mv "$ofv_tmp" "$OFV_DIR"
      /bin/mv "$ovpn_tmp" "$OVPN_DIR"
      /bin/mv "$xray_tmp" "$XRAY_DIR"
      /bin/mv -f "$stamp_tmp" "$BUILD_FILE"
      # Last: the shell reads this script from the file it opened, so the new one replaces it safely.
      /bin/mv -f "$hlp_tmp" "$HELPER_PATH"
      echo "refreshed to build $newbuild"
      exit 0
    fi
    if [ "$cmd" = "selftest" ]; then
      exec /usr/bin/env -i PATH="$PATH" OPENSSL_CONF=/dev/null DYLD_LIBRARY_PATH="$OFV_DIR" DYLD_PRINT_LIBRARIES=1 "$OFV_DIR/openfortivpn" --version
    fi
    if [ "$cmd" = "stop" ] || [ "$cmd" = "stopall" ]; then
      if [ "$cmd" = "stop" ]; then pid="${2:-}"; sig="${3:-TERM}"; else pid=""; sig="${2:-TERM}"; fi
      case "$sig" in TERM|KILL) ;; *) echo "invalid signal" >&2; exit 2;; esac
      # OpenVPN and Xray: only FiveT's own copies, never another app's (Tunnelblick runs an openvpn too).
      if [ "$cmd" = "stopall" ]; then
        /usr/bin/pkill "-$sig" -x openfortivpn || true
        /usr/bin/pkill "-$sig" -f "^$OVPN_DIR/openvpn " || true
        /usr/bin/pkill "-$sig" -f "^$XRAY_DIR/xray " || true
        exit 0
      fi
      case "$pid" in ''|*[!0-9]*) echo "invalid pid" >&2; exit 2;; esac
      comm=$(/bin/ps -o comm= -p "$pid" 2>/dev/null || true)
      if [ "${comm##*/}" = "openfortivpn" ] || [ "$comm" = "$OVPN_DIR/openvpn" ] || [ "$comm" = "$XRAY_DIR/xray" ]; then
        targets="$pid"
      else
        targets=$( { /usr/bin/pgrep -P "$pid" -x openfortivpn; /usr/bin/pgrep -P "$pid" -f "^$OVPN_DIR/openvpn "; /usr/bin/pgrep -P "$pid" -f "^$XRAY_DIR/xray "; } || true)
      fi
      [ -n "$targets" ] || { echo "no openfortivpn, openvpn or xray under pid $pid" >&2; exit \(helperNotFoundStatus); }
      for t in $targets; do /bin/kill "-$sig" "$t"; done
      exit 0
    fi
    domain="${2:-}"
    case "$domain" in
      ''|*[!A-Za-z0-9.-]*|.*|*..*|*.) echo "invalid domain" >&2; exit 2;;
    esac
    f="/etc/resolver/$domain"
    case "$cmd" in
      add)
        shift 2
        [ $# -ge 1 ] || { echo "no nameserver given" >&2; exit 2; }
        for ns in "$@"; do
          case "$ns" in ''|*[!0-9A-Fa-f.:]*) echo "invalid nameserver $ns" >&2; exit 2;; esac
        done
        mkdir -p /etc/resolver
        tmp="/etc/resolver/.fivet.$domain.tmp"
        echo "$MARK" > "$tmp"
        for ns in "$@"; do echo "nameserver $ns" >> "$tmp"; done
        chmod 0644 "$tmp"
        mv -f "$tmp" "$f"
        ;;
      remove)
        if [ -f "$f" ] && head -n 1 "$f" | grep -q "managed by FiveT"; then rm -f "$f"; fi
        ;;
      *) echo "usage: run [-v] | ovpn-run [-v] | xray-run | stop <pid> [TERM|KILL] | stopall [TERM|KILL] | dns-set <tag> <utunN> <ipv4> <ns>... | dns-clear <tag> | ks-on [utunN] <address>... | ks-off | add <domain> <ns>... | remove <domain> | check | refresh <app> | selftest" >&2; exit 2;;
    esac

    """

    enum HelperState { case current, outdated, missing }

    /// `current` when sudo runs the v5 helper without a password and the copies of openfortivpn,
    /// OpenVPN and Xray are in place; `outdated` when an older helper or sudoers rule is installed.
    static func helperState() -> HelperState {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: resolverHelperPath), fm.isExecutableFile(atPath: openfortivpnCopyDir + "/openfortivpn"),
           fm.isExecutableFile(atPath: openvpnCopyDir + "/openvpn"), fm.isExecutableFile(atPath: xrayCopyDir + "/xray") {
            let r = run("/usr/bin/sudo", ["-n", resolverHelperPath, "check"])
            // The whole script, not only its number: a helper changed without a new number (a
            // build between releases) is replaced too, never left running old rules as root.
            if r.status == 0 && r.output.trimmed == resolverHelperVersion,
               (try? String(contentsOfFile: resolverHelperPath, encoding: .utf8)) == resolverHelperScript { return .current }
        }
        return fm.fileExists(atPath: sudoersFile) || fm.fileExists(atPath: resolverHelperPath) ? .outdated : .missing
    }

    /// The number the installed helper answers `check` with, when sudo runs it without a password.
    static func installedHelperVersion() -> Int? {
        guard FileManager.default.isExecutableFile(atPath: resolverHelperPath) else { return nil }
        let r = run("/usr/bin/sudo", ["-n", resolverHelperPath, "check"])
        return r.status == 0 ? Int(r.output.trimmed) : nil
    }

    /// Whether this app may have the helper replace itself and the copies from it, with no password:
    /// the installed helper can (v6 or newer), and this is the FiveT in an Applications folder. A copy
    /// anywhere else (a build being tried, a disk image) never replaces what the installed FiveT uses.
    static func canRefreshHelper() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return false }
        return (installedHelperVersion() ?? 0) >= refreshMinHelperVersion
    }

    /// True when FiveT's root-owned copies are the programs inside this app (openfortivpn only when
    /// the app's own is the one in use, not Homebrew's).
    static func copiesMatchBundle() -> Bool {
        if openfortivpnPath == bundledOpenfortivpnPath,
           let now = try? OpenfortivpnFiles.sources(of: URL(fileURLWithPath: bundledOpenfortivpnPath)), !copyMatches(now) { return false }
        if FileManager.default.isExecutableFile(atPath: bundledOpenVPNPath), !openvpnCopyMatches() { return false }
        if FileManager.default.isExecutableFile(atPath: bundledXrayPath), !xrayCopyMatches() { return false }
        return true
    }

    private static let refreshQueue = DispatchQueue(label: "app.fivet.helper-refresh")
    /// A refresh has run since FiveT started: if the copies still do not share the app's disk blocks
    /// (a volume without clones), another refresh would not change that, so none is started for it.
    private static var refreshedSinceLaunch = false

    /// APFS clone id of a file's data: files cloned from each other share it. nil where the file system
    /// has none (not APFS) or the file is missing.
    static func cloneID(_ path: String) -> UInt64? {
        struct Reply {
            var length: UInt32 = 0
            var returned = attribute_set_t()
            var cloneID: UInt64 = 0
        }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var reply = Reply()
        guard getattrlist(path, &list, &reply, MemoryLayout<Reply>.size, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0,
              reply.returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 else { return nil }
        return reply.cloneID
    }

    /// True when a refresh would make FiveT's root-owned copies share disk blocks with this app's
    /// programs: the installed helper makes clones (v7), the app and the copies are on one volume that
    /// has them, and they share none yet (copies made by an older helper, or an update replaced the
    /// app's files). Xray stands for the three programs: it is the 36 MB one.
    static func copiesCouldShareStorage() -> Bool {
        guard !refreshedSinceLaunch else { return false }
        let fm = FileManager.default
        func volume(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.systemNumber] as? Int }
        let copy = xrayCopyDir + "/xray"
        guard let here = volume(bundledXrayPath), here == volume(copy),
              let appID = cloneID(bundledXrayPath), let copyID = cloneID(copy), appID != copyID else { return false }
        // Last, because asking the helper starts sudo: only an installed helper that clones can improve this.
        return (installedHelperVersion() ?? 0) >= 7
    }

    /// Has the installed helper replace itself and FiveT's copies of the programs with the ones in this
    /// app, through its `refresh` command: no password, because the helper checks that this app is
    /// signed with FiveT's own certificate (and not older than what is installed) before it takes
    /// anything from it. Returns nil when the helper and the copies match this app afterwards,
    /// else why not. One run at a time; a caller that waited finds it done.
    static func refreshHelper() -> String? {
        refreshQueue.sync {
            if helperState() == .current && copiesMatchBundle() && !copiesCouldShareStorage() { return nil }
            guard canRefreshHelper() else { return "The installed helper cannot update itself from here." }
            // The refresh that runs first is the installed helper's. When it has brought a newer helper,
            // that one has not done its work yet (v7: clones instead of copies), so it runs once more.
            for pass in 1...2 {
                let r = run("/usr/bin/sudo", ["-n", resolverHelperPath, "refresh", Bundle.main.bundlePath])
                let said = r.output.trimmed
                guard r.status == 0 else {
                    Log.shared.write("helper refresh refused (status \(r.status)): \(said)", level: .error)
                    return said.isEmpty ? "The helper did not accept this update." : said
                }
                Log.shared.write("helper refreshed from this app, no password: \(said)")
                if pass == 2 || !copiesCouldShareStorage() { break }
            }
            refreshedSinceLaunch = true
            return helperState() == .current && copiesMatchBundle() ? nil : "The helper was refreshed but still does not match this app."
        }
    }

    /// The build number in this app's Info.plist, digits only (what `refresh` compares).
    static var bundleBuild: String {
        let b = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        return !b.isEmpty && b.allSatisfy(\.isNumber) ? b : "0"
    }

    /// The version of the copy, run as this user the way the helper runs it.
    static func copyVersion() -> String? {
        let r = run("/usr/bin/env", ["-i", "OPENSSL_CONF=/dev/null", "DYLD_LIBRARY_PATH=\(openfortivpnCopyDir)",
                                     openfortivpnCopyDir + "/openfortivpn", "--version"])
        return r.status == 0 ? r.output.trimmed : nil
    }

    /// True when the root-owned OpenVPN is the one inside this FiveT (by code hash, like openfortivpn).
    static func openvpnCopyMatches() -> Bool {
        if let a = cdhash(bundledOpenVPNPath), let b = cdhash(openvpnCopyDir + "/openvpn") { return a == b }
        return FileManager.default.contentsEqual(atPath: bundledOpenVPNPath, andPath: openvpnCopyDir + "/openvpn")
    }

    /// True when the root-owned Xray and address list are the ones inside this FiveT.
    static func xrayCopyMatches() -> Bool {
        let fm = FileManager.default
        guard fm.contentsEqual(atPath: bundledXrayGeoPath, andPath: xrayCopyDir + "/geoip-lite.dat") else { return false }
        if let a = cdhash(bundledXrayPath), let b = cdhash(xrayCopyDir + "/xray") { return a == b }
        return fm.contentsEqual(atPath: bundledXrayPath, andPath: xrayCopyDir + "/xray")
    }

    /// The files the copy was made from (written at install time), binary first.
    static func copySources() -> [String] {
        let text = (try? String(contentsOfFile: openfortivpnCopyDir + "/sources", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// True when the copy holds the same code as `sources` (binary first, then its libraries),
    /// wherever it was copied from. Compared by code-signature hash, which stays the same when a
    /// new FiveT release re-signs an unchanged openfortivpn; byte for byte for unsigned files.
    static func copyMatches(_ sources: [URL]) -> Bool {
        sources.enumerated().allSatisfy { i, src in
            let copy = openfortivpnCopyDir + "/" + (i == 0 ? "openfortivpn" : src.lastPathComponent)
            if let a = cdhash(src.path), let b = cdhash(copy) { return a == b }
            return FileManager.default.contentsEqual(atPath: src.path, andPath: copy)
        }
    }

    private static func cdhash(_ path: String) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    /// Where the copy loads its non-system libraries from when root starts it (helper `selftest`).
    static func copyLibrariesAsRoot() -> [String] {
        let r = run("/usr/bin/sudo", ["-n", resolverHelperPath, "selftest"])
        guard r.status == 0 else { return [] }
        return r.output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("dyld["), let path = line.split(separator: " ").last.map(String.init),
                  path.hasSuffix(".dylib"), !path.hasPrefix("/usr/lib/"), !path.hasPrefix("/System/") else { return nil }
            return path
        }
    }

    static func checks() -> [SetupCheck] {
        var out: [SetupCheck] = []
        var version: String?
        let bundled = openfortivpnPath == bundledOpenfortivpnPath
        if bundled {
            version = bundledOpenfortivpnVersion
            out.append(SetupCheck(id: "ofv", title: "openfortivpn included", ok: true,
                                  detail: "Version \(version ?? "?"), comes with FiveT: nothing to install", fix: nil))
        } else if let ofv = openfortivpnPath {
            version = run(ofv, ["--version"]).output.trimmed
            out.append(SetupCheck(id: "ofv", title: "openfortivpn installed", ok: true,
                                  detail: "\(ofv) (version \(version ?? "?"))", fix: nil))
        } else {
            out.append(SetupCheck(id: "ofv", title: "openfortivpn is missing", ok: false,
                                  detail: "This copy of FiveT is incomplete. Download FiveT again from \(downloadPage)",
                                  fix: nil, hint: "Download FiveT again from \(downloadPage)"))
        }
        let ovpnBundled = FileManager.default.isExecutableFile(atPath: bundledOpenVPNPath)
        out.append(SetupCheck(id: "ovpn", title: ovpnBundled ? "OpenVPN included" : "OpenVPN is missing", ok: ovpnBundled,
                              detail: ovpnBundled ? "Version \(bundledOpenVPNVersion ?? "?"), comes with FiveT: nothing to install"
                                                  : "This copy of FiveT is incomplete. Download FiveT again from \(downloadPage)",
                              fix: nil))
        let xrayBundled = FileManager.default.isExecutableFile(atPath: bundledXrayPath)
        out.append(SetupCheck(id: "xray", title: xrayBundled ? "V2Ray (Xray) included" : "V2Ray (Xray) is missing", ok: xrayBundled,
                              detail: xrayBundled ? "Xray \(bundledXrayVersion ?? "?"), comes with FiveT: nothing to install"
                                                  : "This copy of FiveT is incomplete. Download FiveT again from \(downloadPage)",
                              fix: nil))
        let pppd = FileManager.default.isExecutableFile(atPath: "/usr/sbin/pppd")
        out.append(SetupCheck(id: "pppd", title: pppd ? "pppd available" : "pppd is missing", ok: pppd,
                              detail: "/usr/sbin/pppd (ships with macOS)", fix: nil))
        switch helperState() {
        case .current:
            guard let copy = copyVersion() else {
                out.append(SetupCheck(id: "helper", title: "Helper's openfortivpn does not start", ok: false,
                                      detail: "Click Install Helper… to copy openfortivpn again.", fix: .installHelper))
                break
            }
            var detail = "\(resolverHelperPath) with FiveT's own copy of openfortivpn \(copy)"
            var fix: SetupFix?
            var hint: String?
            let libs = copyLibrariesAsRoot()
            if !libs.isEmpty && !libs.allSatisfy({ $0.hasPrefix(openfortivpnCopyDir + "/") }) {
                detail += ". Warning: it loads \(libs.filter { !$0.hasPrefix(openfortivpnCopyDir + "/") }.joined(separator: ", ")) from outside its folder"
                hint = "Warning: its openfortivpn loads libraries from outside its folder."
            }
            // FiveT (after an update) or Homebrew (brew upgrade) has other code than the copy: the
            // copy keeps working, but is not the newest.
            if let ofv = openfortivpnPath, let now = try? OpenfortivpnFiles.sources(of: URL(fileURLWithPath: ofv)),
               !copyMatches(now) {
                let v = version ?? "?"
                // Where the copy came from, not the exact path: FiveT may have moved since (a first
                // setup from the disk image or Downloads, then /Applications).
                let copyWasFiveTs = copySources().first?.hasSuffix(".app/Contents/Helpers/openfortivpn") == true
                if !bundled {
                    detail += ". Homebrew has a newer openfortivpn or OpenSSL (\(v)): click Install Helper… to use it"
                    hint = "Homebrew has a newer openfortivpn."
                } else if copyWasFiveTs {
                    detail += ". FiveT has an updated openfortivpn (\(v)): click Install Helper… to use it"
                    hint = "FiveT has a newer openfortivpn."
                } else {
                    detail += ". FiveT now includes its own openfortivpn (\(v)), so Homebrew's is no longer needed: click Install Helper… to switch to it"
                    hint = "Switch to the openfortivpn included with FiveT."
                }
                fix = .installHelper
            }
            if fix == nil, FileManager.default.isExecutableFile(atPath: bundledOpenVPNPath), !openvpnCopyMatches() {
                detail += ". FiveT has an updated OpenVPN (\(bundledOpenVPNVersion ?? "?")): click Install Helper… to use it"
                hint = "FiveT has a newer OpenVPN."
                fix = .installHelper
            }
            if fix == nil, FileManager.default.isExecutableFile(atPath: bundledXrayPath), !xrayCopyMatches() {
                detail += ". FiveT has an updated Xray or address list (\(bundledXrayVersion ?? "?")): click Install Helper… to use it"
                hint = "FiveT has a newer Xray."
                fix = .installHelper
            }
            out.append(SetupCheck(id: "helper", title: "Helper installed", ok: true, detail: detail, fix: fix, hint: hint))
        case .outdated:
            out.append(SetupCheck(id: "helper", title: "Helper needs an update", ok: false,
                                  detail: "Click Install Helper… (one admin prompt). The new helper starts only FiveT's own copy of openfortivpn, with checked settings, so no other program on this Mac can use it to gain admin rights.",
                                  fix: .installHelper))
        case .missing:
            out.append(SetupCheck(id: "helper", title: "Helper not installed", ok: false,
                                  detail: "Lets FiveT start and stop the VPN, and set up split DNS, without asking for your password every time. One-time admin prompt.",
                                  fix: .installHelper))
        }
        return out
    }

    /// Copies openfortivpn and its libraries into a root-owned folder and installs the helper and
    /// the sudoers rule, through the standard macOS admin prompt. Returns an error message, or nil.
    static func installHelper() -> String? {
        // A helper that can update itself does it from this app: no password prompt.
        if canRefreshHelper() {
            if let problem = refreshHelper() {
                Log.shared.write("helper refresh did not work (\(problem)); asking for the password instead")
            } else {
                Log.shared.write("helper is current: no password needed")
                return nil
            }
        }
        guard let ofv = openfortivpnPath else {
            return "This copy of FiveT has no openfortivpn inside. Download FiveT again from \(downloadPage)."
        }
        let sources: [URL]
        do { sources = try OpenfortivpnFiles.sources(of: URL(fileURLWithPath: ofv)) } catch {
            let message = (error as? OpenfortivpnFiles.Failure)?.message ?? error.localizedDescription
            Log.shared.write("helper install: \(message)", level: .error)
            return message
        }
        // The paths go into a root shell command, quoted; a line break could still end the command.
        if let odd = sources.first(where: { $0.path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }) {
            return "FiveT will not copy \(odd.path): the path has unexpected characters."
        }
        let ovpn = bundledOpenVPNPath
        guard FileManager.default.isExecutableFile(atPath: ovpn) else {
            return "This copy of FiveT has no OpenVPN inside. Download FiveT again from \(downloadPage)."
        }
        if ovpn.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "FiveT will not copy \(ovpn): the path has unexpected characters."
        }
        let xray = bundledXrayPath, geo = bundledXrayGeoPath
        guard FileManager.default.isExecutableFile(atPath: xray), FileManager.default.fileExists(atPath: geo) else {
            return "This copy of FiveT has no Xray inside. Download FiveT again from \(downloadPage)."
        }
        let script = "do shell script \(appleScriptString(installCommands(sources: sources, openvpn: ovpn, xray: xray, geo: geo)))"
            + " with prompt \(appleScriptString("FiveT needs your Mac password once, to install the helper that starts and stops the VPN."))"
            + " with administrator privileges"
        Log.shared.write("installing helper v\(resolverHelperVersion) (sudoers rule + root helper + copy of \(sources.map(\.lastPathComponent).joined(separator: ", ")), openvpn, xray)")
        let r = run("/usr/bin/osascript", ["-e", script])
        if r.status != 0 {
            let msg = r.output.trimmed
            Log.shared.write("helper install failed: \(msg)", level: .error)
            return msg.contains("-128") ? cancelledMessage : (msg.isEmpty ? "Install failed." : msg)
        }
        if helperState() == .current {
            Log.shared.write("helper installed OK")
            return nil
        }
        return "Installed, but the check still fails. Copy diagnostics and share the log."
    }

    /// The root shell command installHelper() runs: the copy first, then the helper, then the
    /// sudoers rule (checked by visudo), each written under a temporary name and moved into place.
    /// The copy loses the quarantine flag a browser download puts on FiveT.app: macOS kills a
    /// quarantined unsigned program when it starts, and `cp` keeps the flag.
    static func installCommands(sources: [URL], openvpn: String, xray: String, geo: String) -> String {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        let dir = openfortivpnCopyDir, dtmp = openfortivpnCopyDir + ".tmp"
        let vdir = openvpnCopyDir, vtmp = openvpnCopyDir + ".tmp"
        let xdir = xrayCopyDir, xtmp = xrayCopyDir + ".tmp"
        let stmp = sudoersFile + ".tmp"   // names containing '.' are ignored by sudo until renamed
        let btmp = buildStampFile + ".tmp"
        let htmp = resolverHelperPath + ".tmp"
        var sh = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/rm -rf \(dtmp)",
            "/bin/mkdir \(dtmp)",
        ]
        for (i, src) in sources.enumerated() {
            sh.append("/bin/cp \(shellQuote(src.path)) \(dtmp)/\(shellQuote(i == 0 ? "openfortivpn" : src.lastPathComponent))")
        }
        sh += [
            "echo '\(b64(sources.map(\.path).joined(separator: "\n") + "\n"))' | /usr/bin/base64 --decode > \(dtmp)/sources",
            "/usr/bin/xattr -dr com.apple.quarantine \(dtmp)",
            "/usr/sbin/chown -R root:wheel \(dtmp)",
            "/bin/chmod -R 0755 \(dtmp)",
            "/bin/chmod 0644 \(dtmp)/sources",
            "/bin/rm -rf \(dir)",
            "/bin/mv \(dtmp) \(dir)",
            // OpenVPN: one self-contained file, copied the same way.
            "/bin/rm -rf \(vtmp)",
            "/bin/mkdir \(vtmp)",
            "/bin/cp \(shellQuote(openvpn)) \(vtmp)/openvpn",
            "/usr/bin/xattr -dr com.apple.quarantine \(vtmp)",
            "/usr/sbin/chown -R root:wheel \(vtmp)",
            "/bin/chmod -R 0755 \(vtmp)",
            "/bin/rm -rf \(vdir)",
            "/bin/mv \(vtmp) \(vdir)",
            // Xray and the address list its routing reads (found next to it: XRAY_LOCATION_ASSET).
            "/bin/rm -rf \(xtmp)",
            "/bin/mkdir \(xtmp)",
            "/bin/cp \(shellQuote(xray)) \(xtmp)/xray",
            "/bin/cp \(shellQuote(geo)) \(xtmp)/geoip-lite.dat",
            "/usr/bin/xattr -dr com.apple.quarantine \(xtmp)",
            "/usr/sbin/chown -R root:wheel \(xtmp)",
            "/bin/chmod 0755 \(xtmp) \(xtmp)/xray",
            "/bin/chmod 0644 \(xtmp)/geoip-lite.dat",
            "/bin/rm -rf \(xdir)",
            "/bin/mv \(xtmp) \(xdir)",
            // Which build the copies come from: `refresh` never goes back to an older one.
            "echo '\(bundleBuild)' > \(btmp)",
            "/usr/sbin/chown root:wheel \(btmp)",
            "/bin/chmod 0644 \(btmp)",
            "/bin/mv -f \(btmp) \(buildStampFile)",
            "echo '\(b64(resolverHelperScript))' | /usr/bin/base64 --decode > \(htmp)",
            "/usr/sbin/chown root:wheel \(htmp)",
            "/bin/chmod 0755 \(htmp)",
            "/bin/mv -f \(htmp) \(resolverHelperPath)",
            "echo '\(b64(sudoersContent()))' | /usr/bin/base64 --decode > \(stmp)",
            "/bin/chmod 0440 \(stmp)",
            "/usr/sbin/visudo -cf \(stmp)",
            "/bin/mv -f \(stmp) \(sudoersFile)",
            // The helper and copies of a FiveT from before the identifier changed (any other *.fivet.* name).
            "for old in /Library/PrivilegedHelperTools/*.fivet.*; do case \"$old\" in /Library/PrivilegedHelperTools/app.fivet.*) ;; *) /bin/rm -rf \"$old\";; esac; done",
        ]
        return sh.joined(separator: " && ") + " || { /bin/rm -rf \(stmp) \(htmp) \(dtmp) \(vtmp) \(xtmp) \(btmp); exit 1; }"
    }

    /// `s` as one word for /bin/sh, whatever it contains.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `s` as an AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static var loggedNoExitCallback = false

    /// Runs a command to completion and returns exit status + combined output.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Not waitUntilExit() alone: on the main thread it only notices the exit on a run-loop poll, about
        // 65 ms late (measured), on every connect, stop and quit. The handler says so at once. The wait is
        // short because a macOS that delivered the handler through the calling thread's run loop would
        // stall every call here for all of it; the log line would show a colleague's Mac doing that.
        if exited.wait(timeout: .now() + 2) == .timedOut {
            if !loggedNoExitCallback {   // once: Copy Diagnostics shows info and above
                loggedNoExitCallback = true
                Log.shared.write("Setup.run: no exit callback 2 s after the output ended (\(path)); waiting for the exit instead")
            }
            p.waitUntilExit()
        }
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// The one-click setup: Install Helper… behind a single macOS password prompt. The Set Up FiveT
/// button in Settings, the menu item and a connect click on a Mac that is not set up yet all go
/// through here, so they show the same progress and never open a second prompt.
final class SetupFlow: ObservableObject {
    static let shared = SetupFlow()

    @Published private(set) var working = false
    /// What the last run said: progress, success, or why it failed.
    @Published private(set) var message: String?
    /// The last run set up a Mac that needed it; Settings shows "FiveT is ready" until the tab changes.
    @Published private(set) var justSetUp = false
    /// The last run failed or was cancelled; `message` says why.
    @Published private(set) var failed = false

    private var waiting: [(String?) -> Void] = []
    private var tabWatch: AnyCancellable?

    private init() {
        tabWatch = SettingsRouter.shared.$tab.dropFirst().sink { [weak self] _ in self?.justSetUp = false }
    }

    /// Installs the helper; `done` gets nil once it works, else the error. A call while a run is
    /// going waits for that run instead of starting another.
    func run(_ done: ((String?) -> Void)? = nil) {
        if let done { waiting.append(done) }
        guard !working else { return }
        let wasNeeded = VPNManager.shared.needsSetup
        working = true
        justSetUp = false
        failed = false
        message = "macOS will ask for your Mac password…"
        DispatchQueue.global(qos: .userInitiated).async {
            let error = Setup.installHelper()
            DispatchQueue.main.async {
                self.working = false
                self.failed = error != nil
                self.justSetUp = error == nil && wasNeeded
                self.message = error ?? (ConnectionStore.shared.connections.isEmpty
                    ? "FiveT is set up. Next, add your VPN under Connections."
                    : "FiveT is set up. You can connect now.")
                VPNManager.shared.recheckSetup()
                let callbacks = self.waiting
                self.waiting = []
                callbacks.forEach { $0(error) }
            }
        }
    }

    /// Runs `action` at once, or after the setup while this Mac is not set up: a connect click on a
    /// new Mac asks for the password once, then connects. `failed` runs when the setup did not work
    /// (not when the password prompt was cancelled), to show why.
    func whenReady(_ action: @escaping () -> Void, failed: @escaping () -> Void) {
        guard VPNManager.shared.needsSetup else { return action() }
        run { error in
            if error == nil { action() } else if error != Setup.cancelledMessage { failed() }
        }
    }
}

/// What the helper's copy of openfortivpn is made of: the binary and every library it loads from
/// outside macOS (Homebrew's OpenSSL), found by reading the Mach-O load commands, so no developer
/// tools are needed.
enum OpenfortivpnFiles {
    struct Failure: Error { let message: String }

    /// Real paths, the binary first. The copies are found by file name (DYLD_LIBRARY_PATH), so two
    /// libraries must not share one.
    static func sources(of binary: URL) throws -> [URL] {
        var out = [binary.resolvingSymlinksInPath()]
        var queue = out
        while !queue.isEmpty {
            let file = queue.removeFirst()
            for name in try linkedLibraries(of: file) where !name.hasPrefix("/usr/lib/") && !name.hasPrefix("/System/") {
                let url = try resolve(name, loadedBy: file, executable: out[0])
                if !out.contains(url) { out.append(url); queue.append(url) }
            }
        }
        let names = out.dropFirst().map(\.lastPathComponent)
        guard Set(names).count == names.count else {
            throw Failure(message: "openfortivpn loads two libraries with the same name (\(names.joined(separator: ", "))); FiveT cannot copy them.")
        }
        return out
    }

    private static func resolve(_ name: String, loadedBy file: URL, executable: URL) throws -> URL {
        let path: String
        if name.hasPrefix("/") {
            path = name
        } else if name.hasPrefix("@loader_path/") {
            path = file.deletingLastPathComponent().path + "/" + name.dropFirst("@loader_path/".count)
        } else if name.hasPrefix("@executable_path/") {
            path = executable.deletingLastPathComponent().path + "/" + name.dropFirst("@executable_path/".count)
        } else {
            throw Failure(message: "openfortivpn loads \(name), which FiveT cannot locate to copy.")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "openfortivpn needs \(name), which is missing. Reinstall it:  brew reinstall openfortivpn")
        }
        return url
    }

    /// The install names in LC_LOAD_DYLIB and friends, from every 64-bit slice of the file.
    static func linkedLibraries(of url: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw Failure(message: "Could not read \(url.path).")
        }
        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        // A universal file lists its slices in a big-endian header; a thin file is one slice at 0.
        var slices = [0]
        if let magic = u32(0, bigEndian: true), magic == 0xcafe_babe || magic == 0xcafe_babf {
            let wide = magic == 0xcafe_babf, entry = wide ? 32 : 20
            slices = (0..<Int(min(u32(4, bigEndian: true) ?? 0, 16))).compactMap { i in
                let at = 8 + i * entry + 8
                return (wide ? u32(at + 4, bigEndian: true) : u32(at, bigEndian: true)).map(Int.init)
            }
        }
        let dylibCommands: Set<UInt32> = [0xc, 0x20, 0x8000_0018, 0x8000_001f, 0x8000_0023]
        var names: [String] = []
        var parsed = false
        for base in slices where u32(base) == 0xfeed_facf {   // MH_MAGIC_64
            parsed = true
            var offset = base + 32
            for _ in 0..<Int(u32(base + 16) ?? 0) {
                guard let cmd = u32(offset), let size = u32(offset + 4), size >= 8 else { break }
                if dylibCommands.contains(cmd), let nameOffset = u32(offset + 8) {
                    let start = offset + Int(nameOffset), end = min(offset + Int(size), data.count)
                    if start < end, let s = String(bytes: data[start..<end].prefix { $0 != 0 }, encoding: .utf8),
                       !names.contains(s) { names.append(s) }
                }
                offset += Int(size)
            }
        }
        guard parsed else { throw Failure(message: "\(url.path) is not a 64-bit Mac program.") }
        return names
    }
}

enum Diagnostics {
    /// `checks` come from Setup.checks(), which runs processes: collect them off the main thread.
    static func text(checks: [SetupCheck]) -> String {
        var s = "FiveT diagnostics — \(Log.formatter.string(from: Date()))\n"
        s += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        s += "app \(version) at \(Bundle.main.bundlePath)\n"
        for c in checks { s += "[\(c.ok ? "OK" : "!!")] \(c.title) — \(c.detail)\n" }
        let vpn = VPNManager.shared
        let all = vpn.sessions.isEmpty ? [vpn.status] : vpn.sessions
        if all.count > 1 { s += "tunnels: \(all.count) active\n" }
        for st in all {
            s += "status: \(st.summary)\n"
            if let n = st.network {
                s += "network: \(n.interface) \(n.tunnelIP) → \(n.peerIP.isEmpty ? "?" : n.peerIP), dns [\(n.dnsServers.joined(separator: ", "))]"
                if !n.searchDomains.isEmpty { s += ", search [\(n.searchDomains.joined(separator: ", "))]" }
                s += ", \(n.routes.count) routes via tunnel\n"
            }
            if let sd = st.splitDNS { s += "split dns: \(sd.state) [\(sd.domains.joined(separator: ", "))]\(sd.detail.isEmpty ? "" : " — " + sd.detail)\n" }
        }
        if !vpn.sessions.isEmpty, let e = vpn.lastError { s += "last error: \(e)\n" }
        let mcp = MCPServer.shared
        s += "mcp: " + (mcp.isListening ? "listening on \(MCPPaths.socketPath), \(mcp.clientCount) assistant(s) connected" : "off") + "\n"
        for c in ConnectionStore.shared.connections {
            s += "connection '\(c.name)': \(c.gatewayDescription) user=\(c.username) otp=\(c.otpMode.rawValue)"
            s += " cert=\(c.hasPinForGateway ? "pinned" : (c.knowsGateway ? "ca-verified" : "not-yet-seen"))"
            if !c.trustedCertNames.isEmpty { s += " certNames=[\(c.trustedCertNames.joined(separator: ", "))]" }
            if c.hasPendingReview { s += " certReview=\(c.pendingCertFirst ? "first-meeting" : "changed") (waiting for the user)" }
            s += " dnsDomains=[\(c.dnsDomainList.joined(separator: ", "))]"
            s += " extra=\(redactedOptions(c.extraConfig))"
            if let d = c.lastConnectedAt { s += " lastConnected=\(Log.formatter.string(from: d))" }
            if let e = c.lastError { s += " lastError=\(e)" }
            s += "\n"
        }
        s += "--- recent log (info and errors) ---\n" + Log.shared.recentText(level: .info, last: 200) + "\n"
        return s
    }

    /// The extra openfortivpn options as "key = value; …", showing the value only for options known
    /// to hold none of the user's secrets: diagnostics get pasted into chats and read by AI
    /// assistants, and the helper accepts `password` and `pem-passphrase` among the extra options.
    /// Any other allowed key shows as "key = <hidden>", a key that is no option not at all; comments are left out and
    /// a line without '=' (which could be a password on its own) shows only that it exists.
    static func redactedOptions(_ extra: String) -> String {
        let lines = extra.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let parts = lines.map { line -> String in
            guard let eq = line.firstIndex(of: "=") else { return "<line without '=', hidden>" }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A key that is no option could itself be the secret ("JBSWY3DP… = ====").
            guard Setup.allowedOptions.contains(key) else { return "<not an option, hidden>" }
            return "\(key) = \(shownOptions.contains(key) ? value : "<hidden>")"
        }
        return parts.isEmpty ? "-" : parts.joined(separator: "; ")
    }

    /// Options whose values are settings, never secrets.
    static let shownOptions: Set<String> = Set(Setup.allowedOptions).subtracting(["password", "pem-passphrase", "otp", "username"])

    /// Collects the checks in the background, then copies the text; `done` runs on the main thread.
    static func copyToClipboard(_ done: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            let checks = Setup.checks()
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text(checks: checks), forType: .string)
                done()
            }
        }
    }
}
