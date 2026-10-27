import Foundation
import PDFKit

enum CompressionError: LocalizedError {
    case notSmaller(original: Int64, result: Int64)

    var errorDescription: String? {
        switch self {
        case .notSmaller(let original, let result):
            let formatter = ByteCountFormatter()
            return String(localized: "Сжатый файл (\(formatter.string(fromByteCount: result))) не меньше оригинала ")
                + String(localized: "(\(formatter.string(fromByteCount: original))). Выберите другой формат или меньший размер.")
        }
    }
}

struct CompressionSettings: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case preset, quality, targetSize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .preset: String(localized: "Пресет")
            case .quality: String(localized: "Качество")
            case .targetSize: String(localized: "Размер файла")
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case high, balanced, small
        var id: String { rawValue }
        var title: String {
            switch self {
            case .high: String(localized: "Высокое качество")
            case .balanced: String(localized: "Сбалансированно")
            case .small: String(localized: "Минимальный размер")
            }
        }
        var detail: String {
            switch self {
            case .high: String(localized: "Лучшее качество при умеренной экономии")
            case .balanced: String(localized: "Заметно меньше файл, почти без видимых потерь")
            case .small: String(localized: "Самые маленькие файлы, потери качества заметнее")
            }
        }
        var quality: Double {
            switch self {
            case .high: 0.85
            case .balanced: 0.7
            case .small: 0.45
            }
        }
        var maxPixelSize: Int? { self == .small ? 2560 : nil }
    }

    var mode: Mode = .preset
    var preset: Preset = .balanced
    var quality = 0.7
    /// Upper bound for each output file in target-size mode.
    var targetBytes: Int64 = 1_000_000
    /// Longer side limit; nil keeps the original dimensions.
    var maxPixelSize: Int?
    /// nil keeps the original format when it is lossy, otherwise picks `defaultLossyFormat`.
    var format: FileFormat?
    var preserveMetadata = true

    static let selectableFormats: [FileFormat] = [.jpg, .heic, .webp, .avif]
}

/// Image size reduction by quality, preset, or a target file size.
enum ImageCompression {
    /// Formats with transparency fall back to one that keeps it.
    static var defaultLossyFormat: FileFormat {
        ExternalTool.isAvailable("cwebp") ? .webp : .heic
    }

    static func outputFormat(for source: FileFormat, settings: CompressionSettings) -> FileFormat {
        if let format = settings.format { return format }
        return source.isLossy ? source : defaultLossyFormat
    }

    /// Compresses one image in memory.
    static func compress(_ input: URL, settings: CompressionSettings) throws -> (data: Data, format: FileFormat) {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let format = outputFormat(for: source, settings: settings)
        let maxPixelSize = settings.mode == .preset ? (settings.preset.maxPixelSize ?? settings.maxPixelSize) : settings.maxPixelSize
        let loaded = try ImageConverter.load(input, maxPixelSize: maxPixelSize)
        var image = loaded.image
        let keptMetadata = settings.preserveMetadata ? loaded.metadata : nil

        switch settings.mode {
        case .preset:
            return (try ImageConverter.encode(image, as: format, quality: settings.preset.quality, metadata: keptMetadata), format)
        case .quality:
            return (try ImageConverter.encode(image, as: format, quality: settings.quality, metadata: keptMetadata), format)
        case .targetSize:
            // Find the highest quality that fits; if even the lowest is too big, shrink the pixels and retry.
            for _ in 0..<6 {
                if let data = try bestFit(image, format: format, metadata: keptMetadata, limit: settings.targetBytes) {
                    return (data, format)
                }
                let smallest = try ImageConverter.encode(image, as: format, quality: 0.05, metadata: keptMetadata)
                let ratio = sqrt(Double(settings.targetBytes) / Double(max(smallest.count, 1))) * 0.9
                let width = max(1, Int(Double(image.width) * min(ratio, 0.9)))
                let height = max(1, Int(Double(image.height) * min(ratio, 0.9)))
                image = try resized(image, width: width, height: height)
            }
            return (try ImageConverter.encode(image, as: format, quality: 0.05, metadata: keptMetadata), format)
        }
    }

    private static func bestFit(_ image: CGImage, format: FileFormat, metadata: [CFString: Any]?,
                                limit: Int64) throws -> Data? {
        guard format.isLossy else {
            let data = try ImageConverter.encode(image, as: format, quality: nil, metadata: metadata)
            return data.count <= limit ? data : nil
        }
        var low = 0.05, high = 0.95
        var best: Data?
        for _ in 0..<7 {
            let quality = (low + high) / 2
            let data = try ImageConverter.encode(image, as: format, quality: quality, metadata: metadata)
            if data.count <= limit {
                best = data
                low = quality
            } else {
                high = quality
            }
        }
        if best == nil {
            let data = try ImageConverter.encode(image, as: format, quality: 0.05, metadata: metadata)
            if data.count <= limit { best = data }
        }
        return best
    }

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.png)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    /// Compresses and writes `<name> (сжатый).<ext>` next to the original.
    /// Throws `CompressionError.notSmaller` instead of writing a bigger file.
    static func compressFile(_ input: URL, settings: CompressionSettings) throws -> URL {
        let original = fileSize(input)
        if FileFormat.detect(input) == .pdf {
            return try compressPDF(input, settings: settings, originalSize: original)
        }
        let (data, format) = try compress(input, settings: settings)
        guard Int64(data.count) < original else {
            throw CompressionError.notSmaller(original: original, result: Int64(data.count))
        }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (сжатый)"),
            pathExtension: format.fileExtension
        ) { try data.write(to: $0) }
    }

    /// Scanned pages (no text layer) are drawn again as a single JPEG each: PDFKit's own image options leave
    /// uncompressed scans as they are. Pages with text keep their content; PDFKit re-encodes their images.
    /// In target-size mode the scans get smaller steps until the file fits.
    static func compressPDF(_ input: URL, settings: CompressionSettings, originalSize: Int64) throws -> URL {
        guard PDFDocument(url: input) != nil else { throw ConversionError.unreadable(input) }
        let steps: [ScanStep] = switch settings.mode {
        case .preset: [ScanStep(preset: settings.preset)]
        case .quality: [ScanStep(dpi: 150, quality: settings.quality)]
        case .targetSize: [ScanStep(dpi: 200, quality: 0.8), ScanStep(dpi: 150, quality: 0.7), ScanStep(dpi: 120, quality: 0.55),
                           ScanStep(dpi: 100, quality: 0.4), ScanStep(dpi: 72, quality: 0.3)]
        }
        var best: Data?
        for step in steps {
            // A fresh copy each time: pages are replaced in place.
            guard let document = PDFDocument(url: input) else { throw ConversionError.unreadable(input) }
            guard !document.isLocked else { throw PDFToolError.locked(input) }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), isScan(page),
                      let replacement = jpegPage(page, step: step, maxPixelSize: settings.maxPixelSize) else { continue }
                document.removePage(at: index)
                document.insert(replacement, at: index)
            }
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard let data = document.dataRepresentation(options: options) else { throw PDFToolError.writeFailed }
            if best.map({ data.count < $0.count }) ?? true { best = data }
            if settings.mode != .targetSize || Int64(data.count) <= settings.targetBytes { break }
        }
        guard let data = best, Int64(data.count) < originalSize else {
            throw CompressionError.notSmaller(original: originalSize, result: Int64(best?.count ?? 0))
        }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (сжатый)"),
            pathExtension: "pdf"
        ) { try data.write(to: $0) }
    }

    /// Resolution and JPEG quality for a scanned page.
    struct ScanStep {
        var dpi: CGFloat
        var quality: Double

        init(dpi: CGFloat, quality: Double) {
            self.dpi = dpi
            self.quality = quality
        }

        init(preset: CompressionSettings.Preset) {
            switch preset {
            case .high: self.init(dpi: 200, quality: 0.8)
            case .balanced: self.init(dpi: 150, quality: 0.7)
            case .small: self.init(dpi: 110, quality: 0.5)
            }
        }
    }

    /// A page with no text layer: a scan or a photo placed on a page.
    static func isScan(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The page drawn at `step.dpi` and stored as one JPEG on a page of the same size and rotation.
    /// Quartz keeps JPEG-backed images as JPEG in the PDF, so the page holds exactly these bytes.
    static func jpegPage(_ page: PDFPage, step: ScanStep, maxPixelSize: Int?) -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        var scale = step.dpi / 72
        if let maxPixelSize, maxPixelSize > 0 {
            scale = min(scale, CGFloat(maxPixelSize) / max(box.width, box.height))
        }
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        page.draw(with: .mediaBox, to: bitmap)
        guard let raster = bitmap.makeImage(),
              let jpeg = try? ImageConverter.encode(raster, as: .jpg, quality: step.quality, metadata: nil),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let pageData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pageData) else { return nil }
        var media = CGRect(origin: .zero, size: box.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        context.beginPage(mediaBox: &media)
        context.draw(image, in: media)
        context.endPage()
        context.closePDF()
        guard let replacement = PDFDocument(data: pageData as Data)?.page(at: 0) else { return nil }
        replacement.rotation = page.rotation
        return replacement
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
