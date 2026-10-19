import AppKit
import ImageIO

/// Image → image conversion via ImageIO, with WebP encoding delegated to `cwebp`.
enum ImageConverter {
    static func convert(_ input: URL, to target: FileFormat, output: URL, options: ConversionOptions) throws {
        if FileFormat.detect(input) == .svg {
            try convertSVG(input, to: target, output: output, options: options)
            return
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(input)
        }
        let count = CGImageSourceGetCount(source)
        if target == .webp {
            if count > 1, FileFormat.detect(input) == .gif, ExternalTool.isAvailable("gif2webp") {
                try ExternalTool.run("gif2webp", ["-quiet", "-mixed", "-q", String(options.webpQuality),
                                                  input.path, "-o", output.path])
            } else {
                try encodeWebP(source, input: input, output: output, options: options)
            }
            return
        }

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

    /// Encodes a single already-decoded image (used for rendered PDF pages and SVG).
    /// `metadata` are source properties to carry over; orientation is reset because pixels are upright.
    static func write(_ image: CGImage, as target: FileFormat, to output: URL, options: ConversionOptions,
                      metadata: [CFString: Any]? = nil) throws {
        try encode(image, as: target, quality: options.quality(for: target), metadata: metadata).write(to: output)
    }

    /// Encodes in memory. `quality` is 0…1 and only used by lossy formats.
    static func encode(_ image: CGImage, as target: FileFormat, quality: Double?,
                       metadata: [CFString: Any]? = nil) throws -> Data {
        if target == .webp {
            return try encodeWebP(image, quality: quality ?? 0.8)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, target.utType.identifier as CFString, 1, nil
        ) else {
            throw ConversionError.encodeFailed(target)
        }
        let pixels = !target.supportsAlpha && image.hasAlpha ? try flattened(image) : image
        var properties = metadata ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        // The new pixel size comes from the image itself.
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if let quality, target.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(target) }
        return data as Data
    }

    private static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("mangosteen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let png = workspace.appendingPathComponent("in.png")
        let webp = workspace.appendingPathComponent("out.webp")
        try encode(image, as: .png, quality: nil).write(to: png)
        try ExternalTool.run("cwebp", ["-quiet", "-q", String(Int((quality * 100).rounded())), png.path, "-o", webp.path])
        return try Data(contentsOf: webp)
    }

    /// Decodes the primary image upright, optionally downscaled so its longer side is at most `maxPixelSize`.
    /// Returns the image together with the source metadata.
    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> (image: CGImage, metadata: [CFString: Any]) {
        if FileFormat.detect(url) == .svg {
            guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
                throw ConversionError.unreadable(url)
            }
            let longest = CGFloat(maxPixelSize ?? Int(svgMinimumPixelSize))
            let scale = longest / max(svg.size.width, svg.size.height)
            let width = Int((svg.size.width * scale).rounded()), height = Int((svg.size.height * scale).rounded())
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ConversionError.unreadable(url)
            }
            drawImage(svg, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw ConversionError.unreadable(url) }
            return (image, [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = metadata[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = metadata[kCGImagePropertyPixelHeight] as? Int ?? 0
        let image: CGImage?
        if let maxPixelSize, maxPixelSize < max(width, height) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        } else {
            image = orientedImage(source, at: index)
        }
        guard let image else { throw ConversionError.unreadable(url) }
        return (image, metadata)
    }

    // MARK: - SVG

    /// SVG has no pixel size of its own; it is rasterised so the longer side is at least this many pixels.
    static let svgMinimumPixelSize: CGFloat = 2048

    private static func convertSVG(_ input: URL, to target: FileFormat, output: URL,
                                   options: ConversionOptions) throws {
        guard let image = NSImage(contentsOf: input), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.unreadable(input)
        }
        if target == .pdf {
            // Keep vectors: draw straight into a PDF page.
            var mediaBox = CGRect(origin: .zero, size: image.size)
            guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
                throw ConversionError.encodeFailed(.pdf)
            }
            context.beginPDFPage(nil)
            drawImage(image, in: context, rect: mediaBox)
            context.endPDFPage()
            context.closePDF()
            return
        }

        let scale = max(1, svgMinimumPixelSize / max(image.size.width, image.size.height))
        let width = Int((image.size.width * scale).rounded())
        let height = Int((image.size.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(target)
        }
        drawImage(image, in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raster = context.makeImage() else { throw ConversionError.encodeFailed(target) }

        if target == .webp {
            let intermediate = FileManager.default.temporaryDirectory
                .appendingPathComponent("mangosteen-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            try write(raster, as: .png, to: intermediate, options: options)
            try convert(intermediate, to: .webp, output: output, options: options)
        } else {
            try write(raster, as: target, to: output, options: options)
        }
    }

    private static func drawImage(_ image: NSImage, in context: CGContext, rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
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
