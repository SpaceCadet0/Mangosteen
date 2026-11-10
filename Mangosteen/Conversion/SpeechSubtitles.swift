import AVFoundation
import Speech

enum SpeechSubtitlesError: LocalizedError {
    case notAllowed
    case unsupported(String)
    case nothingHeard(URL)

    var errorDescription: String? {
        switch self {
        case .notAllowed:
            String(localized: "Mangosteen не разрешено распознавать речь. Разрешите в «Системные настройки → Конфиденциальность и безопасность → Распознавание речи».")
        case .unsupported(let language):
            String(localized: "Распознавание речи на этом Mac не поддерживает язык «\(language)». Скачайте его в «Системные настройки → Клавиатура → Диктовка».")
        case .nothingHeard(let url):
            String(localized: "В «\(url.lastPathComponent)» не удалось распознать речь.")
        }
    }
}

/// Subtitles from what is said in a video or audio file, recognised on this Mac. On macOS 26 the newer
/// `SpeechTranscriber` handles the languages it knows (English, Spanish, German and others, not Russian); the rest,
/// Russian among them, go to `SFSpeechRecognizer` working on the device. Nothing is sent anywhere; the system may
/// download a language's recognition model once, as it does for dictation.
enum SpeechSubtitles {
    struct Word: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    enum Engine: Equatable {
        /// `SpeechTranscriber` (macOS 26).
        case transcriber
        /// `SFSpeechRecognizer` on the device.
        case recognizer
    }

    struct Language: Identifiable, Hashable {
        let locale: Locale
        let engine: Engine
        var id: String { locale.identifier }
        var title: String {
            Locale.current.localizedString(forIdentifier: locale.identifier)?.capitalized(with: Locale.current) ?? locale.identifier
        }
    }

    // MARK: Languages

    /// Languages this Mac can recognise without a server, sorted by name; the newer engine wins where both know one.
    static func languages() async -> [Language] {
        var result: [String: Language] = [:]
        for locale in SFSpeechRecognizer.supportedLocales() where SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true {
            result[key(locale)] = Language(locale: locale, engine: .recognizer)
        }
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                result[key(locale)] = Language(locale: locale, engine: .transcriber)
            }
        }
        return result.values.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    /// The language to start with: the first of the user's languages this Mac can recognise.
    static func preferred(in languages: [Language]) -> Language? {
        for identifier in Locale.preferredLanguages {
            let wanted = Locale(identifier: identifier)
            if let exact = languages.first(where: { key($0.locale) == key(wanted) }) { return exact }
            // "zh-Hans" means mainland Chinese (zh-Hans-CN), not Taiwan's zh-Hant-TW; "ru" means ru-Cyrl-RU.
            if let likely = languages.first(where: { $0.locale.language.maximalIdentifier == wanted.language.maximalIdentifier }) {
                return likely
            }
            if let sameScript = languages.first(where: {
                $0.locale.language.languageCode == wanted.language.languageCode && $0.locale.language.script == wanted.language.script
            }) {
                return sameScript
            }
            if let sameLanguage = languages.first(where: { $0.locale.language.languageCode == wanted.language.languageCode }) {
                return sameLanguage
            }
        }
        return languages.first
    }

    private static func key(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "-", with: "_")
    }

    // MARK: Making subtitles

    /// Writes "<name> (речь).srt" (or VTT, ASS, TXT) for `input`.
    static func makeSubtitles(_ input: URL, language: Language, as target: FileFormat,
                              progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("mangosteen-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 16 kHz mono is what both engines work at; it also takes the sound out of any video container.
        let audio = workspace.appendingPathComponent("speech.wav")
        let duration = try? MediaConverter.probe(input).duration
        try MediaConverter.runFFmpeg(["-i", input.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"],
                                     output: audio, duration: duration, progress: { progress?($0 * 0.1) },
                                     cancellation: cancellation)
        let words: [Word]
        switch language.engine {
        case .transcriber:
            guard #available(macOS 26.0, *) else { throw SpeechSubtitlesError.unsupported(language.title) }
            words = try wait { try await transcribe(audio, locale: language.locale, duration: duration ?? 0,
                                                    progress: { progress?(0.1 + $0 * 0.9) }) }
        case .recognizer:
            words = try recognize(audio, locale: language.locale, workspace: workspace,
                                  progress: { progress?(0.1 + $0 * 0.9) }, cancellation: cancellation)
        }
        try cancellation?.throwIfCancelled()
        let cues = cues(from: words)
        guard !cues.isEmpty else { throw SpeechSubtitlesError.nothingHeard(input) }
        let text: String = switch target {
        case .vtt: SubtitleConverter.vtt(cues)
        case .ass: SubtitleConverter.ass(cues)
        case .txt: cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        default: SubtitleConverter.srt(cues)
        }
        return try OutputNaming.writeAtomically(directory: input.deletingLastPathComponent(),
                                                baseName: String(localized: "\(OutputNaming.baseName(of: input)) (речь)"),
                                                pathExtension: target.fileExtension) { output in
            try (text + "\n").write(to: output, atomically: false, encoding: .utf8)
        }
    }

    /// Runs async work from a job's background thread.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    // MARK: SFSpeechRecognizer

    /// The older engine is fed 50-second pieces: a long file in one request can stop early, and pieces give progress.
    private static func recognize(_ audio: URL, locale: Locale, workspace: URL, progress: @escaping (Double) -> Void,
                                  cancellation: CancellationToken?) throws -> [Word] {
        try authorize()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw SpeechSubtitlesError.unsupported(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let pieceLength = 50.0
        let pieces = workspace.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", audio.path, "-f", "segment",
                                        "-segment_time", String(Int(pieceLength)), "-c", "copy",
                                        pieces.appendingPathComponent("%05d.wav").path])
        let files = try FileManager.default.contentsOfDirectory(at: pieces, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var words: [Word] = []
        var offset = 0.0
        for (number, file) in files.enumerated() {
            try cancellation?.throwIfCancelled()
            let length = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? pieceLength
            words += try recognizePiece(file, recognizer: recognizer).map {
                Word(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
            offset += length
            progress(Double(number + 1) / Double(files.count))
        }
        return words
    }

    private static func recognizePiece(_ file: URL, recognizer: SFSpeechRecognizer) throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let semaphore = DispatchSemaphore(value: 0)
        var words: [Word] = []
        var failure: Error?
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                words = result.bestTranscription.segments.map {
                    Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                }
                semaphore.signal()
            } else if let error {
                // "No speech detected" in a silent piece is not a failure of the whole file.
                if (error as NSError).code != 1110 { failure = error }
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 600) == .timedOut { task.cancel() }
        if let failure { throw failure }
        return words
    }

    private static func authorize() throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { status = $0; semaphore.signal() }
            semaphore.wait()
        }
        guard status == .authorized else { throw SpeechSubtitlesError.notAllowed }
    }

    // MARK: SpeechTranscriber

    @available(macOS 26.0, *)
    private static func transcribe(_ audio: URL, locale: Locale, duration: TimeInterval,
                                   progress: @escaping (Double) -> Void) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The system downloads the language's model once if it is not on this Mac yet.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
                if duration > 0 { progress(min(result.range.end.seconds / duration, 1)) }
            }
            return words
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audio), finishAfterFile: true)
        return try await collector.value
    }

    // MARK: Cues

    /// Groups words into subtitles the way people read them: at most two lines of about 42 characters and
    /// 6 seconds, a new subtitle after a sentence ends or a pause of 0.8 s, and each shown for at least a second
    /// when the next one leaves room.
    static func cues(from words: [Word], maxCharacters: Int = 84, maxDuration: TimeInterval = 6) -> [SubtitleConverter.Cue] {
        var cues: [SubtitleConverter.Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            cues.append(SubtitleConverter.Cue(start: first.start, end: last.end, text: twoLines(text, width: maxCharacters / 2)))
            current = []
        }
        for word in words {
            if let previous = current.last {
                let length = current.map(\.text.count).reduce(0, +) + current.count + word.text.count
                let endsSentence = previous.text.last.map { ".?!…".contains($0) } ?? false
                if length > maxCharacters || word.end - current[0].start > maxDuration
                    || word.start - previous.end > 0.8 || endsSentence {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : .infinity
            if cues[index].end - cues[index].start < 1 { cues[index].end = min(cues[index].start + 1, next) }
        }
        return cues
    }

    /// Breaks a subtitle into two lines of similar length at a space, when it is longer than one line.
    static func twoLines(_ text: String, width: Int) -> String {
        guard text.count > width else { return text }
        let spaces = text.indices.filter { text[$0] == " " }
        let middle = text.count / 2
        guard let split = spaces.min(by: {
            abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle)
        }) else { return text }
        return text[..<split] + "\n" + text[text.index(after: split)...]
    }
}
