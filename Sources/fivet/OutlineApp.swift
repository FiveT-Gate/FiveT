import Foundation
import SQLite3

/// The Outline app on this Mac (Jigsaw's Outline client). It keeps the servers its user added as
/// access keys in the browser storage of its own window (`servers_v1`: id, name and the key as it
/// was typed), inside its sandbox folders, which macOS lets another app read only after the user
/// agrees. Keys are Shadowsocks: ss://… (one server) or ssconf://… (an address that answers with
/// the server now), and FiveT runs them like any other Shadowsocks server (V2RayConfig).
enum OutlineApp {
    /// One saved server: the name Outline shows and the key behind it.
    struct Entry {
        var name: String
        var key: String
    }

    struct Failure: LocalizedError {
        let message: String
        /// macOS refused to let FiveT read Outline's folders (they need the user's say-so).
        var denied = false
        init(_ m: String, denied: Bool = false) { message = m; self.denied = denied }
        var errorDescription: String? { message }
    }

    private static let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    /// Bundle identifiers of Outline's builds: the App Store app, and the older standalone download.
    private static let idPrefixes = ["org.outline.macos", "com.gorillized.outlinemac"]

    /// Outline's data folders that exist: its own container, and the one it shares with its VPN extension.
    static var folders: [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let containers = library.appendingPathComponent("Containers")
        for name in ((try? fm.contentsOfDirectory(atPath: containers.path)) ?? []).sorted()
        where idPrefixes.contains(where: name.hasPrefix) && !["extension", "widget"].contains(where: name.lowercased().contains) {
            out.append(containers.appendingPathComponent(name).appendingPathComponent("Data"))
        }
        let groups = library.appendingPathComponent("Group Containers")
        for name in ((try? fm.contentsOfDirectory(atPath: groups.path)) ?? []).sorted() where name.lowercased().contains("outline") {
            out.append(groups.appendingPathComponent(name))
        }
        return out.filter { fm.fileExists(atPath: $0.path) }
    }

    static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Outline.app") || !folders.isEmpty
    }

    /// The folder to point the "Choose Folder" dialog at: Outline's own data folder.
    static var accessFolder: URL? { folders.first { $0.path.contains("/Containers/") } ?? folders.first }

    // MARK: Reading the app

    /// The servers saved in Outline, from a copy of its storage, so Outline's own files are never
    /// opened for writing. What it finds goes to FiveT's log (never a key), so a failed import can be explained.
    /// `chosen`: the folder the user picked in the system's folder dialog, which lets FiveT read it
    /// even where the Full Disk Access switch is off.
    static func savedServers(in chosen: [URL]? = nil) throws -> [Entry] {
        let fm = FileManager.default
        var databases: [URL] = []
        var denied = 0
        let found = chosen ?? folders
        for folder in found {
            // Listing the top first: a folder macOS keeps from FiveT throws here (EPERM), where an
            // enumerator would just come back empty.
            do { _ = try fm.contentsOfDirectory(atPath: folder.path) } catch {
                denied += 1
                Log.shared.write("Outline import: \(folder.path) not readable: \((error as NSError).localizedDescription)", level: .error)
                continue
            }
            var files = 0
            for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                files += 1
                if !url.path.hasSuffix("-wal"), !url.path.hasSuffix("-shm"), isSQLite(url) { databases.append(url) }
            }
            Log.shared.write("Outline import: \(folder.path): \(files) files, \(databases.count) databases so far")
        }
        if databases.isEmpty {
            if denied > 0 { throw Failure("macOS did not let FiveT read Outline's data.", denied: true) }
            throw Failure(found.isEmpty
                    ? "FiveT found no data from the Outline app on this Mac. Copy a key (ss://…) and use Paste Links, Keys or Subscription."
                    : "FiveT found no saved servers in Outline's data. Copy a key (ss://…) from Outline and use Paste Links, Keys or Subscription.")
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("fivet-outline-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        var result: [Entry] = []
        for (i, db) in databases.enumerated() {
            let copy = tmp.appendingPathComponent("\(i).sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? fm.copyItem(at: URL(fileURLWithPath: db.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
            }
            let entries = readStorage(copy)
            if !entries.isEmpty { Log.shared.write("Outline import: \(db.lastPathComponent): \(entries.count) saved server(s)") }
            for e in entries where !result.contains(where: { $0.key == e.key }) { result.append(e) }
        }
        if result.isEmpty { throw Failure("Outline has no saved servers FiveT can read. Copy a key (ss://…) from Outline and use Paste Links, Keys or Subscription.") }
        return result
    }

    /// A SQLite database, by its first bytes.
    private static func isSQLite(_ url: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 16)) == Data("SQLite format 3\u{0}".utf8)
    }

    /// A WebKit localStorage database: one table, ItemTable(key, value), the value a blob of the
    /// string (UTF-16 as WebKit writes it, or 8-bit text). A database without that table is skipped.
    /// The names of the keys it holds (never their values) go to the log, so a database that holds
    /// no `servers_v1` can be told from one that FiveT could not read.
    private static func readStorage(_ url: URL) -> [Entry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Entry] = []
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: k)
            keys.append(key)
            guard key == "servers_v1" || key == "servers", let b = sqlite3_column_blob(stmt, 1) else { continue }
            let value = decode(Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, 1))))
            out += entries(inStorage: value ?? "", legacy: key == "servers")
        }
        Log.shared.write("Outline import: a web storage with keys [\(keys.joined(separator: ", "))] → \(out.count) server(s)")
        return out
    }

    /// A stored string's bytes: UTF-16 (little endian) when the second byte is 0, as it is after a
    /// "[" or "{", otherwise 8-bit text read as UTF-8.
    static func decode(_ d: Data) -> String? {
        if d.count >= 2, d[d.startIndex + 1] == 0 { return String(data: d, encoding: .utf16LittleEndian) }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    /// For testing without the app: a web-storage database (read from a copy, like Outline's own), or
    /// a text file holding the stored list.
    static func entries(inFile url: URL) throws -> [Entry] {
        guard isSQLite(url) else { return entries(inStorage: try String(contentsOf: url, encoding: .utf8)) }
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("fivet-outline-\(UUID().uuidString).sqlite")
        try fm.copyItem(at: url, to: copy)
        defer { try? fm.removeItem(at: copy) }
        return readStorage(copy)
    }

    // MARK: What it holds

    /// The servers in Outline's stored list: `servers_v1` is [{id, name, accessKey}], and the first
    /// version of the app (`servers`, legacy) kept [{name, host, port, method, password}].
    static func entries(inStorage text: String, legacy: Bool = false) -> [Entry] {
        // The list itself: whatever WebKit puts around the stored text (a marker byte) is not part of it.
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let list = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            let name = (d["name"] as? String)?.trimmed ?? ""
            if let key = (d["accessKey"] as? String)?.trimmed, !key.isEmpty { return Entry(name: name, key: key) }
            guard legacy || d["accessKey"] == nil,
                  let host = (d["host"] as? String)?.trimmed, !host.isEmpty,
                  let method = (d["method"] as? String)?.trimmed, let password = d["password"] as? String,
                  let port = (d["port"] as? Int) ?? Int((d["port"] as? String) ?? "") else { return nil }
            let user = Data("\(method):\(password)".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return Entry(name: name, key: "ss://\(user)@\(host.contains(":") ? "[\(host)]" : host):\(port)/?outline=1")
        }
    }
}
