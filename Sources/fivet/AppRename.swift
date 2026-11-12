import AppKit
import ServiceManagement

/// The app was called FiveX for one day (1.16.0) and is FiveT again. A copy that updated to 1.16.0 sits at
/// /Applications/FiveX.app, and the update swaps the new app in over the bundle it runs from, so it is still
/// there. On its first launch it renames itself back to FiveT.app (same folder, same volume: nothing is
/// copied) and starts again from there, before anything is connected. The bundle identifier, the helper and
/// the saved connections never changed.
enum AppRename {
    static let oldName = "FiveX.app"
    static let newName = "FiveT.app"
    private static let reregisterKey = "reregisterLoginItemAfterRenameBack"
    private static let renamedKey = "justRenamedBackToFiveT"

    /// True when the app was renamed and a new copy is starting: the caller quits at once.
    static func renameIfNeeded() -> Bool {
        let fm = FileManager.default
        let url = Bundle.main.bundleURL
        let folder = url.deletingLastPathComponent()
        // Only an installed copy: a build being tried, or one opened from the disk image, keeps its name.
        guard url.lastPathComponent == oldName, folder.lastPathComponent == "Applications",
              fm.isWritableFile(atPath: folder.path) else { return false }
        let target = folder.appendingPathComponent(newName)
        guard !fm.fileExists(atPath: target.path) else {
            Log.shared.write("not renaming the app: \(target.path) already exists")
            return false
        }
        // The login item is registered for this location: switch it off, and on again from the new place.
        let startAtLogin = SMAppService.mainApp.status == .enabled
        if startAtLogin { try? SMAppService.mainApp.unregister() }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            Log.shared.write("could not rename the app to \(newName): \(error.localizedDescription)")
            if startAtLogin { try? SMAppService.mainApp.register() }
            return false
        }
        UserDefaults.standard.set(true, forKey: renamedKey)
        if startAtLogin { UserDefaults.standard.set(true, forKey: reregisterKey) }
        Log.shared.write("renamed the app to \(newName); starting it again")
        // Start the renamed copy once this process has gone (as the updater does), keeping a test copy's
        // FIVET_SOCKET / FIVET_DATA_DIR / FIVET_UPDATE_URL.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open ${FIVET_SOCKET:+--env FIVET_SOCKET=\"$FIVET_SOCKET\"} "
            + "${FIVET_UPDATE_URL:+--env FIVET_UPDATE_URL=\"$FIVET_UPDATE_URL\"} "
            + "${FIVET_DATA_DIR:+--env FIVET_DATA_DIR=\"$FIVET_DATA_DIR\"} \"\(target.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do { try p.run() } catch {
            Log.shared.write("could not start the renamed app: \(error.localizedDescription); open \(target.path) by hand")
        }
        return true
    }

    /// In the renamed copy, once: start at login (if it was on) is registered again for the new place, and an
    /// AI assistant's FiveT entry (Settings → MCP) that still runs the old path is pointed at the new one.
    static func finish() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: renamedKey) else { return }
        defaults.removeObject(forKey: renamedKey)
        if defaults.bool(forKey: reregisterKey) {
            defaults.removeObject(forKey: reregisterKey)
            try? SMAppService.mainApp.register()
        }
        // Only the installed app: a copy being tried must never rewrite the assistants' real configuration.
        if Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" {
            DispatchQueue.global(qos: .utility).async { MCPClientSetup.repairAfterRename() }
        }
    }
}
