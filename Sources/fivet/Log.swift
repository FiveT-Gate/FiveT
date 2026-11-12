import Foundation

enum LogLevel: String, Comparable, CaseIterable {
    case debug, info, error

    private var rank: Int { self == .debug ? 0 : (self == .info ? 1 : 2) }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }

    var tag: String { rawValue.uppercased() }
    /// The tag padded to the five characters of the log's level column.
    var paddedTag: String { self == .debug ? "DEBUG" : (self == .info ? "INFO " : "ERROR") }
}

/// One log line. `connection` is the `[name]` prefix of the message ("mcp" is not a connection).
struct LogEntry {
    let date: Date
    let level: LogLevel
    let connection: String?
    let message: String   // the full message, including the [name] prefix

    var line: String {
        "\(Log.formatter.string(from: date)) \(level.paddedTag) \(message)"
    }
}

/// Append-only log at ~/Library/Logs/fivet/fivet.log plus an in-memory tail that
/// "Copy Diagnostics", the MCP `get_log` tool and the CLI read. Never log passwords.
///
/// Levels: `error` for failures, `info` for events (connect, auth, tunnel up, DNS, routes,
/// MCP calls), `debug` for openfortivpn's DEBUG chatter. Packet traces are dropped before
/// they get here unless the "packet traces" setting is on (see VPNManager.handle).
final class Log {
    static let shared = Log()

    let fileURL: URL
    private let queue = DispatchQueue(label: "fivet.log")
    private var recent: [LogEntry] = []
    private let maxRecent = 2000
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private static let maxBytes: UInt64 = 2_000_000

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/fivet", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("fivet.log")
        openFile()
        if size > Self.maxBytes { rotate() }
    }

    /// Opens the log in append mode (creating it when missing) and notes its size. O_APPEND puts
    /// every line at the file's real end. Without it, a log emptied while FiveT ran (or written by
    /// a second copy of FiveT) got the next line at the old offset and the gap filled with zero
    /// bytes: 1.2 MB of them in one log, enough for grep to call it a binary file.
    private func openFile() {
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// Keeps the log under ~2 MB while the app runs for weeks: the full file becomes
    /// fivet.log.1 (replacing the previous one) and a fresh fivet.log is started.
    private func rotate() {
        try? handle?.close()
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        openFile()
    }

    func write(_ message: String, level: LogLevel = .info) {
        // One entry, one line: text from outside (a link, an assistant's arguments, a gateway) must
        // not be able to add lines that look like FiveT's own.
        let message = message.contains(where: \.isNewline)
            ? message.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ") : message
        let entry = LogEntry(date: Date(), level: level, connection: Log.connection(in: message), message: message)
        queue.async {
            self.recent.append(entry)
            // Dropped in batches: taking one entry off the front of a full array moves the other 1,999
            // every time, and a detailed log can be a few thousand lines a second.
            if self.recent.count > self.maxRecent + 250 {
                self.recent.removeFirst(self.recent.count - self.maxRecent)
            }
            if let data = (self.fileLine(entry) + "\n").data(using: .utf8) {
                // The throwing API: the old write(_:) raises an exception (a crash) when the disk is full.
                try? self.handle?.write(contentsOf: data)
                // After an append the offset is the file's size, whoever else wrote to it.
                self.size = (try? self.handle?.offset()) ?? (self.size + UInt64(data.count))
                if self.size > Self.maxBytes { self.rotate() }
            }
        }
    }

    private var stampSecond = 0
    private var stampText = ""

    /// entry.line, with the date and time formatted once for each second instead of once per line
    /// (queue only: it keeps the last one).
    private func fileLine(_ e: LogEntry) -> String {
        let second = Int(e.date.timeIntervalSince1970)
        if second != stampSecond { stampSecond = second; stampText = Log.formatter.string(from: e.date) }
        return "\(stampText) \(e.level.paddedTag) \(e.message)"
    }

    /// Filtered view of the in-memory tail: at least `level`, optionally one connection,
    /// after `since`, containing `grep` (case-insensitive); the last `last` matches.
    func entries(level: LogLevel = .info, connection: String? = nil, since: Date? = nil,
                 grep: String? = nil, last: Int = 60) -> [LogEntry] {
        let all = queue.sync { recent }
        let conn = connection?.trimmed.lowercased()
        let needle = grep?.trimmed.lowercased()
        var out: [LogEntry] = []
        for e in all.reversed() {
            guard e.level >= level else { continue }
            if let conn, !conn.isEmpty, e.connection?.lowercased() != conn { continue }
            if let since, e.date < since { continue }
            if let needle, !needle.isEmpty, !e.message.lowercased().contains(needle) { continue }
            out.append(e)
            if out.count >= last { break }
        }
        return out.reversed()
    }

    /// Logs written before 1.8 can hold openfortivpn's session cookie (a live login, logged with
    /// Detailed log on) and one-time codes, and an older FiveT still running next to this one (or
    /// started later from an old disk image) can add more. At every launch, rewrite the log files
    /// with those values hidden; a file with nothing to hide is only read (about 2 MB at most).
    func scrubOldSecrets() {
        queue.async {
            var hidden = 0
            for url in [self.fileURL.appendingPathExtension("1"), self.fileURL] {
                // Nearly every file has nothing to hide, and masked() only ever changes a line that holds
                // one of its markers: look at those lines in the raw bytes first, so a normal launch does
                // not split two 2 MB files into lines (about 360 ms and 10 MB). Read, not mapped: another
                // copy of FiveT can truncate the file while this one looks at it.
                guard let data = try? Data(contentsOf: url), Log.hasSecret(in: data) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                var changed = false
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                    let s = String(line)
                    let m = VPNManager.masked(s)
                    if m != s { changed = true; hidden += 1 }
                    return m
                }
                guard changed else { continue }
                // In place, not by replacing the file: whoever has it open for appending (this
                // handle, another copy of FiveT) keeps writing into it, at its new end (O_APPEND).
                guard let h = try? FileHandle(forWritingTo: url) else { continue }
                try? h.truncate(atOffset: 0)
                try? h.write(contentsOf: Data(lines.joined(separator: "\n").utf8))
                try? h.close()
                if url == self.fileURL { self.size = (try? self.handle?.seekToEnd()) ?? 0 }
            }
            if hidden > 0 {
                DispatchQueue.main.async { self.write("hid \(hidden) secret value(s) (session cookies, one-time codes, unreadable config lines) in older log lines") }
            }
        }
    }

    /// Whether a line of `data` holds a marker AND masked() would change it. A log written with Detailed
    /// log on is full of lines whose cookie is already hidden: they hold the marker and need nothing. After
    /// 300 such hits it answers yes and leaves the verdict to the full pass, so a file of them is never
    /// slower than it was before this check.
    static func hasSecret(in data: Data) -> Bool {
        var hits = 0
        for marker in VPNManager.maskedMarkers {
            let needle = Data(marker.utf8)
            var from = data.startIndex
            while from < data.endIndex, let hit = data.range(of: needle, in: from..<data.endIndex) {
                hits += 1
                if hits > 300 { return true }
                var start = hit.lowerBound, end = hit.upperBound
                while start > data.startIndex, data[start - 1] != 0x0A { start -= 1 }
                while end < data.endIndex, data[end] != 0x0A { end += 1 }
                let line = String(decoding: data[start..<end], as: UTF8.self)
                if VPNManager.masked(line) != line { return true }
                from = end
            }
        }
        return false
    }

    /// Event lines (info and above) for diagnostics.
    func recentText(level: LogLevel = .info, last: Int = 300) -> String {
        entries(level: level, last: last).map(\.line).joined(separator: "\n")
    }

    /// "[Office] Tunnel is up" → "Office"; "[mcp] ..." → nil.
    static func connection(in message: String) -> String? {
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else { return nil }
        let tag = String(message[message.index(after: message.startIndex)..<close])
        return tag == "mcp" || tag.isEmpty ? nil : tag
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
