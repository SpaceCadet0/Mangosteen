import AppKit

/// Draws the ring of segments and acts as the drop target for each of them.
/// Segments are laid out clockwise starting at 12 o'clock.
final class WheelView: NSView {
    static let innerRadius: CGFloat = 64
    static let outerRadius: CGFloat = 160
    /// Extra tolerance outside the ring that still counts as the segment under the cursor.
    static let hitSlop: CGFloat = 26
    static let diameter = (outerRadius + hitSlop) * 2

    var onSelect: ((WheelItem) -> Void)?
    var onHoverChange: (() -> Void)?

    private(set) var items: [WheelItem] = []
    private var kind: WheelKind = .convert
    private var fileCount = 0
    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
            if highlighted != nil { onHoverChange?() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(kind: WheelKind, items: [WheelItem], fileCount: Int) {
        self.kind = kind
        self.items = items
        self.fileCount = fileCount
        highlighted = nil
        needsDisplay = true
    }

    private var ringCenter: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var span: CGFloat { 2 * .pi / CGFloat(max(items.count, 1)) }

    /// Index of the segment under `point` (view coordinates), if any.
    func segmentIndex(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - ringCenter.x
        let dy = point.y - ringCenter.y
        let distance = hypot(dx, dy)
        guard distance >= Self.innerRadius, distance <= Self.outerRadius + Self.hitSlop else { return nil }
        var angle = atan2(dx, dy) // 0 at 12 o'clock, growing clockwise
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + span / 2) / span) % items.count
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        background.setFill()
        circle(radius: Self.outerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        for index in items.indices {
            drawSegment(index)
        }
        drawCenter()
    }

    private func circle(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: ringCenter.x - radius, y: ringCenter.y - radius,
                                    width: radius * 2, height: radius * 2))
    }

    private func segmentPath(_ index: Int) -> NSBezierPath {
        if items.count == 1 {
            let path = circle(radius: Self.outerRadius - 4)
            path.append(circle(radius: Self.innerRadius + 4))
            path.windingRule = .evenOdd
            return path
        }
        let gap: CGFloat = 0.025
        let start = CGFloat(index) * span - span / 2 + gap
        let end = CGFloat(index) * span + span / 2 - gap
        // NSBezierPath angles are degrees counter-clockwise from 3 o'clock.
        func degrees(_ clockwiseFromTop: CGFloat) -> CGFloat { 90 - clockwiseFromTop * 180 / .pi }
        let path = NSBezierPath()
        path.appendArc(withCenter: ringCenter, radius: Self.outerRadius - 4,
                       startAngle: degrees(start), endAngle: degrees(end), clockwise: true)
        path.appendArc(withCenter: ringCenter, radius: Self.innerRadius + 4,
                       startAngle: degrees(end), endAngle: degrees(start), clockwise: false)
        path.close()
        return path
    }

    private func drawSegment(_ index: Int) {
        let isHighlighted = index == highlighted
        let path = segmentPath(index)
        (isHighlighted ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        path.fill()

        let item = items[index]
        let middle = CGFloat(index) * span
        let radius = (Self.innerRadius + Self.outerRadius) / 2
        let labelCenter = NSPoint(x: ringCenter.x + radius * sin(middle), y: ringCenter.y + radius * cos(middle))
        let tint: NSColor = isHighlighted ? .white : .labelColor

        if let symbol = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium)
                .applying(.init(paletteColors: [tint]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: labelCenter.x - size.width / 2, y: labelCenter.y + 2,
                                   width: size.width, height: size.height))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: tint,
        ]
        let title = NSAttributedString(string: item.title, attributes: attributes)
        let titleSize = title.size()
        title.draw(at: NSPoint(x: labelCenter.x - titleSize.width / 2, y: labelCenter.y - titleSize.height - 2))
    }

    private func drawCenter() {
        let primary: String
        let secondary: String
        if items.isEmpty {
            primary = "Нет вариантов"
            secondary = "для этих файлов"
        } else {
            primary = kind.title
            secondary = Self.filesLabel(fileCount)
        }
        let primaryText = NSAttributedString(string: primary, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.labelColor,
        ])
        let secondaryText = NSAttributedString(string: secondary, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let primarySize = primaryText.size()
        let secondarySize = secondaryText.size()
        primaryText.draw(at: NSPoint(x: ringCenter.x - primarySize.width / 2, y: ringCenter.y + 1))
        secondaryText.draw(at: NSPoint(x: ringCenter.x - secondarySize.width / 2, y: ringCenter.y - secondarySize.height - 1))
    }

    static func filesLabel(_ count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        let noun: String
        if (11...14).contains(lastTwo) {
            noun = "файлов"
        } else if last == 1 {
            noun = "файл"
        } else if (2...4).contains(last) {
            noun = "файла"
        } else {
            noun = "файлов"
        }
        return "\(count) \(noun)"
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = segmentIndex(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = segmentIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        onSelect?(items[index])
        return true
    }

    // MARK: - Mouse (wheel opened from the menu bar)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        highlighted = segmentIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = segmentIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(items[index])
    }
}
