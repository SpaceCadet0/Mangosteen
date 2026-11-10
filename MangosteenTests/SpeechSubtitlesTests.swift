import Speech
import XCTest

/// Subtitles from speech: how words become readable subtitles, and the recognition itself on speech made by `say`.
final class SpeechSubtitlesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func words(_ text: String, from start: Double = 0, step: Double = 0.4) -> [SpeechSubtitles.Word] {
        text.split(separator: " ").enumerated().map { index, word in
            SpeechSubtitles.Word(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + 0.3)
        }
    }

    func testSentencesPausesAndLengthStartNewSubtitles() {
        let cues = SpeechSubtitles.cues(from: words("Привет всем. Сегодня мы") + words("после паузы", from: 5))
        XCTAssertEqual(cues.map(\.text), ["Привет всем.", "Сегодня мы", "после паузы"])
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 0.8, accuracy: 0.001, "a short subtitle is stretched only up to the next one")
        XCTAssertEqual(cues[2].end, 6.0, accuracy: 0.001, "the last one stays at least a second")

        let long = words(Array(repeating: "слово", count: 30).joined(separator: " "), step: 0.15)
        let longCues = SpeechSubtitles.cues(from: long)
        XCTAssertGreaterThan(longCues.count, 1)
        for cue in longCues {
            XCTAssertLessThanOrEqual(cue.text.split(separator: "\n").count, 2)
            XCTAssertTrue(cue.text.split(separator: "\n").allSatisfy { $0.count <= 48 }, cue.text)
        }
    }

    func testALongSubtitleIsSplitIntoTwoEvenLines() {
        XCTAssertEqual(SpeechSubtitles.twoLines("короткая строка", width: 42), "короткая строка")
        let text = "это довольно длинная фраза, которой нужно две строки на экране"
        let lines = SpeechSubtitles.twoLines(text, width: 42).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThan(abs(lines[0].count - lines[1].count), 12)
    }

    private func speech(_ text: String, voice: String, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try ExternalTool.run("/usr/bin/say", ["-v", voice, "-o", url.path, text])
        return url
    }

    /// The newer engine (macOS 26) on English speech; skipped where it or the English model is missing.
    func testEnglishSpeechBecomesSubtitles() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber needs macOS 26") }
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        guard installed.contains("en_US") else { throw XCTSkip("The English speech model is not installed") }
        let audio = try speech("The quick brown fox jumps over the lazy dog. Mangosteen makes subtitles from speech.",
                               voice: "Samantha", name: "english.aiff")
        let language = SpeechSubtitles.Language(locale: Locale(identifier: "en_US"), engine: .transcriber)
        let output = try await Task.detached { try SpeechSubtitles.makeSubtitles(audio, language: language, as: .srt) }.value
        let text = try String(contentsOf: output, encoding: .utf8).lowercased()
        XCTAssertTrue(text.contains("fox"), text)
        XCTAssertTrue(text.contains("subtitles"), text)
        XCTAssertTrue(text.hasPrefix("1\n00:00:0"), text)
        XCTAssertEqual(output.lastPathComponent, "english (речь).srt")
    }

    /// The older engine on Russian speech; it needs the speech recognition permission, so it runs only where the
    /// test runner already has it.
    func testRussianSpeechBecomesSubtitles() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw XCTSkip("No speech recognition permission") }
        let audio = try speech("Мангостин делает субтитры из речи. Это проверка распознавания.", voice: "Milena", name: "russian.aiff")
        let language = SpeechSubtitles.Language(locale: Locale(identifier: "ru_RU"), engine: .recognizer)
        let output = try SpeechSubtitles.makeSubtitles(audio, language: language, as: .vtt)
        let text = try String(contentsOf: output, encoding: .utf8).lowercased()
        XCTAssertTrue(text.hasPrefix("webvtt"), text)
        XCTAssertTrue(text.contains("субтитры"), text)
    }
}
