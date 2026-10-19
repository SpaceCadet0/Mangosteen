import AppKit

/// Watches system-wide file drags and reports modifier-key taps made while a drag is in progress.
///
/// Uses only mouse event monitors and `NSEvent.modifierFlags` polling, so no Accessibility or
/// Input Monitoring permission is required.
final class DragMonitor {
    /// Called on the main thread when the user taps a modifier combination during a file drag.
    var onModifierTap: ((NSEvent.ModifierFlags, [URL]) -> Void)?
    /// Called on the main thread when the mouse button is released after a file drag.
    var onDragEnded: (() -> Void)?

    private(set) var isDragging = false
    private(set) var draggedURLs: [URL] = []

    /// A press longer than this is treated as a hold (e.g. Finder's ⌘-to-move), not a tap.
    var maximumTapDuration: TimeInterval = 0.8

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var baselineChangeCount = NSPasteboard(name: .drag).changeCount
    private var lastFlags: NSEvent.ModifierFlags = []
    private var pressedFlags: NSEvent.ModifierFlags = []
    private var pressStart: Date?

    func start() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.mouseDragged()
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseReleased()
        }) {
            monitors.append(monitor)
        }
        // Drags that start inside Mangosteen's own windows only reach a local monitor.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            if event.type == .leftMouseDragged {
                self?.mouseDragged()
            } else {
                self?.mouseReleased()
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endDrag(notify: false)
    }

    private func mouseDragged() {
        guard !isDragging else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // The drag pasteboard is only rewritten when a real drag session starts.
        guard pasteboard.changeCount != baselineChangeCount else { return }
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { return }
        isDragging = true
        draggedURLs = urls
        lastFlags = currentFlags()
        pressedFlags = []
        pressStart = nil
        startPolling()
    }

    private func mouseReleased() {
        baselineChangeCount = NSPasteboard(name: .drag).changeCount
        endDrag(notify: true)
    }

    private func endDrag(notify: Bool) {
        guard isDragging else { return }
        isDragging = false
        pollTimer?.invalidate()
        pollTimer = nil
        if notify {
            onDragEnded?()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        // The mouse-up event is not always delivered to global monitors while a drag session owns the
        // mouse, so the button state is the source of truth.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            mouseReleased()
            return
        }
        let flags = currentFlags()
        guard flags != lastFlags else { return }
        if lastFlags.isEmpty {
            pressedFlags = flags
            pressStart = Date()
        } else if flags.isEmpty {
            if let start = pressStart, Date().timeIntervalSince(start) <= maximumTapDuration {
                onModifierTap?(pressedFlags, draggedURLs)
            }
            pressedFlags = []
            pressStart = nil
        } else {
            pressedFlags.formUnion(flags)
        }
        lastFlags = flags
    }

    private func currentFlags() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(ModifierChoice.relevantFlags)
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
