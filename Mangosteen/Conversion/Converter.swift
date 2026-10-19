import Foundation

struct ConversionOptions {
    /// 0…1 for ImageIO lossy encoders.
    var jpegQuality = 0.85
    var heicQuality = 0.8
    var avifQuality = 0.7
    /// 0…100 for cwebp.
    var webpQuality = 80
    var preserveMetadata = true

    func quality(for format: FileFormat) -> Double? {
        switch format {
        case .jpg: jpegQuality
        case .heic: heicQuality
        case .avif: avifQuality
        case .webp: Double(webpQuality) / 100
        default: nil
        }
    }
}

enum ConversionError: LocalizedError {
    case unrecognized(URL)
    case unsupported(from: FileFormat, to: FileFormat)
    case unreadable(URL)
    case encodeFailed(FileFormat)

    var errorDescription: String? {
        switch self {
        case .unrecognized(let url): "Неизвестный формат файла «\(url.lastPathComponent)»."
        case .unsupported(let from, let to): "Конвертация \(from.displayName) → \(to.displayName) не поддерживается."
        case .unreadable(let url): "Не удалось прочитать «\(url.lastPathComponent)»."
        case .encodeFailed(let format): "Не удалось сохранить файл в формате \(format.displayName)."
        }
    }
}

/// Entry point for format conversion: picks the converter and writes the result next to the input.
enum Converter {
    /// Converts `input` to `target`. Returns `nil` when the file already has the target format.
    static func convert(_ input: URL, to target: FileFormat, options: ConversionOptions) throws -> URL? {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        if source == target { return nil }
        guard FormatCatalog.targets(for: source).contains(target) else {
            throw ConversionError.unsupported(from: source, to: target)
        }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: OutputNaming.baseName(of: input),
            pathExtension: target.fileExtension
        ) { output in
            switch source.category {
            case .image:
                try ImageConverter.convert(input, to: target, output: output, options: options)
            case .pdf:
                throw ConversionError.unsupported(from: source, to: target)
            }
        }
    }
}
