import AppKit

/// Draws the ring of segments and acts as the drop target for each of them.
/// Segments are laid out clockwise starting at 12 o'clock.
final class WheelView: NSView {
    static let innerRadius: CGFloat = 64
    static let outerRadius: CGFloat = 160
    /// Extra tolerance outside the ring that still counts as the segment under the cursor.
    static let hitSlop: CGFloat = 26
    static let diameter = (outerRadius + hitSlop) * 2

    /// The item and, for a drop, the files that were dropped.
    var onSelect: ((WheelItem, [URL]?) -> Void)?
    var onHoverChange: (() -> Void)?
    /// Called after the wheel turned to its other side.
    var onFlip: (() -> Void)?
    /// Called when the lit segment changes, so glass behind the wheel can tint that piece.
    var onHighlight: ((Int?) -> Void)?
    /// The lit segment, if any.
    var highlightedIndex: Int? { highlighted }

    /// Opacity of the wheel's background (Settings → Appearance).
    var backgroundOpacity: CGFloat = 0.96 { didSet { needsDisplay = true } }
    /// A glass or blur view lies behind the wheel; the drawn drop shadow would show through it.
    var hasBackdrop = false { didSet { needsDisplay = true } }
    /// The backdrop is Liquid Glass shaped like the segments (macOS 26), so the wheel paints no background.
    var glassBehind = false { didSet { needsDisplay = true } }

    /// The slices on the side that is showing.
    private(set) var items: [WheelItem] = []
    private var sides: (front: [WheelItem], back: [WheelItem]) = ([], [])
    private(set) var showingBack = false
    var hasBack: Bool { !sides.back.isEmpty }
    private var kind: WheelKind = .convert
    private var fileCount = 0
    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            showLitLayer()
            onHighlight?(highlighted)
            if highlighted != nil { onHoverChange?() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Files, and pictures dragged out of a browser (file promises or picture data).
        registerForDraggedTypes([.fileURL] + WebImageDrop.draggedTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    #if DEBUG
    func debugHighlight(_ index: Int) { highlighted = index }
    #endif

    func configure(kind: WheelKind, front: [WheelItem], back: [WheelItem] = [], fileCount: Int) {
        self.kind = kind
        sides = (front, back)
        showingBack = false
        items = front
        self.fileCount = fileCount
        litStale = true
        highlighted = nil
        needsDisplay = true
        rebuildAccessibility()
    }

    /// Turns the wheel to its other side, if it has one. `reason` goes to the log, so an unexpected turn can be
    /// traced (`log show --predicate 'subsystem == "dev.mangosteen.app"'`).
    func flip(reason: String = "click") {
        guard hasBack else { return }
        DragMonitor.log.info("Wheel turned over: \(reason, privacy: .public)")
        showingBack.toggle()
        items = showingBack ? sides.back : sides.front
        litStale = true
        highlighted = nil
        needsDisplay = true
        rebuildAccessibility()
        onFlip?()
    }

    /// Lights one slice, as the pointer would (the preview in Settings).
    func showHighlight(_ index: Int?) { highlighted = index }

    private func isInCenter(_ point: NSPoint) -> Bool {
        hypot(point.x - ringCenter.x, point.y - ringCenter.y) < Self.innerRadius - 4
    }

    /// Follows the pointer while a drag is over the wheel. The drag session's own updates reach a panel that
    /// appeared mid-drag late and unevenly, so the lit slice is taken from the pointer itself.
    func followPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        highlighted = segmentIndex(at: point)
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
                self.onSelect?(self.items[index], nil)
            }
            return element
        }
        if hasBack {
            // The centre turns the wheel; VoiceOver reaches it as a button after the slices.
            let center = SegmentElement()
            center.setAccessibilityRole(.button)
            center.setAccessibilityLabel(String(localized: "Другая сторона колеса"))
            center.setAccessibilityParent(self)
            center.setAccessibilityFrameInParentSpace(circle(radius: Self.innerRadius).bounds)
            center.press = { [weak self] in self?.flip(reason: "VoiceOver") }
            segmentElements.append(center)
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

    #if DEBUG
    static var debugDraws = 0
    static var debugDrawTime: CFTimeInterval = 0
    #endif

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        let drawStart = CACurrentMediaTime()
        defer {
            Self.debugDraws += 1
            Self.debugDrawTime += CACurrentMediaTime() - drawStart
        }
        #endif
        // Over the blur the colour fades out with the opacity setting: none at 40%, where the background shows almost
        // sharp, the usual 96% at the default.
        let fill = hasBackdrop ? min(max((backgroundOpacity - 0.4) / 0.56, 0), 1) * 0.96 : backgroundOpacity
        let background = NSColor.windowBackgroundColor.withAlphaComponent(fill)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)

        // Over glass the segments and centre are glass pieces with gaps between them; nothing is painted under them.
        if !glassBehind {
            NSGraphicsContext.saveGraphicsState()
            // Through a see-through background the shadow would darken the wheel itself.
            if backgroundOpacity > 0.9 { shadow.set() }
            background.setFill()
            circle(radius: Self.outerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        for index in items.indices {
            drawSegment(index, lit: false)
        }
        drawCenter()
        // Whatever made the wheel redraw (another side, light or dark mode, accent, opacity) also changes the lit
        // slices; they are rendered again on the next hover.
        litStale = true
        DispatchQueue.main.async { [weak self] in self?.showLitLayer() }
    }

    // MARK: - Lit slice

    /// Each lit slice is its own small layer, rendered once and then only shown or hidden. Redrawing the whole wheel
    /// on every hover cost about 3.5 ms of drawing plus sending the full 744×744 picture to the window server, which
    /// then recomputed the glass or blur behind it: frames were dropped while the pointer moved.
    private var litLayers: [Int: CALayer] = [:]
    private var litStale = false

    private func showLitLayer() {
        guard let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if litStale {
            litLayers.values.forEach { $0.removeFromSuperlayer() }
            litLayers.removeAll()
            litStale = false
        }
        for (index, lit) in litLayers { lit.isHidden = index != highlighted }
        if let index = highlighted, items.indices.contains(index), litLayers[index] == nil {
            let lit = makeLitLayer(index)
            host.addSublayer(lit)
            litLayers[index] = lit
        }
        CATransaction.commit()
    }

    private func makeLitLayer(_ index: Int) -> CALayer {
        let rect = segmentPath(index).bounds.insetBy(dx: -2, dy: -2).integral
        let appearance = effectiveAppearance
        let image = NSImage(size: rect.size, flipped: false) { [weak self] _ in
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.current?.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                self?.drawSegment(index, lit: true)
            }
            return true
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lit = CALayer()
        lit.frame = rect
        lit.contentsScale = scale
        lit.contents = image.layerContents(forContentsScale: scale)
        return lit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
        return NSBezierPath(cgPath: Self.segmentCGPath(index: index, count: items.count, center: ringCenter))
    }

    /// Segment `index` of `count` around `center` (y up), shared by the drawing and the glass behind it. A ring
    /// segment with rounded corners, like a mangosteen segment: the shape is shrunk by the corner radius, then grown
    /// back by a round-joined stroke of that radius. A single segment is the whole ring's outer disc.
    static func segmentCGPath(index: Int, count: Int, center: CGPoint) -> CGPath {
        guard count > 1 else {
            let radius = outerRadius - 4
            return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                          transform: nil)
        }
        let span = 2 * .pi / CGFloat(count)
        let corner: CGFloat = 10
        let gap: CGFloat = 6
        let outer = outerRadius - 4 - corner
        let inner = innerRadius + 4 + corner
        let first = CGFloat(index) * span - span / 2
        let last = CGFloat(index) * span + span / 2
        func inset(at radius: CGFloat) -> CGFloat { (gap / 2 + corner) / radius }
        // Angles here are clockwise from 12 o'clock; Core Graphics measures counter-clockwise from 3.
        func cg(_ clockwiseFromTop: CGFloat) -> CGFloat { .pi / 2 - clockwiseFromTop }
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * sin(angle), y: center.y + radius * cos(angle))
        }
        let path = CGMutablePath()
        path.move(to: point(outer, first + inset(at: outer)))
        path.addArc(center: center, radius: outer, startAngle: cg(first + inset(at: outer)),
                    endAngle: cg(last - inset(at: outer)), clockwise: true)
        path.addLine(to: point(inner, last - inset(at: inner)))
        path.addArc(center: center, radius: inner, startAngle: cg(last - inset(at: inner)),
                    endAngle: cg(first + inset(at: inner)), clockwise: false)
        path.closeSubpath()
        let stroke = path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return path.union(stroke)
    }

    private func drawSegment(_ index: Int, lit isHighlighted: Bool) {
        let path = segmentPath(index)
        // Over glass every segment is a glass piece, the lit one tinted with the accent; nothing is painted.
        if isHighlighted {
            // Over glass the accent stays a little see-through so the glass edge still shows around it.
            (glassBehind ? Brand.nsColor.withAlphaComponent(0.88) : Brand.nsColor).setFill()
            path.fill()
        } else if glassBehind {
            // Unlit segments are the glass pieces drawn by WheelBackdrop.
        } else {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            path.fill()
        }

        let item = items[index]
        let middle = CGFloat(index) * span
        let tint: NSColor = isHighlighted ? Brand.onAccent : .labelColor
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
        // With a back side the block moves up to make room for "↻ 3 more" under it.
        let lift: CGFloat = hasBack ? 7 : 0
        primaryText.draw(at: NSPoint(x: ringCenter.x - primarySize.width / 2, y: ringCenter.y + 1 + lift))
        secondaryText.draw(at: NSPoint(x: ringCenter.x - secondarySize.width / 2, y: ringCenter.y - secondarySize.height - 1 + lift))
        guard hasBack else { return }
        let other = showingBack ? sides.front.count : sides.back.count
        let hint = NSAttributedString(string: "↻ " + String(localized: "ещё \(other)"), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let hintSize = hint.size()
        hint.draw(at: NSPoint(x: ringCenter.x - hintSize.width / 2, y: ringCenter.y - secondarySize.height - hintSize.height - 4 + lift))
    }

    /// "5 файлов" / "5 files" / "5 Dateien" / "5 个文件": each language has its own plural rule.
    static func filesLabel(_ count: Int) -> String {
        switch Bundle.main.preferredLocalizations.first {
        case "en": return count == 1 ? "1 file" : "\(count) files"
        case "es": return count == 1 ? "1 archivo" : "\(count) archivos"
        case "de": return count == 1 ? "1 Datei" : "\(count) Dateien"
        // French counts 0 and 1 as singular.
        case "fr": return count <= 1 ? "\(count) fichier" : "\(count) fichiers"
        case "pt-BR": return count == 1 ? "1 arquivo" : "\(count) arquivos"
        case "zh-Hans": return "\(count) 个文件"
        case "ja": return "\(count) 個のファイル"
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
        let point = convert(sender.draggingLocation, from: nil)
        highlighted = segmentIndex(at: point)
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = segmentIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let item = items[index]
        let pasteboard = sender.draggingPasteboard
        let urls = DragMonitor.fileURLs(on: pasteboard)
        if urls.isEmpty, WebImageDrop.detect(on: pasteboard) != nil {
            // A browser's picture becomes a file in Downloads first; the slice then works on that file.
            WebImageDrop.receive(from: pasteboard, into: WebImageDrop.downloads) { [weak self] result in
                switch result {
                case .success(let url):
                    // Conversions and tools leave only their result; actions (Float, AirDrop…) keep the picture.
                    if item.id.hasPrefix("convert.") || item.id.hasPrefix("tool.") { WebImageDrop.rememberOriginal(url) }
                    self?.onSelect?(item, [url])
                case .failure(let error): Feedback.showError(String(localized: "Картинка из браузера"), error)
                }
            }
            return true
        }
        onSelect?(item, urls)
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
        let point = convert(event.locationInWindow, from: nil)
        if isInCenter(point) {
            flip(reason: "click on the centre")
            return
        }
        guard let index = segmentIndex(at: point) else { return }
        onSelect?(items[index], nil)
    }
}
