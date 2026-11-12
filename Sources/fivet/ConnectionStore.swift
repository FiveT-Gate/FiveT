import Foundation
import Combine
import SwiftUI
import AppKit

/// Persists connections + app settings to
/// ~/Library/Application Support/fivet/connections.json (mode 0600).
final class ConnectionStore: ObservableObject {
    static let shared = ConnectionStore()

    @Published var connections: [Connection] { didSet { persist() } }
    @Published var showNameInMenuBar: Bool { didSet { persist() } }
    @Published var verboseLogging: Bool { didSet { persist() } }
    /// Keep openfortivpn's per-packet "pppd ---> gateway" trace lines (thousands per minute).
    @Published var verbosePackets: Bool { didSet { persist() } }
    @Published var autoReconnect: Bool { didSet { persist() } }
    /// Probe each connected tunnel's DNS server periodically and reconnect a tunnel that stops answering.
    @Published var watchdog: Bool { didSet { persist() } }
    /// Block the Mac's internet while a VPN that carries all traffic is down without having been switched off.
    @Published var killSwitch: Bool { didSet { persist() } }
    /// V2Ray and Outline: .ir names and Iranian addresses skip the server and go direct.
    @Published var bypassIran: Bool { didSet { persist() } }
    /// Settings → MCP: run the MCP server so assistants can control the app.
    @Published var mcpEnabled: Bool { didSet { persist() } }
    /// Settings → General: download updates in the background and install them when no tunnel is up.
    @Published var autoUpdate: Bool { didSet { persist() } }

    let directory: URL
    let fileURL: URL
    private var isLoading = true
    private var pendingSave: DispatchWorkItem?

    private struct FileFormat: Codable {
        var version: Int = 1
        var showNameInMenuBar: Bool = false
        var verboseLogging: Bool = false
        var verbosePackets: Bool = false
        var autoReconnect: Bool = true
        var watchdog: Bool = true
        var killSwitch: Bool = false
        var bypassIran: Bool?   // nil: a file from before this was one setting for all connections
        var mcpEnabled: Bool = true
        var autoUpdate: Bool = true
        var connections: [Connection] = []
        /// Connections in the file that could not be read. Not saved: CodingKeys leaves it out.
        var unreadable = 0

        private enum CodingKeys: String, CodingKey {
            case version, showNameInMenuBar, verboseLogging, verbosePackets, autoReconnect, watchdog, killSwitch, bypassIran, mcpEnabled, autoUpdate, connections
        }
        /// One list entry that decodes to nil instead of failing the whole file.
        private struct Lossy: Decodable {
            let value: Connection?
            init(from decoder: Decoder) throws { value = try? Connection(from: decoder) }
        }

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            showNameInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showNameInMenuBar) ?? false
            verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
            verbosePackets = try c.decodeIfPresent(Bool.self, forKey: .verbosePackets) ?? false
            autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
            watchdog = try c.decodeIfPresent(Bool.self, forKey: .watchdog) ?? true
            killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? false
            bypassIran = try c.decodeIfPresent(Bool.self, forKey: .bypassIran)
            mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? true
            autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
            // One connection FiveT cannot read (written by a newer version, say) must not cost the others.
            let all = try c.decodeIfPresent([Lossy].self, forKey: .connections) ?? []
            connections = all.compactMap(\.value)
            unreadable = all.count - connections.count
        }
    }

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("fivet", isDirectory: true)
        #if !DISTRIBUTION
        // Test copies (fivet-test-copy skill) keep their connections away from the real app's.
        if let test = ProcessInfo.processInfo.environment["FIVET_DATA_DIR"], !test.isEmpty {
            dir = URL(fileURLWithPath: test, isDirectory: true)
        }
        #endif
        directory = dir
        fileURL = directory.appendingPathComponent("connections.json")
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        var loaded = FileFormat()
        var seeded = false
        let data = try? Data(contentsOf: fileURL)
        if let data, let f = try? JSONDecoder().decode(FileFormat.self, from: data) {
            loaded = f
        } else {
            loaded.connections = Connection.seeds
            seeded = true
        }
        // A file that is there but cannot be read (damaged, or partly from a newer FiveT) is kept under
        // another name before the save below replaces it: it holds the user's connections and passwords.
        var setAside: String?
        if let data, !data.isEmpty, seeded || loaded.unreadable > 0 {
            let name = "connections.unreadable-\(Int(Date().timeIntervalSince1970)).json"
            if fm.createFile(atPath: directory.appendingPathComponent(name).path, contents: data, attributes: [.posixPermissions: 0o600]) {
                setAside = name
            }
        }
        // Connections saved with blank lines pasted into their fields (a field shows only the first
        // line, so no one saw them) are repaired once here and saved again below.
        var repaired: [(name: String, fields: [String])] = []
        for i in loaded.connections.indices {
            let fields = loaded.connections[i].cleanPastedFields()
            if !fields.isEmpty { repaired.append((loaded.connections[i].name, fields)) }
        }
        connections = loaded.connections
        showNameInMenuBar = loaded.showNameInMenuBar
        verboseLogging = loaded.verboseLogging
        verbosePackets = loaded.verbosePackets
        autoReconnect = loaded.autoReconnect
        watchdog = loaded.watchdog
        killSwitch = loaded.killSwitch
        // It used to be set per connection: on, unless every V2Ray connection had it off.
        let v2ray = loaded.connections.filter(\.isV2Ray)
        bypassIran = loaded.bypassIran ?? (v2ray.isEmpty || v2ray.contains(where: \.v2rayIranDirect))
        mcpEnabled = loaded.mcpEnabled
        autoUpdate = loaded.autoUpdate
        isLoading = false
        if seeded || !repaired.isEmpty || loaded.unreadable > 0 { save() }
        if data?.isEmpty == false, seeded || loaded.unreadable > 0 {
            Log.shared.write("connections.json could not be read"
                             + (seeded ? "" : " in full (\(loaded.unreadable) connection(s) left out)")
                             + (setAside.map { "; the file as it was is kept as \($0)" } ?? ", and no copy of it could be kept"), level: .error)
        }
        for r in repaired {
            Log.shared.write("[\(r.name)] cleaned the pasted text in its saved \(r.fields.joined(separator: ", "))")
        }
    }

    /// Saves shortly after the last change, not on every one: typing in Settings changes
    /// `connections` with each keystroke, and each save rewrites the whole file. Main thread only.
    func persist() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a change that is still waiting (at quit).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        save()
    }

    private func snapshot() -> FileFormat {
        var f = FileFormat()
        f.showNameInMenuBar = showNameInMenuBar
        f.verboseLogging = verboseLogging
        f.verbosePackets = verbosePackets
        f.autoReconnect = autoReconnect
        f.watchdog = watchdog
        f.killSwitch = killSwitch
        f.bypassIran = bypassIran
        f.mcpEnabled = mcpEnabled
        f.autoUpdate = autoUpdate
        f.connections = connections
        return f
    }

    private func encoded(_ f: FileFormat) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(f)
    }

    private func save() {
        pendingSave = nil
        do {
            try encoded(snapshot()).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.shared.write("ERROR saving connections.json: \(error)", level: .error)
        }
    }

    // MARK: Backup file (.fivet)

    /// Every connection (with its saved passwords and one-time-code secrets) and every setting, as
    /// the text of a .fivet file: the same format as connections.json, so a newer FiveT can read an older file.
    func backupData() throws -> Data { try encoded(snapshot()) }

    /// Reads a .fivet file: its settings replace this Mac's, its connections are added (one with the
    /// same id as a saved connection replaces it). Throws, changing nothing, when it is not a FiveT file.
    /// Returns what happened, as a sentence for the user.
    func restore(from data: Data) throws -> String {
        let f: FileFormat
        do { f = try JSONDecoder().decode(FileFormat.self, from: data) }
        catch { throw NSError(domain: "fivet", code: 1, userInfo: [NSLocalizedDescriptionKey: "This is not a FiveT settings file."]) }
        var added = 0, replaced = 0
        var list = connections
        for c in f.connections {
            if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c; replaced += 1 } else { list.append(c); added += 1 }
        }
        connections = list
        showNameInMenuBar = f.showNameInMenuBar
        verboseLogging = f.verboseLogging
        verbosePackets = f.verbosePackets
        autoReconnect = f.autoReconnect
        watchdog = f.watchdog
        if killSwitch != f.killSwitch { killSwitch = f.killSwitch; VPNManager.shared.killSwitchChanged() }
        bypassIran = f.bypassIran ?? bypassIran
        mcpEnabled = f.mcpEnabled
        autoUpdate = f.autoUpdate
        Log.shared.write("imported a .fivet file: \(added) connection(s) added, \(replaced) replaced, \(f.unreadable) unreadable")
        return "Imported \(added) new and \(replaced) updated connection(s) and the settings."
            + (f.unreadable > 0 ? " \(f.unreadable) could not be read (made by a newer FiveT?)." : "")
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// A connection named by a person or a program (MCP tools, the CLI, fivet:// links): the exact
    /// name ignoring case first, then the id, then a name that starts with it, if only one does.
    static func find(_ raw: String, in conns: [Connection]) -> Connection? {
        let q = raw.trimmed
        guard !q.isEmpty else { return nil }
        if let c = conns.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return c }
        if let id = UUID(uuidString: q), let c = conns.first(where: { $0.id == id }) { return c }
        let prefix = conns.filter { $0.name.lowercased().hasPrefix(q.lowercased()) }
        return prefix.count == 1 ? prefix[0] : nil
    }

    /// Only the exact name (ignoring case) or the id: a saved fivet:// link must not reach another
    /// connection after a rename, and a web page must not reach one by a single letter.
    static func findExact(_ raw: String, in conns: [Connection]) -> Connection? {
        let q = raw.trimmed
        guard !q.isEmpty else { return nil }
        if let c = conns.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return c }
        if let id = UUID(uuidString: q) { return conns.first { $0.id == id } }
        return nil
    }

    func update(_ c: Connection) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) {
            connections[i] = c
        }
    }

    /// Changes one field of the stored copy without clobbering others with a stale snapshot.
    func mutate(id: UUID, _ change: (inout Connection) -> Void) {
        if let i = connections.firstIndex(where: { $0.id == id }) {
            change(&connections[i])
        }
    }

    @discardableResult
    func add() -> Connection {
        let c = Connection()
        connections.append(c)
        return c
    }

    /// Adds a connection made elsewhere (an imported OpenVPN profile).
    @discardableResult
    func add(_ c: Connection) -> Connection {
        connections.append(c)
        return c
    }

    func remove(id: UUID) {
        connections.removeAll { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<Connection> {
        Binding(
            get: { self.connections.first { $0.id == id } ?? Connection() },
            set: { new in
                if let i = self.connections.firstIndex(where: { $0.id == id }) {
                    // Every edit in Settings passes here: a paste with blank lines is cleaned at once.
                    var c = new
                    let breaks = c.lineBreakCount
                    c.cleanPastedFields()
                    self.connections[i] = c
                    // SwiftUI does not put a different value into a field while it is being edited, so
                    // the field would keep showing the paste (its last line, which is empty) until it
                    // is left. Ending the edit shows the cleaned text now. Only the edit that removed
                    // line breaks does this: one that is left in a password must not take the focus
                    // away at every keystroke.
                    if c.lineBreakCount < breaks { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
                }
            }
        )
    }
}
