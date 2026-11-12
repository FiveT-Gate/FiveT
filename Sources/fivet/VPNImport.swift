import Foundation

/// Adding connections to the VPN tab, however they arrive: OpenVPN profiles, V2Ray links, Outline
/// keys (ss://, ssconf://), Xray JSON files, subscriptions (fetched), the saved servers of Outline,
/// and whatever is dropped or pasted. Each import returns what it added and one line per
/// thing worth saying, for the alert.
@MainActor
enum VPNImport {
    struct Outcome {
        var added: [Connection] = []
        var lines: [String] = []
        /// macOS kept FiveT from reading the Outline app's data: Settings then offers to ask for it.
        var needsOutlineAccess = false
        mutating func merge(_ o: Outcome) { added += o.added; lines += o.lines; needsOutlineAccess = needsOutlineAccess || o.needsOutlineAccess }
        var message: String { lines.isEmpty ? "Nothing to import." : lines.joined(separator: "\n\n") }
    }

    // MARK: V2Ray

    /// The configs as new connections; one already here (the same server, ID and transport) is skipped.
    static func addV2Ray(_ imps: [V2RayConfig.Imported], from source: String) -> Outcome {
        let store = ConnectionStore.shared
        var out = Outcome()
        var already = 0, insecure = 0, prefixed: [String] = []
        for imp in imps {
            let outbound = V2RayConfig.json(imp.outbound)
            if store.connections.contains(where: { $0.isV2Ray && $0.v2rayOutbound == outbound }) {
                already += 1
                continue
            }
            let c = store.add(V2RayConfig.connection(from: imp, taken: store.connections.map(\.name)))
            out.added.append(c)
            if imp.insecure { insecure += 1 }
            if imp.prefix { prefixed.append(c.name) }
        }
        if !out.added.isEmpty {
            let names = out.added.prefix(5).map(\.name).joined(separator: ", ") + (out.added.count > 5 ? ", …" : "")
            out.lines.append("Added \(out.added.count) \(out.added.count == 1 ? "server" : "servers"): \(names).")
            Log.shared.write("\(out.added.count) V2Ray connection(s) imported from \(source)")
        }
        if already > 0 { out.lines.append("\(already) \(already == 1 ? "was" : "were") already here.") }
        if insecure > 0 {
            out.lines.append("\(insecure == 1 ? "One link asks" : "\(insecure) links ask") to skip checking the server's certificate, which Xray no longer allows. If \(insecure == 1 ? "it does" : "they do") not connect, ask your provider for a config with a valid certificate or Reality.")
        }
        if !prefixed.isEmpty {
            out.lines.append("\(prefixed.count == 1 ? "\(prefixed[0]) uses" : "\(prefixed.count) of these use") Outline's prefix (a disguise for the first bytes of the connection), which FiveT does not send. \(prefixed.count == 1 ? "It connects" : "They connect") on networks that allow Shadowsocks; on one that blocks it, use the Outline app.")
        }
        return out
    }

    /// Links, a subscription body, or a JSON config, as text; https:// lines are fetched as subscriptions.
    static func addText(_ text: String, from source: String) async -> Outcome {
        let parsed = V2RayConfig.importText(text, name: source)
        var out = addV2Ray(parsed.configs, from: source)
        out.lines += parsed.problems.prefix(5).map { "Skipped \($0)" }
        if parsed.problems.count > 5 { out.lines.append("…and \(parsed.problems.count - 5) more that could not be read.") }
        for url in parsed.subscriptions { out.merge(await addSubscription(url)) }
        if parsed.configs.isEmpty && parsed.problems.isEmpty && parsed.subscriptions.isEmpty {
            out.lines.append("No V2Ray links (vless://, vmess://, trojan://, ss://, hysteria2://), Outline keys (ss://, ssconf://) or subscription address found.")
        }
        return out
    }

    /// Every config a subscription lists, each remembering the subscription so Refresh can update it.
    static func addSubscription(_ url: URL) async -> Outcome {
        do {
            let sub = try await V2RayConfig.fetchSubscription(url)
            var out = addV2Ray(sub.configs, from: "subscription \(url.host ?? "")")
            out.lines.insert("Subscription \(sub.title ?? url.host ?? url.absoluteString): \(sub.configs.count) \(sub.configs.count == 1 ? "server" : "servers").", at: 0)
            if !sub.problems.isEmpty { out.lines.append("\(sub.problems.count) could not be read.") }
            return out
        } catch {
            return Outcome(lines: ["Subscription \(url.host ?? url.absoluteString): \(error.localizedDescription)"])
        }
    }

    /// Fetches the subscription again: new servers are added, ones it no longer lists are removed
    /// (unless connected), and the ones still listed stay as they are (with their settings).
    static func refresh(subscription address: String) async -> Outcome {
        guard let url = URL(string: address) else { return Outcome(lines: ["The subscription address is not valid."]) }
        let store = ConnectionStore.shared
        do {
            let sub = try await V2RayConfig.fetchSubscription(url)
            // An answer FiveT can read nothing of says nothing about which servers are gone.
            guard !sub.configs.isEmpty else {
                return Outcome(lines: ["Could not refresh the subscription: none of the \(sub.problems.count) servers it lists now could be read. Nothing was changed."])
            }
            let listed = Set(sub.configs.map { V2RayConfig.json($0.outbound) })
            let gone = store.connections.filter {
                $0.isV2Ray && $0.v2raySubscription == address && !listed.contains($0.v2rayOutbound)
                    && VPNManager.shared.status(for: $0.id) == nil
            }
            for c in gone { store.remove(id: c.id) }
            // Looked up in a set: asking every saved connection about every listed server took seconds
            // for a subscription of a thousand.
            let saved = Set(store.connections.filter(\.isV2Ray).map(\.v2rayOutbound))
            let fresh = sub.configs.filter { !saved.contains(V2RayConfig.json($0.outbound)) }
            var out = addV2Ray(fresh, from: "subscription \(url.host ?? "")")
            out.lines = ["Subscription \(sub.title ?? url.host ?? address): \(sub.configs.count) servers now; \(out.added.count) new, \(gone.count) removed."]
            Log.shared.write("subscription \(url.host ?? "") refreshed: \(sub.configs.count) listed, \(out.added.count) new, \(gone.count) removed")
            return out
        } catch {
            return Outcome(lines: ["Could not refresh the subscription: \(error.localizedDescription)"])
        }
    }

    /// The servers saved in the Outline app on this Mac.
    static func addOutline(folders: [URL]? = nil) async -> Outcome {
        do { return await addOutline(try OutlineApp.savedServers(in: folders), from: "Outline") } catch {
            var out = Outcome(lines: [error.localizedDescription])
            out.needsOutlineAccess = (error as? OutlineApp.Failure)?.denied == true
            return out
        }
    }

    /// Outline's saved servers under the names they have there. An ss:// key is one server; an
    /// ssconf:// (or https://) key is fetched, and remembered so Refresh can ask it again.
    static func addOutline(_ entries: [OutlineApp.Entry], from source: String) async -> Outcome {
        var imps: [V2RayConfig.Imported] = []
        var skipped: [String] = []
        for e in entries {
            let label = e.name.nonEmpty ?? "a server"
            let low = e.key.lowercased()
            do {
                if low.hasPrefix("ss://") {
                    var imp = try V2RayConfig.parse(link: e.key)
                    if let n = e.name.nonEmpty { imp.name = n }
                    imp.link = V2RayConfig.markedAsOutline(imp.link)   // it came from Outline: the list says so
                    imps.append(imp)
                } else if low.hasPrefix("ssconf://") || low.hasPrefix("https://") {
                    guard let url = V2RayConfig.dynamicKeyURL(e.key) else { throw V2RayConfig.Failure("its key address is not valid.") }
                    var configs = try await V2RayConfig.fetchSubscription(url).configs
                    if configs.count == 1, let n = e.name.nonEmpty { configs[0].name = n }
                    imps += configs
                } else {
                    skipped.append("\(label): this kind of key is not supported (FiveT reads ss:// and ssconf:// keys).")
                }
            } catch {
                skipped.append("\(label): \(error.localizedDescription)")
            }
        }
        var out = addV2Ray(imps, from: source)
        out.lines += skipped.prefix(5).map { "Skipped \($0)" }
        if skipped.count > 5 { out.lines.append("…and \(skipped.count - 5) more that could not be read.") }
        if entries.isEmpty { out.lines.append("Outline has no saved servers.") }
        return out
    }

    // MARK: OpenVPN

    /// OpenVPN profiles: each becomes a connection (its certificates and keys inside it). A profile
    /// that is already here is skipped; what FiveT left out of a profile is listed. `names`: the name
    /// each file has in the app it came from, by the file's name without ".ovpn" (OpenVPN Connect).
    static func addOpenVPN(_ urls: [URL], from source: String, names: [String: String] = [:]) -> Outcome {
        let store = ConnectionStore.shared
        var out = Outcome()
        for url in urls {
            do {
                var imp = try OpenVPNProfile.importProfile(at: url)
                // OpenVPN Connect saves its copies under a number: the name its user sees (or gave) is
                // the one to keep, over the profile's own comments and over its server's name.
                if let name = names[url.deletingPathExtension().lastPathComponent] { imp.name = name }
                if let same = store.connections.first(where: { $0.isOpenVPN && $0.ovpnProfile == imp.text }) {
                    out.lines.append("\(same.name) is already here.")
                    continue
                }
                let c = store.add(OpenVPNProfile.connection(from: imp, taken: store.connections.map(\.name)))
                out.added.append(c)
                var line = "Added \(c.name) (\(c.host):\(c.port))."
                if !imp.dropped.isEmpty { line += " Left out: \(imp.dropped.joined(separator: "; "))." }
                if OpenVPNProfile.needsLogin(imp.text) && c.password.isEmpty { line += " Enter its username and password." }
                if c.otpMode == .separate && c.totpSecret.isEmpty { line += " Its server asks for a one-time code: enter the secret." }
                out.lines.append(line)
                Log.shared.write("[\(c.name)] OpenVPN profile imported from \(source) (\(c.host):\(c.port))")
            } catch {
                out.lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if urls.isEmpty { out.lines.append("No OpenVPN profiles found.") }
        return out
    }

    // MARK: Files, by what they hold

    /// Dropped or chosen files: an OpenVPN profile, an Xray JSON config, or text with V2Ray links.
    static func addFiles(_ urls: [URL]) async -> Outcome {
        var out = Outcome()
        for url in urls {
            if isOpenVPNProfile(url) {
                out.merge(addOpenVPN([url], from: "a file"))
                continue
            }
            // The size is asked before the file is read: a 200 MB file dropped by mistake used to be read
            // whole (5 s and +600 MB on the main thread) and only then refused.
            guard (fileSize(url) ?? Int.max) < 4_000_000, let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else {
                out.lines.append("\(url.lastPathComponent): not a VPN config FiveT can read.")
                continue
            }
            out.merge(await addText(text, from: url.lastPathComponent))
        }
        return out
    }

    /// A file's size in bytes without reading it; nil when it cannot be told.
    private static func fileSize(_ url: URL) -> Int? { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }

    /// .ovpn, or a .conf/.txt that reads like one ("client" / "remote" lines).
    static func isOpenVPNProfile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "ovpn" { return true }
        guard ["conf", "txt", ""].contains(ext), (fileSize(url) ?? Int.max) < 4_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // Not a list of V2Ray links or subscription addresses; a web address in a comment is fine.
        return lines.contains { $0.hasPrefix("remote ") }
            && !lines.contains { V2RayConfig.isLink($0) || $0.lowercased().hasPrefix("http") || $0.lowercased().hasPrefix("ssconf://") }
    }
}
