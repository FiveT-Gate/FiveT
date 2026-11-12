import AppKit
import Combine

/// The tab strip of the Settings window, placed in the title bar by the app itself.
///
/// A stock SwiftUI `TabView` lets each macOS release decide where the tabs go (in the
/// title bar on macOS 26, in a row under the window title on older releases). Owning
/// the toolbar here makes the layout identical on every Mac. `SettingsRouter.tab` stays
/// the single source of truth: the control follows it, and SwiftUI switches the content.
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    static let shared = SettingsToolbar()

    private static let tabs: [(tab: SettingsTab, title: String)] = [
        (.connections, "Forti"), (.openvpn, "VPN"), (.assistants, "MCP"), (.general, "General"),
    ]
    private static let tabsItem = NSToolbarItem.Identifier("fivet.tabs")

    private let router = SettingsRouter.shared
    private var subscription: AnyCancellable?
    private weak var group: NSToolbarItemGroup?

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "fivet.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.tabsItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        subscription = router.$tab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self, let i = Self.tabs.firstIndex(where: { $0.tab == tab }) else { return }
                if self.group?.selectedIndex != i { self.group?.selectedIndex = i }
            }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.tabsItem else { return nil }
        let g = NSToolbarItemGroup(itemIdentifier: id, titles: Self.tabs.map(\.title), selectionMode: .selectOne,
                                   labels: nil, target: self, action: #selector(tabChosen(_:)))
        g.selectedIndex = Self.tabs.firstIndex { $0.tab == router.tab } ?? 0
        group = g
        return g
    }

    @objc private func tabChosen(_ sender: Any?) {
        guard let g = group, Self.tabs.indices.contains(g.selectedIndex) else { return }
        router.tab = Self.tabs[g.selectedIndex].tab
    }
}
