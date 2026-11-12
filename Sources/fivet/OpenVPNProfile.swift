import Foundation

/// OpenVPN profiles (.ovpn): importing one into a connection, checking it against what FiveT's root
/// helper allows (Setup.openvpnAllowedOptions, the same rules the helper applies), and the text FiveT
/// hands the helper to start a tunnel, the login included, which never touches the disk.
enum OpenVPNProfile {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What an import produced.
    struct Imported {
        var text: String                 // the profile to keep: every certificate and key inline
        var name: String
        var host: String                 // its first server
        var port: Int
        var username = ""                // from an auth-user-pass file or block, if the profile had one
        var password = ""
        var staticChallenge = false      // the server asks for a one-time code with the password
        var dropped: [String] = []       // options FiveT left out, and why
    }

    /// OpenVPN Connect's own copies of the profiles imported into it.
    static var openVPNConnectFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenVPN Connect/profiles", isDirectory: true)
    }

    static func openVPNConnectProfiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: openVPNConnectFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "ovpn" }.sorted { $0.path < $1.path }
    }

    /// OpenVPN Connect's saved state, where it keeps the names of its profiles.
    static var openVPNConnectState: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenVPN Connect/config.json")
    }

    /// The name OpenVPN Connect shows for each of its profiles, by the number its copy of the profile
    /// is saved under ("1781727071873.ovpn" → "1781727071873"). The copy does not say: the names, a
    /// rename made in the app included, are in config.json, whose "persist:root" holds the app's saved
    /// state as JSON inside JSON (status → profiles → one entry per profile). `profileDisplayName` is
    /// what the app lists and `profileName` the name it stores; the app itself shows the first one set.
    /// Empty when the file is missing or laid out differently (another version of the app): the
    /// import then names a profile after its server, as it did before.
    static func openVPNConnectNames(stateFile: URL = openVPNConnectState) -> [String: String] {
        guard let data = try? Data(contentsOf: stateFile), data.count <= 8_000_000,
              let top = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        /// A JSON object, or a string holding one (how the saved state nests its parts).
        func object(_ value: Any?) -> [String: Any]? {
            if let o = value as? [String: Any] { return o }
            guard let s = value as? String, let d = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let root = object((top as? [String: Any])?["persist:root"]),
              let status = object(root["status"]),
              let profiles = object(status["profiles"]) else { return [:] }
        var names: [String: String] = [:]
        for (id, entry) in profiles {
            guard let p = entry as? [String: Any] else { continue }
            // It becomes a connection's name, in the menu and the log: one short line.
            let name = ["profileDisplayName", "profileName", "name"]
                .compactMap { (p[$0] as? String).map(Connection.firstLine) }
                .first { !$0.isEmpty }
            if let name { names[id] = String(name.prefix(100)) }
        }
        return names
    }

    /// Windows-only options: OpenVPN on a Mac stops at them, and they mean nothing here.
    private static let windowsOnly: Set<String> = [
        "block-outside-dns", "register-dns", "dhcp-renew", "dhcp-release", "dhcp-pre-release", "windows-driver",
        "route-method", "ip-win32", "tap-sleep", "service", "show-net-up", "allow-nonadmin", "win-sys",
    ]
    /// Options common in profiles written for Linux that FiveT does itself or never allows: left out
    /// at import, with a note, rather than refusing the whole profile.
    private static let leftOut: [String: String] = [
        "up": "scripts", "down": "scripts", "up-delay": "scripts", "down-pre": "scripts", "up-restart": "scripts",
        "route-up": "scripts", "route-pre-down": "scripts", "ipchange": "scripts", "script-security": "scripts",
        "plugin": "plug-ins", "log": "log files", "log-append": "log files", "status": "status files",
        "status-version": "status files", "writepid": "pid files", "daemon": "running in the background",
        "user": "dropping root", "group": "dropping root", "chroot": "dropping root",
        "management": "the management interface", "management-hold": "the management interface",
        "management-query-passwords": "the management interface", "management-client": "the management interface",
    ]
    /// Options whose argument is a file: read at import and kept inline.
    private static let fileOptions: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2",
                                                   "extra-certs", "pkcs12", "crl-verify"]

    // MARK: Import

    static func importProfile(at url: URL) throws -> Imported {
        guard let data = try? Data(contentsOf: url), data.count <= Setup.ovpnMaxConfigBytes else {
            throw Failure(message: "\(url.lastPathComponent) could not be read, or is larger than an OpenVPN profile can be.")
        }
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try importProfile(text: raw, name: url.deletingPathExtension().lastPathComponent,
                                 folder: url.deletingLastPathComponent())
    }

    /// `folder`: where file names in the profile are looked up.
    static func importProfile(text raw: String, name: String, folder: URL?) throws -> Imported {
        var out: [String] = []
        var result = Imported(text: "", name: name, host: "", port: 1194)
        var dropped: [String: Set<String>] = [:]   // why → options
        var inBlock: String?
        var blockLines: [String] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // A file the profile points to (ca, cert, auth-user-pass…) is read from next to the profile
        // only: an absolute or ~-rooted path, or one a symlink walks outside that folder, could
        // otherwise read anything the user can (an SSH key, AWS credentials…), and for auth-user-pass
        // its first two lines become this connection's username and password, sent to its server.
        func readFile(_ path: String, option: String) throws -> String {
            guard let folder else {
                throw Failure(message: "The profile's \(option) is in a separate file, \(path), but this profile was not opened from a file FiveT can look next to it in. Use a profile with everything inline.")
            }
            let outsideMessage = "The profile's \(option) names a file outside its own folder (\(path)), which FiveT will not read for safety. Put everything inline in the profile instead."
            guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Failure(message: outsideMessage) }
            let base = folder.resolvingSymlinksInPath()
            let fileURL = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard fileURL.path == base.path || fileURL.path.hasPrefix(base.path + "/") else {
                throw Failure(message: outsideMessage)
            }
            guard let data = try? Data(contentsOf: fileURL) else {
                throw Failure(message: "The profile's \(option) is in a separate file, \(path), which FiveT could not read. Put the file next to the profile, or use a profile with everything inline.")
            }
            if option == "pkcs12" { return data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) }
            // Windows line ends go: a login file's "user\r" would be refused at connect as a line break.
            // So does Notepad's byte-order mark, which would become the first letter of the username.
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let b = inBlock {
                // Prefix, not exact equality: OpenVPN itself ends the block on any line starting with
                // "</name>" and discards anything after the tag on that line, so "</ca>x" must close
                // it here too, or everything up to the real next close tag is read as block content.
                if t.hasPrefix("</\(b)>") {
                    if b == "auth-user-pass" {
                        // A login written into the profile goes into the connection's fields instead.
                        let creds = blockLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        result.username = creds.first ?? ""
                        result.password = creds.count > 1 ? creds[1] : ""
                        out.append("auth-user-pass")
                    } else {
                        // The canonical tag, not the raw line: re-emitting "</ca>x" verbatim would
                        // carry the same trick into the text problems() and the helper check next.
                        out.append("<\(b)>"); out.append(contentsOf: blockLines); out.append("</\(b)>")
                    }
                    inBlock = nil; blockLines = []
                } else {
                    blockLines.append(line)
                }
                continue
            }
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") {
                // "# OVPN_ACCESS_SERVER_PROFILE=user@vpn.example.com" or a friendly-name comment.
                if let r = t.range(of: #"^#\s*(OVPN_ACCESS_SERVER_FRIENDLY_NAME|OVPN_ACCESS_SERVER_PROFILE|Friendly name)\s*[=:]\s*"#,
                                   options: [.regularExpression, .caseInsensitive]) {
                    let v = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { result.name = v }
                }
                continue
            }
            if t.hasPrefix("<"), t.hasSuffix(">"), !t.hasPrefix("</"), t != "<connection>" {
                inBlock = String(t.dropFirst().dropLast()); blockLines = []
                continue
            }
            if t == "<connection>" || t == "</connection>" { out.append(t); continue }

            let scanned = scan(t)
            var words = scanned.words
            guard !words.isEmpty else { continue }
            if words[0].hasPrefix("--") { words[0] = String(words[0].dropFirst(2)) }
            var key = words[0]
            // "setenv opt <option>" is that option, if OpenVPN knows it.
            if key == "setenv", words.count >= 3, words[1] == "opt" { key = words[2] }

            if windowsOnly.contains(key) { dropped["Windows-only", default: []].insert(key); continue }
            if let why = leftOut[key] { dropped[why, default: []].insert(key); continue }
            switch key {
            case "static-challenge":
                result.staticChallenge = true   // FiveT sends the code with the password itself
                continue
            case "askpass":
                throw Failure(message: "This profile's private key is protected by a passphrase, which FiveT does not support yet. Export the profile with an unencrypted key, or ask your VPN administrator for one.")
            case "auth-user-pass":
                if words.count >= 2 {
                    let creds = try readFile(words[1], option: "login file").components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    result.username = creds.first ?? ""
                    result.password = creds.count > 1 ? creds[1] : ""
                }
                out.append("auth-user-pass")
                continue
            default:
                break
            }
            if fileOptions.contains(key), words.count >= 2, words[0] == key, words[1] == "[inline]" {
                // "ca [inline]": the <ca> block in the profile holds it, and is all FiveT keeps.
                if key == "tls-auth", words.count >= 3 { out.append("key-direction \(words[2])") }
                continue
            }
            if fileOptions.contains(key), words.count >= 2, words[0] == key {
                let content = try readFile(words[1], option: key)
                if key == "tls-auth", words.count >= 3 { out.append("key-direction \(words[2])") }
                out.append("<\(key)>"); out.append(content); out.append("</\(key)>")
                continue
            }
            // Without a comment after the option: the helper's check counts its words as arguments.
            out.append(scanned.text.trimmingCharacters(in: .whitespaces))
        }
        if let b = inBlock { throw Failure(message: "The profile's <\(b)> block is not closed: the file looks cut off.") }

        result.text = out.joined(separator: "\n") + "\n"
        let bad = problems(result.text)
        guard bad.isEmpty else {
            throw Failure(message: "This profile uses OpenVPN options FiveT does not allow: \(bad.joined(separator: ", ")).")
        }
        guard let first = remotes(result.text).first else {
            throw Failure(message: "This profile names no server (no \"remote\" line).")
        }
        result.host = first.host
        result.port = first.port
        // OpenVPN Connect names its copies by number ("1781727071873.ovpn"): the server says more.
        if result.name.isEmpty || result.name.allSatisfy(\.isNumber) { result.name = first.host }
        result.dropped = dropped.keys.sorted().map { "\($0): \(dropped[$0]!.sorted().joined(separator: ", "))" }
        return result
    }

    /// A new connection from an import, named apart from the ones in `taken`.
    static func connection(from imp: Imported, taken: [String]) -> Connection {
        var c = Connection()
        c.kind = .openvpn
        var name = imp.name.trimmed.isEmpty ? imp.host : imp.name.trimmed
        if taken.contains(name) {
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            name = "\(name) \(n)"
        }
        c.name = name
        apply(imp, to: &c)
        return c
    }

    /// The imported profile into `c` (a new connection, or Replace Profile… on one): a login found
    /// in the profile fills empty fields only, and a server that asks for a one-time code with the
    /// password gets it sent that way (OpenVPN's static challenge), once a secret is entered.
    static func apply(_ imp: Imported, to c: inout Connection) {
        c.ovpnProfile = imp.text
        c.host = imp.host
        c.port = imp.port
        c.realm = ""
        if c.username.isEmpty { c.username = imp.username }
        if c.password.isEmpty { c.password = imp.password }
        if imp.staticChallenge && c.otpMode == .none { c.otpMode = .separate }
    }

    // MARK: Checks

    /// What the root helper would refuse in `text`, the same rules as its ovpn-run check.
    static func problems(_ text: String) -> [String] {
        let ok = Set(Setup.openvpnAllowedOptions)
        let blocks = Set(Setup.openvpnInlineBlocks)
        let inlineOnly = Set(Setup.openvpnInlineOnly)
        var bad: [String] = []
        func add(_ w: String) { if !bad.contains(w) { bad.append(w) } }
        var inBlock: String?
        var conn = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            // OpenVPN ends an inline block on any line that starts with "</name>", not only a line
            // that is exactly that, discarding anything after the tag on that same line: "</ca>x"
            // closes it. An exact-match check here would read everything up to the next real close
            // tag as block content, hiding whatever it holds from the checks below.
            if let b = inBlock { if t.hasPrefix("</\(b)>") { inBlock = nil }; continue }
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") { continue }
            if t == "<connection>" { if conn { add("nested <connection>") }; conn = true; continue }
            if t == "</connection>" { if !conn { add("</connection>") }; conn = false; continue }
            if t.range(of: "^<[A-Za-z0-9-]+>$", options: .regularExpression) != nil {
                let name = String(t.dropFirst().dropLast())
                if !blocks.contains(name) { add("<\(name)>") }
                inBlock = name; continue
            }
            if t.hasPrefix("<") { add("a line starting with <"); continue }
            // tokens(), not a raw whitespace split: OpenVPN unquotes each word before reading it, so a
            // quoted "opt" right after setenv (or a quoted option name) must not hide from this list.
            var w = tokens(t)
            guard !w.isEmpty else { continue }
            if w[0].hasPrefix("--") { w[0] = String(w[0].dropFirst(2)) }
            if w[0] == "setenv", w.count >= 2, w[1] == "opt" {
                if w.count < 3 { continue }
                w.removeFirst(2)
                if w[0].hasPrefix("--") { w[0] = String(w[0].dropFirst(2)) }
            }
            let key = w[0]
            guard ok.contains(key) else { add(key); continue }
            if inlineOnly.contains(key) && w.count > 1 { add("\(key) with a file") }
            // No argument is refused too, as the helper does.
            let arg = w.count > 1 ? w[1] : ""
            if key == "dev", arg.range(of: "^tun[0-9]*$", options: .regularExpression) == nil { add("dev \(arg)") }
            if key == "dev-type", arg != "tun" { add("dev-type \(arg)") }
            if (key == "http-proxy" || key == "socks-proxy") && w.count > 3 { add("\(key) with a password file") }
        }
        if let b = inBlock { add("unclosed <\(b)>") }
        if conn { add("unclosed <connection>") }
        return bad
    }

    /// The profile asks for a username and password (an auth-user-pass line).
    static func needsLogin(_ text: String) -> Bool {
        directives(text).contains { $0.first == "auth-user-pass" }
    }

    /// The profile itself sends all traffic through the tunnel (servers often push this instead).
    static func redirectsGateway(_ text: String) -> Bool {
        directives(text).contains { $0.first == "redirect-gateway" }
    }

    /// Its servers in order: host, port, protocol ("udp" unless the profile says otherwise).
    static func remotes(_ text: String) -> [(host: String, port: Int, proto: String)] {
        var port = 1194
        var proto = "udp"
        var hosts: [(String, Int?, String?)] = []
        for d in directives(text) {
            switch d.first {
            case "port", "rport": if d.count > 1, let p = Int(d[1]) { port = p }
            case "proto": if d.count > 1 { proto = d[1] }
            case "remote": if d.count > 1 { hosts.append((d[1], d.count > 2 ? Int(d[2]) : nil, d.count > 3 ? d[3] : nil)) }
            default: break
            }
        }
        return hosts.map { (host: $0.0, port: $0.1 ?? port, proto: ($0.2 ?? proto).hasPrefix("tcp") ? "tcp" : "udp") }
    }

    /// Every host OpenVPN itself connects to: the servers, or the proxy it reaches them through.
    static func serverHosts(_ text: String) -> [String] {
        let proxies = directives(text).filter { ["http-proxy", "socks-proxy"].contains($0[0]) && $0.count > 1 }.map { $0[1] }
        return proxies.isEmpty ? remotes(text).map(\.host) : proxies
    }

    // MARK: Launch

    /// The profile as FiveT hands it to the helper: the login inline (username, then the password,
    /// with the one-time code appended or as OpenVPN's static-challenge answer), never on disk.
    static func forLaunch(_ c: Connection, code: String?) -> String {
        var text = c.ovpnProfile
        guard needsLogin(text) else { return text }
        // The bare auth-user-pass line would make OpenVPN ask on the console: the inline block replaces it.
        var lines: [String] = []
        var inBlock: String?
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let b = inBlock { if t == "</\(b)>" { inBlock = nil }; lines.append(line); continue }
            if t.range(of: "^<[A-Za-z0-9-]+>$", options: .regularExpression) != nil, t != "<connection>" {
                inBlock = String(t.dropFirst().dropLast())
            }
            let w = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if w.first.map(String.init)?.replacingOccurrences(of: "--", with: "") == "auth-user-pass" && inBlock == nil { continue }
            lines.append(line)
        }
        var password = c.password
        if let code {
            switch c.otpMode {
            case .appendToPassword: password += code
            case .separate:
                password = "SCRV1:" + Data(c.password.utf8).base64EncodedString() + ":" + Data(code.utf8).base64EncodedString()
            case .none: break
            }
        }
        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text + "<auth-user-pass>\n\(c.username.trimmed)\n\(password)\n</auth-user-pass>\n"
    }

    // MARK: Parsing

    /// Every option line outside inline blocks (those inside <connection> too), as words.
    private static func directives(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var inBlock: String?
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let b = inBlock { if t == "</\(b)>" { inBlock = nil }; continue }
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") || t == "<connection>" || t == "</connection>" { continue }
            if t.hasPrefix("<"), t.hasSuffix(">") { inBlock = String(t.dropFirst().dropLast()); continue }
            var w = tokens(t)
            if let f = w.first, f.hasPrefix("--") { w[0] = String(f.dropFirst(2)) }
            if !w.isEmpty { out.append(w) }
        }
        return out
    }

    /// A line split into words the way OpenVPN reads it: spaces separate, "double" or 'single'
    /// quotes keep a word together, and a backslash escapes the next character outside single quotes.
    static func tokens(_ line: String) -> [String] { scan(line).words }

    /// …and the line without the comment OpenVPN ends it at: a "#" or ";" where a new word would start.
    private static func scan(_ line: String) -> (words: [String], text: Substring) {
        var words: [String] = []
        var cur = ""
        var have = false
        var quote: Character?
        var escape = false
        var end = line.endIndex
        for i in line.indices {
            let ch = line[i]
            if escape { cur.append(ch); escape = false; have = true; continue }
            if !have, quote == nil, ch == "#" || ch == ";" { end = i; break }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; have = true; continue }
            if ch == " " || ch == "\t" {
                if have { words.append(cur); cur = ""; have = false }
                continue
            }
            cur.append(ch); have = true
        }
        if have { words.append(cur) }
        return (words, line[..<end])
    }
}
