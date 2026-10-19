import Foundation

/// Speed changes, joining, video cropping and media compression, all through ffmpeg.
enum MediaEffects {
    // MARK: - Speed

    /// `atempo` accepts 0.5…2 per instance on older builds, so larger changes are chained.
    static func atempoChain(_ factor: Double) -> [String] {
        var remaining = factor
        var filters: [String] = []
        while remaining > 2 {
            filters.append("atempo=2")
            remaining /= 2
        }
        while remaining < 0.5 {
            filters.append("atempo=0.5")
            remaining /= 0.5
        }
        filters.append(String(format: "atempo=%.6g", remaining))
        return filters
    }

    static func speedLabel(_ factor: Double) -> String {
        "×" + String(format: "%g", (factor * 100).rounded() / 100).replacingOccurrences(of: ".", with: ",")
    }

    /// Writes `<name> (скорость ×2).<ext>`. With `preservePitch` off, audio is resampled like tape.
    static func changeSpeed(_ input: URL, factor: Double, preservePitch: Bool,
                            progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category.isMedia, factor > 0 else {
            throw ConversionError.unrecognized(input)
        }
        let info = try MediaConverter.probe(input)
        let format = MediaTools.outputFormat(for: source)
        let videoFilters = info.hasVideo ? [String(format: "setpts=PTS/%.6g", factor)] : []
        let audioFilters: [String]
        if preservePitch {
            audioFilters = atempoChain(factor)
        } else {
            let rate = info.sampleRate ?? 48000
            audioFilters = ["asetrate=\(Int(Double(rate) * factor))", "aresample=\(rate)"]
        }
        let arguments = MediaConverter.encodeArguments(for: format, info: info,
                                                       videoFilters: videoFilters, audioFilters: audioFilters)
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (скорость \(speedLabel(factor)))",
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.run(input: input, output: output, codecArguments: arguments,
                                   duration: info.duration.map { $0 / factor },
                                   progress: progress, cancellation: cancellation)
        }
    }

    // MARK: - Join

    /// Concatenates videos into `Объединено.mp4`. The first clip sets the frame size and rate; other
    /// clips are fitted inside it with bars, and clips without sound get silence.
    static func join(_ inputs: [URL], progress: ((Double) -> Void)? = nil,
                     cancellation: CancellationToken? = nil) throws -> URL {
        guard inputs.count >= 2 else { throw PDFToolError.nothingToDo }
        let infos = try inputs.map(MediaConverter.probe)
        guard let first = infos.first, let width = first.width, let height = first.height else {
            throw MediaError.noVideo(inputs[0])
        }
        for (url, info) in zip(inputs, infos) where !info.hasVideo {
            throw MediaError.noVideo(url)
        }
        let canvasWidth = width / 2 * 2
        let canvasHeight = height / 2 * 2
        let fps = String(format: "%.3f", first.frameRate ?? 30)

        var graph: [String] = []
        var concatInputs = ""
        for (index, info) in infos.enumerated() {
            graph.append("[\(index):v:0]scale=\(canvasWidth):\(canvasHeight):force_original_aspect_ratio=decrease,"
                         + "pad=\(canvasWidth):\(canvasHeight):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(index)]")
            if info.hasAudio {
                graph.append("[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            } else {
                let duration = String(format: "%.3f", info.duration ?? 0)
                graph.append("anullsrc=channel_layout=stereo:sample_rate=48000,atrim=0:\(duration),aformat=sample_fmts=fltp[a\(index)]")
            }
            concatInputs += "[v\(index)][a\(index)]"
        }
        graph.append("\(concatInputs)concat=n=\(inputs.count):v=1:a=1[v][a]")

        let arguments = inputs.flatMap { ["-i", $0.path] } + [
            "-filter_complex", graph.joined(separator: ";"),
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
        ]
        let total = infos.compactMap(\.duration).reduce(0, +)
        return try OutputNaming.writeAtomically(
            directory: inputs[0].deletingLastPathComponent(), baseName: "Объединено", pathExtension: "mp4"
        ) { output in
            try MediaConverter.runFFmpeg(arguments, output: output, duration: total,
                                         progress: progress, cancellation: cancellation)
        }
    }

    // MARK: - Crop

    /// Writes `<name> (кадрирование).<ext>`. `rect` is normalised against the upright frame; `outputSize`
    /// scales the result to exact pixels.
    static func cropVideo(_ input: URL, rect: CGRect, outputSize: CGSize?,
                          progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category == .video else { throw MediaError.noVideo(input) }
        let info = try MediaConverter.probe(input)
        // ffmpeg rotates frames upright before filtering, so measure a decoded frame, not the stream.
        let frame = try MediaTools.frame(input, at: 0)
        let size = CGSize(width: frame.width, height: frame.height)
        let pixels = ImageCropper.pixelRect(rect, imageSize: size)
        let width = max(Int(pixels.width) / 2 * 2, 2)
        let height = max(Int(pixels.height) / 2 * 2, 2)
        var filters = ["crop=\(width):\(height):\(Int(pixels.minX)):\(Int(pixels.minY))"]
        if let outputSize, outputSize.width >= 2, outputSize.height >= 2 {
            filters.append("scale=\(Int(outputSize.width) / 2 * 2):\(Int(outputSize.height) / 2 * 2)")
        }
        let format = MediaTools.outputFormat(for: source)
        let arguments = MediaConverter.encodeArguments(for: format, info: info, videoFilters: filters)
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (кадрирование)",
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.run(input: input, output: output, codecArguments: arguments, duration: info.duration,
                                   progress: progress, cancellation: cancellation)
        }
    }

    // MARK: - Compress

    struct CompressionSettings: Equatable {
        enum Quality: String, CaseIterable, Identifiable {
            case high, balanced, small
            var id: String { rawValue }
            var title: String {
                switch self {
                case .high: "Высокое качество"
                case .balanced: "Сбалансированно"
                case .small: "Минимальный размер"
                }
            }
            var h264CRF: Int { switch self { case .high: 23; case .balanced: 27; case .small: 31 } }
            var hevcCRF: Int { switch self { case .high: 26; case .balanced: 30; case .small: 34 } }
            var audioKbps: Int { switch self { case .high: 160; case .balanced: 128; case .small: 80 } }
        }

        var quality = Quality.balanced
        /// Limit for the frame height (the longer side for portrait videos is handled by ffmpeg's -2).
        var maxHeight: Int?
        var hevc = false
        var useTargetSize = false
        var targetBytes: Int64 = 25_000_000
    }

    static let lossyAudio: Set<FileFormat> = [.mp3, .m4a, .ogg, .opus, .wma]

    static func compressedFormat(for source: FileFormat) -> FileFormat {
        if source.category == .video {
            return [.mp4, .mov, .mkv].contains(source) ? source : .mp4
        }
        return lossyAudio.contains(source) ? source : .m4a
    }

    static func compressionArguments(for source: FileFormat, info: MediaInfo, settings: CompressionSettings) -> [String] {
        let duration = max(info.duration ?? 1, 0.1)
        var audioKbps = settings.quality.audioKbps
        if source.category == .audio {
            if settings.useTargetSize {
                audioKbps = Int(Double(settings.targetBytes) * 8 / duration / 1000 * 0.95)
            }
            audioKbps = min(max(audioKbps, 24), 320)
            let codec: [String] = switch compressedFormat(for: source) {
            case .mp3: ["-c:a", "libmp3lame"]
            case .ogg: ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
            case .opus: ["-c:a", "libopus"]
            case .wma: ["-c:a", "wmav2"]
            default: ["-c:a", "aac"]
            }
            return ["-vn"] + codec + ["-b:a", "\(audioKbps)k"]
        }

        var filters: [String] = []
        if let maxHeight = settings.maxHeight {
            filters.append("scale=-2:'min(\(maxHeight),ih)'")
        }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        var arguments = ["-map", "0:v:0", "-map", "0:a?", "-vf", filters.joined(separator: ","), "-pix_fmt", "yuv420p"]
        arguments += settings.hevc
            ? ["-c:v", "libx265", "-preset", "medium", "-tag:v", "hvc1"]
            : ["-c:v", "libx264", "-preset", "medium"]
        if settings.useTargetSize {
            audioKbps = 96
            let videoKbps = max(Int(Double(settings.targetBytes) * 8 / duration / 1000 * 0.93) - audioKbps, 80)
            arguments += ["-b:v", "\(videoKbps)k", "-maxrate", "\(videoKbps * 3 / 2)k", "-bufsize", "\(videoKbps * 2)k"]
        } else {
            arguments += ["-crf", String(settings.hevc ? settings.quality.hevcCRF : settings.quality.h264CRF)]
        }
        arguments += ["-c:a", "aac", "-b:a", "\(audioKbps)k"]
        if compressedFormat(for: source) == .mp4 { arguments += ["-movflags", "+faststart"] }
        return arguments
    }

    /// Predicted output size. Video is measured by encoding a short sample from the middle with the same
    /// settings; audio follows from the bitrate; target-size mode returns the target.
    static func estimateCompressedSize(_ input: URL, settings: CompressionSettings,
                                       cancellation: CancellationToken? = nil) throws -> Int64 {
        guard let source = FileFormat.detect(input), source.category.isMedia else { throw ConversionError.unrecognized(input) }
        let info = try MediaConverter.probe(input)
        let duration = info.duration ?? 0
        if settings.useTargetSize {
            return settings.targetBytes
        }
        if source.category == .audio {
            let kbps = min(max(settings.quality.audioKbps, 24), 320)
            return Int64(Double(kbps) * 1000 / 8 * duration)
        }
        let sampleLength = min(duration, 6)
        guard sampleLength > 0 else { throw ConversionError.unreadable(input) }
        let start = max(0, duration / 2 - sampleLength / 2)
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangosteen-estimate-\(UUID().uuidString)")
            .appendingPathExtension(compressedFormat(for: source).fileExtension)
        defer { try? FileManager.default.removeItem(at: sample) }
        try MediaConverter.runFFmpeg(
            ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", sampleLength), "-i", input.path]
                + compressionArguments(for: source, info: info, settings: settings),
            output: sample, duration: sampleLength, progress: nil, cancellation: cancellation
        )
        return Int64(Double(ImageCompression.fileSize(sample)) * duration / sampleLength)
    }

    /// Writes `<name> (сжатый).<ext>`; refuses to keep a result that is not smaller than the original.
    static func compress(_ input: URL, settings: CompressionSettings,
                         progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category.isMedia else { throw ConversionError.unrecognized(input) }
        let info = try MediaConverter.probe(input)
        if source.category == .video, !info.hasVideo { throw MediaError.noVideo(input) }
        let format = compressedFormat(for: source)
        let output = try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (сжатый)",
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.run(input: input, output: output,
                                   codecArguments: compressionArguments(for: source, info: info, settings: settings),
                                   duration: info.duration, progress: progress, cancellation: cancellation)
        }
        let original = ImageCompression.fileSize(input)
        let result = ImageCompression.fileSize(output)
        if result >= original {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.notSmaller(original: original, result: result)
        }
        return output
    }
}
