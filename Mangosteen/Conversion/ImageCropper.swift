import Foundation
import ImageIO

/// Crops images by a rectangle in normalised coordinates (0…1, origin at the top-left of the upright image).
enum ImageCropper {
    /// The largest rectangle of `aspect` (width / height, in pixels) centred in an image of `size`.
    static func centeredRect(aspect: CGFloat, imageSize size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = size.width / size.height
        if aspect > imageAspect {
            let height = imageAspect / aspect
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = aspect / imageAspect
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        func point(in rect: CGRect) -> CGPoint {
            let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
            let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
            return CGPoint(x: x, y: y)
        }
    }

    /// Drags `handle` by (dx, dy) in normalised units. `aspect` is width / height in normalised units.
    /// Returns nil when the result would leave the image or become too small, so the caller keeps the last rect.
    static func resize(_ rect: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat, aspect: CGFloat?,
                       minSize: CGFloat = 0.03) -> CGRect? {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX += dx }
        if handle.movesRight { maxX += dx }
        if handle.movesTop { minY += dy }
        if handle.movesBottom { maxY += dy }
        if let aspect, aspect > 0 {
            switch handle {
            case .left, .right:
                let height = (maxX - minX) / aspect
                minY = rect.midY - height / 2
                maxY = rect.midY + height / 2
            case .top, .bottom:
                let width = (maxY - minY) * aspect
                minX = rect.midX - width / 2
                maxX = rect.midX + width / 2
            default:
                let height = (maxX - minX) / aspect
                if handle.movesTop { minY = maxY - height } else { maxY = minY + height }
            }
        }
        let tolerance: CGFloat = 0.0001
        guard maxX - minX >= minSize, maxY - minY >= minSize,
              minX >= -tolerance, minY >= -tolerance, maxX <= 1 + tolerance, maxY <= 1 + tolerance else {
            return nil
        }
        return CGRect(x: max(minX, 0), y: max(minY, 0), width: min(maxX, 1) - max(minX, 0), height: min(maxY, 1) - max(minY, 0))
    }

    /// Pixel size of the image as displayed (EXIF orientation applied).
    static func uprightSize(_ url: URL) throws -> CGSize {
        if FileFormat.detect(url) != .svg,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        let image = try ImageConverter.load(url).image
        return CGSize(width: image.width, height: image.height)
    }

    static func pixelRect(_ normalized: CGRect, imageSize size: CGSize) -> CGRect {
        let rect = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                          width: normalized.width * size.width, height: normalized.height * size.height).integral
        return rect.intersection(CGRect(origin: .zero, size: size))
    }

    /// Rotation by quarter turns and mirroring, as shown on screen: the image is turned first, then mirrored.
    struct Transform: Equatable {
        /// Clockwise quarter turns, 0…3.
        var quarterTurns = 0
        var flipHorizontal = false
        var flipVertical = false

        var isIdentity: Bool { quarterTurns == 0 && !flipHorizontal && !flipVertical }

        func size(for size: CGSize) -> CGSize {
            quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        }

        /// Turns what is on screen by 90°. A mirror made before the turn now runs along the other axis.
        mutating func rotate(clockwise: Bool) {
            quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
            swap(&flipHorizontal, &flipVertical)
        }
    }

    /// Draws `image` turned and mirrored by `transform`.
    static func apply(_ transform: Transform, to image: CGImage) throws -> CGImage {
        guard !transform.isIdentity else { return image }
        let width = image.width, height = image.height
        let size = transform.size(for: CGSize(width: width, height: height))
        guard let context = losslessContext(like: image, size: size) else { throw ConversionError.encodeFailed(.png) }
        // Core Graphics applies the last transform first: the mirror is set up before the turn.
        if transform.flipHorizontal {
            context.translateBy(x: size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if transform.flipVertical {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        switch transform.quarterTurns {
        case 1:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 3:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    /// Cut positions (0…1) that divide a side into `parts` equal pieces.
    static func evenCuts(_ parts: Int) -> [CGFloat] {
        parts > 1 ? (1..<parts).map { CGFloat($0) / CGFloat(parts) } : []
    }

    /// A bitmap context with the image's own bit depth, colour space and alpha, so turning and mirroring do not
    /// reduce 16-bit or float images to 8 bits or convert CMYK and grayscale to RGB. Combinations Core Graphics cannot
    /// draw into (grayscale with alpha, for one) fall back to RGB at the same depth.
    private static func losslessContext(like image: CGImage, size: CGSize) -> CGContext? {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let bits = image.bitsPerComponent
        let float = image.bitmapInfo.contains(.floatComponents)
        let source = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
        func context(bits: Int, space: CGColorSpace, alpha: CGImageAlphaInfo, float: Bool) -> CGContext? {
            var info = alpha.rawValue
            if float { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
            return CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: bits,
                             bytesPerRow: 0, space: space, bitmapInfo: info)
        }
        if let source {
            let alpha: CGImageAlphaInfo = switch source.model {
            case .rgb: hasAlpha ? .premultipliedLast : .noneSkipLast
            default: hasAlpha ? .premultipliedLast : .none
            }
            if let made = context(bits: bits, space: source, alpha: alpha, float: float) { return made }
        }
        let rgb = source.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context(bits: bits > 8 ? 16 : 8, space: rgb, alpha: .premultipliedLast, float: false)
            ?? context(bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: .premultipliedLast, float: false)
    }

    /// Cuts the image into a grid, row by row from the top-left; edges fall on whole pixels.
    static func tiles(_ image: CGImage, columns: Int, rows: Int) -> [CGImage] {
        tiles(image, columnCuts: evenCuts(columns), rowCuts: evenCuts(rows))
    }

    /// Cuts the image at the given positions (fractions of its width and height), row by row from the top-left.
    static func tiles(_ image: CGImage, columnCuts: [CGFloat], rowCuts: [CGFloat]) -> [CGImage] {
        func edges(_ cuts: [CGFloat], length: Int) -> [Int] {
            let inner = cuts.filter { $0 > 0 && $0 < 1 }.sorted().map { Int(($0 * CGFloat(length)).rounded()) }
            var result = [0]
            for edge in inner + [length] where edge > result.last! { result.append(edge) }
            return result
        }
        let xs = edges(columnCuts, length: image.width), ys = edges(rowCuts, length: image.height)
        return (0..<(ys.count - 1)).flatMap { row in
            (0..<(xs.count - 1)).compactMap { column in
                image.cropping(to: CGRect(x: xs[column], y: ys[row], width: xs[column + 1] - xs[column],
                                          height: ys[row + 1] - ys[row]))
            }
        }
    }

    /// Turns and mirrors the image, crops `rect` (normalised, in the turned image), scales it to `outputSize`
    /// when given, and writes `<name> (обрезано).<ext>` next to the original, keeping its format and metadata.
    /// With cut lines (even ones from `columns` × `rows`, or the given positions) the result is cut into parts
    /// saved in a `<name> (части)` folder.
    static func cropFile(_ input: URL, rect normalized: CGRect, outputSize: CGSize?,
                         transform: Transform = Transform(), columns: Int = 1, rows: Int = 1,
                         columnCuts: [CGFloat]? = nil, rowCuts: [CGFloat]? = nil,
                         options: ConversionOptions) throws -> URL {
        let columnCuts = columnCuts ?? evenCuts(columns), rowCuts = rowCuts ?? evenCuts(rows)
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (original, metadata) = try ImageConverter.load(input)
        let image = try apply(transform, to: original)
        let size = CGSize(width: image.width, height: image.height)
        let area = pixelRect(normalized, imageSize: size)
        guard area.width >= 1, area.height >= 1, var cropped = image.cropping(to: area) else {
            throw ConversionError.encodeFailed(source)
        }
        if let outputSize, outputSize.width >= 1, outputSize.height >= 1 {
            cropped = try ImageCompression.resized(cropped, width: Int(outputSize.width), height: Int(outputSize.height))
        }
        // Read-only formats (SVG, PSD…) are saved as PNG.
        let target = FormatCatalog.editableImageFormats.contains(source) ? source : .png
        let baseName = OutputNaming.baseName(of: input)
        let carried = options.preserveMetadata ? metadata : nil
        let directory = input.deletingLastPathComponent()

        if !columnCuts.isEmpty || !rowCuts.isEmpty {
            let parts = tiles(cropped, columnCuts: columnCuts, rowCuts: rowCuts)
            return try OutputNaming.writeAtomically(
                directory: directory, baseName: String(localized: "\(baseName) (части)"), pathExtension: ""
            ) { folder in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, part) in parts.enumerated() {
                    let url = folder.appendingPathComponent("\(baseName) \(OutputNaming.partNumber(index, of: parts.count))")
                        .appendingPathExtension(target.fileExtension)
                    try ImageConverter.write(part, as: target, to: url, options: options, metadata: carried)
                }
            }
        }

        let isCrop = outputSize != nil || pixelRect(normalized, imageSize: size).size != size
        let suffix = isCrop || transform.isIdentity ? String(localized: "\(baseName) (обрезано)") : String(localized: "\(baseName) (изменено)")
        return try OutputNaming.writeAtomically(
            directory: directory, baseName: suffix, pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(cropped, as: target, to: url, options: options, metadata: carried)
        }
    }
}
