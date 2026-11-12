import Foundation

enum OTPMode: String, Codable, CaseIterable, Identifiable {
    case none
    case appendToPassword
    case separate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None (static password only)"
        case .appendToPassword: return "Append TOTP code to password"
        case .separate: return "Send TOTP code as second step"
        }
    }
}

/// What a connection logs in to: a FortiGate SSL-VPN (openfortivpn), an OpenVPN server, or a
/// V2Ray server (VLESS, VMess, Trojan, Shadowsocks, Hysteria2; run by Xray).
enum VPNKind: String, Codable {
    case fortinet
    case openvpn
    case v2ray
}

struct Connection: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "New connection"
    var kind: VPNKind = .fortinet
    /// OpenVPN: the profile as imported, with every certificate and key inline (OpenVPNProfile).
    /// `host` and `port` hold its first server, for display and for the failed-login count.
    var ovpnProfile: String = ""
    /// V2Ray: the server as an Xray outbound (JSON), from a link or a JSON config
    /// (V2RayConfig). `host` and `port` hold its server, for display.
    var v2rayOutbound: String = ""
    /// The share link it was imported from (empty for a JSON config), for Copy Link.
    var v2rayLink: String = ""
    /// The subscription URL it came from, if any: Refresh replaces what it lists.
    var v2raySubscription: String = ""
    /// Iranian sites (.ir and Iranian addresses) skip the V2Ray server and go direct.
    var v2rayIranDirect: Bool = true   // no longer used: Settings → General → Bypass Iranian Websites replaced it (read once, to carry the choice over)
    var host: String = ""
    var port: Int = 10443
    var realm: String = ""
    var username: String = ""
    var password: String = ""
    var totpSecret: String = ""
    var otpMode: OTPMode = .none
    /// SHA-256 digest of the gateway certificate, learned on first connect. Empty for a gateway
    /// whose certificate openfortivpn verifies itself (public CA and matching host name).
    var trustedCert: String = ""
    /// The gateway ("host:port", see `gatewayKey`) FiveT has logged in to, with `trustedCert` or a
    /// certificate openfortivpn verified itself. Another certificate from it is a change to review,
    /// never a first meeting. After the host or port is edited, the gateway is a new one.
    var trustedCertHost: String = ""
    /// The names the trusted certificate is made out to (common name, DNS alternative names). A
    /// different certificate is accepted without asking only when macOS vouches for it and it
    /// carries one of these names (CertCheck).
    var trustedCertNames: [String] = []
    /// A certificate the gateway showed that FiveT did not trust by itself: waiting for the user's
    /// decision (Review New Certificate… in the menu or Settings). Empty when there is none.
    var pendingCert: String = ""
    /// The gateway `pendingCert` came from; the review is moot once the host or port is edited.
    var pendingCertHost: String = ""
    /// True when `pendingCert` is from a gateway FiveT had never logged in to (not a change).
    var pendingCertFirst: Bool = false
    /// What FiveT knows about `pendingCert`, for the review: names, issuer, expiry, why it was not trusted.
    var pendingCertInfo: String = ""
    /// Extra openfortivpn config lines appended verbatim (advanced).
    var extraConfig: String = ""
    /// Split DNS: domains (comma/space separated) that must be resolved through the tunnel's
    /// DNS servers while connected, via /etc/resolver/<domain>. See VPNManager.applySplitDNS.
    var dnsDomains: String = ""
    /// History, kept for list_connections and the Settings window.
    var lastConnectedAt: Date? = nil
    var lastError: String? = nil
    /// The gateway and the way of sending the one-time code that last got a login through
    /// (`otpAcceptedKey` as it was then). Editing the gateway or the way makes it stale again.
    var acceptedOTP: String = ""

    var usesTOTP: Bool { otpMode != .none }
    /// "host:port" and the way the code is sent, as they are set now.
    var otpAcceptedKey: String { "\(gatewayKey) \(otpMode.rawValue)" }
    /// The gateway has taken a login with the code sent this way before: one refusal after that is
    /// more likely the password, the account or the gateway than the way the code goes out.
    var otpModeAccepted: Bool { usesTOTP && acceptedOTP == otpAcceptedKey }
    var isOpenVPN: Bool { kind == .openvpn }
    var isV2Ray: Bool { kind == .v2ray }
    /// Listed on the VPN tab (OpenVPN and V2Ray), not the Forti tab.
    var isOtherVPN: Bool { kind != .fortinet }

    /// Cleaned list of split-DNS domains: lowercase, no leading dot, only valid host characters.
    var dnsDomainList: [String] { Self.cleanDomains([dnsDomains]) }

    /// Splits free text (commas, spaces, semicolons, newlines) into unique, valid domain names.
    /// Also used for the DNS suffixes a gateway pushes.
    static func cleanDomains(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" }) }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty && !$0.contains("..") && $0.contains(".") && !$0.hasSuffix(".")
                      && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } }
            .filter { seen.insert($0).inserted }
    }

    // MARK: Pasted text

    /// The first line of `raw` that is not blank, trimmed: what a paste of "name\n\n" means. A text
    /// field shows only the first line of what is pasted into it, so a paste that carried blank
    /// lines (or the same line twice) looks right on screen while the saved value holds all of it.
    static func firstLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// A gateway as typed or pasted: one line, and without the word "remote" in front when the text
    /// is a line copied from an OpenVPN profile ("remote link1.example.com").
    static func cleanedHost(_ raw: String) -> String {
        let line = firstLine(raw)
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.count >= 2, words[0].lowercased() == "remote" { return String(words[1]) }
        return line
    }

    /// How many line breaks the text fields hold. A paste that carried blank lines raises it, and
    /// cleaning lowers it again.
    var lineBreakCount: Int {
        [name, host, realm, username, password, totpSecret].reduce(0) { $0 + $1.filter(\.isNewline).count }
    }

    /// Takes the line breaks out of what was pasted into the fields. openfortivpn's config holds one
    /// setting per line, so a value with a line break can never be used (launch() refuses it), and a
    /// field hides all but a paste's first line. Only a value that needs it changes, so typing (a
    /// space inside a user name, say) is left alone. A line break inside a password or a secret is
    /// ambiguous and stays for launch() to refuse. Returns the labels of what changed, never a value.
    @discardableResult
    mutating func cleanPastedFields() -> [String] {
        var changed: [String] = []
        func clean(_ label: String, _ value: String, _ cleaned: String) -> String {
            if cleaned != value { changed.append(label) }
            return cleaned
        }
        func oneLine(_ value: String) -> String { value.contains(where: \.isNewline) ? Self.firstLine(value) : value }
        name = clean("name", name, oneLine(name))
        host = clean("gateway", host, Self.cleanedHost(host))
        realm = clean("realm", realm, oneLine(realm))
        username = clean("username", username, oneLine(username))
        password = clean("password", password, password.trimmingCharacters(in: .newlines))
        // A pasted otpauth:// link is read by the secret field itself (Settings), as it came.
        if !totpSecret.lowercased().contains("otpauth") {
            let secret = totpSecret.contains(where: \.isNewline)
                ? totpSecret.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces) : totpSecret
            totpSecret = clean("TOTP secret", totpSecret, secret)
        }
        return changed
    }

    var gatewayDescription: String {
        realm.isEmpty ? "\(host):\(port)" : "\(host):\(port)/\(realm)"
    }

    /// Where openfortivpn really connects: the host and port fields, unless the extra options set
    /// `host`, `port` or `sni` (later config lines override earlier ones).
    var endpoint: (host: String, port: Int, sni: String?) {
        var h = host.trimmed, p = port
        var sni: String?
        for (key, value) in Self.optionLines(extraConfig) {
            switch key {
            case "host": h = value
            case "port": p = Int(value) ?? p
            case "sni": sni = value.isEmpty ? nil : value
            default: break
            }
        }
        return (h, p, sni)
    }

    /// The gateway a certificate pin belongs to: "host:port" as openfortivpn connects to it.
    var gatewayKey: String {
        let e = endpoint
        return "\(e.host.lowercased()):\(e.port)"
    }

    /// FiveT has logged in to this gateway before (as it is set now).
    var knowsGateway: Bool { !trustedCertHost.isEmpty && trustedCertHost == gatewayKey }

    /// True when a certificate is pinned for the gateway as it is set now.
    var hasPinForGateway: Bool { !trustedCert.isEmpty && knowsGateway }

    /// A certificate from this gateway waits for the user's decision.
    var hasPendingReview: Bool { !pendingCert.isEmpty && pendingCertHost == gatewayKey }

    /// Trusts `digest` for the current gateway (a renewal macOS vouched for, or the user's review).
    mutating func trust(_ digest: String, names: [String]) {
        trustedCert = digest.lowercased()
        trustedCertHost = gatewayKey
        trustedCertNames = names
        clearPendingReview()
    }

    /// Logged in with a certificate openfortivpn verified itself (public CA, matching host name):
    /// from now on this gateway is known, so a certificate it has to be asked about is a change.
    mutating func markGatewayVerified() {
        guard !knowsGateway else { return }
        trustedCert = ""
        trustedCertNames = []
        trustedCertHost = gatewayKey
    }

    mutating func setPendingReview(_ digest: String, first: Bool, info: String) {
        pendingCert = digest.lowercased()
        pendingCertHost = gatewayKey
        pendingCertFirst = first
        pendingCertInfo = info
    }

    mutating func clearPendingReview() {
        pendingCert = ""
        pendingCertHost = ""
        pendingCertFirst = false
        pendingCertInfo = ""
    }

    /// Settings → Forget: the next connect meets the gateway as for the first time (and asks).
    mutating func forgetCertificate() {
        trustedCert = ""
        trustedCertHost = ""
        trustedCertNames = []
        clearPendingReview()
    }

    // MARK: Extra openfortivpn options

    /// The "key = value" lines of the extra options, keys lowercased; comments and lines without
    /// '=' left out.
    static func optionLines(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { return nil }
            return (key, line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// The extra options as they go to openfortivpn: only "key = value" lines. openfortivpn
    /// ignores anything else, but first repeats it in its log ("Bad line in configuration file:
    /// "…""), and a line without '=' may well be a password pasted in the wrong place.
    var extraConfigForOpenfortivpn: String {
        Self.optionLines(extraConfig).map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }
}

extension Connection: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, realm, username, password, totpSecret, otpMode, trustedCert, extraConfig
        case dnsDomains, lastConnectedAt, lastError, kind, ovpnProfile, acceptedOTP
        case v2rayOutbound, v2rayLink, v2raySubscription, v2rayIranDirect
        case trustedCertHost, trustedCertNames, pendingCert, pendingCertHost, pendingCertFirst, pendingCertInfo
    }

    // Tolerant decoding so older files keep loading when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Connection"
        kind = try c.decodeIfPresent(VPNKind.self, forKey: .kind) ?? .fortinet
        ovpnProfile = try c.decodeIfPresent(String.self, forKey: .ovpnProfile) ?? ""
        v2rayOutbound = try c.decodeIfPresent(String.self, forKey: .v2rayOutbound) ?? ""
        v2rayLink = try c.decodeIfPresent(String.self, forKey: .v2rayLink) ?? ""
        v2raySubscription = try c.decodeIfPresent(String.self, forKey: .v2raySubscription) ?? ""
        v2rayIranDirect = try c.decodeIfPresent(Bool.self, forKey: .v2rayIranDirect) ?? true
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 10443
        realm = try c.decodeIfPresent(String.self, forKey: .realm) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        totpSecret = try c.decodeIfPresent(String.self, forKey: .totpSecret) ?? ""
        otpMode = try c.decodeIfPresent(OTPMode.self, forKey: .otpMode) ?? .none
        trustedCert = try c.decodeIfPresent(String.self, forKey: .trustedCert) ?? ""
        extraConfig = try c.decodeIfPresent(String.self, forKey: .extraConfig) ?? ""
        dnsDomains = try c.decodeIfPresent(String.self, forKey: .dnsDomains) ?? ""
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        trustedCertNames = try c.decodeIfPresent([String].self, forKey: .trustedCertNames) ?? []
        pendingCert = try c.decodeIfPresent(String.self, forKey: .pendingCert) ?? ""
        pendingCertHost = try c.decodeIfPresent(String.self, forKey: .pendingCertHost) ?? ""
        pendingCertFirst = try c.decodeIfPresent(Bool.self, forKey: .pendingCertFirst) ?? false
        pendingCertInfo = try c.decodeIfPresent(String.self, forKey: .pendingCertInfo) ?? ""
        trustedCertHost = try c.decodeIfPresent(String.self, forKey: .trustedCertHost) ?? ""
        // Saved before 1.8: a gateway with a pin, or one logged in to before, is the gateway as it
        // is set now.
        if !c.contains(.trustedCertHost) && (!trustedCert.isEmpty || lastConnectedAt != nil) { trustedCertHost = gatewayKey }
        // Saved before the accepted way was remembered: a connection that has connected before did so
        // the way it is saved.
        acceptedOTP = try c.decodeIfPresent(String.self, forKey: .acceptedOTP) ?? ""
        if !c.contains(.acceptedOTP) && lastConnectedAt != nil { acceptedOTP = otpAcceptedKey }
    }
}

extension Connection {
    /// Seeded into connections.json on first launch.
    static var seeds: [Connection] {
        #if DISTRIBUTION
        // Builds made for other people (build.sh --dmg) start with no connections.
        return []
        #else
        // Real seeds live in LocalSeeds.swift, which is git-ignored (build.sh creates an empty one).
        return LocalSeeds.connections
        #endif
    }
}
