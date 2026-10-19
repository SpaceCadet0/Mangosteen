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
            return try compressPDF(input, originalSize: original)
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

    /// Re-encodes embedded images as JPEG at screen resolution.
    static func compressPDF(_ input: URL, originalSize: Int64) throws -> URL {
        guard let document = PDFDocument(url: input) else { throw ConversionError.unreadable(input) }
        let output = try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (сжатый)"),
            pathExtension: "pdf"
        ) { url in
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard document.write(to: url, withOptions: options) else { throw PDFToolError.writeFailed }
        }
        let result = fileSize(output)
        if result >= originalSize {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.notSmaller(original: originalSize, result: result)
        }
        return output
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
