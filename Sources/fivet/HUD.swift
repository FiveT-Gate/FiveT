import AppKit

/// A small message that floats near the top of the screen for a moment, the way macOS shows a
/// volume change: how a shortcut tells you it worked (or why it did not) without taking the
/// keyboard focus away from the field the code is going into. Main thread only.
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill",
                     tint: NSColor = .systemGreen, seconds: TimeInterval = 1.6) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let icon = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.maximumNumberOfLines = 1
        var lines: [NSView] = [heading]
        if let detail {
            let text = NSTextField(wrappingLabelWithString: detail)
            text.font = .systemFont(ofSize: 12)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = 300
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
            lines.append(text)
        }
        let texts = NSStackView(views: lines)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3

        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content

        // The wrapped detail line needs its width before its height (and so the panel's) is known.
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // On the screen the pointer is on, which is the one being worked on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 28,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: [title, detail].compactMap { $0 }.joined(separator: ". ")])

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A panel that never takes the keyboard from the app in front, ignores the mouse, and shows
    /// over full-screen apps and on every desktop.
    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}
