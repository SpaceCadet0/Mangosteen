import AppKit

/// One mark on a photo. Geometry is in pixels of the full-size upright image, origin at the top-left.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        /// Top-left corner of the text.
        case text(CGPoint, String)
        /// Centre and label.
        case number(CGPoint, Int)
        case pen([CGPoint])
        case highlight([CGPoint])
        /// Centre and radius; shows the area around the centre at 2× zoom.
        case magnifier(CGPoint, CGFloat)
        case image(CGRect, URL)
    }

    var id = UUID()
    var shape: Shape
    var color: RGBAColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, text, number, pen, highlight, magnifier, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Выбор"
        case .arrow: "Стрелка"
        case .rectangle: "Прямоугольник"
        case .ellipse: "Овал"
        case .text: "Текст"
        case .number: "Номер"
        case .pen: "Карандаш"
        case .highlight: "Маркер"
        case .magnifier: "Лупа"
        case .image: "Картинка"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .number: "1.circle"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .magnifier: "plus.magnifyingglass"
        case .image: "photo.badge.plus"
        }
    }
}

enum AnnotationHandle: Hashable {
    case start, end, radius
    case corner(ImageCropper.Handle)
}

enum AnnotationGeometry {
    static let magnification: CGFloat = 2

    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: max(size, 1), weight: .bold)
    }

    static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let text = string.isEmpty ? " " : string
        return NSAttributedString(string: text, attributes: [.font: font(size: fontSize)]).size()
    }

    static func bounds(_ annotation: Annotation) -> CGRect {
        switch annotation.shape {
        case .arrow(let start, let end):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .rectangle(let rect), .ellipse(let rect), .image(let rect, _):
            return rect.standardized
        case .text(let origin, let string):
            return CGRect(origin: origin, size: textSize(string, fontSize: annotation.fontSize))
        case .number(let center, _):
            let radius = annotation.fontSize * 0.75
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .pen(let points), .highlight(let points):
            guard let first = points.first else { return .null }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        case .magnifier(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    static func translated(_ annotation: Annotation, by delta: CGVector) -> Annotation {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.dx, y: point.y + delta.dy) }
        func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.dx, dy: delta.dy) }
        var result = annotation
        switch annotation.shape {
        case .arrow(let start, let end): result.shape = .arrow(move(start), move(end))
        case .rectangle(let rect): result.shape = .rectangle(move(rect))
        case .ellipse(let rect): result.shape = .ellipse(move(rect))
        case .text(let origin, let string): result.shape = .text(move(origin), string)
        case .number(let center, let value): result.shape = .number(move(center), value)
        case .pen(let points): result.shape = .pen(points.map(move))
        case .highlight(let points): result.shape = .highlight(points.map(move))
        case .magnifier(let center, let radius): result.shape = .magnifier(move(center), radius)
        case .image(let rect, let url): result.shape = .image(move(rect), url)
        }
        return result
    }

    static func handles(_ annotation: Annotation) -> [(AnnotationHandle, CGPoint)] {
        let corners: [ImageCropper.Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        switch annotation.shape {
        case .arrow(let start, let end):
            return [(.start, start), (.end, end)]
        case .rectangle(let rect), .ellipse(let rect), .image(let rect, _):
            return corners.map { (.corner($0), $0.point(in: rect.standardized)) }
        case .magnifier(let center, let radius):
            return [(.radius, CGPoint(x: center.x + radius, y: center.y))]
        default:
            return []
        }
    }

    /// Moves one handle of `annotation` (as it was when the drag began) to `point`.
    static func moving(_ annotation: Annotation, handle: AnnotationHandle, to point: CGPoint,
                       imageAspect: CGFloat? = nil) -> Annotation {
        var result = annotation
        func resize(_ rect: CGRect, _ corner: ImageCropper.Handle) -> CGRect {
            let rect = rect.standardized
            let opposite = CGPoint(x: corner.movesLeft ? rect.maxX : rect.minX, y: corner.movesTop ? rect.maxY : rect.minY)
            var width = max(abs(point.x - opposite.x), 4)
            var height = max(abs(point.y - opposite.y), 4)
            if let imageAspect, imageAspect > 0 {
                height = width / imageAspect
                width = height * imageAspect
            }
            let x = point.x < opposite.x ? opposite.x - width : opposite.x
            let y = point.y < opposite.y ? opposite.y - height : opposite.y
            return CGRect(x: x, y: y, width: width, height: height)
        }
        switch (annotation.shape, handle) {
        case (.arrow(_, let end), .start): result.shape = .arrow(point, end)
        case (.arrow(let start, _), .end): result.shape = .arrow(start, point)
        case (.rectangle(let rect), .corner(let corner)): result.shape = .rectangle(resize(rect, corner))
        case (.ellipse(let rect), .corner(let corner)): result.shape = .ellipse(resize(rect, corner))
        case (.image(let rect, let url), .corner(let corner)): result.shape = .image(resize(rect, corner), url)
        case (.magnifier(let center, _), .radius):
            result.shape = .magnifier(center, max(hypot(point.x - center.x, point.y - center.y), 8))
        default: break
        }
        return result
    }

    /// Topmost annotation under `point`, within `tolerance` pixels.
    static func hitTest(_ annotations: [Annotation], at point: CGPoint, tolerance: CGFloat) -> UUID? {
        for annotation in annotations.reversed() {
            let slop = tolerance + annotation.lineWidth
            if bounds(annotation).insetBy(dx: -slop, dy: -slop).contains(point) {
                return annotation.id
            }
        }
        return nil
    }
}

enum AnnotationRenderer {
    /// Draws `base` (any size) with annotations given in `fullSize` pixel coordinates on top.
    /// `images` supplies decoded pictures for image annotations.
    static func render(_ annotations: [Annotation], on base: CGImage, fullSize: CGSize,
                       images: [URL: CGImage] = [:]) throws -> CGImage {
        let width = base.width, height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.png)
        }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / max(fullSize.width, 1)

        // Work in top-left pixel coordinates of the full-size image.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context, base: base, scale: scale, images: images)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return image
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, base: CGImage, scale: CGFloat,
                             images: [URL: CGImage]) {
        let color = annotation.color.cgColor
        let lineWidth = annotation.lineWidth
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case .arrow(let start, let end):
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { return }
            let direction = CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
            let headLength = min(lineWidth * 4 + 6, length)
            let base = CGPoint(x: end.x - direction.dx * headLength, y: end.y - direction.dy * headLength)
            let spread = headLength * 0.6
            context.move(to: start)
            context.addLine(to: base)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: base.x - direction.dy * spread, y: base.y + direction.dx * spread))
            context.addLine(to: CGPoint(x: base.x + direction.dy * spread, y: base.y - direction.dx * spread))
            context.closePath()
            context.fillPath()

        case .rectangle(let rect):
            let radius = min(lineWidth * 1.5, min(rect.width, rect.height) / 2)
            context.addPath(CGPath(roundedRect: rect.standardized, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()

        case .ellipse(let rect):
            context.strokeEllipse(in: rect.standardized)

        case .text(let origin, let string):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = annotation.fontSize * 0.08
            NSAttributedString(string: string, attributes: [
                .font: AnnotationGeometry.font(size: annotation.fontSize),
                .foregroundColor: NSColor(cgColor: color) ?? .red,
                .shadow: shadow,
            ]).draw(at: origin)

        case .number(let center, let value):
            let radius = annotation.fontSize * 0.75
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let label = NSAttributedString(string: "\(value)", attributes: [
                .font: AnnotationGeometry.font(size: annotation.fontSize * 0.85),
                .foregroundColor: NSColor.white,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))

        case .pen(let points):
            strokePolyline(points, in: context)

        case .highlight(let points):
            context.setBlendMode(.multiply)
            context.setAlpha(0.4)
            context.setLineWidth(lineWidth * 5)
            context.setLineCap(.square)
            strokePolyline(points, in: context)

        case .magnifier(let center, let radius):
            let sourceSide = radius * 2 / AnnotationGeometry.magnification
            let source = CGRect(x: (center.x - sourceSide / 2) * scale, y: (center.y - sourceSide / 2) * scale,
                                width: sourceSide * scale, height: sourceSide * scale)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if let crop = base.cropping(to: source.integral) {
                context.saveGState()
                context.addEllipse(in: circle)
                context.clip()
                drawUpright(crop, in: circle, context: context)
                context.restoreGState()
            }
            context.setStrokeColor(.white)
            context.setLineWidth(lineWidth * 2)
            context.strokeEllipse(in: circle)
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: circle)

        case .image(let rect, let url):
            if let image = images[url] {
                drawUpright(image, in: rect.standardized, context: context)
            }
        }
    }

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: first)
        }
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    /// Draws a CGImage the right way up in the flipped (top-left origin) context.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// Writes `<name> (пометки).<ext>` next to the original.
    static func applyFile(_ input: URL, annotations: [Annotation], images: [URL: CGImage],
                          options: ConversionOptions) throws -> URL {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (image, metadata) = try ImageConverter.load(input)
        let result = try render(annotations, on: image, fullSize: CGSize(width: image.width, height: image.height),
                                images: images)
        let target = FormatCatalog.imageOutputs.contains(source) && source != .pdf ? source : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (пометки)",
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(result, as: target, to: url, options: options,
                                     metadata: options.preserveMetadata ? metadata : nil)
        }
    }
}
