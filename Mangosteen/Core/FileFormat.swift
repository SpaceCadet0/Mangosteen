import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String {
    case image
    case pdf
    case document
    case subtitle
    case table
    case archive
}

/// A file format Mangosteen can read and/or write.
enum FileFormat: String, CaseIterable, Identifiable {
    // Images (read + write)
    case jpg, png, webp, heic, tiff, avif, bmp, gif
    // Images (read only)
    case svg, ico, icns, psd, jp2, tga, exr
    case pdf
    // Documents
    case docx, doc, odt, rtf, rtfd, txt, md, html
    // Subtitles
    case srt, vtt
    // Tables
    case csv, tsv
    // Archives
    case zip, tar, tgz

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .tgz: "tar.gz"
        default: rawValue
        }
    }

    var displayName: String {
        switch self {
        case .jpg: "JPG"
        case .webp: "WebP"
        case .jp2: "JPEG 2000"
        case .md: "Markdown"
        case .tgz: "TAR.GZ"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        switch self {
        case .pdf: .pdf
        case .docx, .doc, .odt, .rtf, .rtfd, .txt, .md, .html: .document
        case .srt, .vtt: .subtitle
        case .csv, .tsv: .table
        case .zip, .tar, .tgz: .archive
        default: .image
        }
    }

    var utType: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .webp: .webP
        case .heic: .heic
        case .tiff: .tiff
        case .avif: UTType("public.avif") ?? .image
        case .bmp: .bmp
        case .gif: .gif
        case .svg: .svg
        case .ico: .ico
        case .icns: .icns
        case .psd: UTType("com.adobe.photoshop-image") ?? .image
        case .jp2: UTType("public.jpeg-2000") ?? .image
        case .tga: UTType("com.truevision.tga-image") ?? .image
        case .exr: UTType("com.ilm.openexr-image") ?? .image
        case .pdf: .pdf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .doc: UTType("com.microsoft.word.doc") ?? .data
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .txt: .plainText
        case .md: UTType("net.daringfireball.markdown") ?? .plainText
        case .html: .html
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .zip: .zip
        case .tar: UTType("public.tar-archive") ?? .archive
        case .tgz: .gzip
        }
    }

    /// Whether the encoded file can carry transparency. Opaque formats get a white background.
    var supportsAlpha: Bool {
        switch self {
        case .jpg, .bmp: false
        default: true
        }
    }

    /// Whether ImageIO's encoder accepts a lossy-quality hint for this format.
    var isLossy: Bool {
        switch self {
        case .jpg, .heic, .avif, .webp: true
        default: false
        }
    }

    var symbolName: String {
        switch category {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: self == .html ? "chevron.left.forwardslash.chevron.right" : "doc.text"
        case .subtitle: "captions.bubble"
        case .table: "tablecells"
        case .archive: "archivebox"
        }
    }

    private static let extensionAliases: [String: FileFormat] = [
        "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg,
        "tif": .tiff,
        "heif": .heic, "hif": .heic,
        "j2k": .jp2, "jpf": .jp2, "jpx": .jp2,
        "dib": .bmp,
        "markdown": .md, "mdown": .md, "text": .txt,
        "htm": .html, "xhtml": .html,
        "webvtt": .vtt,
        "tab": .tsv,
        "gz": .tgz,
    ]

    /// Detects the format from the file name, falling back to the system content type.
    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tgz }
        let ext = url.pathExtension.lowercased()
        if let format = FileFormat(rawValue: ext) ?? extensionAliases[ext] {
            return format
        }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }
        return allCases.first { type.conforms(to: $0.utType) }
    }
}
