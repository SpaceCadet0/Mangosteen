import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String {
    case image
    case pdf
    case document
    case subtitle
    case table
    case archive
    case video
    case audio

    var isMedia: Bool { self == .video || self == .audio }
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
    case csv, tsv, xlsx
    // Archives
    case zip, tar, tgz
    // Video (m4v is read only)
    case mp4, mov, mkv, webm, avi, wmv, m4v
    // Audio (aac is read only)
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma, aac

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
        case .webm: "WebM"
        case .opus: "Opus"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        switch self {
        case .pdf: .pdf
        case .docx, .doc, .odt, .rtf, .rtfd, .txt, .md, .html: .document
        case .srt, .vtt: .subtitle
        case .csv, .tsv, .xlsx: .table
        case .zip, .tar, .tgz: .archive
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v: .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma, .aac: .audio
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
        case .xlsx: UTType("org.openxmlformats.spreadsheetml.sheet") ?? Self.byExtension("xlsx")
        case .zip: .zip
        case .tar: UTType("public.tar-archive") ?? .archive
        case .tgz: .gzip
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .avi: .avi
        case .m4v: UTType("com.apple.m4v-video") ?? Self.byExtension("m4v")
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        case .aac: UTType("public.aac-audio") ?? Self.byExtension("aac")
        case .mkv, .webm, .wmv, .flac, .ogg, .opus, .wma: Self.byExtension(rawValue)
        }
    }

    /// A type that only matches this extension (a dynamic type when the system does not know it),
    /// so the content-type fallback in `detect` never matches unrelated files.
    private static func byExtension(_ ext: String) -> UTType {
        UTType(filenameExtension: ext) ?? UTType(exportedAs: "dev.mangosteen.\(ext)")
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
        case .video: "film"
        case .audio: "waveform"
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
        "qt": .mov, "mpeg4": .mp4,
        "aif": .aiff, "aifc": .aiff, "oga": .ogg, "wave": .wav,
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
