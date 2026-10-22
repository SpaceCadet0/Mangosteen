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

    #if DEBUG
    func debugHighlight(_ index: Int) { highlighted = index }
    #endif

    func configure(kind: WheelKind, items: [WheelItem], fileCount: Int) {
        self.kind = kind
        self.items = items
        self.fileCount = fileCount
        highlighted = nil
        needsDisplay = true
        rebuildAccessibility()
    }

    // MARK: - Accessibility

    /// One wheel segment as a VoiceOver button; pressing it does what a click or a drop on the segment does.
    private final class SegmentElement: NSAccessibilityElement {
        var press: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            press?()
            return press != nil
        }
    }

    private var segmentElements: [SegmentElement] = []

    private func rebuildAccessibility() {
        segmentElements = items.indices.map { index in
            let element = SegmentElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(items[index].title)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(segmentPath(index).bounds)
            element.press = { [weak self] in
                guard let self, self.items.indices.contains(index) else { return }
                self.onSelect?(self.items[index])
            }
            return element
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "\(kind.title), \(Self.filesLabel(fileCount))" }
    override func accessibilityChildren() -> [Any]? { segmentElements }

    #if DEBUG
    /// Snapshot mode: what VoiceOver reads for the wheel and its buttons.
    var debugAccessibilitySummary: String {
        ([accessibilityLabel() ?? ""] + segmentElements.map { "[\($0.accessibilityLabel() ?? "")]" }).joined(separator: " ")
    }
    #endif

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
        // A ring segment with rounded corners, like a mangosteen segment: the shape is shrunk by the
        // corner radius, then grown back by a round-joined stroke of that radius.
        let corner: CGFloat = 10
        let gap: CGFloat = 6
        let outer = Self.outerRadius - 4 - corner
        let inner = Self.innerRadius + 4 + corner
        let first = CGFloat(index) * span - span / 2
        let last = CGFloat(index) * span + span / 2
        func inset(at radius: CGFloat) -> CGFloat { (gap / 2 + corner) / radius }
        // Angles here are clockwise from 12 o'clock; Core Graphics measures counter-clockwise from 3.
        func cg(_ clockwiseFromTop: CGFloat) -> CGFloat { .pi / 2 - clockwiseFromTop }
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: ringCenter.x + radius * sin(angle), y: ringCenter.y + radius * cos(angle))
        }
        let path = CGMutablePath()
        path.move(to: point(outer, first + inset(at: outer)))
        path.addArc(center: ringCenter, radius: outer, startAngle: cg(first + inset(at: outer)),
                    endAngle: cg(last - inset(at: outer)), clockwise: true)
        path.addLine(to: point(inner, last - inset(at: inner)))
        path.addArc(center: ringCenter, radius: inner, startAngle: cg(last - inset(at: inner)),
                    endAngle: cg(first + inset(at: inner)), clockwise: false)
        path.closeSubpath()
        let stroke = path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return NSBezierPath(cgPath: path.union(stroke))
    }

    private func drawSegment(_ index: Int) {
        let isHighlighted = index == highlighted
        let path = segmentPath(index)
        (isHighlighted ? Brand.nsColor : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        path.fill()

        let item = items[index]
        let middle = CGFloat(index) * span
        let tint: NSColor = isHighlighted ? .white : .labelColor
        let baseRadius = (Self.innerRadius + Self.outerRadius) / 2

        // Dense wheels (10+ segments) use a slightly smaller icon so the title has room.
        let symbol = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)?
            .withSymbolConfiguration(.init(pointSize: items.count >= 10 ? 14 : 18, weight: .medium)
                .applying(.init(paletteColors: [tint])))
        let fullIconSize = symbol?.size ?? .zero

        // Icon and title are centred together on the segment. The title gets the largest font (11.5 → 9 pt) and the
        // widest wrap (≤ 2 lines, no word broken) for which both boxes lie entirely within the segment's ring sector.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var chosen: (title: NSAttributedString, text: NSRect, icon: NSRect)?
        // Every segment keeps its icon; crowded wheels get a smaller font instead (down to 8 pt).
        let iconSize = fullIconSize
        let gap: CGFloat = 3
        // Font size first, then wrap width, then how far out the label sits: the segment widens outwards, and a long
        // word fits better there, but a tall block can run past the outer edge, so a few radii are tried.
        layout: for size in stride(from: 11.5, through: 8, by: -0.5) {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: paragraph]
            let title = NSAttributedString(string: item.title, attributes: attributes)
            let longestWord = item.title.split(separator: " ").map {
                ceil(NSAttributedString(string: String($0), attributes: [.font: font]).size().width)
            }.max() ?? 0
            for maxWidth in stride(from: CGFloat(84), through: 44, by: -8) where longestWord <= maxWidth {
                let bounds = title.boundingRect(with: NSSize(width: maxWidth, height: 200),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading])
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                guard bounds.height <= lineHeight * 2 + 1 else { continue }
                let width = min(ceil(title.size().width), maxWidth)
                let height = ceil(bounds.height)
                for shift: CGFloat in [0, 6, -6, 10, -10, 14] {
                    let radius = baseRadius + shift
                    let labelCenter = NSPoint(x: ringCenter.x + radius * sin(middle), y: ringCenter.y + radius * cos(middle))
                    let top = labelCenter.y + (iconSize.height + gap + height) / 2
                    let icon = NSRect(x: labelCenter.x - iconSize.width / 2, y: top - iconSize.height,
                                      width: iconSize.width, height: iconSize.height)
                    let text = NSRect(x: labelCenter.x - width / 2, y: icon.minY - gap - height, width: width, height: height)
                    if chosen == nil || shift == 0 { chosen = (title, text, icon) }
                    if labelFits(text, segment: index), labelFits(icon, segment: index) {
                        chosen = (title, text, icon)
                        break layout
                    }
                }
            }
        }
        guard let chosen else { return }
        symbol?.draw(in: chosen.icon)
        chosen.title.draw(with: chosen.text, options: [.usesLineFragmentOrigin, .usesFontLeading])
        #if DEBUG
        if !labelFits(chosen.text, segment: index) || !labelFits(chosen.icon, segment: index) {
            let failing = [chosen.text, chosen.icon].flatMap { r in
                [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
            }.filter { !labelFits(NSRect(origin: $0, size: .zero), segment: index) }.map { point -> String in
                let dx = point.x - ringCenter.x, dy = point.y - ringCenter.y
                let offset = abs(remainder(atan2(dx, dy) - middle, 2 * .pi))
                return String(format: "r=%.0f off=%.1f° limit=%.1f°", hypot(dx, dy), offset * 180 / .pi,
                              (span / 2 - 4 / hypot(dx, dy)) * 180 / .pi)
            }
            print("snapshot: label overflow «\(item.title)» seg \(index)/\(items.count) text \(chosen.text) \(failing)")
        }
        #endif
    }

    /// Whether `rect` (view coordinates) lies inside segment `index`'s ring sector, away from its edges and gaps.
    func labelFits(_ rect: NSRect, segment index: Int) -> Bool {
        let middle = CGFloat(index) * span
        let corners = [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                       NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
        for corner in corners {
            let dx = corner.x - ringCenter.x, dy = corner.y - ringCenter.y
            let radius = hypot(dx, dy)
            guard radius >= Self.innerRadius + 6, radius <= Self.outerRadius - 6 else { return false }
            let angle = atan2(dx, dy) // 0 at 12 o'clock, clockwise
            let offset = abs(remainder(angle - middle, 2 * .pi))
            if offset > span / 2 - 4 / radius { return false }
        }
        return true
    }

    private func drawCenter() {
        let primary: String
        let secondary: String
        if items.isEmpty {
            primary = String(localized: "Нет вариантов")
            secondary = String(localized: "для этих файлов")
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

    /// "5 файлов" / "5 files" / "5 archivos": each language has its own plural rule.
    static func filesLabel(_ count: Int) -> String {
        switch Bundle.main.preferredLocalizations.first {
        case "en": return count == 1 ? "1 file" : "\(count) files"
        case "es": return count == 1 ? "1 archivo" : "\(count) archivos"
        default: break
        }
        let lastTwo = count % 100
        let last = count % 10
        let noun: String
        if (11...14).contains(lastTwo) {
            noun = String(localized: "файлов")
        } else if last == 1 {
            noun = String(localized: "файл")
        } else if (2...4).contains(last) {
            noun = String(localized: "файла")
        } else {
            noun = String(localized: "файлов")
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
