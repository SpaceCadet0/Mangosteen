import Foundation

struct ConversionOptions {
    /// 0…1 for ImageIO lossy encoders.
    var jpegQuality = 0.85
    var heicQuality = 0.8
    var avifQuality = 0.7
    /// 0…100 for cwebp.
    var webpQuality = 80
    var preserveMetadata = true
    /// Resolution used when rendering PDF pages to images.
    var pdfRenderDPI: CGFloat = 300

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
    case unsupported(from: String, to: FileFormat)
    case unreadable(URL)
    case encodeFailed(FileFormat)

    var errorDescription: String? {
        switch self {
        case .unrecognized(let url): String(localized: "Неизвестный формат файла «\(url.lastPathComponent)».")
        case .unsupported(let from, let to): String(localized: "Конвертация \(from) → \(to.displayName) не поддерживается.")
        case .unreadable(let url): String(localized: "Не удалось прочитать «\(url.lastPathComponent)».")
        case .encodeFailed(let format): String(localized: "Не удалось сохранить файл в формате \(format.displayName).")
        }
    }
}

/// Entry point for format conversion: picks the converter and writes the result next to the input.
enum Converter {
    /// Converts `input` to `target`. Returns `nil` when the file already has the target format.
    static func convert(_ input: URL, to target: FileFormat, options: ConversionOptions,
                        progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL? {
        let (source, targets) = FormatCatalog.conversion(for: input)
        if source == target { return nil }
        guard targets.contains(target) else {
            if let source {
                throw ConversionError.unsupported(from: source.displayName, to: target)
            }
            throw ConversionError.unrecognized(input)
        }
        let directory = input.deletingLastPathComponent()
        let baseName = OutputNaming.baseName(of: input)

        // Several PDF pages become a folder of images.
        if source == .pdf, target.category == .image, try PDFConverter.pageCount(input) > 1 {
            return try OutputNaming.writeAtomically(
                directory: directory, baseName: "\(baseName) (\(target.displayName))", pathExtension: ""
            ) { folder in
                try PDFConverter.renderPages(input, as: target, into: folder, baseName: baseName, options: options)
            }
        }

        // A workbook with several sheets becomes a folder with one table per sheet; a single sheet is written
        // straight from the rows already read, so the workbook is parsed only once.
        if source == .xlsx {
            let sheets = try XLSX.read(input).filter { !$0.rows.isEmpty }
            if sheets.count > 1 {
                return try OutputNaming.writeAtomically(
                    directory: directory, baseName: "\(baseName) (\(target.displayName))", pathExtension: ""
                ) { folder in
                    try TableConverter.writeSheets(sheets, as: target, into: folder)
                }
            }
            return try OutputNaming.writeAtomically(
                directory: directory, baseName: baseName, pathExtension: target.fileExtension
            ) { output in
                try TableConverter.write(sheets.first?.rows ?? [], as: target, sheetName: sheets.first?.name ?? baseName, to: output)
            }
        }

        return try OutputNaming.writeAtomically(
            directory: directory, baseName: baseName, pathExtension: target.fileExtension
        ) { output in
            guard let source else {
                try ArchiveConverter.pack(input, as: target, to: output)
                return
            }
            switch source.category {
            case .image:
                try ImageConverter.convert(input, to: target, output: output, options: options)
            case .pdf:
                try PDFConverter.convert(input, to: target, output: output, options: options)
            case .document:
                try DocumentConverter.convert(input, from: source, to: target, output: output)
            case .subtitle:
                try SubtitleConverter.convert(input, to: target, output: output)
            case .table:
                try TableConverter.convert(input, from: source, to: target, output: output)
            case .archive:
                try ArchiveConverter.repack(input, from: source, as: target, to: output)
            case .video, .audio:
                try MediaConverter.convert(input, to: target, output: output, progress: progress, cancellation: cancellation)
            }
        }
    }
}
