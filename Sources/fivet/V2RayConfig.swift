import Foundation

/// V2Ray connections, run by Xray. Share links (vless:// vmess:// trojan:// ss:// hysteria2://),
/// Xray JSON files and subscriptions each become a connection. A
/// connection keeps only its server, as an Xray outbound (`Connection.v2rayOutbound`); the root
/// helper puts it into FiveT's own config (TUN, routing, DNS) at connect time, so nothing an import
/// brings decides what runs as root.
enum V2RayConfig {
    struct Imported {
        var name: String
        /// The share link it came from; empty for a JSON config.
        var link: String = ""
        var outbound: [String: Any]
        var host: String
        var port: Int
        /// The subscription it came from, to refresh it later.
        var subscription: String = ""
        /// The link asks to skip the server's certificate check, which Xray no longer does.
        var insecure = false
        /// An Outline key with a `prefix` (bytes Outline puts in front of the first packet so a firewall
        /// does not see Shadowsocks). Xray does not send it: the server still answers, but a network
        /// that blocks plain Shadowsocks will not let it through.
        var prefix = false
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// The server protocols FiveT runs (the helper accepts the same ones).
    static let protocols: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "hysteria"]
    static let schemes = ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2"]

    // MARK: Share links

    static func isLink(_ s: String) -> Bool {
        guard let r = s.range(of: "://") else { return false }
        return schemes.contains(s[..<r.lowerBound].lowercased())
    }

    /// One share link as an Xray outbound.
    static func parse(link raw: String) throws -> Imported {
        var imp = try parseLink(raw)
        let low = raw.lowercased()
        imp.insecure = ["allowinsecure=1", "allowinsecure=true", "insecure=1", "insecure=true", "\"allowinsecure\":\"1\"", "\"allowinsecure\":true"]
            .contains { low.contains($0) } || (low.hasPrefix("vmess://") && (decodeBase64(String(raw.dropFirst(8)).components(separatedBy: "#")[0])?
                .replacingOccurrences(of: " ", with: "").lowercased().contains("\"allowinsecure\":\"1\"") ?? false))
        return imp
    }

    private static func parseLink(_ raw: String) throws -> Imported {
        let s = raw.trimmed
        guard let r = s.range(of: "://") else { throw Failure("Not a V2Ray link.") }
        let scheme = s[..<r.lowerBound].lowercased()
        let body = String(s[r.upperBound...])
        switch scheme {
        case "vmess":
            if let json = decodeBase64(body.components(separatedBy: "#")[0]),
               let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                return try vmessJSON(obj, link: s)
            }
            return try urlStyle(protocol: "vmess", body: body, link: s)
        case "vless": return try urlStyle(protocol: "vless", body: body, link: s)
        case "trojan": return try urlStyle(protocol: "trojan", body: body, link: s)
        case "ss": return try shadowsocks(body, link: s)
        case "hysteria2", "hy2": return try urlStyle(protocol: "hysteria", body: body, link: s)
        default: throw Failure("\(scheme):// links are not supported.")
        }
    }

    /// The parts of "user@host:port/?query#name", decoded. Done by hand: names are often raw
    /// Persian text or emoji, which URLComponents refuses.
    private struct LinkParts {
        var user = "", host = "", port = 0, name = ""
        var query: [String: String] = [:]
    }

    private static func split(_ body: String) throws -> LinkParts {
        var p = LinkParts()
        var rest = body
        if let h = rest.firstIndex(of: "#") {
            let frag = String(rest[rest.index(after: h)...])
            p.name = (frag.removingPercentEncoding ?? frag).trimmed
            rest = String(rest[..<h])
        }
        if let q = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let k = kv.first, !k.isEmpty else { continue }
                let v = kv.count > 1 ? kv[1] : ""
                p.query[k] = v.removingPercentEncoding ?? v
            }
            rest = String(rest[..<q])
        }
        // The path starts at the first "/" after the "@": an older Shadowsocks link keeps its
        // user part in plain base64, which can hold a "/" itself.
        if let slash = rest[(rest.lastIndex(of: "@") ?? rest.startIndex)...].firstIndex(of: "/") { rest = String(rest[..<slash]) }
        var hostPort = rest
        if let at = rest.lastIndex(of: "@") {
            let u = String(rest[..<at])
            p.user = u.removingPercentEncoding ?? u
            hostPort = String(rest[rest.index(after: at)...])
        }
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            p.host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") { p.port = Int(after.dropFirst()) ?? 0 }
        } else if let colon = hostPort.lastIndex(of: ":") {
            p.host = String(hostPort[..<colon])
            p.port = Int(hostPort[hostPort.index(after: colon)...]) ?? 0
        } else {
            p.host = hostPort
        }
        guard !p.host.isEmpty, (1...65535).contains(p.port) else { throw Failure("The link has no server address and port.") }
        return p
    }

    private static func urlStyle(protocol proto: String, body: String, link: String) throws -> Imported {
        let p = try split(body)
        let q = p.query
        var out: [String: Any] = ["protocol": proto]
        let server: [String: Any] = ["address": p.host, "port": p.port]
        switch proto {
        case "vless":
            guard !p.user.isEmpty else { throw Failure("The VLESS link has no user ID.") }
            var user: [String: Any] = ["id": p.user, "encryption": q["encryption"].nonEmpty ?? "none"]
            if let flow = q["flow"].nonEmpty { user["flow"] = flow }
            out["settings"] = ["vnext": [server.merging(["users": [user]]) { a, _ in a }]]
            out["streamSettings"] = try stream(q, network: q["type"] ?? "tcp", security: q["security"] ?? "none")
        case "vmess":
            guard !p.user.isEmpty else { throw Failure("The VMess link has no user ID.") }
            let user: [String: Any] = ["id": p.user, "security": q["encryption"].nonEmpty ?? "auto"]
            out["settings"] = ["vnext": [server.merging(["users": [user]]) { a, _ in a }]]
            out["streamSettings"] = try stream(q, network: q["type"] ?? "tcp", security: q["security"] ?? "none")
        case "trojan":
            guard !p.user.isEmpty else { throw Failure("The Trojan link has no password.") }
            out["settings"] = ["servers": [server.merging(["password": p.user]) { a, _ in a }]]
            out["streamSettings"] = try stream(q, network: q["type"] ?? "tcp", security: q["security"] ?? "tls")
        default:   // hysteria2: the server in settings, the password in hysteriaSettings, QUIC over TLS (h3)
            out["settings"] = ["version": 2, "address": p.host, "port": p.port]
            var hq = q
            if hq["alpn"].nonEmpty == nil { hq["alpn"] = "h3" }
            var s = try stream(hq, network: "hysteria", security: "tls")
            var hs: [String: Any] = ["version": 2]
            if !p.user.isEmpty { hs["auth"] = p.user }
            s["hysteriaSettings"] = hs
            if let obfs = q["obfs"].nonEmpty {
                guard obfs == "salamander", let pw = q["obfs-password"].nonEmpty else {
                    throw Failure("The Hysteria2 link uses \(obfs) obfuscation, which is not supported.")
                }
                s["finalmask"] = ["udp": [["type": "salamander", "settings": ["password": pw]]]]
            }
            out["streamSettings"] = s
        }
        return Imported(name: p.name, link: link, outbound: out, host: p.host, port: p.port)
    }

    /// vmess://base64(JSON), the v2rayN format: v, ps, add, port, id, aid, scy, net, type, host, path, tls, sni, alpn, fp.
    private static func vmessJSON(_ j: [String: Any], link: String) throws -> Imported {
        func f(_ k: String) -> String {
            if let s = j[k] as? String { return s.trimmed }
            if let n = j[k] as? NSNumber { return n.stringValue }
            return ""
        }
        let host = f("add"), port = Int(f("port")) ?? 0
        guard !host.isEmpty, (1...65535).contains(port), !f("id").isEmpty else { throw Failure("The VMess link is missing its server, port or ID.") }
        var q: [String: String] = ["host": f("host"), "path": f("path"), "sni": f("sni"), "alpn": f("alpn"), "fp": f("fp")]
        let net = f("net").isEmpty ? "tcp" : f("net")
        switch net {
        case "grpc": q["serviceName"] = f("path"); q["mode"] = f("type")
        case "kcp": q["headerType"] = f("type"); q["seed"] = f("path")
        case "xhttp", "splithttp": q["mode"] = f("type")
        default: q["headerType"] = f("type")
        }
        let user: [String: Any] = ["id": f("id"), "alterId": Int(f("aid")) ?? 0, "security": f("scy").isEmpty ? "auto" : f("scy")]
        let out: [String: Any] = [
            "protocol": "vmess",
            "settings": ["vnext": [["address": host, "port": port, "users": [user]]]],
            "streamSettings": try stream(q, network: net, security: f("tls")),
        ]
        return Imported(name: f("ps"), link: link, outbound: out, host: host, port: port)
    }

    /// ss://base64(method:password)@host:port#name (SIP002), or ss://base64(method:password@host:port)#name.
    /// Outline's access keys are this form with "/?outline=1" (and sometimes "&prefix=…") after the port.
    private static func shadowsocks(_ body: String, link: String) throws -> Imported {
        var b = body
        var name = ""
        var prefix = false
        if let h = b.firstIndex(of: "#") {
            let frag = String(b[b.index(after: h)...])
            name = (frag.removingPercentEncoding ?? frag).trimmed
            b = String(b[..<h])
        }
        if let q = b.firstIndex(of: "?") {
            let query = b[b.index(after: q)...]
            if query.contains("plugin=") { throw Failure("Shadowsocks links with a plugin are not supported.") }
            prefix = query.split(separator: "&").contains { $0.hasPrefix("prefix=") && $0.count > "prefix=".count }
            b = String(b[..<q])
        }
        if !b.contains("@"), let decoded = decodeBase64(b) { b = decoded }
        var p = try split(b + (name.isEmpty ? "" : "#" + name))
        var userinfo = p.user
        if !userinfo.contains(":"), let decoded = decodeBase64(userinfo) { userinfo = decoded }
        guard let colon = userinfo.firstIndex(of: ":") else { throw Failure("The Shadowsocks link has no method and password.") }
        let method = String(userinfo[..<colon]), password = String(userinfo[userinfo.index(after: colon)...])
        p.name = name
        let out: [String: Any] = [
            "protocol": "shadowsocks",
            "settings": ["servers": [["address": p.host, "port": p.port, "method": method, "password": password]]],
        ]
        var imp = Imported(name: p.name, link: link, outbound: out, host: p.host, port: p.port)
        imp.prefix = prefix
        return imp
    }

    /// The server an Outline "online config" describes: {"server", "server_port", "password", "method",
    /// optionally "prefix"}, what an ssconf:// (dynamic) key answers with.
    private static func outlineJSON(_ d: [String: Any], name: String) -> Imported? {
        guard let host = (d["server"] as? String)?.trimmed, !host.isEmpty,
              let method = (d["method"] as? String)?.trimmed, !method.isEmpty,
              let password = d["password"] as? String else { return nil }
        let raw = d["server_port"] ?? d["port"]
        guard let port = (raw as? Int) ?? Int((raw as? String) ?? ""), (1...65535).contains(port) else { return nil }
        let out: [String: Any] = [
            "protocol": "shadowsocks",
            "settings": ["servers": [["address": host, "port": port, "method": method, "password": password]]],
        ]
        var imp = Imported(name: name, outbound: out, host: host, port: port)
        imp.prefix = (d["prefix"] as? String)?.isEmpty == false
        return imp
    }

    /// Xray streamSettings from a link's query (Xray's share-link standard).
    private static func stream(_ q: [String: String], network: String, security: String) throws -> [String: Any] {
        var net = network.lowercased()
        if net.isEmpty || net == "raw" { net = "tcp" }
        if net == "splithttp" { net = "xhttp" }
        if net == "h2" { net = "http" }
        if net == "mkcp" { net = "kcp" }
        var s: [String: Any] = ["network": net]
        let path = q["path"] ?? "", host = q["host"] ?? ""
        let hosts = host.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        switch net {
        case "tcp":
            if q["headerType"] == "http" {
                var req: [String: Any] = ["path": [path.isEmpty ? "/" : path]]
                if !hosts.isEmpty { req["headers"] = ["Host": hosts] }
                s["tcpSettings"] = ["header": ["type": "http", "request": req]]
            }
        case "ws", "httpupgrade":
            var w: [String: Any] = ["path": path.isEmpty ? "/" : path]
            if !host.isEmpty { w["host"] = host }
            s[net == "ws" ? "wsSettings" : "httpupgradeSettings"] = w
        case "xhttp":
            var x: [String: Any] = ["path": path.isEmpty ? "/" : path]
            if !host.isEmpty { x["host"] = host }
            if let m = q["mode"].nonEmpty { x["mode"] = m }
            if let e = q["extra"].nonEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(e.utf8)) { x["extra"] = obj }
            s["xhttpSettings"] = x
        case "grpc":
            var g: [String: Any] = ["serviceName": q["serviceName"] ?? path]
            if q["mode"] == "multi" { g["multiMode"] = true }
            if let a = q["authority"].nonEmpty { g["authority"] = a }
            s["grpcSettings"] = g
        case "kcp":
            var k: [String: Any] = [:]
            if let t = q["headerType"].nonEmpty, t != "none" { k["header"] = ["type": t] }
            if let seed = q["seed"].nonEmpty { k["seed"] = seed }
            s["kcpSettings"] = k
        case "http":
            var h: [String: Any] = ["path": path.isEmpty ? "/" : path]
            if !hosts.isEmpty { h["host"] = hosts }
            s["httpSettings"] = h
        case "hysteria":
            break
        default:
            throw Failure("The \(network) transport is not supported.")
        }
        switch security.lowercased() {
        case "", "none":
            break
        case "tls":
            var t: [String: Any] = [:]
            // Without one, the Host the link names (a CDN address given as an IP): Xray would otherwise
            // ask for a certificate for the IP address, and the handshake fails.
            if let sni = q["sni"].nonEmpty ?? q["peer"].nonEmpty ?? hosts.first { t["serverName"] = sni }
            if let fp = q["fp"].nonEmpty { t["fingerprint"] = fp }
            if let alpn = q["alpn"].nonEmpty { t["alpn"] = alpn.split(separator: ",").map { String($0).trimmed } }
            if let pin = q["pinSHA256"].nonEmpty { t["pinnedPeerCertificateChainSha256"] = [pin] }
            s["security"] = "tls"
            s["tlsSettings"] = t
        case "reality":
            guard let pbk = q["pbk"].nonEmpty else { throw Failure("The Reality link has no public key (pbk).") }
            var r: [String: Any] = ["publicKey": pbk, "fingerprint": q["fp"].nonEmpty ?? "chrome"]
            if let sni = q["sni"].nonEmpty { r["serverName"] = sni }
            if let sid = q["sid"] { r["shortId"] = sid }
            if let spx = q["spx"].nonEmpty { r["spiderX"] = spx }
            if let pqv = q["pqv"].nonEmpty { r["mldsa65Verify"] = pqv }
            s["security"] = "reality"
            s["realitySettings"] = r
        default:
            throw Failure("The \(security) security is not supported.")
        }
        return s
    }

    // MARK: JSON configs

    /// An Xray/V2Ray JSON config (its proxy outbounds), one outbound, or a list of either.
    static func importJSON(_ data: Data, name: String) throws -> [Imported] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw Failure("\(name) is not valid JSON.") }
        var found: [Imported] = []
        func walk(_ o: Any, _ label: String) {
            if let list = o as? [Any] {
                for (i, item) in list.enumerated() { walk(item, list.count > 1 ? "\(label) \(i + 1)" : label) }
            } else if let d = o as? [String: Any] {
                let remark = (d["remarks"] as? String)?.trimmed.nonEmpty
                if let outs = d["outbounds"] as? [Any] {
                    let proxies = outs.compactMap { $0 as? [String: Any] }.filter { protocols.contains(($0["protocol"] as? String ?? "").lowercased()) }
                    for (i, ob) in proxies.enumerated() {
                        let base = remark ?? label
                        if let imp = outbound(ob, name: proxies.count > 1 ? "\(base) \(i + 1)" : base) { found.append(imp) }
                    }
                } else if let imp = outbound(d, name: remark ?? label) {
                    found.append(imp)
                } else if let imp = outlineJSON(d, name: (d["name"] as? String)?.trimmed.nonEmpty ?? remark ?? label) {
                    found.append(imp)
                }
            }
        }
        walk(obj, name)
        if found.isEmpty { throw Failure("\(name) holds no VLESS, VMess, Trojan, Shadowsocks (Outline) or Hysteria2 server.") }
        return found
    }

    /// One outbound as FiveT keeps it: the proxy part only. Its tag, mux and sockopt are FiveT's to set.
    private static func outbound(_ d: [String: Any], name: String) -> Imported? {
        guard let proto = (d["protocol"] as? String)?.lowercased(), protocols.contains(proto) else { return nil }
        var out: [String: Any] = ["protocol": proto]
        if let s = d["settings"] { out["settings"] = s }
        if var st = d["streamSettings"] as? [String: Any] {
            st["sockopt"] = nil
            if var tls = st["tlsSettings"] as? [String: Any], tls["allowInsecure"] != nil {
                tls["allowInsecure"] = nil
                st["tlsSettings"] = tls
            }
            out["streamSettings"] = st
        }
        let (host, port) = server(of: out)
        guard !host.isEmpty else { return nil }
        return Imported(name: name, outbound: out, host: host, port: port)
    }

    /// The server an outbound connects to.
    static func server(of out: [String: Any]) -> (String, Int) {
        let settings = out["settings"] as? [String: Any] ?? [:]
        let first = (settings["vnext"] as? [[String: Any]])?.first ?? (settings["servers"] as? [[String: Any]])?.first ?? settings
        let host = (first["address"] as? String)?.trimmed ?? ""
        let port = (first["port"] as? Int) ?? Int(first["port"] as? String ?? "") ?? 0
        return (host, port)
    }

    // MARK: Text: pasted, dropped, or a subscription's body

    /// Every link (or JSON config) in `text`; a subscription body may be all of it in base64.
    /// https:// lines are returned as subscriptions to fetch.
    static func importText(_ text: String, name: String = "Pasted config") -> (configs: [Imported], problems: [String], subscriptions: [URL]) {
        var t = text.trimmed
        if t.hasPrefix("{") || t.hasPrefix("[") {
            do { return (try importJSON(Data(t.utf8), name: name), [], []) } catch { return ([], [error.localizedDescription], []) }
        }
        if !t.contains("://"), let decoded = decodeBase64(t.filter { !$0.isWhitespace }), decoded.contains("://") { t = decoded }
        var configs: [Imported] = [], problems: [String] = [], subs: [URL] = []
        for token in tokens(t) {
            let low = token.lowercased()
            if low.hasPrefix("https://") || low.hasPrefix("http://") {
                if let u = URL(string: token) { subs.append(u) }
            } else if low.hasPrefix("ssconf://") {
                if let u = dynamicKeyURL(token) { subs.append(u) } else { problems.append("\(shortLink(token)): not a valid key address.") }
            } else if isLink(token) {
                do { configs.append(try parse(link: token)) } catch {
                    problems.append("\(shortLink(token)): \(error.localizedDescription)")
                }
            }
        }
        return (configs, problems, subs)
    }

    /// The links in `text`: one per line, or several on a line. A link ends where the next one
    /// starts, not at a space: names after "#" are often typed with spaces, not as %20.
    static func tokens(_ text: String) -> [String] {
        let starts = (schemes + ["https", "http", "ssconf"]).map { $0 + "://" }
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            var cuts: [String.Index] = []
            var i = l.startIndex
            while i < l.endIndex {
                if i == l.startIndex || l[l.index(before: i)].isWhitespace {
                    // Only the 12 characters a scheme can fill (hysteria2://): lowercasing the rest of the
                    // line at every word made a long line quadratic (500 links on one line took 51 s).
                    let head = l[i...].prefix(12).lowercased()
                    if starts.contains(where: { head.hasPrefix($0) }) { cuts.append(i) }
                }
                i = l.index(after: i)
            }
            for (n, c) in cuts.enumerated() {
                let end = n + 1 < cuts.count ? cuts[n + 1] : l.endIndex
                let piece = String(l[c..<end]).trimmed
                // A subscription URL never has a space in it; anything after one is not part of it.
                out.append(piece.lowercased().hasPrefix("http") ? String(piece.prefix { !$0.isWhitespace }) : piece)
            }
        }
        return out
    }

    /// An Outline dynamic key (ssconf://host/path#name) as the https:// address it is fetched from;
    /// the name after "#" stays in the URL's fragment, which a request never sends.
    static func dynamicKeyURL(_ key: String) -> URL? {
        var rest = key.trimmed
        guard let r = rest.range(of: "://") else { return nil }
        rest = String(rest[r.upperBound...])
        var address = rest, name = ""
        if let h = rest.firstIndex(of: "#") {
            address = String(rest[..<h])
            let frag = String(rest[rest.index(after: h)...])
            name = (frag.removingPercentEncoding ?? frag).trimmed
        }
        guard !address.isEmpty, !address.contains(where: \.isWhitespace) else { return nil }
        var c = URLComponents(string: "https://" + address)
        guard c?.host?.isEmpty == false else { return nil }
        if !name.isEmpty { c?.fragment = name }
        return c?.url
    }

    /// The configs a subscription URL lists now, and the title its server gives it.
    static func fetchSubscription(_ url: URL) async throws -> (title: String?, configs: [Imported], problems: [String]) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        // Panels (Marzban, 3x-ui…) answer in the format of the client they recognise; this one is
        // the plain list of links.
        req.setValue("v2rayN/7.0", forHTTPHeaderField: "User-Agent")
        // Ephemeral: URLSession.shared would keep cookies and a cache on disk for a one-off request.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure("The subscription server answered \(http.statusCode).")
        }
        var title: String?
        if let raw = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "profile-title") {
            title = raw.hasPrefix("base64:") ? decodeBase64(String(raw.dropFirst(7))) : raw
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure("The subscription is not text.") }
        let fallback = title ?? url.host ?? "Subscription"
        var r = importText(text, name: fallback)
        for i in r.configs.indices { r.configs[i].subscription = url.absoluteString }
        // An Outline dynamic key carries its name in the address, not in what the server answers
        // (whose one server importText names after the fallback).
        if let name = url.fragment?.removingPercentEncoding?.trimmed.nonEmpty {
            for i in r.configs.indices where r.configs[i].name.trimmed.isEmpty || r.configs[i].name == fallback { r.configs[i].name = name }
        }
        if r.configs.isEmpty && r.problems.isEmpty { throw Failure("The subscription lists no configs FiveT can use.") }
        return (title, r.configs, r.problems)
    }

    // MARK: Connections

    /// A new connection from an import, named apart from the ones in `taken`.
    static func connection(from imp: Imported, taken: [String]) -> Connection {
        var c = Connection()
        c.kind = .v2ray
        var name = imp.name.trimmed.isEmpty ? "\(imp.host)" : imp.name.trimmed
        if taken.contains(name) {
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            name = "\(name) \(n)"
        }
        c.name = name
        apply(imp, to: &c)
        return c
    }

    static func apply(_ imp: Imported, to c: inout Connection) {
        c.v2rayOutbound = json(imp.outbound)
        c.v2rayLink = imp.link
        c.v2raySubscription = imp.subscription
        c.host = imp.host
        c.port = imp.port
        c.realm = ""
    }

    /// A Shadowsocks server (what Outline's keys are), for labels. The outbound is written with sorted
    /// keys and no spaces (json()), so this is a plain text test, cheap enough for every render.
    static func isShadowsocks(_ outboundJSON: String) -> Bool { outboundJSON.contains("\"protocol\":\"shadowsocks\"") }

    /// The link with `outline=1` in its query (before any #name), which is how kindLabel knows a key
    /// from the Outline app is an Outline key even when its own text does not say so.
    static func markedAsOutline(_ link: String) -> String {
        guard !link.contains("outline=1") else { return link }
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0]), tail = parts.count > 1 ? "#" + parts[1] : ""
        return head + (head.contains("?") ? "&" : "?") + "outline=1" + tail
    }

    /// What the list and the detail title call a connection: Outline for a Shadowsocks server that came
    /// as an Outline key (`outline=1`) or an ssconf:// address, Shadowsocks for any other, V2Ray for the rest.
    static func kindLabel(_ c: Connection) -> String {
        guard isShadowsocks(c.v2rayOutbound) else { return "V2Ray" }
        return c.v2rayLink.contains("outline=1") || !c.v2raySubscription.isEmpty ? "Outline" : "Shadowsocks"
    }

    /// "VLESS · Reality · xhttp", for Settings.
    static func summary(_ outboundJSON: String) -> String {
        guard let o = object(outboundJSON) else { return "" }
        let proto = (o["protocol"] as? String ?? "").lowercased()
        let names = ["vless": "VLESS", "vmess": "VMess", "trojan": "Trojan", "shadowsocks": "Shadowsocks", "hysteria": "Hysteria2"]
        var parts = [names[proto] ?? proto]
        let st = o["streamSettings"] as? [String: Any] ?? [:]
        if let sec = st["security"] as? String, sec != "none" { parts.append(sec == "reality" ? "Reality" : sec.uppercased()) }
        if let net = st["network"] as? String, net != "tcp", net != "hysteria" { parts.append(net) }
        return parts.joined(separator: " · ")
    }

    static func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func object(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    // MARK: Running

    /// Xray's end of the TUN ("gateway" 198.18.0.1/30: it is .1, the Mac .2). The Mac's DNS points
    /// at it while connected, and Xray answers those questions itself (its dns outbound): names
    /// are looked up through the server, never by the local network's resolver, which in Iran
    /// answers blocked names with a wrong address.
    static let tunGateway = "198.18.0.1"
    static let tunAddress = "198.18.0.2"
    /// DNS servers Xray asks, through the V2Ray server, over TCP: Xray 26.10 on macOS 27 cannot bind a
    /// UDP socket to the Wi-Fi ("falied to set interface"), so a UDP question to the server's relay
    /// never gets back out of the TUN, while TCP does (measured: 0.4-0.8 s a name, 0.01 s again).
    static let remoteDNS = ["tcp://1.1.1.1", "tcp://8.8.8.8"]

    /// The host names (not addresses) the server settings connect to: every "address" in the outbound
    /// (the server, and any other one an XHTTP download setting names). FiveT looks them up before the
    /// tunnel exists and gives Xray the answers (forLaunch's serverIPs).
    static func serverNames(of outboundJSON: String) -> [String] {
        // A real server has one or two (the address, perhaps a second hop). A cap, because an import can
        // hold thousands of "address" fields and each name is a lookup.
        Array(serverAddresses(of: outboundJSON).filter(isHostName).prefix(8))
    }

    /// Every "address" in the outbound, names and IP addresses alike, sorted.
    static func serverAddresses(of outboundJSON: String) -> [String] {
        guard let out = object(outboundJSON) else { return [] }
        var names: Set<String> = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, x) in d {
                    if k == "address", let s = x as? String { names.insert(s.trimmed.lowercased()) } else { walk(x) }
                }
            } else if let list = v as? [Any] {
                list.forEach(walk)
            }
        }
        walk(out)
        return names.sorted()
    }

    /// A DNS name Xray would look up: ASCII letters, digits, "-", "_" and dots, not an IP address (the
    /// helper only accepts ASCII keys, so an internationalised name is left to Xray).
    private static func isHostName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) != 1 && inet_pton(AF_INET6, s, &v6) != 1
    }

    /// The whole Xray config for `c`: one TUN that takes all of the Mac's traffic, the server, and
    /// routing that sends the local network, `direct` (the Forti gateways) and, when the
    /// connection says so, Iranian sites (.ir names, Iranian addresses) straight out. `localDNS`
    /// answers .ir names then, as it would without the VPN. `serverIPs` are the addresses the Mac's own
    /// DNS gave the server's name before the tunnel existed: with the Mac's DNS pointing into the
    /// tunnel, Xray can only look the name up through the server, which it cannot reach without the
    /// answer, so a server given by name never connected. The helper checks the config again as root.
    /// The port of the local SOCKS proxy in apps-only mode (`tun` nil): the same for every run, so an app
    /// started through it finds the proxy again after a reconnect.
    static let appProxyPort = 10808

    static func forLaunch(_ c: Connection, tun: String?, localDNS: [String], direct: [String],
                          serverIPs: [String: [String]] = [:], verbose: Bool) throws -> String {
        guard var proxy = object(c.v2rayOutbound),
              let proto = proxy["protocol"] as? String, protocols.contains(proto.lowercased()) else {
            throw Failure("its server settings are missing")
        }
        proxy["tag"] = "proxy"
        proxy["mux"] = nil
        if var st = proxy["streamSettings"] as? [String: Any] {
            st["sockopt"] = nil   // the TUN's autoOutboundsInterface keeps every outbound off the tunnel
            if var tls = st["tlsSettings"] as? [String: Any] {
                tls["allowInsecure"] = nil   // refused by Xray since 2026
                st["tlsSettings"] = tls
            }
            proxy["streamSettings"] = st
        }
        var rules: [[String: Any]] = tun == nil ? [] : [
            // The Mac's DNS questions (it asks tunGateway) are answered by Xray's DNS.
            ["inboundTag": ["tun"], "network": "udp", "port": "53", "outboundTag": "dns-out"],
            // Any other UDP is dropped. Xray cannot bind a UDP socket to the Wi-Fi here ("falied to set
            // interface"), so what it sent on would go straight back into the TUN and loop. Browsers
            // fall back from QUIC to TCP; the log shows "[tun -> block]" for each dropped flow.
            ["inboundTag": ["tun"], "network": "udp", "outboundTag": "block"],
        ]
        rules.append(["ip": ["ext:geoip-lite.dat:private"], "outboundTag": "direct"])
        if !direct.isEmpty { rules.append(["ip": direct, "outboundTag": "direct"]) }
        var servers: [Any] = []
        if ConnectionStore.shared.bypassIran {
            rules.append(["domain": ["domain:ir"], "outboundTag": "direct"])
            rules.append(["ip": ["ext:geoip-lite.dat:ir"], "outboundTag": "direct"])
            if let local = localDNS.first {
                servers.append(["address": local, "domains": ["domain:ir"], "skipFallback": true])
            }
        }
        servers += remoteDNS
        // Last: a name the world's DNS does not know (some Iranian sites' .com and .io names only exist
        // on Iranian resolvers: varzesh3.com, telewebion.com, virgool.io) is asked of the local one,
        // whose answer counts only when it is an Iranian address, so a filter's fake answer never does.
        if ConnectionStore.shared.bypassIran, let local = localDNS.first {
            servers.append(["address": local, "expectIPs": ["ext:geoip-lite.dat:ir"]])
        }
        // The server's own name, answered from what the Mac found: no lookup through a server that is
        // not reachable yet. A name with only IPv6 addresses needs Xray to ask for them.
        var dns: [String: Any] = ["tag": "dns-internal", "queryStrategy": "UseIPv4", "servers": servers]
        let known = serverIPs.filter { !$0.value.isEmpty }
        if !known.isEmpty {
            dns["hosts"] = Dictionary(known.map { ("full:" + $0.key.lowercased(), $0.value as Any) }, uniquingKeysWith: { a, _ in a })
            if known.values.contains(where: { $0.allSatisfy { $0.contains(":") } }) { dns["queryStrategy"] = "UseIP" }
        }
        rules.append(["network": "tcp,udp", "outboundTag": "proxy"])
        // Apps-only: no TUN and no routes, just a SOCKS proxy on this Mac that the chosen apps are started with.
        let appInbound: [String: Any] = [
            "tag": "app", "protocol": "socks", "listen": "127.0.0.1", "port": appProxyPort,
            "settings": ["auth": "noauth", "udp": false] as [String: Any],
            "sniffing": ["enabled": true, "destOverride": ["http", "tls"], "routeOnly": true] as [String: Any],
        ]
        let config: [String: Any] = [
            "log": ["loglevel": verbose ? "info" : "warning"],
            "inbounds": tun == nil ? [appInbound] : [[
                "tag": "tun",
                "protocol": "tun",
                "settings": [
                    "name": tun ?? "",
                    "mtu": 1500,
                    "gateway": ["\(tunGateway)/30"],
                    // Xray adds the routes itself and binds its own connections to the Wi-Fi or
                    // Ethernet, re-picked when it changes. Quarters, not halves: the Mac's default
                    // route stays, and another VPN that takes everything with two halves (NordVPN,
                    // OpenVPN's def1) neither blocks these routes nor wins over them.
                    "autoSystemRoutingTable": ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2",
                                               "::/2", "4000::/2", "8000::/2", "c000::/2"],
                    "autoOutboundsInterface": "auto",
                ] as [String: Any],
                "sniffing": ["enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true] as [String: Any],
            ] as [String: Any]],
            "outbounds": [
                proxy,
                ["protocol": "freedom", "tag": "direct"],
                ["protocol": "blackhole", "tag": "block"],
                // A and AAAA go to Xray's DNS; every other type (HTTPS, TXT…) is answered at once with no
                // records and no error (NOERROR, empty: what a resolver says for a name that has no record
                // of that type, so a browser's HTTPS lookup falls back to plain A/AAAA without a fuss).
                // Replaces nonIPQuery "reject", which Xray 26.10 warns it will remove and which answered
                // REFUSED (rCode 5): put 5 here to get that behaviour back.
                ["protocol": "dns", "tag": "dns-out", "settings": ["rules": [
                    ["action": "hijack", "qType": "1,28"],
                    ["action": "return", "rCode": 0],
                ]]] as [String: Any],
            ],
            "dns": dns,
            "routing": ["domainStrategy": "AsIs", "rules": rules] as [String: Any],
        ]
        return json(config)
    }

    // MARK: Helpers

    /// Base64, standard or URL-safe, with or without padding.
    static func decodeBase64(_ s: String) -> String? {
        var t = s.trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) else { return nil }
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// A link for a message: its scheme and server, never its ID or password.
    static func shortLink(_ s: String) -> String {
        guard let r = s.range(of: "://") else { return "a line" }
        let scheme = s[..<r.lowerBound]
        if let at = s.lastIndex(of: "@") {
            let hp = s[s.index(after: at)...].prefix { $0 != "?" && $0 != "#" && $0 != "/" }
            return "\(scheme)://…@\(hp)"
        }
        return "a \(scheme):// link"
    }
}

extension Optional where Wrapped == String {
    /// The string, unless it is nil or blank.
    var nonEmpty: String? { self?.trimmed.isEmpty == false ? self : nil }
}

extension String {
    var nonEmpty: String? { trimmed.isEmpty ? nil : self }
}
