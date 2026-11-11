import Foundation
import PDFKit

/// Tags of video, audio and PDF files: title, artist and the like. Media tags are written by ffmpeg copying the
/// streams as they are, so nothing is re-encoded; PDF properties by PDFKit. Results are new files,
/// "<name> (метаданные).<ext>"; the original stays as it was.
enum FileTags {
    enum Field: String, CaseIterable, Identifiable {
        case title, artist, album, date, genre, comment
        // PDF document properties.
        case subject, keywords

        var id: String { rawValue }

        var title: String {
            switch self {
            case .title: String(localized: "Название")
            case .artist: String(localized: "Автор")
            case .album: String(localized: "Альбом")
            case .date: String(localized: "Год")
            case .genre: String(localized: "Жанр")
            case .comment: String(localized: "Комментарий")
            case .subject: String(localized: "Тема")
            case .keywords: String(localized: "Ключевые слова")
            }
        }

        /// The PDF document attribute.
        var pdfAttribute: PDFDocumentAttribute? {
            switch self {
            case .title: .titleAttribute
            case .artist: .authorAttribute
            case .subject: .subjectAttribute
            case .keywords: .keywordsAttribute
            default: nil
            }
        }
    }

    /// The fields that make sense for a format.
    static func fields(for format: FileFormat) -> [Field] {
        switch format.category {
        case .audio: [.title, .artist, .album, .date, .genre, .comment]
        case .video: [.title, .artist, .date, .comment]
        case .pdf: [.title, .artist, .subject, .keywords]
        default: []
        }
    }

    static func supports(_ format: FileFormat) -> Bool { !fields(for: format).isEmpty }

    // MARK: Reading

    static func read(_ url: URL) throws -> [Field: String] {
        guard let format = FileFormat.detect(url) else { throw ConversionError.unrecognized(url) }
        if format == .pdf {
            guard let document = PDFDocument(url: url) else { throw PDFToolError.unreadable(url) }
            let attributes = document.documentAttributes ?? [:]
            var result: [Field: String] = [:]
            for field in fields(for: .pdf) {
                guard let key = field.pdfAttribute, let value = attributes[key] else { continue }
                let text = (value as? [String])?.joined(separator: ", ") ?? "\(value)"
                if !text.isEmpty { result[field] = text }
            }
            return result
        }
        let output = try ExternalTool.run("ffprobe", ["-v", "error", "-show_entries", "format_tags", "-of", "json", url.path])
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let tags = (json?["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]
        // Containers spell keys differently (TITLE in Ogg and FLAC, ©nam mapped to title in MP4).
        let lowered = Dictionary(tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var result: [Field: String] = [:]
        for field in fields(for: format) {
            let keys = field == .date ? ["date", "year", "creation_time"] : field == .comment ? ["comment", "description"] : [field.rawValue]
            if let value = keys.lazy.compactMap({ lowered[$0] }).first(where: { !$0.isEmpty }) {
                result[field] = field == .date && value.count > 10 ? String(value.prefix(10)) : value
            }
        }
        return result
    }

    // MARK: Writing

    /// Writes a copy with `changes` applied: a value sets the field, an empty string clears it; fields not listed
    /// stay as they were. `removeAll` drops every tag first.
    static func write(_ input: URL, changes: [Field: String], removeAll: Bool,
                      progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let format = FileFormat.detect(input), supports(format) else { throw ConversionError.unrecognized(input) }
        let baseName = String(localized: "\(OutputNaming.baseName(of: input)) (метаданные)")
        if format == .pdf {
            guard let document = PDFDocument(url: input) else { throw PDFToolError.unreadable(input) }
            guard !document.isLocked else { throw PDFToolError.locked(input) }
            var attributes = removeAll ? [:] : (document.documentAttributes ?? [:])
            for (field, value) in changes {
                guard let key = field.pdfAttribute else { continue }
                if value.isEmpty {
                    attributes[key] = nil
                } else if field == .keywords {
                    attributes[key] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    attributes[key] = value
                }
            }
            document.documentAttributes = attributes
            return try OutputNaming.writeAtomically(directory: input.deletingLastPathComponent(), baseName: baseName,
                                                    pathExtension: "pdf") { output in
                guard document.write(to: output) else { throw PDFToolError.writeFailed }
            }
        }
        var arguments = ["-map", "0", "-c", "copy", "-map_metadata", removeAll ? "-1" : "0"]
        // MP4 and MOV store tags in a way ffmpeg only writes with this flag.
        if [.mp4, .mov, .m4a, .m4v].contains(format) { arguments += ["-movflags", "use_metadata_tags"] }
        for (field, value) in changes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            arguments += ["-metadata", "\(field.rawValue)=\(value)"]
        }
        let duration = try? MediaConverter.probe(input).duration
        return try OutputNaming.writeAtomically(directory: input.deletingLastPathComponent(), baseName: baseName,
                                                pathExtension: input.pathExtension.lowercased()) { output in
            // Not MediaConverter.run: it appends "-map_metadata 0", which would undo "remove all".
            try MediaConverter.runFFmpeg(["-i", input.path] + arguments, output: output, duration: duration,
                                         progress: progress, cancellation: cancellation)
        }
    }
}
