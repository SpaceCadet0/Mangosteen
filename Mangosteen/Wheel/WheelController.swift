import AppKit

/// Shows the wheel in a non-activating panel centred on the cursor.
final class WheelController {
    private let panel: NSPanel
    private let container: NSView
    private let wheelView: WheelView
    private var backdrop: WheelBackdrop?
    private var urls: [URL] = []
    private var pendingHide: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var scrollMonitors: [Any] = []
    /// One flip per scroll gesture: trackpad deltas add up until the threshold, a wheel mouse flips per notch.
    private var scrollAmount: CGFloat = 0
    private var flippedThisGesture = false
    private var lastNotchFlip = Date.distantPast
    private var pointerTimer: Timer?
    private var tabWasDown = false
    private static var isTabDown: Bool { CGEventSource.keyState(.combinedSessionState, key: 0x30) } // kVK_Tab

    var isVisible: Bool { panel.isVisible }

    #if DEBUG
    var debugWindow: NSWindow { panel }
    func debugHighlight(_ index: Int) { wheelView.debugHighlight(index) }
    func debugFlip() { wheelView.flip() }
    var debugAccessibilitySummary: String { wheelView.debugAccessibilitySummary }

    /// Measures the wheel: for `seconds` the lit slice moves on every frame (or stays, with `sweep` false), then the
    /// time spent drawing is printed and the app quits. CPU of this process and WindowServer is sampled from outside.
    func debugBench(seconds: Double, sweep: Bool) {
        print("bench: pid \(ProcessInfo.processInfo.processIdentifier) ready"); fflush(stdout)
        WheelView.debugDraws = 0
        WheelView.debugDrawTime = 0
        var frame = 0
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            if sweep { self.wheelView.debugHighlight(frame % max(self.wheelView.items.count, 1)) }
            frame += 1
            if CACurrentMediaTime() - start > seconds {
                timer.invalidate()
                let draws = WheelView.debugDraws
                let ms = WheelView.debugDrawTime * 1000
                print(String(format: "bench: %d draws, %.2f ms each, %.1f%% of one core", draws, draws > 0 ? ms / Double(draws) : 0,
                             ms / (seconds * 10)))
                fflush(stdout)
                exit(0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
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
        wheelView.onFlip = { [weak self] in
            Feedback.hover()
            self?.updateBackdrop()
        }
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
        startFollowingPointer()
    }

    /// While a drag holds the button, the lit slice follows the pointer 60 times a second (see
    /// `WheelView.followPointer`); opened from the menu bar, the wheel's own mouse tracking does it.
    /// The same tick turns the wheel over when Tab goes down. Key events from other apps reach a global monitor
    /// only with the Accessibility permission, which Mangosteen does not ask for, so the key's state is read instead.
    private func startFollowingPointer() {
        pointerTimer?.invalidate()
        tabWasDown = Self.isTabDown
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            let tabDown = Self.isTabDown
            if tabDown, !self.tabWasDown { self.wheelView.flip(reason: "Tab") }
            self.tabWasDown = tabDown
            if NSEvent.pressedMouseButtons & 1 != 0 { self.wheelView.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// Opacity, blur and glass follow Settings → Appearance each time the wheel opens. There is always a backdrop:
    /// a blur without the glass effect, shaped glass with it.
    private func applyAppearance(_ settings: AppSettings) {
        wheelView.backgroundOpacity = settings.wheelOpacity
        let wantsGlass = settings.wheelGlass
        if backdrop == nil || backdrop?.isGlass != wantsGlass {
            backdrop?.removeFromSuperview()
            let view = WheelBackdrop(frame: container.bounds, glass: wantsGlass)
            container.addSubview(view, positioned: .below, relativeTo: wheelView)
            backdrop = view
        }
        wheelView.hasBackdrop = true
        wheelView.glassBehind = backdrop?.isGlass ?? false
        updateBackdrop()
    }

    /// The glass pieces follow the segments of the side showing.
    private func updateBackdrop() {
        backdrop?.update(segments: wheelView.items.count, opacity: AppSettings.shared.wheelOpacity)
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
        pointerTimer?.invalidate()
        pointerTimer = nil
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
    /// keys; Tab is read from the key state instead (`startFollowingPointer`).
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

    /// A deliberate scroll turns the wheel over:
    /// - a wheel mouse's notches (no precise deltas) always count, at most one flip per half second;
    /// - a trackpad or Magic Mouse counts only while no mouse button is held. During a drag the finger resting on
    ///   them slides with every move and sends scroll gestures, which flipped the wheel on any movement; there Tab
    ///   turns it instead. A gesture must travel 80 points, mostly vertically, and flips once.
    private func scrolled(_ event: NSEvent) {
        guard panel.isVisible, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
        // Momentum after the fingers lift is not a new request.
        guard event.momentumPhase.isEmpty else { return }
        let settled = Date().timeIntervalSince(lastNotchFlip) > 0.5
        if !event.hasPreciseScrollingDeltas {
            guard event.phase.isEmpty, abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0, settled else { return }
            lastNotchFlip = Date()
            wheelView.flip(reason: "mouse wheel notch")
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            flippedThisGesture = true // the rest of this gesture does not count either
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollAmount = 0
            flippedThisGesture = false
        }
        guard !event.phase.isEmpty, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }
        scrollAmount += event.scrollingDeltaY
        if !flippedThisGesture, abs(scrollAmount) > 80, settled {
            flippedThisGesture = true
            lastNotchFlip = Date()
            wheelView.flip(reason: "scroll gesture")
        }
    }
}
