import Foundation

/// SRT ↔ WebVTT, and either → plain text.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    static func convert(_ input: URL, to target: FileFormat, output: URL) throws {
        let cues = parse(try DocumentConverter.readText(input))
        guard !cues.isEmpty else { throw ConversionError.unreadable(input) }
        let result: String = switch target {
        case .srt: srt(cues)
        case .vtt: vtt(cues)
        case .txt: cues.map { stripTags($0.text) }.joined(separator: "\n")
        default: throw ConversionError.encodeFailed(target)
        }
        try (result + "\n").write(to: output, atomically: false, encoding: .utf8)
    }

    /// Parses both SRT and VTT: blocks separated by blank lines, each with a `start --> end` line.
    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm` and `MM:SS.mmm`.
    static func timestamp(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = value.components(separatedBy: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds: TimeInterval = 0
        for field in fields {
            guard let number = Double(field) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    static func format(_ time: TimeInterval, decimalSeparator: String) -> String {
        let milliseconds = Int((time * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1000 % 60
        return String(format: "%02d:%02d:%02d\(decimalSeparator)%03d", hours, minutes, seconds, milliseconds % 1000)
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(format(cue.start, decimalSeparator: ",")) --> \(format(cue.end, decimalSeparator: ","))\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(format(cue.start, decimalSeparator: ".")) --> \(format(cue.end, decimalSeparator: "."))\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>|\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }
}
