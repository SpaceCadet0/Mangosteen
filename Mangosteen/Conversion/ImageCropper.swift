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

    /// Writes `<name> (обрезано).<ext>` next to the original, keeping its format and metadata.
    /// `outputSize`, when given, scales the cropped area to exactly those pixels.
    static func cropFile(_ input: URL, rect normalized: CGRect, outputSize: CGSize?,
                         options: ConversionOptions) throws -> URL {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (image, metadata) = try ImageConverter.load(input)
        let size = CGSize(width: image.width, height: image.height)
        let area = pixelRect(normalized, imageSize: size)
        guard area.width >= 1, area.height >= 1, var cropped = image.cropping(to: area) else {
            throw ConversionError.encodeFailed(source)
        }
        if let outputSize, outputSize.width >= 1, outputSize.height >= 1 {
            cropped = try ImageCompression.resized(cropped, width: Int(outputSize.width), height: Int(outputSize.height))
        }
        // Read-only formats (SVG, PSD…) are saved as PNG.
        let target = FormatCatalog.imageOutputs.contains(source) && source != .pdf ? source : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (обрезано)",
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(cropped, as: target, to: url, options: options,
                                     metadata: options.preserveMetadata ? metadata : nil)
        }
    }
}
