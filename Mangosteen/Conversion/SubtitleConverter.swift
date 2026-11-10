import Foundation

/// SRT, WebVTT and ASS/SSA into each other, and any of them → plain text.
enum SubtitleConverter {
    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        /// SRT-style text: lines separated by "\n", italics and bold as <i> and <b>.
        var text: String
    }

    static func convert(_ input: URL, to target: FileFormat, output: URL) throws {
        let text = try DocumentConverter.readText(input)
        let cues = FileFormat.detect(input) == .ass ? parseASS(text) : parse(text)
        guard !cues.isEmpty else { throw ConversionError.unreadable(input) }
        let result: String = switch target {
        case .srt: srt(cues)
        case .vtt: vtt(cues)
        case .ass: ass(cues)
        case .txt: cues.map { stripTags($0.text) }.joined(separator: "\n")
        default: throw ConversionError.encodeFailed(target)
        }
        try (result + "\n").write(to: output, atomically: false, encoding: .utf8)
    }

    // MARK: ASS / SSA

    /// The `Dialogue:` lines of the `[Events]` section. Their fields are named by the section's `Format:` line; the
    /// text is the last field and may itself contain commas. Override blocks are dropped except italics and bold.
    static func parseASS(_ text: String) -> [Cue] {
        var inEvents = false
        var fields: [String] = []
        var cues: [Cue] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
            if kind == "format" {
                fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard kind == "dialogue", !fields.isEmpty else { continue }
            let values = value.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == fields.count,
                  let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text"),
                  let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]) else { continue }
            let body = assToSRTText(values[textIndex])
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `{\i1}Hi{\i0}\Nthere` → `<i>Hi</i>\nthere`; other override blocks are dropped.
    static func assToSRTText(_ text: String) -> String {
        let result = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        let tags: [(String, String)] = [("\\i1", "<i>"), ("\\i0", "</i>"), ("\\b1", "<b>"), ("\\b0", "</b>")]
        var output = ""
        var index = result.startIndex
        while index < result.endIndex {
            if result[index] == "{", let close = result[index...].firstIndex(of: "}") {
                let block = String(result[result.index(after: index)..<close])
                for (tag, html) in tags where block.contains(tag) { output += html }
                index = result.index(after: close)
            } else {
                output.append(result[index])
                index = result.index(after: index)
            }
        }
        return output
    }

    /// One "Default" style and a `Dialogue:` line per cue.
    static func ass(_ cues: [Cue]) -> String {
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288
        WrapStyle: 0

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        let lines = cues.map { cue in
            var text = cue.text.replacingOccurrences(of: "<i>", with: "{\\i1}").replacingOccurrences(of: "</i>", with: "{\\i0}")
                .replacingOccurrences(of: "<b>", with: "{\\b1}").replacingOccurrences(of: "</b>", with: "{\\b0}")
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: "\\N")
            return "Dialogue: 0,\(assTime(cue.start)),\(assTime(cue.end)),Default,,0,0,0,,\(text)"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    /// `H:MM:SS.cc`, as ASS writes it.
    static func assTime(_ time: TimeInterval) -> String {
        let centiseconds = Int((max(time, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", centiseconds / 360_000, centiseconds / 6000 % 60,
                      centiseconds / 100 % 60, centiseconds % 100)
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
