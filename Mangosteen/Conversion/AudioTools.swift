import Foundation
import ImageIO

/// Loudness normalisation, channel mixing, bleeping and audio visualisation through ffmpeg.
/// For videos only the audio track changes; the picture is copied as is.
enum AudioTools {
    // MARK: - Shared

    /// Audio codec for the sound track inside a video container.
    static func audioCodecArguments(forVideo format: FileFormat) -> [String] {
        switch format {
        case .webm: ["-c:a", "libopus", "-b:a", "160k"]
        case .avi: ["-c:a", "libmp3lame", "-q:a", "2"]
        case .wmv: ["-c:a", "wmav2", "-b:a", "192k"]
        default: ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    /// Re-encodes the audio of `input` through a filter. Either `filter` (a simple `-af` chain) or `graph`
    /// (a filter_complex whose output label is `[a]`) must be given.
    static func processAudio(_ input: URL, suffix: String, filter: String? = nil, graph: String? = nil,
                             progress: ((Double) -> Void)?, cancellation: CancellationToken?) throws -> URL {
        guard let source = FileFormat.detect(input), source.category.isMedia else { throw ConversionError.unrecognized(input) }
        let info = try MediaConverter.probe(input)
        guard info.hasAudio else { throw MediaError.noAudio(input) }
        let format = MediaTools.outputFormat(for: source)
        let isVideo = source.category == .video && info.hasVideo

        var arguments = ["-i", input.path]
        if let graph {
            arguments += ["-filter_complex", graph, "-map", "[a]"]
        } else {
            arguments += ["-map", "0:a:0"]
            if let filter { arguments += ["-af", filter] }
        }
        if isVideo {
            arguments += ["-map", "0:v:0", "-c:v", "copy"] + audioCodecArguments(forVideo: format)
        } else {
            // The audio encoders' own arguments; drop "-vn" and maps that assume a single input.
            arguments += MediaConverter.encodeArguments(for: format, info: info).filter { $0 != "-vn" }
        }
        arguments += ["-map_metadata", "0"]
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (\(suffix))",
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.runFFmpeg(arguments, output: output, duration: info.duration,
                                         progress: progress, cancellation: cancellation)
        }
    }

    /// Renders the processed sound only, for listening before saving.
    static func renderPreview(_ input: URL, filter: String? = nil, graph: String? = nil, to output: URL,
                              cancellation: CancellationToken? = nil) throws {
        var arguments = ["-i", input.path]
        if let graph {
            arguments += ["-filter_complex", graph, "-map", "[a]"]
        } else {
            arguments += ["-map", "0:a:0"]
            if let filter { arguments += ["-af", filter] }
        }
        arguments += ["-vn", "-c:a", "aac", "-b:a", "160k"]
        try MediaConverter.runFFmpeg(arguments, output: output, duration: nil, progress: nil, cancellation: cancellation)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Loudness

    struct LoudnessTarget: Equatable {
        /// Integrated loudness, LUFS.
        var integrated = -14.0
        /// Maximum true peak, dBTP.
        var truePeak = -1.0
        /// Loudness range, LU.
        var range = 11.0
    }

    struct LoudnessMeasurement: Equatable {
        var integrated: Double
        var truePeak: Double
        var range: Double
        var threshold: Double
        var offset: Double
    }

    private static func loudnormFilter(_ target: LoudnessTarget) -> String {
        "loudnorm=I=\(number(target.integrated)):TP=\(number(target.truePeak)):LRA=\(number(target.range))"
    }

    /// First loudnorm pass: measures the file against `target`.
    static func measureLoudness(_ input: URL, target: LoudnessTarget = LoudnessTarget()) throws -> LoudnessMeasurement {
        let output = try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-i", input.path, "-map", "0:a:0", "-vn",
            "-af", loudnormFilter(target) + ":print_format=json", "-f", "null", "-",
        ])
        guard let start = output.range(of: "{", options: .backwards),
              let end = output.range(of: "}", options: .backwards), start.lowerBound < end.upperBound,
              let json = try JSONSerialization.jsonObject(with: Data(output[start.lowerBound..<end.upperBound].utf8)) as? [String: String] else {
            throw ConversionError.unreadable(input)
        }
        func value(_ key: String) -> Double {
            json[key].flatMap(Double.init).map { $0.isFinite ? $0 : -70 } ?? -70
        }
        return LoudnessMeasurement(integrated: value("input_i"), truePeak: value("input_tp"), range: value("input_lra"),
                                   threshold: value("input_thresh"), offset: value("target_offset"))
    }

    /// Two-pass EBU R128 normalisation. Writes `<name> (громкость).<ext>`.
    static func normalize(_ input: URL, target: LoudnessTarget,
                          progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        let measured = try measureLoudness(input, target: target)
        try cancellation?.throwIfCancelled()
        let sampleRate = try MediaConverter.probe(input).sampleRate ?? 48000
        let filter = loudnormFilter(target)
            + ":measured_I=\(number(measured.integrated)):measured_TP=\(number(measured.truePeak))"
            + ":measured_LRA=\(number(measured.range)):measured_thresh=\(number(measured.threshold))"
            + ":offset=\(number(measured.offset)):linear=true"
            // loudnorm works at 192 kHz internally; return to the source rate.
            + ",aresample=\(sampleRate)"
        return try processAudio(input, suffix: String(localized: "громкость"), filter: filter, progress: progress, cancellation: cancellation)
    }

    // MARK: - Channels

    struct ChannelSettings: Equatable {
        enum Layout: String, CaseIterable, Identifiable {
            case stereo, mono
            var id: String { rawValue }
            var title: String { self == .stereo ? String(localized: "Стерео") : String(localized: "Моно") }
        }

        var layout = Layout.stereo
        /// 0…2 (100% = 1).
        var left = 1.0
        var right = 1.0
        var swap = false
    }

    /// A `pan` filter for the settings. Mono sources feed both sides from their single channel.
    static func channelFilter(_ settings: ChannelSettings, sourceChannels: Int) -> String {
        let leftSource = sourceChannels < 2 ? "c0" : (settings.swap ? "c1" : "c0")
        let rightSource = sourceChannels < 2 ? "c0" : (settings.swap ? "c0" : "c1")
        let left = number(settings.left)
        let right = number(settings.right)
        switch settings.layout {
        case .stereo:
            return "pan=stereo|c0=\(left)*\(leftSource)|c1=\(right)*\(rightSource)"
        case .mono:
            return "pan=mono|c0=\(number(settings.left / 2))*\(leftSource)+\(number(settings.right / 2))*\(rightSource)"
        }
    }

    /// Writes `<name> (каналы).<ext>`.
    static func convertChannels(_ input: URL, settings: ChannelSettings,
                                progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        let channels = try MediaConverter.probe(input).audioChannels ?? 2
        return try processAudio(input, suffix: String(localized: "каналы"), filter: channelFilter(settings, sourceChannels: channels),
                                progress: progress, cancellation: cancellation)
    }

    // MARK: - Bleep

    static func bleepGraph(ranges: [ClosedRange<Double>], frequency: Double, volume: Double, duration: Double) -> String {
        let condition = ranges.map { "between(t,\(String(format: "%.3f", $0.lowerBound)),\(String(format: "%.3f", $0.upperBound)))" }
            .joined(separator: "+")
        let length = String(format: "%.3f", max(duration, 0.1))
        return "[0:a:0]aformat=sample_fmts=fltp:sample_rates=48000,volume=0:enable='\(condition)'[muted];"
            + "sine=frequency=\(Int(frequency)):sample_rate=48000:duration=\(length),aformat=sample_fmts=fltp:channel_layouts=mono,"
            + "volume=\(number(volume)),volume=0:enable='not(\(condition))'[tone];"
            + "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
    }

    /// Replaces each range with a tone. Writes `<name> (запикано).<ext>`.
    static func bleep(_ input: URL, ranges: [ClosedRange<Double>], frequency: Double = 1000, volume: Double = 0.3,
                      progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard !ranges.isEmpty else { throw PDFToolError.nothingToDo }
        let duration = try MediaConverter.probe(input).duration ?? 0
        return try processAudio(input, suffix: String(localized: "запикано"),
                                graph: bleepGraph(ranges: ranges, frequency: frequency, volume: volume, duration: duration),
                                progress: progress, cancellation: cancellation)
    }

    // MARK: - Visualizer

    struct VisualizerSettings: Equatable {
        enum Style: String, CaseIterable, Identifiable {
            case waveform, spectrum, still
            var id: String { rawValue }
            var title: String {
                switch self {
                case .waveform: String(localized: "Волна")
                case .spectrum: String(localized: "Спектр")
                case .still: String(localized: "Картинка")
                }
            }
        }

        enum Orientation: String, CaseIterable, Identifiable {
            case landscape, portrait, square
            var id: String { rawValue }
            var title: String {
                switch self {
                case .landscape: String(localized: "Альбомная 16:9")
                case .portrait: String(localized: "Вертикальная 9:16")
                case .square: String(localized: "Квадрат")
                }
            }
            var size: (width: Int, height: Int) {
                switch self {
                case .landscape: (1920, 1080)
                case .portrait: (1080, 1920)
                case .square: (1080, 1080)
                }
            }
        }

        var style = Style.waveform
        var orientation = Orientation.landscape
        var waveColor = RGBAColor(red: 1, green: 0.62, blue: 0.2)
        var background = RGBAColor(red: 0.08, green: 0.08, blue: 0.1)
        var image: URL?
    }

    static func hex(_ color: RGBAColor) -> String {
        String(format: "0x%02X%02X%02X", Int(color.red * 255), Int(color.green * 255), Int(color.blue * 255))
    }

    /// Inputs and filters for the visualiser. `preview` renders one second from that position instead.
    static func visualizerArguments(_ input: URL, settings: VisualizerSettings, duration: Double,
                                    preview: Double? = nil) -> [String] {
        let (width, height) = settings.orientation.size
        let seconds: Double = preview == nil ? duration : 1.5
        let length = String(format: "%.3f", seconds)
        var arguments: [String] = []
        if let preview { arguments += ["-ss", String(format: "%.3f", max(preview - 0.75, 0)), "-t", length] }
        arguments += ["-i", input.path]

        let background: String
        if let image = settings.image {
            arguments += ["-loop", "1", "-framerate", "30", "-t", length, "-i", image.path]
            background = "[1:v]scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height),setsar=1,format=yuv420p[bg]"
        } else {
            background = "color=c=\(hex(settings.background)):s=\(width)x\(height):r=30:d=\(length),format=yuv420p[bg]"
        }

        let waveHeight = Int(Double(height) * (settings.orientation == .portrait ? 0.22 : 0.4)) / 2 * 2
        // The picture follows a mono, level-evened copy so quiet recordings still move; the sound itself is
        // mapped straight from the input.
        let visualAudio = "[0:a:0]aformat=channel_layouts=mono,dynaudnorm=f=150:g=15,"
        let graph: String
        switch settings.style {
        case .waveform:
            graph = "\(background);\(visualAudio)showwaves=s=\(width)x\(waveHeight):mode=cline:scale=sqrt:draw=full:rate=30:colors=\(hex(settings.waveColor)),format=yuva420p[w];"
                + "[bg][w]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .spectrum:
            graph = "\(background);\(visualAudio)showfreqs=s=\(width)x\(waveHeight):mode=bar:ascale=sqrt:fscale=log:win_size=2048:colors=\(hex(settings.waveColor)),"
                + "fps=30,format=yuva420p[w];[bg][w]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .still:
            graph = "\(background);[bg]null[v]"
        }
        arguments += ["-filter_complex", graph, "-map", "[v]"]
        return arguments
    }

    /// Writes `<name> (визуализация).mp4` with the audio and the chosen picture.
    static func visualize(_ input: URL, settings: VisualizerSettings,
                          progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        let info = try MediaConverter.probe(input)
        guard info.hasAudio, let duration = info.duration else { throw MediaError.noAudio(input) }
        let arguments = visualizerArguments(input, settings: settings, duration: duration) + [
            "-map", "0:a:0", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart",
        ]
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (визуализация)"),
            pathExtension: "mp4"
        ) { output in
            try MediaConverter.runFFmpeg(arguments, output: output, duration: duration,
                                         progress: progress, cancellation: cancellation)
        }
    }

    /// One frame of the visualiser at `time`.
    static func visualizerFrame(_ input: URL, settings: VisualizerSettings, duration: Double, at time: Double) throws -> CGImage {
        let data = try ExternalTool.runData("ffmpeg", ["-hide_banner", "-nostdin", "-loglevel", "error"]
            + visualizerArguments(input, settings: settings, duration: duration, preview: time)
            // A frame from the middle of the window: the first frames come before the waveform has data.
            + ["-ss", "0.75", "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "-"])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadable(input)
        }
        return image
    }
}
