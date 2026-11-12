import Foundation
import Network
import Security
import CryptoKit

/// A second opinion on a gateway certificate that differs from the one FiveT trusts.
///
/// openfortivpn only compares fingerprints: a renewed certificate and an attacker's look the same to
/// it. FiveT opens its own TLS connection to the gateway, takes the certificate it is shown (which
/// must be the one openfortivpn saw: same SHA-256), and asks macOS whether it is a real one:
/// issued by a certificate authority macOS trusts, not expired, and made out to the gateway's host
/// name, or, for a gateway reached by IP address (certificates name host names, so that check can
/// never pass), made out to a name the previously trusted certificate had. Only then does FiveT
/// trust it without asking; anything else waits for the user.
enum CertCheck {
    /// What FiveT learned about the certificate the gateway showed it.
    struct Leaf: Equatable {
        var sha256: String          // lowercase hex of the DER, the digest openfortivpn prints
        var names: [String]         // common name and DNS subject alternative names, lowercased
        var summary: String         // "CN=…, issued by …, valid until …"
        /// The chain leads to a certificate authority macOS trusts and nothing in it has expired.
        var chainTrusted: Bool
        /// …and the certificate is made out to the host name FiveT connects to.
        var trustedForHost: Bool
        var trustError: String?
    }

    enum Verdict: Equatable {
        /// A real certificate for this gateway: trust it without asking.
        case renewal(Leaf)
        /// Not provably the same gateway; `leaf` is nil when FiveT could not fetch it.
        case unverified(Leaf?, reason: String)
    }

    /// Decides whether `digest` (what openfortivpn saw) is a renewal of the certificate whose names
    /// were `pinnedNames`. Blocking: call off the main thread.
    static func judge(host: String, port: Int, sni: String?, digest: String, pinnedNames: [String]) -> Verdict {
        let leaf: Leaf
        switch fetchMatching(host: host, port: port, sni: sni, digest: digest) {
        case .failure(let v): return v
        case .success(let l): leaf = l
        }
        if leaf.trustedForHost { return .renewal(leaf) }
        guard leaf.chainTrusted else {
            return .unverified(leaf, reason: leaf.trustError ?? "macOS does not trust the new certificate")
        }
        let pinned = Set(pinnedNames.map { $0.lowercased() })
        if !pinned.isEmpty, !pinned.isDisjoint(with: leaf.names) { return .renewal(leaf) }
        return .unverified(leaf, reason: pinned.isEmpty
            ? "the new certificate is valid, but FiveT has no record of the old certificate's name to compare"
            : "the new certificate is made out to \(leaf.names.joined(separator: ", ")), not \(pinned.sorted().joined(separator: ", "))")
    }

    /// A gateway met for the first time: trusted without asking only when macOS vouches for the
    /// certificate for exactly the host name FiveT connects to (the check a browser makes). Nothing
    /// to compare with yet, so a certificate made out to a name, reached by IP address, is asked about.
    static func judgeFirstMeeting(host: String, port: Int, sni: String?, digest: String) -> Verdict {
        switch fetchMatching(host: host, port: port, sni: sni, digest: digest) {
        case .failure(let v): return v
        case .success(let leaf):
            if leaf.trustedForHost { return .renewal(leaf) }
            return .unverified(leaf, reason: leaf.chainTrusted
                ? "macOS trusts the certificate, but it is made out to \(leaf.names.joined(separator: ", ")), not to \(host)"
                : (leaf.trustError ?? "macOS does not trust the certificate"))
        }
    }

    private enum Fetched { case success(Leaf), failure(Verdict) }

    /// The certificate the gateway shows FiveT, if it is the one openfortivpn saw (same SHA-256).
    private static func fetchMatching(host: String, port: Int, sni: String?, digest: String) -> Fetched {
        guard let leaf = fetch(host: host, port: port, sni: sni) else {
            return .failure(.unverified(nil, reason: "FiveT could not fetch the gateway's certificate to check it"))
        }
        guard leaf.sha256 == digest.lowercased() else {
            // The gateway showed openfortivpn and FiveT different certificates (a gateway behind a load
            // balancer can; so can someone in the middle choosing whom to fool).
            return .failure(.unverified(nil, reason: "the gateway showed FiveT a different certificate than the VPN client"))
        }
        return .success(leaf)
    }

    /// Opens a TLS connection, takes the certificate chain the gateway presents, and closes the
    /// connection before anything is sent. nil when the gateway cannot be reached within `timeout`.
    /// `sni`: the server name openfortivpn sends (the extra option `sni`), else the host when it is a name.
    static func fetch(host: String, port: Int, sni: String? = nil, timeout: TimeInterval = 8) -> Leaf? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let queue = DispatchQueue(label: "fivet.certcheck")
        let done = DispatchSemaphore(value: 0)
        var captured: SecTrust?

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        // The server name openfortivpn sends: the `sni` option, else the host if it is a name.
        if let sni, !sni.isEmpty { sec_protocol_options_set_tls_server_name(sec, sni) }
        else if !isIPAddress(host) { sec_protocol_options_set_tls_server_name(sec, host) }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            captured = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(false)   // seen what we need: end the handshake here, nothing is ever sent
            done.signal()
        }, queue)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: done.signal()
            case .waiting: done.signal()   // no route or refused: do not sit out the timeout
            default: break
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        conn.cancel()
        guard let trust = queue.sync(execute: { captured }) else { return nil }
        return evaluate(trust, host: host)
    }

    /// Reads the leaf and asks macOS twice: for any SSL server (chain and dates), and for this host
    /// name. Only the certificate authorities that come with macOS count: not roots an app, an
    /// administrator or a device-management profile added (TLS-inspecting proxies, antivirus,
    /// debugging proxies whose keys sit on disk), which openfortivpn does not trust either.
    static func evaluate(_ trust: SecTrust, host: String) -> Leaf? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        let sha = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let anchors else { return nil }
        SecTrustSetAnchorCertificates(trust, anchors)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
        let chainTrusted = SecTrustEvaluateWithError(trust, nil)
        var hostTrusted = false
        if chainTrusted {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            hostTrusted = SecTrustEvaluateWithError(trust, nil)
        }
        let names = Self.names(of: cert)
        let until = Self.notAfter(of: cert)
        // macOS's own words for an untrusted chain are vague ("certificate is not trusted"); an
        // expired certificate is the usual reason, and the one an IT team needs to hear.
        // Never macOS's own error text: it quotes the certificate, whose maker chose every word.
        var reason = "macOS does not trust it (it is not from a certificate authority that comes with macOS, or not valid)"
        if !chainTrusted, let until, until < Date() { reason = "the certificate expired on \(Log.formatter.string(from: until).prefix(10))" }
        var summary = "made out to " + (names.isEmpty ? clean(SecCertificateCopySubjectSummary(cert) as String? ?? "?") : names.joined(separator: ", "))
        if let issuer = Self.issuer(of: cert) { summary += ", issued by \(clean(issuer))" }
        if let until { summary += ", valid until \(Log.formatter.string(from: until).prefix(10))" }
        return Leaf(sha256: sha, names: names, summary: summary, chainTrusted: chainTrusted, trustedForHost: hostTrusted,
                    trustError: chainTrusted ? nil : reason)
    }

    /// Text read off a certificate, fit to show and log: whoever made the certificate chose it, so
    /// no control or direction-changing characters, and at most 64 characters.
    static func clean(_ s: String) -> String {
        let shown = String(s.unicodeScalars.map { scalar -> Character in
            let bad = CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0x200E || scalar.value == 0x200F
            return bad ? "?" : Character(scalar)
        })
        return shown.count > 64 ? String(shown.prefix(64)) + "…" : shown
    }

    /// The common name and the DNS names in the subject alternative names, lowercased, unique,
    /// cleaned (at most 20).
    static func names(of cert: SecCertificate) -> [String] {
        Array(rawNames(of: cert).map { clean($0) }.prefix(20))
    }

    private static func rawNames(of cert: SecCertificate) -> [String] {
        var out: [String] = []
        var cn: CFString?
        if SecCertificateCopyCommonName(cert, &cn) == errSecSuccess, let cn = cn as String?, !cn.isEmpty { out.append(cn.lowercased()) }
        if let values = SecCertificateCopyValues(cert, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
           let san = values[kSecOIDSubjectAltName as String] as? [String: Any],
           let entries = san[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for e in entries where (e[kSecPropertyKeyLabel as String] as? String) == "DNS Name" {
                if let v = (e[kSecPropertyKeyValue as String] as? String)?.lowercased(), !out.contains(v) { out.append(v) }
            }
        }
        return out
    }

    private static func issuer(of cert: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [String: Any],
              let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let parts = issuer[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        let cn = parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) }
        let org = parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationName as String) }
        return (cn?[kSecPropertyKeyValue as String] as? String) ?? (org?[kSecPropertyKeyValue as String] as? String)
    }

    private static func notAfter(of cert: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let v = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let n = v[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: n.doubleValue)
    }

    static func isIPAddress(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }
}
