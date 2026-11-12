import Foundation

/// `fivet://` links, so Shortcuts, Raycast, Alfred, a Stream Deck button, a bookmark or a link in a
/// chat can switch a VPN on or off:
///
///     fivet://connect/Office     fivet://disconnect/Office     fivet://toggle/Lab
///     fivet://disconnect         (every tunnel)                fivet://settings
///
/// Any web page can open a link too (browsers ask first), so links only do what a click in the menu
/// does: connect and disconnect. They never change a setting, trust a certificate or show a secret.
enum LinkCommand: Equatable {
    case connect(String)
    case disconnect(String?)   // nil: every tunnel
    case toggle(String)
    case settings

    struct Failure: Error, Equatable { let message: String }

    static let examples = "fivet://connect/<name>, fivet://disconnect/<name>, fivet://disconnect, fivet://toggle/<name> or fivet://settings"

    /// `fivet://connect/My%20VPN` → .connect("My VPN"). Also accepts `fivet:connect/Office` and
    /// `fivet://connect?name=Office`.
    static func parse(_ url: URL) throws -> LinkCommand {
        guard url.scheme?.lowercased() == "fivet",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure(message: "Not a FiveT link: \(url.absoluteString)")
        }
        // fivet://connect/Office has host "connect" and path "/Office"; fivet:connect/Office has no
        // host and path "connect/Office". Both become ["connect", "Office"].
        var words = ((parts.host.map { [$0] } ?? []) + parts.path.split(separator: "/").map(String.init))
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
        if let q = parts.queryItems?.first(where: { $0.name.lowercased() == "name" })?.value, !q.isEmpty { words.append(q) }
        guard let action = words.first?.lowercased() else {
            throw Failure(message: "This FiveT link says nothing to do. Links look like \(examples).")
        }
        let name = words.dropFirst().joined(separator: "/").trimmed
        switch action {
        case "connect", "up":
            guard !name.isEmpty else { throw Failure(message: "fivet://connect needs a connection name, e.g. fivet://connect/office.") }
            return .connect(name)
        case "disconnect", "down":
            return .disconnect(name.isEmpty ? nil : name)
        case "toggle":
            guard !name.isEmpty else { throw Failure(message: "fivet://toggle needs a connection name, e.g. fivet://toggle/office.") }
            return .toggle(name)
        case "settings", "open":
            return .settings
        default:
            // Not echoed: the link's text is whatever the page that opened it chose.
            throw Failure(message: "This link asks for something FiveT links cannot do. Links look like \(examples).")
        }
    }
}
