import CoreGraphics
import Foundation

struct CollageSettings: Equatable {
    enum Layout: String, CaseIterable, Identifiable {
        case grid, row, column, featured
        var id: String { rawValue }
        var title: String {
            switch self {
            case .grid: String(localized: "Сетка")
            case .row: String(localized: "Ряд")
            case .column: String(localized: "Колонка")
            case .featured: String(localized: "Главное фото")
            }
        }
    }

    var layout = Layout.grid
    /// Grid columns; 0 picks a near-square grid.
    var columns = 0
    var aspect = CanvasAspect.auto
    /// Output width in pixels.
    var width = 3000
    /// Gap between and around photos, as a fraction of the width.
    var spacing = 0.015
    /// Corner radius as a fraction of each cell's shorter side.
    var cornerRadius = 0.0
    enum Fill: String, CaseIterable, Identifiable {
        case color, gradient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .color: String(localized: "Цвет")
            case .gradient: String(localized: "Градиент")
            }
        }
    }

    var fill = Fill.color
    var background = RGBAColor.white
    var gradientStart = FrameSettings().gradientStart
    var gradientEnd = FrameSettings().gradientEnd
    /// Degrees, 0 = left → right, 90 = bottom → top.
    var gradientAngle = FrameSettings().gradientAngle
    /// 0…1, a soft shadow under every photo.
    var shadow = 0.0
    var format = FileFormat.jpg
}

/// Arranges several images on one canvas. Cells are filled edge to edge (cropping when the cell's
/// proportions differ), except Row and Column with automatic proportions, which keep every photo whole.
enum CollageComposer {
    /// Canvas size and cell rectangles (origin at the top-left) for images with the given aspect ratios.
    static func layout(aspects: [CGFloat], settings: CollageSettings) -> (size: CGSize, cells: [CGRect]) {
        let count = aspects.count
        guard count > 0 else { return (.zero, []) }
        let width = CGFloat(max(settings.width, 100))
        let gap = (settings.spacing * width).rounded()
        let fixedHeight = settings.aspect.ratio.map { (width / $0).rounded() }

        switch settings.layout {
        case .row:
            if let height = fixedHeight {
                let cellWidth = (width - gap * CGFloat(count + 1)) / CGFloat(count)
                let cells = (0..<count).map { CGRect(x: gap + CGFloat($0) * (cellWidth + gap), y: gap,
                                                     width: cellWidth, height: height - gap * 2) }
                return (CGSize(width: width, height: height), cells)
            }
            let rowHeight = (width - gap * CGFloat(count + 1)) / aspects.reduce(0, +)
            var x = gap
            let cells = aspects.map { aspect -> CGRect in
                defer { x += aspect * rowHeight + gap }
                return CGRect(x: x, y: gap, width: aspect * rowHeight, height: rowHeight)
            }
            return (CGSize(width: width, height: (rowHeight + gap * 2).rounded()), cells)

        case .column:
            let cellWidth = width - gap * 2
            if let height = fixedHeight {
                let cellHeight = (height - gap * CGFloat(count + 1)) / CGFloat(count)
                let cells = (0..<count).map { CGRect(x: gap, y: gap + CGFloat($0) * (cellHeight + gap),
                                                     width: cellWidth, height: cellHeight) }
                return (CGSize(width: width, height: height), cells)
            }
            var y = gap
            let cells = aspects.map { aspect -> CGRect in
                let height = cellWidth / aspect
                defer { y += height + gap }
                return CGRect(x: gap, y: y, width: cellWidth, height: height)
            }
            return (CGSize(width: width, height: y.rounded()), cells)

        case .featured where count > 1:
            let height = fixedHeight ?? (width * 3 / 4).rounded()
            let mainWidth = ((width - gap * 3) * 2 / 3).rounded()
            let sideWidth = width - gap * 3 - mainWidth
            let others = count - 1
            let sideHeight = (height - gap * CGFloat(others + 1)) / CGFloat(others)
            var cells = [CGRect(x: gap, y: gap, width: mainWidth, height: height - gap * 2)]
            for index in 0..<others {
                cells.append(CGRect(x: gap * 2 + mainWidth, y: gap + CGFloat(index) * (sideHeight + gap),
                                    width: sideWidth, height: sideHeight))
            }
            return (CGSize(width: width, height: height), cells)

        case .grid, .featured:
            let columns = settings.columns > 0
                ? min(settings.columns, count)
                : Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let cellWidth = (width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let height: CGFloat
            let cellHeight: CGFloat
            if let fixedHeight {
                height = fixedHeight
                cellHeight = (height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            } else {
                let averageAspect = aspects.reduce(0, +) / CGFloat(count)
                cellHeight = cellWidth / averageAspect
                height = (cellHeight * CGFloat(rows) + gap * CGFloat(rows + 1)).rounded()
            }
            var cells: [CGRect] = []
            for index in 0..<count {
                let row = index / columns
                let inRow = row == rows - 1 ? count - row * columns : columns
                // Centre a shorter last row.
                let rowInset = (CGFloat(columns - inRow) * (cellWidth + gap)) / 2
                let column = index % columns
                cells.append(CGRect(x: rowInset + gap + CGFloat(column) * (cellWidth + gap),
                                    y: gap + CGFloat(row) * (cellHeight + gap),
                                    width: cellWidth, height: cellHeight))
            }
            return (CGSize(width: width, height: height), cells)
        }
    }

    static func compose(_ images: [CGImage], settings: CollageSettings) throws -> CGImage {
        let aspects = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
        let (size, cells) = layout(aspects: aspects, settings: settings)
        guard size.width >= 1, size.height >= 1, let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(settings.format)
        }
        context.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: size)
        switch settings.fill {
        case .color:
            context.setFillColor(settings.background.cgColor)
            context.fill(canvas)
        case .gradient:
            FrameComposer.drawGradient(in: context, rect: canvas, from: settings.gradientStart, to: settings.gradientEnd,
                                       angle: settings.gradientAngle)
        }

        // Layout uses a top-left origin; Core Graphics draws from the bottom-left.
        let shapes = cells.map { cell -> (rect: CGRect, path: CGPath) in
            let rect = CGRect(x: cell.minX, y: size.height - cell.maxY, width: cell.width, height: cell.height)
            let radius = settings.cornerRadius * min(rect.width, rect.height)
            return (rect, CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        // All shadows first, so no shadow falls on a neighbouring photo; the photos then cover the shapes.
        if settings.shadow > 0 {
            for shape in shapes {
                let blur = settings.shadow * min(shape.rect.width, shape.rect.height) * 0.08
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                                  color: CGColor(gray: 0, alpha: 0.25 + settings.shadow * 0.3))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.addPath(shape.path)
                context.fillPath()
                context.restoreGState()
            }
        }
        for (image, shape) in zip(images, shapes) {
            context.saveGState()
            context.addPath(shape.path)
            context.clip()
            FrameComposer.drawAspectFill(image, in: context, rect: shape.rect)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(settings.format) }
        return result
    }

    /// Loads images no larger than needed for the output width.
    static func loadImages(_ urls: [URL], maxPixelSize: Int) throws -> [CGImage] {
        try urls.map { try ImageConverter.load($0, maxPixelSize: maxPixelSize).image }
    }

    /// Writes `Коллаж.<ext>` next to the first image.
    static func composeFile(_ urls: [URL], settings: CollageSettings, options: ConversionOptions) throws -> URL {
        guard let first = urls.first else { throw PDFToolError.nothingToDo }
        let images = try loadImages(urls, maxPixelSize: settings.width)
        let result = try compose(images, settings: settings)
        return try OutputNaming.writeAtomically(
            directory: first.deletingLastPathComponent(), baseName: String(localized: "Коллаж"), pathExtension: settings.format.fileExtension
        ) { url in
            try ImageConverter.write(result, as: settings.format, to: url, options: options)
        }
    }
}
