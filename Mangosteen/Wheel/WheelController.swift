import AppKit

/// Shows the wheel in a non-activating panel centred on the cursor.
final class WheelController {
    private let panel: NSPanel
    private let container: NSView
    private let wheelView: WheelView
    private var backdrop: NSView?
    private var urls: [URL] = []
    private var pendingHide: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var scrollMonitors: [Any] = []
    /// One flip per scroll gesture: trackpad deltas add up until the threshold, a wheel mouse flips per notch.
    private var scrollAmount: CGFloat = 0
    private var flippedThisGesture = false
    private var lastNotchFlip = Date.distantPast

    var isVisible: Bool { panel.isVisible }

    #if DEBUG
    var debugWindow: NSWindow { panel }
    func debugHighlight(_ index: Int) { wheelView.debugHighlight(index) }
    func debugFlip() { wheelView.flip() }
    var debugAccessibilitySummary: String { wheelView.debugAccessibilitySummary }
    #endif

    init() {
        let size = WheelView.diameter
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        wheelView = WheelView(frame: frame)
        container = NSView(frame: frame)
        container.addSubview(wheelView)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = container

        wheelView.onSelect = { [weak self] item, dropped in
            guard let self else { return }
            // The drop carries the complete list; the one read when the wheel opened may be partial. A browser's
            // picture was only a placeholder name until it was saved, so only the dropped file counts then.
            let waitingForPicture = !self.urls.isEmpty && self.urls.allSatisfy(WebImageDrop.isPlaceholder)
            let urls = waitingForPicture ? (dropped ?? [])
                : (dropped?.count ?? 0) > self.urls.count ? dropped ?? [] : self.urls
            guard !urls.isEmpty else {
                self.hide()
                return
            }
            DragMonitor.log.info("Wheel: \(self.urls.count) files when opened, \(dropped?.count ?? -1) dropped, \(urls.count) used")
            self.hide()
            // Leave the drag-and-drop callback before running anything that may show UI.
            DispatchQueue.main.async { item.perform(urls) }
        }
        wheelView.onHoverChange = { Feedback.hover() }
        wheelView.onFlip = { Feedback.hover() }
    }

    func show(kind: WheelKind, urls: [URL], at point: NSPoint = NSEvent.mouseLocation) {
        pendingHide?.cancel()
        self.urls = urls
        let settings = AppSettings.shared
        let sides = WheelLayout.split(WheelItemProvider.items(for: kind, urls: urls), id: \.id,
                                      choices: settings.slicePlacements)
        wheelView.configure(kind: kind, front: sides.front, back: sides.back, fileCount: urls.count)
        applyAppearance(settings)

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
        startWatchingScroll()
    }

    /// Opacity and the glass backdrop follow Settings → Appearance each time the wheel opens.
    private func applyAppearance(_ settings: AppSettings) {
        wheelView.backgroundOpacity = settings.wheelOpacity
        if settings.wheelGlass, backdrop == nil {
            let view = WheelView.makeBackdrop(in: container.bounds)
            container.addSubview(view, positioned: .below, relativeTo: wheelView)
            backdrop = view
        } else if !settings.wheelGlass, let view = backdrop {
            view.removeFromSuperview()
            backdrop = nil
        }
        wheelView.hasBackdrop = backdrop != nil
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
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
    }

    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        // Clicks inside the panel go to WheelView; global monitors only see clicks elsewhere.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    /// Scrolling over the wheel turns it over. Mouse events reach a global monitor without any permission, unlike
    /// keys, which is why Tab cannot be used while another app owns the drag.
    private func startWatchingScroll() {
        guard scrollMonitors.isEmpty, wheelView.hasBack else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] in self?.scrolled($0) }) {
            scrollMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.scrolled(event)
            return event
        }) {
            scrollMonitors.append(monitor)
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard panel.isVisible, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
        // Momentum after the fingers lift is not a new request.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.isEmpty {
            // A wheel mouse: each notch counts, but not faster than one flip per 0.35 s.
            guard abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0,
                  Date().timeIntervalSince(lastNotchFlip) > 0.35 else { return }
            lastNotchFlip = Date()
            wheelView.flip()
            return
        }
        if event.phase.contains(.began) {
            scrollAmount = 0
            flippedThisGesture = false
        }
        scrollAmount += event.scrollingDeltaY + event.scrollingDeltaX
        if !flippedThisGesture, abs(scrollAmount) > 24 {
            flippedThisGesture = true
            wheelView.flip()
        }
    }
}
