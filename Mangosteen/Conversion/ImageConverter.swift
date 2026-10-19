import CoreGraphics
import Foundation
import ImageIO

/// Image → image conversion via ImageIO, with WebP encoding delegated to `cwebp`.
enum ImageConverter {
    static func convert(_ input: URL, to target: FileFormat, output: URL, options: ConversionOptions) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(input)
        }
        if target == .webp {
            try encodeWebP(source, input: input, output: output, options: options)
            return
        }

        let count = CGImageSourceGetCount(source)
        // Keep every frame/page where the target can hold several (animated GIF, multi-page TIFF/PDF).
        let keepsAllFrames = [.gif, .tiff, .pdf].contains(target) && count > 1
        let indices = keepsAllFrames ? Array(0..<count) : [CGImageSourceGetPrimaryImageIndex(source)]

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, target.utType.identifier as CFString, indices.count, nil
        ) else {
            throw ConversionError.encodeFailed(target)
        }
        if keepsAllFrames, target == .gif,
           let containerProperties = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(destination, containerProperties)
        }

        for index in indices {
            guard var image = orientedImage(source, at: index) else {
                throw ConversionError.unreadable(input)
            }
            if !target.supportsAlpha, image.hasAlpha {
                image = try flattened(image)
            }
            let properties = frameProperties(source, at: index, target: target, options: options)
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encodeFailed(target)
        }
    }

    // MARK: - Pixels

    /// Decodes a frame with its EXIF orientation applied, so every output format displays upright
    /// (BMP, GIF and PDF have no orientation tag).
    static func orientedImage(_ source: CGImageSource, at index: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1 else {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary)
    }

    /// Composites onto white for formats without transparency.
    static func flattened(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.jpg)
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.jpg) }
        return result
    }

    // MARK: - Metadata

    private static func frameProperties(_ source: CGImageSource, at index: Int, target: FileFormat,
                                        options: ConversionOptions) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if options.preserveMetadata,
           let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] {
            properties = original
        }
        // Pixels are already upright.
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let quality = options.quality(for: target), target.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        return properties
    }

    // MARK: - WebP

    private static func encodeWebP(_ source: CGImageSource, input: URL, output: URL,
                                   options: ConversionOptions) throws {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = orientedImage(source, at: index) else { throw ConversionError.unreadable(input) }

        // cwebp reads PNG losslessly, so an intermediate PNG keeps full quality and transparency.
        let intermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangosteen-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        guard let destination = CGImageDestinationCreateWithURL(
            intermediate as CFURL, FileFormat.png.utType.identifier as CFString, 1, nil
        ) else {
            throw ConversionError.encodeFailed(.webp)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(.webp) }

        try ExternalTool.run("cwebp", [
            "-quiet", "-q", String(options.webpQuality), "-metadata", "icc",
            intermediate.path, "-o", output.path,
        ])
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
