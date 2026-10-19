import Foundation

/// Which output formats are offered for which inputs.
enum FormatCatalog {
    static let imageOutputs: [FileFormat] = [.png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf]
    static let documentOutputs: [FileFormat] = [.pdf, .docx, .odt, .rtf, .rtfd, .txt, .md, .html]
    static let pdfOutputs: [FileFormat] = [.png, .jpg, .txt, .md, .rtf, .docx, .html]
    static let subtitleOutputs: [FileFormat] = [.srt, .vtt, .txt]
    static let tableOutputs: [FileFormat] = [.csv, .tsv]
    static let archiveOutputs: [FileFormat] = [.zip, .tar, .tgz]

    /// Order of segments on the wheel.
    private static let displayOrder: [FileFormat] = [
        .png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf,
        .docx, .odt, .rtf, .rtfd, .txt, .md, .html,
        .srt, .vtt, .csv, .tsv, .zip, .tar, .tgz,
    ]

    static func targets(for source: FileFormat) -> [FileFormat] {
        let outputs: [FileFormat] = switch source.category {
        case .image: imageOutputs
        case .pdf: pdfOutputs
        case .document: documentOutputs
        case .subtitle: subtitleOutputs
        case .table: tableOutputs
        case .archive: archiveOutputs
        }
        return outputs.filter { $0 != source }
    }

    /// The detected format of an item (nil for plain folders) and what it can become.
    static func conversion(for url: URL) -> (source: FileFormat?, targets: [FileFormat]) {
        if let source = FileFormat.detect(url) {
            return (source, targets(for: source))
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return (nil, isDirectory ? archiveOutputs : [])
    }

    /// Formats offered for a selection. A format is offered when every convertible item can either be
    /// converted to it or already is it (those items are skipped), and at least one item needs converting.
    /// Items that cannot be converted at all are ignored.
    static func targets(for urls: [URL]) -> [FileFormat] {
        let items = urls.map(conversion(for:)).filter { !$0.targets.isEmpty }
        guard !items.isEmpty else { return [] }
        return displayOrder.filter { target in
            items.allSatisfy { $0.source == target || $0.targets.contains(target) }
                && items.contains { $0.source != target }
        }
    }
}
