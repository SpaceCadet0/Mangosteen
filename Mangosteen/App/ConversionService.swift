import AppKit

/// Runs conversions and tools off the main thread and reports the outcome.
final class ConversionService {
    static let shared = ConversionService()

    private let queue = DispatchQueue(label: "dev.mangosteen.jobs", qos: .userInitiated, attributes: .concurrent)

    func convert(_ urls: [URL], to target: FileFormat) {
        // Several photos to PDF make one document with a page per photo; other files still convert one by one.
        if target == .pdf {
            let photos = urls.filter(PDFTools.isPageImage)
            if photos.count > 1 {
                runBatch(String(localized: "Создание PDF"), inputs: photos) { [try PDFTools.createPDF(fromImages: $0)] }
                let others = urls.filter { !photos.contains($0) }
                if !others.isEmpty { convertEach(others, to: target) }
                return
            }
        }
        convertEach(urls, to: target)
    }

    private func convertEach(_ urls: [URL], to target: FileFormat) {
        let options = AppSettings.shared.conversionOptions
        // ffmpeg already uses every core; two at a time keeps the Mac responsive.
        let hasMedia = urls.contains { FileFormat.detect($0)?.category.isMedia == true }
        runEach(String(localized: "Конвертация в \(target.displayName)"), inputs: urls, maxConcurrent: hasMedia ? 2 : nil) { url, progress, cancellation in
            try Converter.convert(url, to: target, options: options, progress: progress, cancellation: cancellation)
        }
    }

    /// Runs `work` for every input in parallel. `work` returns the produced file, or nil when skipped.
    func runEach(_ title: String, inputs: [URL], work: @escaping (URL) throws -> URL?) {
        runEach(title, inputs: inputs, maxConcurrent: nil) { url, _, _ in try work(url) }
    }

    /// Like `runEach(_:inputs:work:)`, but `work` also gets a per-file progress callback (0…1) and a
    /// cancellation token wired to the progress panel's Stop button.
    func runEach(_ title: String, inputs: [URL], maxConcurrent: Int?,
                 work: @escaping (URL, @escaping (Double) -> Void, CancellationToken) throws -> URL?) {
        let cancellation = CancellationToken()
        let job = ProgressHUD.shared.begin(title, total: inputs.count, cancel: { cancellation.cancel() })
        queue.async {
            let lock = NSLock()
            var outputs: [URL] = []
            var failures: [(URL, Error)] = []
            let slots = DispatchSemaphore(value: max(1, maxConcurrent ?? inputs.count))
            DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                slots.wait()
                defer { slots.signal() }
                let input = inputs[index]
                if !cancellation.isCancelled {
                    let report: (Double) -> Void = { fraction in
                        DispatchQueue.main.async { ProgressHUD.shared.update(job, item: index, fraction: fraction) }
                    }
                    do {
                        let output = try work(input, report, cancellation)
                        lock.withLock { if let output { outputs.append(output) } }
                    } catch is CancellationError {
                        // Stopped by the user; nothing to report.
                    } catch {
                        lock.withLock { failures.append((input, error)) }
                    }
                }
                DispatchQueue.main.async { ProgressHUD.shared.step(job, item: index) }
            }
            DispatchQueue.main.async {
                ProgressHUD.shared.end(job)
                Feedback.finished(title, outputs: outputs, failures: failures)
            }
        }
    }

    /// Runs one job that consumes all inputs at once (merge, collage…).
    func runBatch(_ title: String, inputs: [URL], work: @escaping ([URL]) throws -> [URL]) {
        let job = ProgressHUD.shared.begin(title, total: 1)
        queue.async {
            let result = Result { try work(inputs) }
            DispatchQueue.main.async {
                ProgressHUD.shared.end(job)
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
    /// A short, muted click like pressing a trackpad: a soft low thump with a faint tick on top.
    private static let hoverSound = synthesize(duration: 0.022, volume: 0.45) { t in
        let thump = sin(2 * .pi * 180 * t) * exp(-t * 320)
        let tick = sin(2 * .pi * 2_600 * t) * exp(-t * 2_200) * 0.35
        return (thump + tick) * 0.5
    }

    /// A soft, low two-note chime (C5 then G5) with gentle attack and quick decay — calmer than "Glass".
    private static let doneSound = synthesize(duration: 0.5, volume: 0.5) { t in
        func note(_ frequency: Double, at start: Double, decay: Double) -> Double {
            let local = t - start
            guard local >= 0 else { return 0 }
            let attack = min(1, local / 0.006)
            return attack * exp(-local * decay)
                * (sin(2 * .pi * frequency * local) + 0.18 * sin(4 * .pi * frequency * local))
        }
        let fadeOut = min(1, (0.5 - t) / 0.03)
        return (note(523.25, at: 0, decay: 13) + note(783.99, at: 0.085, decay: 11)) * 0.32 * fadeOut
    }

    /// Renders `sample(t)` (−1…1) as 16-bit mono 44.1 kHz WAV and wraps it in a sound.
    private static func synthesize(duration: Double, volume: Float, sample: (Double) -> Double) -> NSSound? {
        let rate = 44_100.0
        let count = Int(rate * duration)
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let payload = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(payload.littleEndian)
        for index in 0..<count {
            let value = max(-1, min(1, sample(Double(index) / rate)))
            append(Int16(value * Double(Int16.max)).littleEndian)
        }
        let sound = NSSound(data: data)
        sound?.volume = volume
        return sound
    }

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
        OperationHistory.shared.record(title, outputs: outputs)
        if !outputs.isEmpty {
            if settings.playSounds, let sound = doneSound {
                sound.stop()
                sound.play()
            }
            if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
        guard !failures.isEmpty else { return }

        let lines = failures.prefix(6).map { url, error in
            "• \(url.lastPathComponent): \(error.localizedDescription)"
        }
        let more = failures.count > 6 ? String(localized: "\n…и ещё \(failures.count - 6)") : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "\(title): не удалось обработать \(WheelView.filesLabel(failures.count))")
        alert.informativeText = lines.joined(separator: "\n") + more
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func showError(_ title: String, _ error: Error) {
        finished(title, outputs: [], failures: [(URL(fileURLWithPath: "/"), error)])
    }
}
