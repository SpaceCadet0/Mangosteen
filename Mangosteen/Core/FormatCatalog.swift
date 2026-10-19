import Foundation

/// Which output formats are offered for which inputs.
enum FormatCatalog {
    static let imageOutputs: [FileFormat] = [.png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf]

    static func targets(for source: FileFormat) -> [FileFormat] {
        switch source.category {
        case .image: imageOutputs.filter { $0 != source }
        case .pdf: []
        }
    }

    /// Formats offered for a selection. A format is offered when every recognised file can either be
    /// converted to it or already is it (those files are skipped), and at least one file needs converting.
    /// Unrecognised files are ignored.
    static func targets(for urls: [URL]) -> [FileFormat] {
        let sources = urls.compactMap(FileFormat.detect)
        guard let first = sources.first else { return [] }
        let candidates = targets(for: first) + [first]
        let ordered = imageOutputs.filter(candidates.contains)
        return ordered.filter { target in
            sources.allSatisfy { $0 == target || targets(for: $0).contains(target) }
                && sources.contains { $0 != target }
        }
    }
}
