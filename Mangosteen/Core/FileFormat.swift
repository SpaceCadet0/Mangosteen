import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String {
    case image
    case pdf
}

/// A file format Mangosteen can read and/or write.
enum FileFormat: String, CaseIterable, Identifiable {
    // Read + write
    case jpg, png, webp, heic, tiff, avif, bmp, gif, pdf
    // Read only
    case svg, ico, icns, psd, jp2, tga, exr

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .jpg: "JPG"
        case .webp: "WebP"
        case .jp2: "JPEG 2000"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        self == .pdf ? .pdf : .image
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
        case .pdf: .pdf
        case .svg: .svg
        case .ico: .ico
        case .icns: .icns
        case .psd: UTType("com.adobe.photoshop-image") ?? .image
        case .jp2: UTType("public.jpeg-2000") ?? .image
        case .tga: UTType("com.truevision.tga-image") ?? .image
        case .exr: UTType("com.ilm.openexr-image") ?? .image
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
        }
    }

    private static let extensionAliases: [String: FileFormat] = [
        "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg,
        "tif": .tiff,
        "heif": .heic, "hif": .heic,
        "j2k": .jp2, "jpf": .jp2, "jpx": .jp2,
        "dib": .bmp,
    ]

    /// Detects the format from the file extension, falling back to the system content type.
    static func detect(_ url: URL) -> FileFormat? {
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
