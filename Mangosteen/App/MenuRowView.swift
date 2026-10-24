import AppKit

/// A status-menu row drawn by the app. NSMenu always highlights rows in the system blue and ignores the app's
/// accent colour, so the rows draw themselves to light up in the brand's wine instead. Everything shown comes
/// from the enclosing menu item: its image, title, badge or key equivalent, and a chevron when it has a submenu.
final class MenuRowView: NSView {
    static let width: CGFloat = 290
    private static let height: CGFloat = 22

    #if DEBUG
    /// Snapshot mode: `MANGOSTEEN_MENU_HIGHLIGHT=<title>` draws that row lit, as if the pointer were over it.
    private static let forcedHighlight = ProcessInfo.processInfo.environment["MANGOSTEEN_MENU_HIGHLIGHT"]
    #endif

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var isLit: Bool {
        guard let item = enclosingMenuItem, item.isEnabled else { return false }
        #if DEBUG
        if let forced = Self.forcedHighlight { return item.title.hasPrefix(forced) }
        #endif
        return item.isHighlighted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let lit = isLit
        if lit {
            Brand.nsColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let text: NSColor = !item.isEnabled ? .disabledControlTextColor : lit ? .white : .labelColor
        let secondary: NSColor = lit ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor

        if let image = item.image {
            let size = NSSize(width: min(image.size.width, 16), height: min(image.size.height, 16))
            let rect = NSRect(x: 14 + (16 - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
            Self.draw(image, in: rect, tint: image.isTemplate ? text : nil)
        }

        var right = bounds.width - 14
        if item.hasSubmenu {
            if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                let rect = NSRect(x: right - chevron.size.width, y: (bounds.height - chevron.size.height) / 2,
                                  width: chevron.size.width, height: chevron.size.height)
                Self.draw(chevron, in: rect, tint: secondary)
                right = rect.minX - 8
            }
        } else if let trailing = trailingText(item) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: secondary]
            let size = (trailing as NSString).size(withAttributes: attributes)
            (trailing as NSString).draw(at: NSPoint(x: right - size.width, y: (bounds.height - size.height) / 2),
                                        withAttributes: attributes)
            right -= size.width + 12
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: text, .paragraphStyle: paragraph,
        ]
        let height = (item.title as NSString).size(withAttributes: attributes).height
        (item.title as NSString).draw(in: NSRect(x: 38, y: (bounds.height - height) / 2, width: right - 38, height: height),
                                      withAttributes: attributes)
    }

    /// The wheel's key badge, or the key equivalent as the system menu would show it (⌘, · ⌘Q).
    private func trailingText(_ item: NSMenuItem) -> String? {
        if let badge = item.badge?.stringValue, !badge.isEmpty { return badge }
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }

    private static func draw(_ image: NSImage, in rect: NSRect, tint: NSColor?) {
        guard let tint else {
            image.draw(in: rect)
            return
        }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    override func mouseUp(with event: NSEvent) {
        perform()
    }

    /// Closes the whole menu, then sends the item's action, as a click on a standard row does.
    private func perform() {
        guard let item = enclosingMenuItem, item.isEnabled, !item.hasSubmenu else { return }
        var top = item.menu
        while let parent = top?.supermenu { top = parent }
        top?.cancelTracking()
        // After the menu has closed, so a window or panel the action opens is not shown under it.
        DispatchQueue.main.async {
            guard let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    override func accessibilityLabel() -> String? { enclosingMenuItem?.title }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }
}

extension NSMenuItem {
    /// Draws the row with `MenuRowView`, so it lights up in the brand colour.
    @discardableResult
    func withBrandRow() -> NSMenuItem {
        view = MenuRowView()
        return self
    }
}
