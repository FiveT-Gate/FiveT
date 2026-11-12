import Foundation

/// Reads FortiClient's SSL-VPN profiles so they can become FiveT connections.
///
/// Two sources: the store FortiClient keeps on this Mac (a plist, world-readable, no passwords)
/// and a configuration backup made in FortiClient → Settings → Backup (an XML file; passwords in
/// it are encrypted and are left empty here). IPsec profiles are skipped: openfortivpn speaks
/// SSL-VPN only.
enum FortiClientImport {
    static let localStore = "/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

    static var localStoreExists: Bool { FileManager.default.isReadableFile(atPath: localStore) }

    struct Outcome {
        var imported: [Connection] = []
        var skipped: [String] = []     // already present (same gateway and user)
        var ignored: [String] = []     // not SSL-VPN

        var summary: String {
            var lines: [String] = []
            if !imported.isEmpty { lines.append("Imported: " + imported.map(\.name).joined(separator: ", ") + ".") }
            if !skipped.isEmpty { lines.append("Already present, skipped: " + skipped.joined(separator: ", ") + ".") }
            if !ignored.isEmpty { lines.append("Not SSL-VPN, ignored: " + ignored.joined(separator: ", ") + ".") }
            if imported.isEmpty && skipped.isEmpty && ignored.isEmpty { lines.append("No VPN profiles found.") }
            if !imported.isEmpty { lines.append("FortiClient never hands out passwords: enter the password (and the TOTP secret, if any) for each imported connection.") }
            return lines.joined(separator: "\n")
        }
    }

    enum ImportError: LocalizedError {
        case unreadable(String), encrypted, unknownFormat

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Could not read the file: \(why)"
            case .encrypted: return "This backup is encrypted. In FortiClient, make the backup again without a password, then import that file."
            case .unknownFormat: return "This is not a FortiClient configuration (expected a FortiClient backup .conf/.xml or its vpn.plist)."
            }
        }
    }

    /// A profile as FortiClient describes it, before it becomes a Connection.
    struct Profile {
        var name: String
        var server: String     // "host", "host:port", "host/realm", "host:port/realm"; several may be joined by ";"
        var port: Int?
        var username: String
        var isSSL: Bool
    }

    // MARK: Sources

    static func readLocalStore() throws -> [Profile] {
        try read(url: URL(fileURLWithPath: localStore))
    }

    /// Detects the format from the content: a plist (binary or XML plist) or FortiClient's backup XML.
    static func read(url: URL) throws -> [Profile] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ImportError.unreadable(error.localizedDescription) }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return profiles(fromPlist: plist)
        }
        let head = String(decoding: data.prefix(512), as: UTF8.self)
        if head.contains("<forticlient_configuration") || head.contains("<sslvpn") || head.contains("<vpn>") {
            return profiles(fromBackupXML: data)
        }
        if head.hasPrefix("<?xml") { return profiles(fromBackupXML: data) }
        // FortiClient writes an encrypted backup as base64-ish text without any XML.
        if !head.contains("<") && !head.isEmpty { throw ImportError.encrypted }
        throw ImportError.unknownFormat
    }

    /// FortiClient on macOS: vpn.plist → Profiles → { Name, Server, ServerPort, EnableCustomPort, User, VpnType }.
    static func profiles(fromPlist plist: [String: Any]) -> [Profile] {
        guard let profiles = plist["Profiles"] as? [String: Any] else { return [] }
        return profiles.compactMap { key, value -> Profile? in
            guard let p = value as? [String: Any] else { return nil }
            let name = (p["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            let server = (p["Server"] as? String) ?? ""
            // plist numbers and booleans both arrive as NSNumber.
            let customPort = (p["EnableCustomPort"] as? NSNumber)?.boolValue ?? true
            let port = customPort ? (p["ServerPort"] as? NSNumber)?.intValue : nil
            let type = (p["VpnType"] as? NSNumber)?.intValue ?? 0
            return Profile(name: name, server: server, port: port,
                           username: (p["User"] as? String) ?? "", isSSL: type == 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// FortiClient backup: <forticlient_configuration><vpn><sslvpn><connections><connection>…
    /// (and <ipsecvpn>, which is reported but not imported).
    static func profiles(fromBackupXML data: Data) -> [Profile] {
        let parser = XMLParser(data: data)
        let delegate = BackupXMLDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.profiles
    }

    private final class BackupXMLDelegate: NSObject, XMLParserDelegate {
        var profiles: [Profile] = []
        private var path: [String] = []
        private var current: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name.lowercased())
            text = ""
            if name.lowercased() == "connection" { current = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let n = name.lowercased()
            if path.count >= 2, path[path.count - 2] == "connection" {
                current[n] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if n == "connection" {
                let ssl = path.contains("sslvpn")
                let ipsec = path.contains("ipsecvpn")
                if ssl || ipsec {
                    profiles.append(Profile(name: current["name"] ?? "Imported connection",
                                            server: current["server"] ?? current["remote_gw"] ?? "",
                                            port: (current["port"]).flatMap(Int.init),
                                            username: current["username"] ?? current["user"] ?? "",
                                            isSSL: ssl))
                }
            }
            path.removeLast()
            text = ""
        }
    }

    // MARK: Conversion

    /// "host:10443/realm" → (host, port, realm). Several servers joined by ";" → the first one.
    static func parseServer(_ raw: String) -> (host: String, port: Int?, realm: String) {
        var s = raw.split(separator: ";").first.map(String.init) ?? raw
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        var realm = ""
        if let slash = s.firstIndex(of: "/") {
            realm = String(s[s.index(after: slash)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            s = String(s[..<slash])
        }
        var port: Int?
        if let colon = s.lastIndex(of: ":"), let p = Int(s[s.index(after: colon)...]), s.filter({ $0 == ":" }).count == 1 {
            port = p
            s = String(s[..<colon])
        }
        return (s, port, realm)
    }

    static func connection(from p: Profile) -> Connection {
        let (host, portInServer, realm) = parseServer(p.server)
        var c = Connection()
        c.name = p.name
        c.host = host
        c.port = portInServer ?? p.port ?? 443
        c.realm = realm
        c.username = p.username
        c.cleanPastedFields()
        return c
    }

    /// Adds the SSL profiles that are not already saved (same host, port, realm and user).
    static func merge(_ profiles: [Profile], into store: ConnectionStore) -> Outcome {
        var out = Outcome()
        for p in profiles {
            guard p.isSSL else { out.ignored.append(p.name); continue }
            var c = connection(from: p)
            guard !c.host.isEmpty else { out.ignored.append(p.name); continue }
            let same = store.connections.first {
                $0.host.caseInsensitiveCompare(c.host) == .orderedSame && $0.port == c.port
                    && $0.realm.caseInsensitiveCompare(c.realm) == .orderedSame
                    && $0.username.caseInsensitiveCompare(c.username) == .orderedSame
            }
            if let same { out.skipped.append("\(p.name) (= \(same.name))"); continue }
            if store.connections.contains(where: { $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) {
                c.name += " (FortiClient)"
            }
            store.connections.append(c)
            out.imported.append(c)
        }
        if !out.imported.isEmpty {
            Log.shared.write("imported from FortiClient: \(out.imported.map { "\($0.name) → \($0.gatewayDescription)" }.joined(separator: ", "))")
        }
        return out
    }
}
