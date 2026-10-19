import AppKit

/// A floating shelf that holds references to files so they can be dragged into another app later.
/// Files are never copied; the shelf only remembers their locations.
final class FloatShelf {
    static let shared = FloatShelf()

    private(set) var urls: [URL] = []
    private var panel: NSPanel?
    private var shelfView: FloatShelfView?

    func add(_ newURLs: [URL]) {
        for url in newURLs.map(\.standardizedFileURL) where !urls.contains(url) {
            urls.append(url)
        }
        show()
        reload()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        reload()
    }

    func clear() {
        urls.removeAll()
        reload()
        panel?.orderOut(nil)
    }

    /// Drops entries whose files were moved away (e.g. dragged out with a move operation).
    func pruneMissing() {
        urls.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        reload()
    }

    func show() {
        let panel = panel ?? makePanel()
        if !panel.isVisible, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20,
                                         y: visible.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func reload() {
        shelfView?.reload(urls)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 200, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = FloatShelfView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = view
        view.reload(urls)
        self.panel = panel
        shelfView = view
        return panel
    }
}

// MARK: - Shelf view (drop target)

private final class FloatShelfView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "Float")
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Перетащите сюда файлы или бросьте их на «Float» в колесе ⌃")
    private let allItemsRow = FloatItemView(urls: [])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let clear = headerButton("trash", "Очистить", #selector(clearTapped))
        let close = headerButton("xmark", "Закрыть Float (файлы не удаляются)", #selector(closeTapped))
        let header = NSStackView(views: [titleLabel, NSView(), clear, close])
        header.orientation = .horizontal
        header.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        let content = NSStackView(views: [header, allItemsRow, scroll, emptyLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
            allItemsRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: header.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    private func headerButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                              target: self, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        return button
    }

    func reload(_ urls: [URL]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in urls {
            let row = FloatItemView(urls: [url])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        titleLabel.stringValue = urls.isEmpty ? "Float" : "Float · \(urls.count)"
        allItemsRow.urls = urls
        allItemsRow.isHidden = urls.count < 2
        emptyLabel.isHidden = !urls.isEmpty
    }

    @objc private func clearTapped() {
        FloatShelf.shared.clear()
    }

    @objc private func closeTapped() {
        window?.orderOut(nil)
    }

    // Drop target

    private var isTargeted = false {
        didSet {
            layer?.borderWidth = isTargeted ? 2 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started on the shelf itself.
        guard !(sender.draggingSource is FloatItemView) else { return [] }
        isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard !(sender.draggingSource is FloatItemView) else { return false }
        let urls = DragMonitor.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        FloatShelf.shared.add(urls)
        return true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Item row (drag source)

/// A row for one file, or (with several URLs) the "drag everything" row.
private final class FloatItemView: NSView, NSDraggingSource {
    var urls: [URL] { didSet { refresh() } }

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var mouseDownEvent: NSEvent?

    private var isGroup: Bool { urls.count != 1 }

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 12)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Убрать из Float")
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.toolTip = "Убрать из Float"

        let row = NSStackView(views: [iconView, nameLabel, removeButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func refresh() {
        if isGroup {
            iconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)
            nameLabel.stringValue = "Перетащить все (\(urls.count))"
            nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            removeButton.isHidden = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        } else if let url = urls.first {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
            nameLabel.stringValue = url.lastPathComponent
            toolTip = url.path
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, !urls.isEmpty else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                             event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil

        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: 6 + offset, y: 4 - offset, width: 32, height: 32), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        DragMonitor.shared.beginDrag(urls: urls)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isGroup else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть", action: #selector(openTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Показать в Finder", action: #selector(revealTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Убрать из Float", action: #selector(removeTapped), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openTapped() {
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func removeTapped() {
        urls.forEach(FloatShelf.shared.remove)
    }

    // NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Inside Mangosteen only the wheel accepts drops; outside, behave like a Finder drag.
        context == .withinApplication ? .copy : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async {
            FloatShelf.shared.pruneMissing()
        }
    }
}
