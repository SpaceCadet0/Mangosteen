import AppKit

/// Shows the wheel in a non-activating panel centred on the cursor.
final class WheelController {
    private let panel: NSPanel
    private let wheelView: WheelView
    private var urls: [URL] = []
    private var pendingHide: DispatchWorkItem?
    private var outsideClickMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    #if DEBUG
    var debugWindow: NSWindow { panel }
    func debugHighlight(_ index: Int) { wheelView.debugHighlight(index) }
    var debugAccessibilitySummary: String { wheelView.debugAccessibilitySummary }
    #endif

    init() {
        let size = WheelView.diameter
        wheelView = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel = NSPanel(contentRect: wheelView.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = wheelView

        wheelView.onSelect = { [weak self] item in
            guard let self else { return }
            let urls = self.urls
            self.hide()
            // Leave the drag-and-drop callback before running anything that may show UI.
            DispatchQueue.main.async { item.perform(urls) }
        }
        wheelView.onHoverChange = { Feedback.hover() }
    }

    func show(kind: WheelKind, urls: [URL], at point: NSPoint = NSEvent.mouseLocation) {
        pendingHide?.cancel()
        self.urls = urls
        wheelView.configure(kind: kind, items: WheelItemProvider.items(for: kind, urls: urls), fileCount: urls.count)

        let size = WheelView.diameter
        var frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        startWatchingOutsideClicks()
    }

    /// The drag finished; give a drop on the wheel time to arrive, then close.
    func dragEnded() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        panel.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        // Clicks inside the panel go to WheelView; global monitors only see clicks elsewhere.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
}
