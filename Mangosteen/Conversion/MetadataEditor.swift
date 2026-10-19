import Foundation
import ImageIO

/// Common editable image metadata fields.
enum MetadataField: String, CaseIterable, Identifiable {
    case description, author, copyright, make, model

    var id: String { rawValue }

    var title: String {
        switch self {
        case .description: String(localized: "Описание")
        case .author: String(localized: "Автор")
        case .copyright: String(localized: "Авторские права")
        case .make: String(localized: "Производитель камеры")
        case .model: String(localized: "Модель камеры")
        }
    }

    var dictionary: CFString { kCGImagePropertyTIFFDictionary }

    var key: CFString {
        switch self {
        case .description: kCGImagePropertyTIFFImageDescription
        case .author: kCGImagePropertyTIFFArtist
        case .copyright: kCGImagePropertyTIFFCopyright
        case .make: kCGImagePropertyTIFFMake
        case .model: kCGImagePropertyTIFFModel
        }
    }
}

/// What to change. Only fields present here are touched; an empty string removes a field.
struct MetadataChanges: Equatable {
    var removeAll = false
    var removeLocation = false
    var text: [MetadataField: String] = [:]
    var dateTaken: Date?
    var latitude: Double?
    var longitude: Double?

    var isEmpty: Bool {
        !removeAll && !removeLocation && text.isEmpty && dateTaken == nil && latitude == nil
    }
}

/// Reads and rewrites image metadata without re-encoding pixels (ImageIO lossless copy).
enum MetadataEditor {
    struct Entry: Identifiable, Hashable {
        let group: String
        let key: String
        let value: String
        var id: String { group + "." + key }
    }

    static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any] ?? [:]
    }

    /// All properties flattened for display, grouped by dictionary.
    static func entries(of properties: [CFString: Any]) -> [Entry] {
        var entries: [Entry] = []
        for (key, value) in properties {
            if let nested = value as? [CFString: Any] {
                let group = (key as String).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                for (nestedKey, nestedValue) in nested {
                    entries.append(Entry(group: group, key: nestedKey as String, value: describe(nestedValue)))
                }
            } else {
                entries.append(Entry(group: String(localized: "Основное"), key: key as String, value: describe(value)))
            }
        }
        return entries.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let array as [Any]: array.map(describe).joined(separator: ", ")
        case let dictionary as [AnyHashable: Any]: String(localized: "\(dictionary.count) полей")
        case let data as Data: String(localized: "\(data.count) байт")
        default: "\(value)"
        }
    }

    static func text(_ field: MetadataField, in properties: [CFString: Any]) -> String {
        (properties[field.dictionary] as? [CFString: Any])?[field.key].map { "\($0)" } ?? ""
    }

    static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func dateTaken(in properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        return raw.flatMap(exifDateFormatter.date(from:))
    }

    static func location(in properties: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
        return (south ? -latitude : latitude, west ? -longitude : longitude)
    }

    // MARK: - Writing

    /// Writes `<name> (метаданные).<ext>` next to the original.
    static func apply(_ changes: MetadataChanges, to input: URL) throws -> URL {
        guard let format = FileFormat.detect(input),
              let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            throw ConversionError.unreadable(input)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let original = CGImageSourceCopyMetadataAtIndex(source, index, nil)
        let metadata = changes.removeAll
            ? CGImageMetadataCreateMutable()
            : (original.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable())

        if changes.removeAll {
            // Keep the picture upright.
            let orientation = properties(of: input)[kCGImagePropertyOrientation] as? Int ?? 1
            if orientation != 1 {
                set(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
        } else {
            for (field, value) in changes.text {
                if value.isEmpty {
                    remove(metadata, field.dictionary, field.key)
                } else {
                    set(metadata, field.dictionary, field.key, value as CFString)
                }
            }
            if let date = changes.dateTaken {
                let raw = exifDateFormatter.string(from: date) as CFString
                set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, raw)
                set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, raw)
                set(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, raw)
            }
            if changes.removeLocation {
                removeLocation(from: metadata)
            } else if let latitude = changes.latitude, let longitude = changes.longitude {
                let gps = kCGImagePropertyGPSDictionary
                set(metadata, gps, kCGImagePropertyGPSLatitude, abs(latitude) as CFNumber)
                set(metadata, gps, kCGImagePropertyGPSLatitudeRef, (latitude < 0 ? "S" : "N") as CFString)
                set(metadata, gps, kCGImagePropertyGPSLongitude, abs(longitude) as CFNumber)
                set(metadata, gps, kCGImagePropertyGPSLongitudeRef, (longitude < 0 ? "W" : "E") as CFString)
            }
        }

        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (метаданные)"),
            pathExtension: format.fileExtension
        ) { output in
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
                throw ConversionError.encodeFailed(format)
            }
            var options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
            ]
            if changes.removeAll || changes.removeLocation {
                options[kCGImageMetadataShouldExcludeGPS] = true
            }
            if changes.removeAll {
                options[kCGImageMetadataShouldExcludeXMP] = true
            }
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                throw error?.takeRetainedValue() ?? ConversionError.encodeFailed(format)
            }
        }
    }

    private static func set(_ metadata: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString, _ value: CFTypeRef) {
        CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value)
    }

    private static func remove(_ metadata: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString) {
        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dictionary, key),
              let prefix = CGImageMetadataTagCopyPrefix(tag),
              let name = CGImageMetadataTagCopyName(tag) else {
            return
        }
        CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
    }

    private static func removeLocation(from metadata: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            let path = path as String
            if path.hasPrefix("exif:GPS") || path.hasPrefix("exifEX:GPS") { paths.append(path) }
            return true
        }
        for path in paths {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }
}
