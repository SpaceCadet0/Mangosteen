import Foundation

/// Which output formats are offered for which inputs.
enum FormatCatalog {
    static let imageOutputs: [FileFormat] = [.png, .jpg, .webp, .heic, .tiff, .avif, .gif, .pdf]
    /// Formats an edited image is saved back in; BMP is not offered on the wheel but is still kept.
    static let editableImageFormats: [FileFormat] = imageOutputs.filter { $0 != .pdf } + [.bmp]
    static let documentOutputs: [FileFormat] = [.pdf, .docx, .odt, .rtf, .rtfd, .txt, .md, .html]
    static let pdfOutputs: [FileFormat] = [.png, .jpg, .txt, .md, .rtf, .docx, .html]
    static let subtitleOutputs: [FileFormat] = [.srt, .vtt, .txt]
    static let tableOutputs: [FileFormat] = [.csv, .tsv, .xlsx]
    static let archiveOutputs: [FileFormat] = [.zip, .tar, .tgz]
    static let videoOutputs: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
    static let audioOutputs: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]

    /// Order of segments on the wheel when the selection mixes kinds of files.
    private static let displayOrder: [FileFormat] = [
        .png, .jpg, .webp, .heic, .tiff, .avif, .gif, .pdf,
        .docx, .odt, .rtf, .rtfd, .txt, .md, .html,
        .srt, .vtt, .csv, .tsv, .xlsx,
        .mp4, .mov, .mkv, .webm, .avi, .wmv,
        .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma,
        .zip, .tar, .tgz,
    ]

    static func outputs(for category: FormatCategory) -> [FileFormat] {
        switch category {
        case .image: imageOutputs
        case .pdf: pdfOutputs
        case .document: documentOutputs
        case .subtitle: subtitleOutputs
        case .table: tableOutputs
        case .archive: archiveOutputs
        case .video: videoOutputs
        case .audio: audioOutputs
        }
    }

    static func targets(for source: FileFormat) -> [FileFormat] {
        outputs(for: source.category).filter { $0 != source }
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
        // A single kind of file keeps that kind's own order (video: MP4 first, GIF near the end).
        let categories = Set(items.map { $0.source?.category ?? .archive })
        let order = categories.count == 1 ? outputs(for: categories.first!) : displayOrder
        return order.filter { target in
            items.allSatisfy { $0.source == target || $0.targets.contains(target) }
                && items.contains { $0.source != target }
        }
    }
}
