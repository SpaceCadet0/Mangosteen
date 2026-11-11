import AppKit
import SwiftUI

/// Zoom commands for `SyncedZoomPanes`, and the current magnification for the toolbar.
final class ZoomControl: ObservableObject {
    /// 1 shows one picture pixel per point.
    @Published fileprivate(set) var magnification: CGFloat = 1
    fileprivate weak var coordinator: SyncedZoomPanes.Coordinator?

    func zoomIn() { coordinator?.zoom(by: 2) }
    func zoomOut() { coordinator?.zoom(by: 0.5) }
    func actualSize() { coordinator?.setMagnification(1) }
    func setMagnification(_ value: CGFloat) { coordinator?.setMagnification(value) }
    func fit() { coordinator?.fit() }
}

/// The original picture and its trace side by side, zoomed and moved together: the scroll wheel (or a pinch) zooms
/// around the pointer, dragging with the button held moves the picture. The trace is drawn from its paths, so it stays sharp at any zoom;
/// the original shows its real pixels when enlarged, to compare against.
struct SyncedZoomPanes: NSViewRepresentable {
    let image: CGImage?
    let result: VectorTracer.Result?
    let control: ZoomControl

    func makeCoordinator() -> Coordinator { Coordinator(control: control) }

    func makeNSView(context: Context) -> NSView {
        let container = PanesContainer()
        let coordinator = context.coordinator
        container.left = coordinator.left
        container.right = coordinator.right
        container.addSubview(coordinator.left)
        container.addSubview(coordinator.right)
        control.coordinator = coordinator
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.show(image: image, result: result)
    }

    // MARK: - Coordinator

    final class Coordinator {
        let left = ZoomingScrollView()
        let right = ZoomingScrollView()
        private let original = PictureDocument()
        private let vector = VectorDocument()
        private let control: ZoomControl
        private var syncing = false
        private var documentSize = CGSize.zero

        init(control: ZoomControl) {
            self.control = control
            for (scroll, document) in [(left, original as NSView), (right, vector as NSView)] {
                scroll.contentView = CenteringClipView()
                scroll.documentView = document
                scroll.hasVerticalScroller = true
                scroll.hasHorizontalScroller = true
                scroll.autohidesScrollers = true
                scroll.allowsMagnification = true
                scroll.minMagnification = 0.02
                scroll.maxMagnification = 32
                scroll.drawsBackground = false
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                       queue: .main) { [weak self, weak scroll] _ in
                    guard let self, let scroll else { return }
                    self.follow(scroll)
                }
            }
        }

        func show(image: CGImage?, result: VectorTracer.Result?) {
            original.image = image
            vector.result = result
            let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? result?.size ?? .zero
            original.needsDisplay = true
            vector.needsDisplay = true
            guard size != documentSize, size.width > 0 else { return }
            documentSize = size
            original.frame = CGRect(origin: .zero, size: size)
            vector.frame = CGRect(origin: .zero, size: size)
            DispatchQueue.main.async { self.fit() }
        }

        /// Copies the zoom and position of the pane the user moved to the other one.
        private func follow(_ source: ZoomingScrollView) {
            guard !syncing else { return }
            syncing = true
            let target = source === left ? right : left
            if target.magnification != source.magnification { target.magnification = source.magnification }
            target.contentView.scroll(to: source.contentView.bounds.origin)
            target.reflectScrolledClipView(target.contentView)
            control.magnification = source.magnification
            original.magnification = source.magnification
            syncing = false
        }

        func zoom(by factor: CGFloat) {
            setMagnification(left.magnification * factor)
        }

        func setMagnification(_ value: CGFloat) {
            let clamped = min(max(value, left.minMagnification), left.maxMagnification)
            let visible = left.contentView.bounds
            left.setMagnification(clamped, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        }

        func fit() {
            guard documentSize.width > 0 else { return }
            left.magnify(toFit: CGRect(origin: .zero, size: documentSize))
        }
    }
}

/// Lays the two panes out side by side with a gap.
private final class PanesContainer: NSView {
    weak var left: NSView?
    weak var right: NSView?
    private let gap: CGFloat = 12

    override func layout() {
        super.layout()
        let width = (bounds.width - gap) / 2
        left?.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        right?.frame = CGRect(x: width + gap, y: 0, width: width, height: bounds.height)
    }
}

/// The scroll wheel zooms around the pointer, like a pinch; moving is done by dragging (`PanningDocument`).
final class ZoomingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard allowsMagnification else {
            super.scrollWheel(with: event)
            return
        }
        // Momentum after a trackpad or Magic Mouse swipe would keep zooming on its own.
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
        let point = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(min(max(magnification * (1 + delta), minMagnification), maxMagnification), centeredAt: point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

/// Keeps a picture smaller than the pane in its middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Grey-and-white squares under a transparent picture.
private func drawCheckerboard(in rect: NSRect, bounds: NSRect, side: CGFloat) {
    NSColor(white: 0.85, alpha: 1).setFill()
    rect.intersection(bounds).fill()
    NSColor(white: 0.7, alpha: 1).setFill()
    let firstColumn = Int(max(rect.minX, 0) / side), lastColumn = Int(min(rect.maxX, bounds.maxX) / side)
    let firstRow = Int(max(rect.minY, 0) / side), lastRow = Int(min(rect.maxY, bounds.maxY) / side)
    guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
    for row in firstRow...lastRow {
        for column in firstColumn...lastColumn where (row + column).isMultiple(of: 2) {
            NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).intersection(bounds).fill()
        }
    }
}

/// A picture in a pane that moves when dragged with the mouse button held, under an open-hand cursor.
private class PanningDocument: NSView {
    private var dragging = false

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: dragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        // The pane is zoomed: a point of mouse movement is 1 / magnification of the picture. The picture follows
        // the hand, so its visible part moves the other way. The view is flipped, so y runs down like the mouse.
        var bounds = clip.bounds
        bounds.origin.x -= event.deltaX / scrollView.magnification
        bounds.origin.y -= event.deltaY / scrollView.magnification
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }
}

/// The original picture, one pixel per point; enlarged pixels stay square.
private final class PictureDocument: PanningDocument {
    var image: CGImage?
    var magnification: CGFloat = 1 { didSet { if (oldValue > 2) != (magnification > 2) { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawCheckerboard(in: dirtyRect, bounds: bounds, side: max(8, bounds.width / 60))
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = magnification > 2 ? .none : .high
        // The view is flipped; CGImage draws y-up.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}

/// The traced shapes, drawn from their paths.
private final class VectorDocument: PanningDocument {
    var result: VectorTracer.Result?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawCheckerboard(in: dirtyRect, bounds: bounds, side: max(8, bounds.width / 60))
        guard let result, result.size.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / result.size.width, y: bounds.height / result.size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for layer in result.layers {
            context.addPath(layer.path)
            context.setFillColor(CGColor(colorSpace: space, components: [layer.color.red, layer.color.green, layer.color.blue, 1])!)
            context.fillPath(using: .evenOdd)
        }
        context.restoreGState()
    }
}
