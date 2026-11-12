import AppKit

// Command-line entry points run before NSApplication is touched, so no menu bar icon or
// Dock entry appears:  `FiveT --mcp` (MCP server over stdio for AI assistants),
// `FiveT status | list | connect <name> | disconnect | log | resolve | check | diagnostics`,
// `FiveT --help`, `FiveT --version`. See MCPServer.swift. Flags such as --setup, --settings
// and --dump-statusitem fall through to the GUI.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first {
    switch first {
    case "--mcp":
        exit(MCPBridge.run())
    case "--help", "-h", "help":
        print(FiveTCLI.usage)
        exit(0)
    case "--version", "-v", "version":
        print("FiveT \(MCPPaths.appVersion)")
        exit(0)
    case "--check-ovpn":
        // What importing an OpenVPN profile would give (never its keys): for testing the importer.
        for path in cliArgs.dropFirst() {
            do {
                let imp = try OpenVPNProfile.importProfile(at: URL(fileURLWithPath: path))
                print("\(path): OK name=\(imp.name) server=\(imp.host):\(imp.port) login=\(OpenVPNProfile.needsLogin(imp.text))"
                      + " user=\(imp.username.isEmpty ? "-" : imp.username) staticChallenge=\(imp.staticChallenge)"
                      + " fullTunnel=\(OpenVPNProfile.redirectsGateway(imp.text)) dropped=[\(imp.dropped.joined(separator: "; "))]"
                      + " problems=\(OpenVPNProfile.problems(imp.text))")
            } catch {
                print("\(path): REFUSED \(error.localizedDescription)")
            }
        }
        exit(0)
    case "--check-openvpn-connect":
        // The profiles of OpenVPN Connect on this Mac and the names FiveT would give them (never their
        // keys): for testing the import. An optional file stands in for OpenVPN Connect's config.json.
        let names = cliArgs.count > 1
            ? OpenVPNProfile.openVPNConnectNames(stateFile: URL(fileURLWithPath: cliArgs[1]))
            : OpenVPNProfile.openVPNConnectNames()
        print("names found in OpenVPN Connect's saved state: \(names.count)")
        for (id, name) in names.sorted(by: { $0.key < $1.key }) { print("  \(id): \(name)") }
        for url in OpenVPNProfile.openVPNConnectProfiles() {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let imp = try OpenVPNProfile.importProfile(at: url)
                print("\(url.lastPathComponent): imports as \"\(names[id] ?? imp.name)\" server=\(imp.host):\(imp.port)"
                      + (names[id] == nil ? " (no name in OpenVPN Connect: the file's or the server's)" : ""))
            } catch {
                print("\(url.lastPathComponent): REFUSED \(error.localizedDescription)")
            }
        }
        exit(0)
    case "--check-v2ray":
        // What importing V2Ray configs would give: each argument a file (JSON, or text with links)
        // or a link; "-" reads stdin. Prints the outbound, for testing the
        // importer; it holds the server's ID or password, so only for test configs.
        for arg in cliArgs.dropFirst() {
            var configs: [V2RayConfig.Imported] = [], problems: [String] = []
            do {
                if arg == "-" { (configs, problems, _) = V2RayConfig.importText(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)) }
                else if V2RayConfig.isLink(arg) { configs = [try V2RayConfig.parse(link: arg)] }
                else { (configs, problems, _) = V2RayConfig.importText(try String(contentsOfFile: arg, encoding: .utf8), name: (arg as NSString).lastPathComponent) }
            } catch { problems.append(error.localizedDescription) }
            for c in configs {
                print("OK name=\(c.name) server=\(c.host):\(c.port) \(V2RayConfig.summary(V2RayConfig.json(c.outbound)))")
                if ProcessInfo.processInfo.environment["FIVET_SHOW_OUTBOUND"] == "1" { print(V2RayConfig.json(c.outbound)) }
                // FIVET_LAUNCH_CONFIG=<dir>: also writes the whole config FiveT would run, one file each.
                if let dir = ProcessInfo.processInfo.environment["FIVET_LAUNCH_CONFIG"] {
                    let conn = V2RayConfig.connection(from: c, taken: [])
                    let text = (try? V2RayConfig.forLaunch(conn, tun: "utun199", localDNS: ["192.168.8.1"], direct: ["203.0.113.10/32"],
                                                           serverIPs: VPNManager.lookUp(V2RayConfig.serverNames(of: conn.v2rayOutbound)), verbose: false)) ?? "{}"
                    let file = (dir as NSString).appendingPathComponent("\(c.host)-\(c.port).json")
                    try? text.write(toFile: file, atomically: true, encoding: .utf8)
                }
            }
            for p in problems { print("REFUSED \(p)") }
        }
        exit(0)
    case "--check-outline":
        // The servers saved in the Outline app on this Mac, as importing them would read them (a
        // name, the kind of key and its server, never a key or password), for testing the import.
        // An optional file stands in for Outline's storage: a web-storage database, or a JSON array of {name, accessKey}.
        // It runs inside an application's run loop, as the + menu does: macOS can only ask the user
        // before FiveT reads another app's data for an app that is running, not for a bare command line.
        let checkApp = NSApplication.shared
        checkApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            let entries: [OutlineApp.Entry]
            do {
                entries = cliArgs.count > 1
                    ? try OutlineApp.entries(inFile: URL(fileURLWithPath: cliArgs[1]))
                    : try OutlineApp.savedServers()
            } catch {
                print("REFUSED \(error.localizedDescription)")
                exit(1)
            }
            print("saved servers found: \(entries.count)")
            for e in entries {
                let low = e.key.lowercased()
                if low.hasPrefix("ss://") {
                    do {
                        let imp = try V2RayConfig.parse(link: e.key)
                        print("  \"\(e.name)\": \(V2RayConfig.summary(V2RayConfig.json(imp.outbound))) server=\(imp.host):\(imp.port) prefix=\(imp.prefix)")
                    } catch { print("  \"\(e.name)\": REFUSED \(error.localizedDescription)") }
                } else if low.hasPrefix("ssconf://") || low.hasPrefix("https://") {
                    print("  \"\(e.name)\": dynamic key, fetched from \(V2RayConfig.dynamicKeyURL(e.key)?.host ?? "an address FiveT cannot read")")
                } else {
                    print("  \"\(e.name)\": a kind of key FiveT does not read (\(V2RayConfig.shortLink(e.key)))")
                }
            }
            // FIVET_APPLY=1 (with FIVET_DATA_DIR, so never the real connections) adds them, twice, to show
            // what the alert says and that a second import adds nothing.
            guard ProcessInfo.processInfo.environment["FIVET_APPLY"] == "1", ProcessInfo.processInfo.environment["FIVET_DATA_DIR"] != nil else { exit(0) }
            Task { @MainActor in
                for round in 1...2 {
                    let out = await VPNImport.addOutline(entries, from: "a test")
                    print("--- import \(round): \(out.added.count) added\n\(out.message)")
                }
                print("--- VPN connections now: \(ConnectionStore.shared.connections.filter(\.isV2Ray).map(\.name))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // the store saves half a second after a change
                exit(0)
            }
        }
        checkApp.run()
    case "--print-install":
        // The root shell command Install Helper… runs (no secrets in it), for checking its syntax.
        print(Setup.installCommands(sources: [URL(fileURLWithPath: Setup.bundledOpenfortivpnPath)], openvpn: Setup.bundledOpenVPNPath,
                                    xray: Setup.bundledXrayPath, geo: Setup.bundledXrayGeoPath))
        exit(0)
    case "--print-helper":
        // The root helper script Install Helper… installs, for reading and testing it (no secrets in it).
        print(Setup.resolverHelperScript, terminator: "")
        exit(0)
    default:
        if !first.hasPrefix("--") { exit(FiveTCLI.run(cliArgs)) }
    }
}

// Entry point. FiveT is a menu bar only app (no Dock icon), so the activation
// policy is "accessory". Everything else lives in AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
