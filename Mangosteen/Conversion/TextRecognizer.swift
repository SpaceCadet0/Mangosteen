import Foundation
import PDFKit
import Vision

/// Recognizes text in photos and scanned PDFs with Vision and writes it as plain text.
enum TextRecognizer {
    enum Failure: LocalizedError {
        case noText(URL)
        case timedOut(URL?)

        var errorDescription: String? {
            switch self {
            case .noText(let url): String(localized: "В «\(url.lastPathComponent)» не найден текст.")
            case .timedOut(let url):
                url.map { String(localized: "Не удалось распознать текст в «\($0.lastPathComponent)» за минуту, распознавание остановлено.") }
                    ?? String(localized: "Не удалось распознать текст за минуту, распознавание остановлено.")
            }
        }
    }

    /// How long one picture or PDF page may take. The first run after a while also loads Vision's models,
    /// which alone can take 10–15 seconds.
    static let timeLimit: TimeInterval = 60

    /// Holds the outcome of the request running on another thread.
    private final class Outcome {
        var result: Result<Void, Error>?
    }

    /// The text of one image, line by line in reading order. Gives up with `Failure.timedOut` after `timeLimit`
    /// and with `CancellationError` when `cancellation` fires.
    static func recognize(_ image: CGImage, timeLimit: TimeInterval = timeLimit, progress: ((Double) -> Void)? = nil,
                          cancellation: CancellationToken? = nil) throws -> String {
        try cancellation?.throwIfCancelled()
        let request = VNRecognizeTextRequest()
        request.progressHandler = { _, fraction, _ in progress?(fraction) }
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
        // Vision runs on its own thread so this one can stop waiting at the deadline or on Stop, even while
        // Vision is still loading its models; the abandoned request is cancelled and finishes on its own.
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.result = Result { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            done.signal()
        }
        let deadline = DispatchTime.now() + timeLimit
        while true {
            let slice = min(DispatchTime.now() + 0.2, deadline)
            if done.wait(timeout: slice) == .success { break }
            if cancellation?.isCancelled == true {
                request.cancel()
                throw CancellationError()
            }
            if DispatchTime.now() >= deadline {
                request.cancel()
                throw Failure.timedOut(nil)
            }
        }
        try outcome.result?.get()
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Writes `<name> (текст).txt` next to the original. PDF pages are rendered at 300 dpi and separated by a
    /// page break.
    static func recognizeFile(_ input: URL, progress: ((Double) -> Void)? = nil,
                              cancellation: CancellationToken? = nil) throws -> URL {
        let text: String
        do {
            if FileFormat.detect(input) == .pdf {
                guard let document = PDFDocument(url: input) else { throw PDFToolError.unreadable(input) }
                guard !document.isLocked else { throw PDFToolError.locked(input) }
                var pages: [String] = []
                let count = max(document.pageCount, 1)
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let pageProgress: (Double) -> Void = { progress?((Double(index) + $0) / Double(count)) }
                    pages.append(try recognize(PDFConverter.render(page, dpi: 300), progress: pageProgress,
                                               cancellation: cancellation))
                }
                text = pages.joined(separator: "\n\u{0C}\n")
            } else {
                text = try recognize(ImageConverter.load(input).image, progress: progress, cancellation: cancellation)
            }
        } catch Failure.timedOut {
            throw Failure.timedOut(input)
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
