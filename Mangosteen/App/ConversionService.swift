import AppKit

/// Runs conversions and tools off the main thread and reports the outcome.
final class ConversionService {
    static let shared = ConversionService()

    private let queue = DispatchQueue(label: "dev.mangosteen.jobs", qos: .userInitiated, attributes: .concurrent)

    func convert(_ urls: [URL], to target: FileFormat) {
        let options = AppSettings.shared.conversionOptions
        runEach("Конвертация в \(target.displayName)", inputs: urls) { url in
            try Converter.convert(url, to: target, options: options)
        }
    }

    /// Runs `work` for every input in parallel. `work` returns the produced file, or nil when skipped.
    func runEach(_ title: String, inputs: [URL], work: @escaping (URL) throws -> URL?) {
        queue.async {
            let lock = NSLock()
            var outputs: [URL] = []
            var failures: [(URL, Error)] = []
            DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                let input = inputs[index]
                do {
                    let output = try work(input)
                    lock.withLock { if let output { outputs.append(output) } }
                } catch {
                    lock.withLock { failures.append((input, error)) }
                }
            }
            DispatchQueue.main.async {
                Feedback.finished(title, outputs: outputs, failures: failures)
            }
        }
    }

    /// Runs one job that consumes all inputs at once (merge, collage…).
    func runBatch(_ title: String, inputs: [URL], work: @escaping ([URL]) throws -> [URL]) {
        queue.async {
            let result = Result { try work(inputs) }
            DispatchQueue.main.async {
                switch result {
                case .success(let outputs):
                    Feedback.finished(title, outputs: outputs, failures: [])
                case .failure(let error):
                    Feedback.finished(title, outputs: [], failures: [(inputs.first ?? URL(fileURLWithPath: "/"), error)])
                }
            }
        }
    }
}

/// Sounds, haptics, Finder reveal and error reporting.
enum Feedback {
    private static let hoverSound: NSSound? = {
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.25
        return sound
    }()
    private static let doneSound = NSSound(named: "Glass")

    static func hover() {
        let settings = AppSettings.shared
        if settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if settings.playSounds, let sound = hoverSound {
            sound.stop()
            sound.play()
        }
    }

    static func finished(_ title: String, outputs: [URL], failures: [(URL, Error)]) {
        let settings = AppSettings.shared
        if !outputs.isEmpty {
            if settings.playSounds { doneSound?.play() }
            if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
        guard !failures.isEmpty else { return }

        let lines = failures.prefix(6).map { url, error in
            "• \(url.lastPathComponent): \(error.localizedDescription)"
        }
        let more = failures.count > 6 ? "\n…и ещё \(failures.count - 6)" : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(title): не удалось обработать \(WheelView.filesLabel(failures.count))"
        alert.informativeText = lines.joined(separator: "\n") + more
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func showError(_ title: String, _ error: Error) {
        finished(title, outputs: [], failures: [(URL(fileURLWithPath: "/"), error)])
    }
}
