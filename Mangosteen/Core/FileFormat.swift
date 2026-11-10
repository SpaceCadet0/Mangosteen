import Foundation
import ImageIO
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
    // Images (read only). `raw` stands for every camera RAW extension; RAW and JPEG XL are decoded by macOS.
    case svg, ico, icns, psd, jp2, tga, exr, raw, jxl
    case pdf
    // Documents
    case docx, doc, odt, rtf, rtfd, txt, md, html
    // Subtitles
    case srt, vtt, ass
    // Tables (JSON as an array of objects)
    case csv, tsv, xlsx, json
    // Archives (7z, rar, iso, tar.xz, tar.bz2 and a single gzipped file are read only)
    case zip, tar, tgz
    case sevenZip = "7z"
    case rar, iso, txz, tbz, gz
    // Video (m4v and the second line are read only)
    case mp4, mov, mkv, webm, avi, wmv, m4v
    case flv, mpg, ts, m2ts, vob, ogv
    case threeGP = "3gp"
    // Audio (aac and the second line are read only)
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma, aac
    case ape, wv, amr, ac3, dts

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .tgz: "tar.gz"
        case .txz: "tar.xz"
        case .tbz: "tar.bz2"
        default: rawValue
        }
    }

    var displayName: String {
        switch self {
        case .jpg: "JPG"
        case .webp: "WebP"
        case .jp2: "JPEG 2000"
        case .jxl: "JPEG XL"
        case .md: "Markdown"
        case .tgz: "TAR.GZ"
        case .txz: "TAR.XZ"
        case .tbz: "TAR.BZ2"
        case .webm: "WebM"
        case .opus: "Opus"
        case .mpg: "MPEG"
        case .wv: "WavPack"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        switch self {
        case .pdf: .pdf
        case .docx, .doc, .odt, .rtf, .rtfd, .txt, .md, .html: .document
        case .srt, .vtt, .ass: .subtitle
        case .csv, .tsv, .xlsx, .json: .table
        case .zip, .tar, .tgz, .sevenZip, .rar, .iso, .txz, .tbz, .gz: .archive
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .flv, .mpg, .ts, .m2ts, .vob, .ogv, .threeGP: .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma, .aac, .ape, .wv, .amr, .ac3, .dts: .audio
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
        case .raw: .rawImage
        case .jxl: UTType("public.jpeg-xl") ?? Self.byExtension("jxl")
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
        case .ass: Self.byExtension("ass")
        case .json: .json
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .xlsx: UTType("org.openxmlformats.spreadsheetml.sheet") ?? Self.byExtension("xlsx")
        case .zip: .zip
        case .tar: UTType("public.tar-archive") ?? .archive
        case .tgz: .gzip
        case .gz: Self.byExtension("gz")
        case .txz: Self.byExtension("txz")
        case .tbz: Self.byExtension("tbz2")
        case .sevenZip, .rar, .iso: Self.byExtension(rawValue)
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
        case .flv, .mpg, .ts, .m2ts, .vob, .ogv, .threeGP, .ape, .wv, .amr, .ac3, .dts: Self.byExtension(rawValue)
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
        "webvtt": .vtt, "ssa": .ass,
        "tab": .tsv,
        "qt": .mov, "mpeg4": .mp4,
        "mpeg": .mpg, "mpe": .mpg, "m1v": .mpg, "m2v": .mpg, "mts": .m2ts, "3g2": .threeGP,
        "aif": .aiff, "aifc": .aiff, "oga": .ogg, "wave": .wav, "awb": .amr,
    ]

    /// Camera RAW extensions; each is offered only when this macOS can decode it.
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl", "pef", "srw",
        "3fr", "fff", "iiq", "erf", "mos", "mrw", "dcr", "kdc",
    ]

    /// Picture types this Mac's ImageIO can read; RAW and JPEG XL support depends on the macOS version.
    private static let readableImageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    private static func systemCanRead(extension ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return readableImageTypes.contains(type.identifier)
    }

    /// `.ts` and `.mts` are also TypeScript source files; only a real MPEG transport stream counts as video.
    /// TS packets are 188 bytes starting with 0x47; M2TS (AVCHD) adds a 4-byte time code before each.
    private static func isTransportStream(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 200), head.count >= 197 else { return false }
        let bytes = [UInt8](head)
        return (bytes[0] == 0x47 && bytes[188] == 0x47) || (bytes[4] == 0x47 && bytes[196] == 0x47)
    }

    /// Detects the format from the file name, falling back to the system content type.
    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tgz }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .txz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tbz }
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return systemCanRead(extension: ext) ? .raw : nil }
        if ext == "jxl" { return systemCanRead(extension: ext) ? .jxl : nil }
        if ext == "ts" || ext == "mts" || ext == "m2ts" {
            // Never fall back to the content type: macOS calls every .ts file a transport stream.
            return isTransportStream(url) ? (ext == "ts" ? .ts : .m2ts) : nil
        }
        if let format = FileFormat(rawValue: ext) ?? extensionAliases[ext], format != .raw {
            return format
        }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }
        let format = allCases.first { type.conforms(to: $0.utType) }
        // A RAW or JPEG XL type found this way is offered only when this macOS can decode it, like one found by name.
        if format == .raw || format == .jxl, !readableImageTypes.contains(type.identifier) { return nil }
        return format
    }

    /// Whether ImageIO can write this picture type, which rewriting metadata in place needs (not RAW, JPEG XL, SVG).
    var canRewriteImageMetadata: Bool {
        category == .image && Self.writableImageTypes.contains(utType.identifier)
    }

    private static let writableImageTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
}
