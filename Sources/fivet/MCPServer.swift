import Foundation
import Combine

// FiveT as an MCP server (Model Context Protocol), so AI assistants such as Claude Desktop,
// Claude Code or Cursor can see and control the VPN. Shell scripts get the same tools through
// the CLI (`FiveT status`, `FiveT connect Office`, …), see FiveTCLI at the bottom.
//
// How the pieces fit:
//
//   assistant ──spawns──▶ `FiveT --mcp` (MCPBridge, plain stdio)      shell ──▶ `FiveT status` (FiveTCLI)
//                              │  Unix socket, mode 0600                              │
//                              ▼◀───────────────────────────────────────────────────────┘
//                        FiveT.app (MCPServer, the process that owns the tunnel)
//
// MCP clients start a fresh process per session and talk JSON-RPC 2.0 over its stdin/stdout,
// one JSON object per line. The VPN state lives in the running menu bar app, so that process
// is only a bridge: it forwards the bytes to the app's socket (starting the app if needed).
// The app itself answers `initialize`, `tools/list` and `tools/call`.

// MARK: - Socket location

enum MCPPaths {
    /// The socket lives inside the 0700 app-support folder and is itself 0600, so only
    /// programs running under this macOS account can reach it.
    /// `FIVET_SOCKET=/path` overrides it (used to test a second copy of the app side by side).
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["FIVET_SOCKET"], !override.isEmpty { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("fivet/mcp.sock").path
    }

    /// Fills a `sockaddr_un` for `path`, or nil when the path is too long for one (104 bytes).
    static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        return addr
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - JSON-RPC plumbing

struct RPCError: Error {
    let code: Int
    let message: String
    init(_ code: Int, _ message: String) { self.code = code; self.message = message }
}

enum MCPJSON {
    static func data(_ object: Any, pretty: Bool = false) -> Data? {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: object, options: opts)
    }

    /// Readable JSON for the text half of a tool result. JSONSerialization escapes "/" as "\/",
    /// which is valid but ugly for a model to read, so undo that.
    static func pretty(_ object: Any) -> String {
        guard let d = data(object, pretty: true), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s.replacingOccurrences(of: "\\/", with: "/")
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts "2026-09-05T19:25:38Z", "...+03:30", fractional seconds, or "2026-09-05 19:25:38" (local time).
    static func date(from s: String) -> Date? {
        let t = s.trimmed
        if let d = iso.date(from: t) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: t) { return d }
        return Log.formatter.date(from: t)
    }
}

/// Writes whole lines to a file descriptor, serialised so concurrent replies never interleave.
final class LineWriter {
    let fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    func send(_ object: [String: Any]) {
        guard var data = MCPJSON.data(object) else { return }
        data.append(0x0A)
        write(data)
    }

    private var closed = false

    /// Closes the descriptor; later writes do nothing. A reply still being worked out when its client
    /// hangs up (connect waits up to 5 minutes) would otherwise go to whatever reuses the number.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                off += n
            }
        }
    }
}

/// Reads newline-delimited JSON objects from a file descriptor.
struct LineReader {
    let fd: Int32
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(fd: Int32) { self.fd = fd }

    /// Next complete line, or nil at EOF / error.
    mutating func nextLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// One connected assistant.
final class MCPClientSession {
    let fd: Int32
    let writer: LineWriter
    var clientName = "assistant"

    init(fd: Int32) { self.fd = fd; writer = LineWriter(fd: fd) }
    func send(_ object: [String: Any]) { writer.send(object) }
}

// MARK: - Server

/// Listens on the Unix socket and answers MCP requests. Start/stop on the main thread;
/// every request is handled on a background queue and hops onto the main thread only
/// for the moments it touches VPNManager / ConnectionStore.
final class MCPServer: ObservableObject {
    static let shared = MCPServer()
    static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    @Published private(set) var isListening = false
    @Published private(set) var clientCount = 0

    private var listenFD: Int32 = -1
    /// Woken when someone connects, so the server costs nothing while nobody does.
    private var acceptSource: DispatchSourceRead?
    /// Bumped by every start() and stop(); a wake-up of the accept source acts only while it still
    /// holds the current value, so an off/on cannot leave the old one taking connections.
    private var generation = 0
    private let lock = NSLock()
    private var clients: [Int32: MCPClientSession] = [:]
    /// When acceptPending last logged an accept error (the accept queue only).
    private var acceptErrorLogged = Date.distantPast

    private init() {}

    func start() {
        guard listenFD < 0 else { return }
        let path = MCPPaths.socketPath
        guard var addr = MCPPaths.address(for: path) else {
            Log.shared.write("[mcp] cannot listen: socket path is too long (\(path))", level: .error)
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.shared.write("[mcp] socket() failed: \(String(cString: strerror(errno)))", level: .error)
            return
        }
        unlink(path)   // a stale file from an earlier crash would make bind() fail
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            Log.shared.write("[mcp] bind() failed: \(String(cString: strerror(errno)))", level: .error)
            close(fd)
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            Log.shared.write("[mcp] listen() failed: \(String(cString: strerror(errno)))", level: .error)
            close(fd)
            unlink(path)
            return
        }
        listenFD = fd
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        isListening = true
        Log.shared.write("[mcp] listening on \(path)")
        // Woken by a connection, not by a timer: the thread this replaces polled every 500 ms for as
        // long as FiveT ran. The socket is non-blocking so one wake-up takes every connection that
        // waits (accept answers EAGAIN after the last one).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // User-initiated: the client threads started from this queue take its priority, as they did from
        // the accept thread this replaces, so an assistant's request is not served at a background priority.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                   queue: DispatchQueue(label: "fivet.mcp.accept", qos: .userInitiated))
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            self?.acceptPending(fd, gen, source)
        }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    func stop() {
        guard listenFD >= 0 else { return }
        Log.shared.write("[mcp] stopping")
        lock.lock()
        generation += 1
        let open = Array(clients.keys)
        lock.unlock()
        // shutdown() wakes each client thread out of read(); the thread closes its own fd.
        for fd in open { shutdown(fd, SHUT_RDWR) }
        unlink(MCPPaths.socketPath)
        acceptSource?.cancel()   // its cancel handler closes the listening socket
        acceptSource = nil
        listenFD = -1
        isListening = false
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    private func acceptPending(_ fd: Int32, _ gen: Int, _ source: DispatchSourceRead) {
        while isCurrent(gen) {
            let c = accept(fd, nil, nil)
            if c < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue   // the caller hung up before we got to it
                case EAGAIN: return                  // the last one is taken
                default:
                    // The source fires again for as long as a connection waits, so an error that does not
                    // go away at once (out of descriptors) would spin a core: pause it for a moment. Said
                    // once in a while, not four times a second for as long as it lasts.
                    let now = Date()
                    if now.timeIntervalSince(acceptErrorLogged) > 30 {
                        acceptErrorLogged = now
                        Log.shared.write("[mcp] accept() failed, pausing 250 ms at a time: \(String(cString: strerror(errno)))", level: .error)
                    }
                    source.suspend()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { source.resume() }
                    return
                }
            }
            // stop() came in between the check above and the accept: nobody is left to serve this one.
            guard isCurrent(gen) else { close(c); return }
            // macOS gives an accepted socket the listening socket's O_NONBLOCK; a client thread reads blocking.
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let session = MCPClientSession(fd: c)
            register(session)
            let t = Thread { [weak self] in self?.serve(session) }
            t.name = "fivet.mcp.client"
            t.start()
        }
    }

    private func register(_ s: MCPClientSession) {
        lock.lock(); clients[s.fd] = s; let n = clients.count; lock.unlock()
        DispatchQueue.main.async { self.clientCount = n }
        Log.shared.write("[mcp] assistant connected (\(n) total)", level: .debug)
    }

    private func unregister(_ s: MCPClientSession) {
        lock.lock(); clients[s.fd] = nil; let n = clients.count; lock.unlock()
        DispatchQueue.main.async { self.clientCount = n }
        Log.shared.write("[mcp] \(s.clientName) disconnected (\(n) left)", level: .debug)
    }

    private func serve(_ session: MCPClientSession) {
        var reader = LineReader(fd: session.fd)
        while let line = reader.nextLine() {
            handle(line: line, session: session)
        }
        unregister(session)
        session.writer.close()
    }

    private func handle(line: Data, session: MCPClientSession) {
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) else {
            session.send(errorReply(id: NSNull(), RPCError(-32700, "Parse error")))
            return
        }
        if let batch = obj as? [[String: Any]] {
            for m in batch { dispatch(m, session) }
        } else if let msg = obj as? [String: Any] {
            dispatch(msg, session)
        } else {
            session.send(errorReply(id: NSNull(), RPCError(-32600, "Invalid request")))
        }
    }

    private func dispatch(_ msg: [String: Any], _ session: MCPClientSession) {
        let id = msg["id"]
        let isNotification = id == nil || id is NSNull
        guard let method = msg["method"] as? String else {
            // Either a response to a request we never sent, or junk. Nothing to answer.
            return
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        if isNotification {
            if method == "notifications/initialized" { Log.shared.write("[mcp] \(session.clientName) ready", level: .debug) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let reply: [String: Any]
            do {
                let result = try handle(method: method, params: params, session: session)
                reply = ["jsonrpc": "2.0", "id": id!, "result": result]
            } catch let e as RPCError {
                reply = errorReply(id: id!, e)
            } catch {
                reply = errorReply(id: id!, RPCError(-32603, "\(error)"))
            }
            session.send(reply)
        }
    }

    private func errorReply(id: Any, _ e: RPCError) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]]
    }

    static let instructions = """
        FiveT is a macOS menu bar app that manages FortiGate SSL-VPN connections (via openfortivpn). \
        Use list_connections to see the saved connections and get_status for the current state, including \
        the tunnel interface, the DNS servers and routes the gateway pushed. connect starts a tunnel and by \
        default waits until it is up or has failed (about 1 s when the gateway answers; up to timeout_seconds); \
        it is idempotent. One VPN (OpenVPN, V2Ray, Outline) is up at a time, next to Forti connections: connect \
        disconnects the VPN that is up first, the same as clicking another VPN in the menu, and leaves Forti \
        connections alone. disconnect stops it, with or without a name. \
        get_status reports the most recent tunnel at the top level and every tunnel under "sessions". \
        With the kill switch on (Settings → General), a V2Ray, Outline or full-tunnel OpenVPN connection that \
        drops leaves the Mac's internet blocked until it is back or disconnect is called: get_status then has \
        "kill_switch_blocking": true, and that, not the network, is why nothing is reachable. \
        DNS caveat: macOS installs the gateway's DNS as a resolver scoped to the tunnel interface. When another \
        VPN owns the default route, normal apps (curl, Python, browsers) do not use it and internal host names \
        fail to resolve while `nslookup` against the pushed DNS server works. The fix is split DNS: FiveT writes \
        /etc/resolver/<domain> while connected for the DNS suffixes the gateway pushes and for the domains \
        listed under the connection's "DNS domains" (Settings → Forti or VPN); add internal domains the \
        gateway does not push. Use resolve and check_reachability to diagnose "VPN up but \
        host unreachable" in one call; they report both the tunnel DNS and the system resolver. \
        get_log returns event lines (info and errors) by default; ask for level "debug" for openfortivpn chatter. \
        Passwords and one-time-code secrets are never exposed.
        """

    private func handle(method: String, params: [String: Any], session: MCPClientSession) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                let v = (info["version"] as? String).map { " \($0)" } ?? ""
                session.clientName = name + v
            }
            Log.shared.write("[mcp] initialize from \(session.clientName) (protocol \(requested) → \(version))", level: .debug)
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "fivet", "title": "FiveT VPN", "version": MCPPaths.appVersion],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": MCPTools.definitions]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError(-32602, "Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let shown = args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            Log.shared.write("[mcp] \(session.clientName) → \(name) \(shown)")
            return try MCPTools.call(name, args)
        default:
            throw RPCError(-32601, "Method not found: \(method)")
        }
    }
}

// MARK: - Tools

/// What an assistant may do. Read-only tools never block; connect/disconnect wait for the
/// tunnel to settle so the assistant gets a real outcome instead of "started".
enum MCPTools {
    static let definitions: [[String: Any]] = [
        tool("get_status",
             "Current VPN state (disconnected / connecting / connected / disconnecting), which connection, uptime, progress detail, last error, and once connected the network facts: interface, tunnel IP, DNS servers, search domains, routes pushed by the gateway, the Mac's own interface and address the tunnel runs over (outer_interface / outer_ip; when that address disappears, e.g. on a move to another Wi-Fi network, FiveT reconnects the tunnel, or disconnects it when auto-reconnect is off), and split-DNS state. The top level describes one tunnel (one that is changing state first, else the most recently connected); \"sessions\" lists every tunnel the same way and \"active_connections\" their names. \"kill_switch_blocking\" is true while the kill switch blocks the Mac's internet because a VPN dropped.",
             readOnly: true),
        tool("list_connections",
             "The saved VPN connections: name, gateway, username, one-time-code mode, split-DNS domains, last successful connect time, last error, and each one's state (one Forti connection and one VPN can be connected together; two VPNs cannot). Never includes passwords.",
             readOnly: true),
        tool("connect",
             "Connect to a saved VPN connection by name. One VPN (OpenVPN, V2Ray, Outline) is up at a time: another VPN that is up is disconnected first; Forti connections are not touched. Idempotent: if that connection is already up it returns outcome \"already_connected\" with the uptime and does not reconnect. By default waits until the tunnel is up or the attempt failed and returns the resulting status with network facts. After failed logins to a gateway FiveT stops (one more failure gets the Mac's internet address banned there): it then returns outcome \"login_limit_reached\" without logging in. Never retry that; the user decides, in FiveT's menu.",
             properties: [
                "name": ["type": "string", "description": "Connection name as shown by list_connections (case-insensitive; the id also works)."],
                "timeout_seconds": ["type": "integer", "minimum": 5, "maximum": 300, "default": 60, "description": "How long to wait for the tunnel before returning outcome \"still_connecting\"."],
                "wait": ["type": "boolean", "default": true, "description": "false returns immediately with outcome \"started\"; poll get_status afterwards."],
             ],
             required: ["name"]),
        tool("disconnect",
             "Disconnect the VPN connection (by name, or without a name whatever is up). Also stops a reconnect loop and lifts a kill switch block. Waits until the tunnel is down and returns the resulting status. Safe to call when nothing is connected.",
             properties: [
                "name": ["type": "string", "description": "Connection name as shown by list_connections (case-insensitive; the id also works). Omit to disconnect all."],
             ]),
        tool("get_log",
             "Recent lines of FiveT's log: connect/disconnect events, authentication, tunnel up, DNS and routes, errors, MCP calls. Default level \"info\" hides openfortivpn's DEBUG chatter; packet traces are never stored unless enabled in Settings.",
             properties: [
                "lines": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 60, "description": "How many trailing lines to return (after filtering)."],
                "level": ["type": "string", "enum": ["error", "info", "debug"], "default": "info", "description": "Minimum level: error = failures only; info = events; debug = everything."],
                "connection": ["type": "string", "description": "Only lines tagged with this connection name."],
                "since": ["type": "string", "description": "Only lines at or after this time (ISO 8601, e.g. 2026-09-05T19:25:00Z, or \"2026-09-05 19:25:00\" local time)."],
                "grep": ["type": "string", "description": "Only lines containing this text (case-insensitive)."],
             ],
             readOnly: true),
        tool("get_diagnostics",
             "Full diagnostics text: setup checks (openfortivpn, helper, split-DNS helper), app version, status, network facts, connections without secrets, and the recent event log.",
             readOnly: true),
        tool("resolve",
             "Resolve a host name two ways: directly against the tunnel's DNS servers (what nslookup does) and through the system resolver (what curl, Python and apps use). Different answers mean split DNS is needed for that domain.",
             properties: ["host": ["type": "string", "description": "Host name, e.g. wiki.corp.example."]],
             required: ["host"],
             readOnly: true),
        tool("check_reachability",
             "One-call diagnosis of \"VPN up but host unreachable\": resolves the host via tunnel DNS and system DNS, checks whether the address is covered by a pushed route, then tries a TCP connect to host:port (3 s timeout) and returns a plain-language diagnosis.",
             properties: [
                "host": ["type": "string", "description": "Host name or IP address."],
                "port": ["type": "integer", "minimum": 1, "maximum": 65535, "default": 443],
             ],
             required: ["host"],
             readOnly: true),
    ]

    private static func tool(_ name: String, _ description: String,
                             properties: [String: Any] = [:], required: [String] = [],
                             readOnly: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        let annotations: [String: Any] = readOnly
            ? ["readOnlyHint": true, "openWorldHint": false]
            : ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        return ["name": name, "description": description, "inputSchema": schema, "annotations": annotations]
    }

    static func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_status":
            return result(withSessions(statusDict(currentStatus())))

        case "list_connections":
            let (conns, states, up, failed) = onMain {
                (ConnectionStore.shared.connections,
                 ConnectionStore.shared.connections.map { VPNManager.shared.status(for: $0.id) },
                 VPNManager.shared.connected.compactMap(\.connectionName),
                 ConnectionStore.shared.connections.map { LoginGuard.shared.count(for: $0.loginGuardKey) })
            }
            return result(["connections": conns.indices.map { summary(conns[$0], states[$0], failedLogins: failed[$0]) },
                           "active": up.last ?? NSNull(), "active_connections": up])

        case "connect":
            guard let raw = args["name"] as? String, !raw.trimmed.isEmpty else {
                throw RPCError(-32602, "'name' is required")
            }
            let timeout = Double(min(max(intArg(args["timeout_seconds"]) ?? 60, 5), 300))
            let wait = (args["wait"] as? Bool) ?? true
            let conns = onMain { ConnectionStore.shared.connections }
            guard let c = resolve(raw, in: conns) else {
                let names = conns.map { "'\($0.name)'" }.joined(separator: ", ")
                return result(["outcome": "unknown_connection", "message": "No connection called '\(raw)'. Saved connections: \(names)."], isError: true)
            }
            let before = status(for: c.id)
            if let before, before.phase == .connected {
                var d = withSessions(statusDict(before)); d["outcome"] = "already_connected"
                d["message"] = "\(c.name) has been connected for \(VPNStatus.durationText(before.uptimeSeconds ?? 0))."
                return result(d)
            }
            if let before, before.phase == .connecting && !wait {
                var d = withSessions(statusDict(before)); d["outcome"] = "started"; d["message"] = "\(c.name) is already connecting."
                return result(d)
            }
            let others = c.isOtherVPN ? onMain { VPNManager.shared.connected.filter { $0.connectionID != c.id && ConnectionStore.shared.connection(id: $0.connectionID ?? UUID())?.isOtherVPN == true }.compactMap(\.connectionName) } : []
            onMain { VPNManager.shared.connect(c) }
            if !wait {
                var d = withSessions(statusDict(status(for: c.id) ?? currentStatus())); d["outcome"] = "started"
                d["message"] = "Connecting to \(c.name); poll get_status."
                return result(d)
            }
            // Watch this connection's own tunnel (the one that was up is on its way down).
            let st = waitSession(id: c.id, timeout: timeout) { $0 == nil || $0?.phase == .connected }
            if let st, st.phase == .connected {
                var d = withSessions(statusDict(st))
                d["outcome"] = "connected"
                if !others.isEmpty { d["message"] = "\(c.name) is up; \(others.joined(separator: ", ")) was disconnected (one VPN at a time)." }
                return result(d)
            }
            guard let st else {
                var d = withSessions(statusDict(currentStatus()))
                // This connection's own error (another tunnel starting would have cleared the global one).
                let after = onMain { ConnectionStore.shared.connection(id: c.id) }
                if onMain({ LoginGuard.shared.isLimited(c.loginGuardKey) }) {
                    // Retrying is exactly what must not happen: one more failure bans the address.
                    d["outcome"] = "login_limit_reached"
                    d["message"] = (after?.lastError ?? "The last logins to \(c.name)'s gateway failed.")
                        + " Do not retry and do not loop: only the user can decide to log in again, by clicking \(c.name) in FiveT's menu (FiveT asks them first)."
                } else if after?.hasPendingReview == true {
                    // Only the user can answer this, in FiveT's menu; retrying cannot.
                    d["outcome"] = "certificate_review_needed"
                    d["message"] = (after?.lastError ?? "\(c.name)'s gateway showed a certificate FiveT does not trust.")
                        + " Ask the user to choose Review New Certificate… in FiveT's menu; no tool can trust a certificate."
                } else {
                    d["outcome"] = "failed"
                    d["message"] = after?.lastError ?? onMain { VPNManager.shared.lastError } ?? "\(c.name) did not connect."
                }
                return result(d, isError: true)
            }
            var d = withSessions(statusDict(st))
            d["outcome"] = "still_connecting"
            d["message"] = "Still connecting after \(Int(timeout)) s. Call get_status to follow it, or disconnect to stop."
            return result(d)

        case "disconnect":
            if let raw = args["name"] as? String, !raw.trimmed.isEmpty {
                let conns = onMain { ConnectionStore.shared.connections }
                guard let c = resolve(raw, in: conns) else {
                    let names = conns.map { "'\($0.name)'" }.joined(separator: ", ")
                    return result(["outcome": "unknown_connection", "message": "No connection called '\(raw)'. Saved connections: \(names)."], isError: true)
                }
                guard status(for: c.id) != nil else {
                    var d = withSessions(statusDict(currentStatus())); d["outcome"] = "not_connected"
                    d["message"] = "\(c.name) is not connected."
                    return result(d)
                }
                onMain { VPNManager.shared.disconnect(id: c.id) }
                let left = waitSession(id: c.id, timeout: 12) { $0 == nil }
                var d = withSessions(statusDict(currentStatus()))
                d["outcome"] = left == nil ? "disconnected" : "still_disconnecting"
                let up = onMain { VPNManager.shared.connected.compactMap(\.connectionName) }
                d["message"] = left == nil
                    ? "\(c.name) disconnected" + (up.isEmpty ? "." : "; \(up.joined(separator: ", ")) still connected.")
                    : "\(c.name) is still disconnecting."
                return result(d)
            }
            let before = currentStatus()
            if before.phase == .idle {
                var d = statusDict(before); d["outcome"] = "not_connected"
                return result(d)
            }
            onMain { VPNManager.shared.disconnect() }
            let st = self.wait(timeout: 12) { $0.phase == .idle }
            var d = withSessions(statusDict(st))
            d["outcome"] = st.phase == .idle ? "disconnected" : "still_disconnecting"
            return result(d)

        case "get_log":
            let n = min(max(intArg(args["lines"]) ?? 60, 1), 1000)
            let level = LogLevel(rawValue: ((args["level"] as? String) ?? "info").lowercased()) ?? .info
            var since: Date? = nil
            if let s = args["since"] as? String, !s.trimmed.isEmpty {
                guard let d = MCPJSON.date(from: s) else { throw RPCError(-32602, "'since' is not an ISO 8601 timestamp: \(s)") }
                since = d
            }
            let entries = Log.shared.entries(level: level, connection: args["connection"] as? String,
                                             since: since, grep: args["grep"] as? String, last: n)
            // Same JSON in text and structuredContent, like every other tool.
            return result(["lines": entries.map(\.line), "count": entries.count, "level": level.rawValue])

        case "get_diagnostics":
            let checks = Setup.checks()   // runs processes: here, not on the main thread
            return text(onMain { Diagnostics.text(checks: checks) })

        case "resolve":
            guard let host = (args["host"] as? String)?.trimmed, !host.isEmpty else { throw RPCError(-32602, "'host' is required") }
            return result(NetTools.resolve(host: host, status: mergedStatus()))

        case "check_reachability":
            guard let host = (args["host"] as? String)?.trimmed, !host.isEmpty else { throw RPCError(-32602, "'host' is required") }
            let port = min(max(intArg(args["port"]) ?? 443, 1), 65535)
            let r = NetTools.checkReachability(host: host, port: port, status: mergedStatus())
            return result(r, isError: (r["reachable"] as? Bool) == false)

        default:
            throw RPCError(-32602, "Unknown tool: \(name)")
        }
    }

    // MARK: helpers

    static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    static func currentStatus() -> VPNStatus {
        onMain { VPNManager.shared.status }
    }

    static func status(for id: UUID) -> VPNStatus? {
        onMain { VPNManager.shared.status(for: id) }
    }

    /// Every connected tunnel folded into one status: the DNS servers and routes of all of them,
    /// so resolve / check_reachability look at the whole picture when two tunnels are up.
    static func mergedStatus() -> VPNStatus {
        let up = onMain { VPNManager.shared.connected }
        guard up.count > 1, var st = up.last else { return currentStatus() }
        var n = NetworkInfo()
        for s in up {
            guard let x = s.network else { continue }
            if !x.interface.isEmpty { n.interface += (n.interface.isEmpty ? "" : "+") + x.interface }
            if n.tunnelIP.isEmpty { n.tunnelIP = x.tunnelIP; n.peerIP = x.peerIP }
            for d in x.dnsServers where !n.dnsServers.contains(d) { n.dnsServers.append(d) }
            for d in x.searchDomains where !n.searchDomains.contains(d) { n.searchDomains.append(d) }
            for r in x.routes where !n.routes.contains(r) { n.routes.append(r) }
        }
        st.network = n
        st.connectionName = up.compactMap(\.connectionName).joined(separator: " + ")
        st.splitDNS = up.compactMap(\.splitDNS).first
        return st
    }

    /// Adds "sessions" (every active tunnel) and "active_connections" to a status payload.
    static func withSessions(_ d: [String: Any]) -> [String: Any] {
        var d = d
        let all = onMain { VPNManager.shared.sessions }
        d["sessions"] = all.map { statusDict($0) }
        d["active_connections"] = all.filter { $0.phase == .connected }.compactMap(\.connectionName)
        d["kill_switch_blocking"] = onMain { VPNManager.shared.killSwitchActive }
        return d
    }

    private static func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// Polls the status until `done` is true or the timeout passes; returns the last status seen.
    private static func wait(timeout: TimeInterval, until done: (VPNStatus) -> Bool) -> VPNStatus {
        let deadline = Date().addingTimeInterval(timeout)
        var st = currentStatus()
        while !done(st) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            st = currentStatus()
        }
        return st
    }

    /// Polls one connection's tunnel until `done` is true or the timeout passes; nil means
    /// the tunnel is gone (never started, failed, or disconnected).
    private static func waitSession(id: UUID, timeout: TimeInterval, until done: (VPNStatus?) -> Bool) -> VPNStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        var st = status(for: id)
        while !done(st) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            st = status(for: id)
        }
        return st
    }

    /// Exact name (case-insensitive) first, then the UUID, then a unique prefix.
    private static func resolve(_ raw: String, in conns: [Connection]) -> Connection? {
        ConnectionStore.find(raw, in: conns)
    }

    static func statusDict(_ st: VPNStatus) -> [String: Any] {
        var d: [String: Any] = ["state": st.stateName, "connection": st.connectionName ?? NSNull(),
                                "needs_setup": st.needsSetup, "summary": st.summary]
        if let id = st.connectionID { d["connection_id"] = id.uuidString }
        if let since = st.since {
            d["connected_since"] = MCPJSON.iso.string(from: since)
            d["uptime_seconds"] = st.uptimeSeconds ?? 0
        }
        if let detail = st.detail { d["detail"] = detail }
        if st.phase == .connected { d["health"] = st.health ?? "ok" }
        if let err = st.lastError { d["last_error"] = err }
        if let n = st.network {
            d["interface"] = n.interface
            d["dns_servers"] = n.dnsServers
            d["network"] = [
                "interface": n.interface,
                "tunnel_ip": n.tunnelIP,
                "peer_ip": n.peerIP,
                "dns_servers": n.dnsServers,
                "search_domains": n.searchDomains,
                "routes": n.routes,
                "outer_interface": n.outerInterface,
                "outer_ip": n.outerIP,
            ]
        }
        if let s = st.splitDNS {
            d["split_dns"] = ["domains": s.domains, "state": s.state, "detail": s.detail]
        }
        return d
    }

    private static func summary(_ c: Connection, _ st: VPNStatus?, failedLogins: Int) -> [String: Any] {
        let state = st?.stateName ?? "disconnected"
        return [
            "id": c.id.uuidString,
            "name": c.name,
            "type": c.isV2Ray ? "v2ray" : c.isOpenVPN ? "openvpn" : "fortigate",
            "gateway": c.gatewayDescription,
            "username": c.username,
            "one_time_code": c.otpMode.rawValue,
            "certificate_trusted": c.knowsGateway,
            // A gateway certificate FiveT did not trust by itself waits for the user (FiveT's menu →
            // Review New Certificate…); no tool can trust it.
            "certificate_review_needed": c.hasPendingReview,
            "dns_domains": c.dnsDomainList,
            // Failed logins in a row to this connection's gateway. At login_limit_reached FiveT logs
            // in only when the user clicks the connection and confirms: one more failure gets the
            // Mac's internet address banned at the gateway.
            "failed_logins": failedLogins,
            "login_limit_reached": failedLogins >= LoginGuard.limit,
            "last_connected_at": c.lastConnectedAt.map { MCPJSON.iso.string(from: $0) } ?? NSNull(),
            "last_error": c.lastError ?? NSNull(),
            "state": state,
        ]
    }

    static func result(_ payload: [String: Any], isError: Bool = false) -> [String: Any] {
        [
            "content": [["type": "text", "text": MCPJSON.pretty(payload)]],
            "structuredContent": payload,
            "isError": isError,
        ]
    }

    private static func text(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": false]
    }
}

// MARK: - Network diagnosis (resolve / check_reachability)

enum NetTools {
    /// Ask one DNS server directly, like nslookup does, bypassing the system resolver.
    static func query(host: String, server: String) -> (addresses: [String], error: String?) {
        let r = Setup.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@" + server, host, "A"])
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let addrs = lines.filter { isIPv4($0) }
        if r.status != 0 {
            let msg = lines.first { $0.contains("timed out") || $0.contains("connection") || $0.hasPrefix(";;") } ?? "dig exited \(r.status)"
            return ([], msg)
        }
        return (addrs, addrs.isEmpty ? "no A record" : nil)
    }

    /// The system resolver (getaddrinfo), which is what curl, Python and apps use.
    static func systemResolve(host: String) -> (addresses: [String], error: String?) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0 else { return ([], String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !out.contains(s) { out.append(s) }
            }
            p = ai.pointee.ai_next
        }
        return (out, out.isEmpty ? "no address" : nil)
    }

    static func isIPv4(_ s: String) -> Bool {
        let o = s.split(separator: ".", omittingEmptySubsequences: false)
        return o.count == 4 && o.allSatisfy { UInt8($0) != nil }
    }

    static func resolve(host: String, status st: VPNStatus) -> [String: Any] {
        var d: [String: Any] = ["host": host]
        let servers = st.network?.dnsServers ?? []
        var tunnelAddrs: [String] = []
        if isIPv4(host) {
            d["tunnel_dns"] = ["addresses": [host], "note": "already an IP address"]
            d["system_dns"] = ["addresses": [host]]
            tunnelAddrs = [host]
        } else {
            if servers.isEmpty {
                d["tunnel_dns"] = ["error": st.phase == .connected ? "the gateway pushed no DNS servers" : "VPN is not connected"]
            } else {
                var last: [String: Any] = [:]
                for s in servers {
                    let q = query(host: host, server: s)
                    last = ["server": s, "addresses": q.addresses]
                    if let e = q.error { last["error"] = e }
                    if !q.addresses.isEmpty { tunnelAddrs = q.addresses; break }
                }
                d["tunnel_dns"] = last
            }
            let sys = systemResolve(host: host)
            var sd: [String: Any] = ["addresses": sys.addresses]
            if let e = sys.error { sd["error"] = e }
            d["system_dns"] = sd
            d["system_resolver_ok"] = !sys.addresses.isEmpty
            if sys.addresses.isEmpty && !tunnelAddrs.isEmpty {
                d["hint"] = splitDNSHint(host: host, status: st)
            }
        }
        d["addresses"] = tunnelAddrs
        return d
    }

    /// TCP connect with a 3 s timeout (via nc -z, which needs no resolver when given an IP).
    static func tcpConnect(ip: String, port: Int) -> (ok: Bool, ms: Int, error: String?) {
        let t0 = Date()
        let r = Setup.run("/usr/bin/nc", ["-z", "-G", "3", "-w", "3", ip, String(port)])
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if r.status == 0 { return (true, ms, nil) }
        let msg = r.output.trimmed
        return (false, ms, msg.isEmpty ? "connection failed or timed out" : msg)
    }

    static func checkReachability(host: String, port: Int, status st: VPNStatus) -> [String: Any] {
        var d = resolve(host: host, status: st)
        d["port"] = port
        d["vpn_state"] = st.stateName
        let tunnelAddrs = (d["addresses"] as? [String]) ?? []
        let sysAddrs = ((d["system_dns"] as? [String: Any])?["addresses"] as? [String]) ?? []
        let candidates = tunnelAddrs.isEmpty ? sysAddrs.filter(isIPv4) : tunnelAddrs
        var diagnosis: [String] = []
        var reachable = false

        if st.phase != .connected { diagnosis.append("The VPN is \(st.stateName).") }
        if candidates.isEmpty {
            diagnosis.append("\(host) does not resolve via the tunnel DNS or the system resolver.")
        } else {
            let ip = candidates[0]
            let routes = st.network?.routes ?? []
            let viaTunnel = VPNManager.ipv4(ip, isCoveredBy: routes)
            d["address_used"] = ip
            d["route_via_tunnel"] = viaTunnel
            let tcp = tcpConnect(ip: ip, port: port)
            var t: [String: Any] = ["address": ip, "port": port, "connected": tcp.ok, "latency_ms": tcp.ms]
            if let e = tcp.error { t["error"] = e }
            d["tcp"] = t
            reachable = tcp.ok
            if tcp.ok {
                diagnosis.append("TCP \(ip):\(port) is open (\(tcp.ms) ms)\(viaTunnel ? ", routed through the tunnel" : "").")
                if sysAddrs.isEmpty && !isIPv4(host) {
                    diagnosis.append("But the system resolver cannot resolve \(host), so apps will still fail by name. " + splitDNSHint(host: host, status: st))
                }
            } else {
                diagnosis.append("TCP connect to \(ip):\(port) failed: \(tcp.error ?? "timeout").")
                if st.phase == .connected && !viaTunnel {
                    diagnosis.append("\(ip) is not covered by any route the gateway pushed (\(routes.count) routes), so traffic goes out the normal interface. The gateway may not publish that subnet, or the host is not behind this VPN.")
                } else if st.phase == .connected {
                    diagnosis.append("The address is routed through the tunnel; the service may be down, the port closed, or filtered by the FortiGate policy.")
                }
            }
        }
        d["reachable"] = reachable
        d["diagnosis"] = diagnosis.joined(separator: " ")
        return d
    }

    private static func splitDNSHint(host: String, status st: VPNStatus) -> String {
        let parts = host.lowercased().split(separator: ".")
        let domain = parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host.lowercased()
        var s = "Split DNS needed: add \"\(domain)\" to the connection's DNS domains (FiveT → Settings → Forti or VPN), then reconnect."
        if let sd = st.splitDNS {
            if sd.state == "helper_needed" { s = "Split DNS is configured but the helper is missing: " + sd.detail }
            else if sd.domains.contains(where: { host.lowercased().hasSuffix($0) }) { s = "Split DNS is \(sd.state) for \(domain)\(sd.detail.isEmpty ? "" : " (" + sd.detail + ")"); the resolver file may need a few seconds, or the DNS server has no record for this host." }
        }
        return s
    }
}

// MARK: - Socket client (shared by the bridge and the CLI)

enum MCPSocket {
    /// Connects to the app's socket, starting FiveT.app first if nothing is running.
    /// Returns the fd, or -1 after printing a reason to stderr.
    static func connectOrLaunch() -> Int32 {
        let path = MCPPaths.socketPath
        var fd = connect(to: path)
        if fd < 0 {
            // Only launch when no FiveT is running: `open -a` on a second copy of the bundle would
            // start a second instance (two menu bar icons) instead of activating the running one.
            let alreadyRunning = Setup.run("/usr/bin/pgrep", ["-x", "FiveT"]).status == 0
            if !alreadyRunning { launchApp() }
            let deadline = Date().addingTimeInterval(alreadyRunning ? 3 : 15)
            while fd < 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.4)
                fd = connect(to: path)
            }
            if fd < 0 {
                if alreadyRunning {
                    warn("FiveT is running but not answering. Either it is an older version "
                         + "(quit it from the shield menu and open it again) or \"Let AI assistants control FiveT\" "
                         + "is off in FiveT → Settings → MCP.")
                } else {
                    warn("could not start FiveT.app (expected socket at \(path)). Open FiveT once by hand, then try again.")
                }
            }
        }
        return fd
    }

    static func connect(to path: String) -> Int32 {
        guard var addr = MCPPaths.address(for: path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if ok != 0 { close(fd); return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func launchApp() {
        // Running from inside FiveT.app → open that bundle; otherwise fall back to /Applications.
        let bundle = Bundle.main.bundleURL
        let app = bundle.pathExtension == "app" ? bundle.path : "/Applications/FiveT.app"
        _ = Setup.run("/usr/bin/open", ["-g", "-a", app])
    }

    static func warn(_ s: String) {
        FileHandle.standardError.write(("fivet: " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - Bridge (`FiveT --mcp`)

/// Runs when the binary is started with `--mcp`: no windows, no menu bar, just stdin/stdout
/// forwarded to the app's socket. Starts FiveT.app first if it is not running.
enum MCPBridge {
    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let sock = MCPSocket.connectOrLaunch()
        guard sock >= 0 else { return 1 }
        let t = Thread {
            pump(from: 0, to: sock)
            shutdown(sock, SHUT_WR)   // stdin closed: tell the app we are done, keep reading replies
        }
        t.name = "fivet.mcp.stdin"
        t.start()
        pump(from: sock, to: 1)
        return 0
    }

    private static func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(src, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            // Note: `&buf[off]` would pass a pointer to a 1-byte temporary, not into the array.
            var off = 0
            var failed = false
            buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { failed = true; return }
                while off < n {
                    let w = write(dst, base + off, n - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { failed = true; return }
                    off += w
                }
            }
            if failed { return }
        }
    }
}

// MARK: - CLI (`FiveT status`, `FiveT connect Office`, …)

/// A plain command line for shell scripts. It is an MCP client of the running app, so it
/// sees exactly what assistants see. Exit codes: 0 success, 1 the action failed (or the host
/// is unreachable), 2 usage error, 3 FiveT.app could not be reached.
enum FiveTCLI {
    static let usage = """
        FiveT \(MCPPaths.appVersion) — FortiGate SSL-VPN from the command line

        usage: FiveT <command> [options]

          status                      current state, tunnel interface, DNS, routes
          list                        saved connections
          connect <name>              connect (a VPN replaces the VPN that is up; Forti stays; waits; idempotent)
              [--timeout N] [--no-wait]
          disconnect [name]           disconnect one connection, or all of them
          log [--lines N] [--level error|info|debug] [--connection NAME]
              [--since ISO-TIME] [--grep TEXT]
          resolve <host>              resolve via the tunnel DNS and the system resolver
          check <host> [port]         DNS + route + TCP connect diagnosis (default port 443)
          diagnostics                 full diagnostics text
          --mcp                       run as an MCP server over stdio (for AI assistants)
          --version, --help

        Add --json to any command for the same JSON the MCP tools return.
        Exit codes: 0 ok, 1 failed/unreachable, 2 usage, 3 FiveT.app not reachable.
        """

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let command = args.first else { print(usage); return 2 }
        args.removeFirst()

        let tool: String
        var params: [String: Any] = [:]
        do {
            switch command {
            case "status": tool = "get_status"
            case "list", "connections": tool = "list_connections"
            case "connect", "up":
                guard let name = args.first, !name.hasPrefix("--") else { throw RPCError(2, "connect needs a connection name") }
                tool = "connect"; params["name"] = name
                if let t = option("--timeout", in: args) { params["timeout_seconds"] = Int(t) ?? 60 }
                if args.contains("--no-wait") { params["wait"] = false }
            case "disconnect", "down":
                tool = "disconnect"
                if let name = args.first, !name.hasPrefix("--") { params["name"] = name }
            case "log", "logs":
                tool = "get_log"
                if let v = option("--lines", in: args) { params["lines"] = Int(v) ?? 60 }
                else if let n = args.first, let i = Int(n) { params["lines"] = i }
                if let v = option("--level", in: args) { params["level"] = v }
                if let v = option("--connection", in: args) { params["connection"] = v }
                if let v = option("--since", in: args) { params["since"] = v }
                if let v = option("--grep", in: args) { params["grep"] = v }
            case "resolve":
                guard let host = args.first else { throw RPCError(2, "resolve needs a host name") }
                tool = "resolve"; params["host"] = host
            case "check", "reach":
                guard let host = args.first else { throw RPCError(2, "check needs a host name") }
                tool = "check_reachability"; params["host"] = host
                if args.count > 1, let p = Int(args[1]) { params["port"] = p }
                if let v = option("--port", in: args) { params["port"] = Int(v) ?? 443 }
            case "diagnostics", "diag": tool = "get_diagnostics"
            default: throw RPCError(2, "unknown command '\(command)'")
            }
        } catch let e as RPCError {
            MCPSocket.warn(e.message + "\n\n" + usage)
            return 2
        } catch { return 2 }

        signal(SIGPIPE, SIG_IGN)
        let fd = MCPSocket.connectOrLaunch()
        guard fd >= 0 else { return 3 }
        defer { close(fd) }
        let writer = LineWriter(fd: fd)
        var reader = LineReader(fd: fd)

        func call(_ id: Int, _ method: String, _ p: [String: Any]) -> [String: Any]? {
            writer.send(["jsonrpc": "2.0", "id": id, "method": method, "params": p])
            while let line = reader.nextLine() {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if (obj["id"] as? Int) == id { return obj }
            }
            return nil
        }

        guard call(1, "initialize", ["protocolVersion": MCPServer.protocolVersion, "capabilities": [:],
                                     "clientInfo": ["name": "fivet-cli", "version": MCPPaths.appVersion]]) != nil else {
            MCPSocket.warn("no answer from FiveT.app"); return 3
        }
        writer.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        guard let reply = call(2, "tools/call", ["name": tool, "arguments": params]) else {
            MCPSocket.warn("connection to FiveT.app closed"); return 3
        }
        if let err = reply["error"] as? [String: Any] {
            MCPSocket.warn((err["message"] as? String) ?? "error")
            return 1
        }
        let res = reply["result"] as? [String: Any] ?? [:]
        let isError = (res["isError"] as? Bool) ?? false
        let payload = res["structuredContent"] as? [String: Any]
        let text = ((res["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if json {
            print(payload.map { MCPJSON.pretty($0) } ?? text)
        } else if let payload {
            print(human(tool, payload))
        } else {
            print(text)
        }
        return isError ? 1 : 0
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Short, readable output for humans; --json gives the full structure.
    private static func human(_ tool: String, _ p: [String: Any]) -> String {
        func statusLine(_ p: [String: Any]) -> String {
            var s = (p["summary"] as? String) ?? (p["state"] as? String ?? "?")
            if let n = p["network"] as? [String: Any] {
                let iface = n["interface"] as? String ?? "?", ip = n["tunnel_ip"] as? String ?? "?"
                let dns = (n["dns_servers"] as? [String] ?? []).joined(separator: ", ")
                let routes = (n["routes"] as? [String] ?? []).count
                s += "\n  tunnel: \(iface) \(ip)   dns: \(dns.isEmpty ? "-" : dns)   routes: \(routes)"
                if let sd = (n["search_domains"] as? [String]), !sd.isEmpty { s += "   search: \(sd.joined(separator: ", "))" }
                if let o = n["outer_ip"] as? String, !o.isEmpty { s += "   over: \(n["outer_interface"] as? String ?? "?") \(o)" }
            }
            if let sd = p["split_dns"] as? [String: Any] {
                s += "\n  split dns: \(sd["state"] ?? "?") [\((sd["domains"] as? [String] ?? []).joined(separator: ", "))]"
                if let d = sd["detail"] as? String, !d.isEmpty { s += " — \(d)" }
            }
            return s
        }
        /// One block per tunnel when several are up; the plain status line otherwise.
        func statusLine() -> String {
            let sessions = p["sessions"] as? [[String: Any]] ?? []
            guard sessions.count > 1 else { return statusLine(p) }
            return sessions.map { statusLine($0) }.joined(separator: "\n")
        }
        switch tool {
        case "get_status": return statusLine()
        case "connect", "disconnect":
            var s = "\(p["outcome"] ?? "?"): " + statusLine()
            if let m = p["message"] as? String { s += "\n  \(m)" }
            return s
        case "list_connections":
            let conns = p["connections"] as? [[String: Any]] ?? []
            return conns.map { c in
                let mark = (c["state"] as? String) == "connected" ? "●" : ((c["state"] as? String) == "connecting" ? "◐" : "○")
                var s = "\(mark) \(c["name"] ?? "?")  \(c["gateway"] ?? "")  \(c["username"] ?? "")  \(c["state"] ?? "")"
                if let d = c["dns_domains"] as? [String], !d.isEmpty { s += "  dns: \(d.joined(separator: ", "))" }
                if let e = c["last_error"] as? String { s += "\n    last error: \(e)" }
                return s
            }.joined(separator: "\n")
        case "get_log":
            return (p["lines"] as? [String] ?? []).joined(separator: "\n")
        case "resolve":
            var s = "\(p["host"] ?? "?")"
            if let t = p["tunnel_dns"] as? [String: Any] {
                s += "\n  tunnel dns\(t["server"].map { " (\($0))" } ?? ""): " + ((t["addresses"] as? [String])?.joined(separator: ", ") ?? "") + (t["error"].map { " — \($0)" } ?? "")
            }
            if let t = p["system_dns"] as? [String: Any] {
                s += "\n  system resolver: " + ((t["addresses"] as? [String])?.joined(separator: ", ") ?? "") + (t["error"].map { " — \($0)" } ?? "")
            }
            if let h = p["hint"] as? String { s += "\n  \(h)" }
            return s
        case "check_reachability":
            var s = human("resolve", p)
            if let t = p["tcp"] as? [String: Any] {
                s += "\n  tcp \(t["address"] ?? "?"):\(t["port"] ?? "?") " + (((t["connected"] as? Bool) ?? false) ? "open" : "closed/timeout") + " (\(t["latency_ms"] ?? 0) ms)"
            }
            if let r = p["route_via_tunnel"] as? Bool { s += "   route via tunnel: \(r ? "yes" : "no")" }
            s += "\n  " + ((p["diagnosis"] as? String) ?? "")
            return s
        default:
            return MCPJSON.pretty(p)
        }
    }
}

// MARK: - Registering FiveT with assistants

/// Writes the `fivet` server entry into the assistants' config files (Settings → MCP).
enum MCPClientSetup {
    /// The command an assistant runs. Inside the bundle this is FiveT.app/Contents/MacOS/FiveT.
    static var command: String {
        Bundle.main.executableURL?.path ?? "/Applications/FiveT.app/Contents/MacOS/FiveT"
    }

    static var serverEntry: [String: Any] { ["command": command, "args": ["--mcp"]] }

    static var snippet: String { MCPJSON.pretty(["mcpServers": ["fivet": serverEntry]]) }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeDesktopConfig: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    static var cursorConfig: URL { home.appendingPathComponent(".cursor/mcp.json") }

    /// Merges the entry into a `{"mcpServers": {...}}` file, keeping everything else in it.
    static func add(to url: URL, appName: String) -> String {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "\(url.lastPathComponent) is not valid JSON. Fix or remove it, then try again."
            }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["fivet"] = serverEntry
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MCPJSON.pretty(root).write(to: url, atomically: true, encoding: .utf8)
            Log.shared.write("[mcp] registered in \(url.path)")
            return "Added to \(appName). Restart \(appName) so it picks up the new server."
        } catch {
            return "Could not write \(url.path): \(error.localizedDescription)"
        }
    }

    /// For one day (1.16.0) the app was /Applications/FiveX.app. An assistant's `fivet` entry that still runs
    /// that path is rewritten to this copy (Claude Desktop and Cursor: their own files; Claude Code: its CLI).
    static func repairAfterRename() {
        let old = "/Applications/FiveX.app/Contents/MacOS/FiveT"
        func mentionsOldPath(_ url: URL) -> Bool {
            (try? String(contentsOf: url, encoding: .utf8))?.contains(old) == true
        }
        for url in [claudeDesktopConfig, cursorConfig] where mentionsOldPath(url) {
            Log.shared.write("[mcp] \(url.lastPathComponent): \(add(to: url, appName: url.lastPathComponent))")
        }
        if mentionsOldPath(home.appendingPathComponent(".claude.json")) {
            Log.shared.write("[mcp] Claude Code: \(addToClaudeCode())")
        }
    }

    /// Uses the `claude` CLI so the entry lands wherever Claude Code keeps user-scope servers.
    static func addToClaudeCode() -> String {
        let candidates = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".npm-global/bin/claude").path,
        ]
        let manual = "claude mcp add -s user fivet -- \"\(command)\" --mcp"
        guard let claude = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "Claude Code CLI not found. In a terminal run:  \(manual)"
        }
        _ = Setup.run(claude, ["mcp", "remove", "-s", "user", "fivet"])   // replace an older entry, if any
        let r = Setup.run(claude, ["mcp", "add", "-s", "user", "fivet", "--", command, "--mcp"])
        if r.status == 0 {
            Log.shared.write("[mcp] registered with Claude Code via \(claude)")
            return "Added to Claude Code. New sessions can use it (/mcp to check)."
        }
        return "claude mcp add failed: \(r.output.trimmed)\nTry in a terminal:  \(manual)"
    }
}
