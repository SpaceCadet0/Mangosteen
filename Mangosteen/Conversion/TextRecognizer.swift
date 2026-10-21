import Foundation
import PDFKit
import Vision

/// Recognizes text in photos and scanned PDFs with Vision and writes it as plain text.
enum TextRecognizer {
    enum Failure: LocalizedError {
        case noText(URL)

        var errorDescription: String? {
            switch self {
            case .noText(let url): String(localized: "В «\(url.lastPathComponent)» не найден текст.")
            }
        }
    }

    /// The text of one image, line by line in reading order.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // The user's languages first, then the app's own; only the ones Vision can read.
        let wanted = Locale.preferredLanguages + ["ru-RU", "en-US", "es-ES"]
        if let supported = try? request.supportedRecognitionLanguages() {
            var languages: [String] = []
            for language in wanted {
                let match = supported.first { $0 == language || $0.hasPrefix(String(language.prefix(2))) }
                if let match, !languages.contains(match) { languages.append(match) }
            }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Writes `<name> (текст).txt` next to the original. PDF pages are rendered at 300 dpi and separated by a
    /// page break.
    static func recognizeFile(_ input: URL) throws -> URL {
        let text: String
        if FileFormat.detect(input) == .pdf {
            guard let document = PDFDocument(url: input) else { throw PDFToolError.unreadable(input) }
            guard !document.isLocked else { throw PDFToolError.locked(input) }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                pages.append(try recognize(PDFConverter.render(page, dpi: 300)))
            }
            text = pages.joined(separator: "\n\u{0C}\n")
        } else {
            text = try recognize(ImageConverter.load(input).image)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0C}"))).isEmpty else {
            throw Failure.noText(input)
        }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (текст)"),
            pathExtension: "txt"
        ) { url in
            try (text + "\n").write(to: url, atomically: false, encoding: .utf8)
        }
    }
}
