import Foundation
import ImageIO

/// Timeline-based media operations: trim, split, frame export, plus thumbnails and waveforms for the UI.
enum MediaTools {
    // MARK: - Timecodes

    /// `83.45` → `00:01:23.450`.
    static func timecode(_ seconds: Double) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }

    /// Accepts `SS`, `MM:SS`, `HH:MM:SS`, each with optional `.mmm` or `,mmm`.
    static func parseTimecode(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let value = Double(field), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: - Output

    /// Trimmed or split parts keep the source format (read-only containers map to a writable one).
    static func outputFormat(for source: FileFormat) -> FileFormat {
        switch source {
        case .m4v: .mp4
        case .aac: .m4a
        default: source
        }
    }

    /// Codec arguments for a cut. `fast` copies streams (cuts land on keyframes); otherwise re-encodes
    /// so the cut is frame-accurate. Lossless audio is always exact, so it is copied.
    static func cutArguments(format: FileFormat, info: MediaInfo, fast: Bool) -> [String] {
        let lossless: Set<FileFormat> = [.wav, .aiff, .flac]
        if fast || lossless.contains(format) {
            return ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        return MediaConverter.encodeArguments(for: format, info: info)
    }

    private static func cut(_ input: URL, info: MediaInfo, format: FileFormat, start: Double, end: Double,
                            fast: Bool, to output: URL, progress: ((Double) -> Void)?,
                            cancellation: CancellationToken?) throws {
        let length = max(end - start, 0.01)
        try MediaConverter.run(
            input: input, output: output,
            codecArguments: ["-t", String(format: "%.3f", length)] + cutArguments(format: format, info: info, fast: fast),
            duration: length,
            extraInputArguments: ["-ss", String(format: "%.3f", max(start, 0))],
            progress: progress, cancellation: cancellation
        )
    }

    /// Writes `<name> (обрезано).<ext>` with the part between `start` and `end` seconds.
    static func trim(_ input: URL, start: Double, end: Double, fast: Bool,
                     progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category.isMedia else { throw ConversionError.unrecognized(input) }
        let info = try MediaConverter.probe(input)
        let format = outputFormat(for: source)
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (обрезано)",
            pathExtension: format.fileExtension
        ) { output in
            try cut(input, info: info, format: format, start: start, end: end, fast: fast, to: output,
                    progress: progress, cancellation: cancellation)
        }
    }

    /// Cut points for `parts` equal pieces.
    static func equalSplitPoints(duration: Double, parts: Int) -> [Double] {
        guard parts > 1, duration > 0 else { return [] }
        return (1..<parts).map { duration * Double($0) / Double(parts) }
    }

    /// Splits at `points` (seconds) into `<name> 1.<ext>`, `<name> 2.<ext>`… inside `<name> (части)`.
    static func split(_ input: URL, at points: [Double], fast: Bool,
                      progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category.isMedia else { throw ConversionError.unrecognized(input) }
        let info = try MediaConverter.probe(input)
        guard let duration = info.duration else { throw ConversionError.unreadable(input) }
        let format = outputFormat(for: source)
        let cuts = Array(Set(points.filter { $0 > 0.05 && $0 < duration - 0.05 })).sorted()
        let bounds = [0] + cuts + [duration]
        let baseName = OutputNaming.baseName(of: input)
        let digits = String(bounds.count - 1).count
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(), baseName: "\(baseName) (части)", pathExtension: ""
        ) { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<(bounds.count - 1) {
                let number = String(format: "%0\(digits)d", index + 1)
                let output = folder.appendingPathComponent("\(baseName) \(number)").appendingPathExtension(format.fileExtension)
                let partCount = Double(bounds.count - 1)
                try cut(input, info: info, format: format, start: bounds[index], end: bounds[index + 1], fast: fast,
                        to: output, progress: { progress?((Double(index) + $0) / partCount) }, cancellation: cancellation)
            }
        }
    }

    // MARK: - Frames

    /// Full-resolution PNG of the frame at `time`.
    static func frameData(_ input: URL, at time: Double, maxHeight: Int? = nil) throws -> Data {
        var filters: [String] = []
        if let maxHeight { filters = ["-vf", "scale=-2:'min(\(maxHeight),ih)'"] }
        return try ExternalTool.runData("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-ss", String(format: "%.3f", max(time, 0)),
            "-i", input.path, "-frames:v", "1", "-an"] + filters + ["-f", "image2pipe", "-c:v", "png", "-",
        ])
    }

    static func frame(_ input: URL, at time: Double, maxHeight: Int? = nil) throws -> CGImage {
        let data = try frameData(input, at: time, maxHeight: maxHeight)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadable(input)
        }
        return image
    }

    /// One frame as `<name> кадр 00-01-23.450.png`; several go into `<name> (кадры)`.
    static func saveFrames(_ input: URL, at times: [Double]) throws -> URL {
        let sorted = times.sorted()
        guard !sorted.isEmpty else { throw PDFToolError.nothingToDo }
        let baseName = OutputNaming.baseName(of: input)
        func name(_ time: Double) -> String {
            "\(baseName) кадр \(timecode(time).replacingOccurrences(of: ":", with: "-"))"
        }
        if sorted.count == 1 {
            return try OutputNaming.writeAtomically(
                directory: input.deletingLastPathComponent(), baseName: name(sorted[0]), pathExtension: "png"
            ) { try frameData(input, at: sorted[0]).write(to: $0) }
        }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(), baseName: "\(baseName) (кадры)", pathExtension: ""
        ) { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for time in sorted {
                let url = OutputNaming.uniqueURL(in: folder, baseName: name(time), pathExtension: "png")
                try frameData(input, at: time).write(to: url)
            }
        }
    }

    /// Evenly spaced small frames for the timeline strip.
    static func thumbnails(_ input: URL, duration: Double, count: Int, height: Int) -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        return (0..<count).compactMap { index in
            try? frame(input, at: duration * (Double(index) + 0.5) / Double(count), maxHeight: height)
        }
    }

    // MARK: - Waveform

    /// Peak level (0…1) of `buckets` equal slices of the first audio track, mixed to mono.
    /// `filter` runs before the mono mixdown, e.g. `pan=mono|c0=c1` for the right channel only.
    static func waveform(_ input: URL, duration: Double, buckets: Int, filter: String? = nil) throws -> [Float] {
        let sampleRate = duration > 600 ? 500 : 4000
        let filterArguments = filter.map { ["-af", $0] } ?? []
        let data = try ExternalTool.runData("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", input.path,
            "-map", "0:a:0"] + filterArguments + ["-ac", "1", "-ar", String(sampleRate), "-f", "f32le", "-",
        ])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty, buckets > 0 else { return [] }
        let size = max(samples.count / buckets, 1)
        return stride(from: 0, to: samples.count, by: size).prefix(buckets).map { start in
            samples[start..<min(start + size, samples.count)].reduce(0) { max($0, abs($1)) }
        }.map { min($0, 1) }
    }
}
