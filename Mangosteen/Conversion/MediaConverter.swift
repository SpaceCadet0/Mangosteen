import Foundation

/// What ffprobe reports about a media file.
struct MediaInfo {
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var audioChannels: Int?
    var frameRate: Double?
    var sampleRate: Int?

    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }
}

enum MediaError: LocalizedError {
    case noAudio(URL)
    case noVideo(URL)

    var errorDescription: String? {
        switch self {
        case .noAudio(let url): String(localized: "В «\(url.lastPathComponent)» нет звуковой дорожки.")
        case .noVideo(let url): String(localized: "В «\(url.lastPathComponent)» нет видео.")
        }
    }
}

/// Video and audio conversion through ffmpeg. Container changes reuse the existing streams when the
/// target supports their codecs (fast and lossless); otherwise the streams are re-encoded.
enum MediaConverter {
    // MARK: - Probing

    static func probe(_ url: URL) throws -> MediaInfo {
        let json = try ExternalTool.run("ffprobe", [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        struct Output: Decodable {
            struct Stream: Decodable {
                let codec_type: String?
                let codec_name: String?
                let width: Int?
                let height: Int?
                let channels: Int?
                let disposition: [String: Int]?
                let avg_frame_rate: String?
                let sample_rate: String?
                let r_frame_rate: String?
            }
            struct Format: Decodable {
                let duration: String?
            }
            let streams: [Stream]?
            let format: Format?
        }
        let output = try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        let streams = output.streams ?? []
        // Cover art is reported as a video stream; it is not a picture track.
        let video = streams.first { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }
        let audio = streams.first { $0.codec_type == "audio" }
        return MediaInfo(
            duration: output.format?.duration.flatMap(Double.init),
            videoCodec: video?.codec_name,
            audioCodec: audio?.codec_name,
            width: video?.width,
            height: video?.height,
            audioChannels: audio?.channels,
            frameRate: rate(video?.avg_frame_rate) ?? rate(video?.r_frame_rate),
            sampleRate: audio?.sample_rate.flatMap { Int($0) }
        )
    }

    /// "30000/1001" → 29.97; nil for "0/0" or garbage.
    static func rate(_ fraction: String?) -> Double? {
        guard let parts = fraction?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0, numerator > 0 else {
            return nil
        }
        return numerator / denominator
    }

    // MARK: - Conversion

    /// Converts `input` to `target`, reporting progress from 0 to 1.
    static func convert(_ input: URL, to target: FileFormat, output: URL,
                        progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws {
        let info = try probe(input)
        if target.category == .audio, !info.hasAudio { throw MediaError.noAudio(input) }
        if target.category == .video, !info.hasVideo { throw MediaError.noVideo(input) }

        if let copy = remuxArguments(for: target, info: info) {
            do {
                try run(input: input, output: output, codecArguments: copy, duration: info.duration,
                        progress: progress, cancellation: cancellation)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some streams cannot be copied into this container after all; re-encode instead.
                try? FileManager.default.removeItem(at: output)
            }
        }
        try run(input: input, output: output, codecArguments: encodeArguments(for: target, info: info),
                duration: info.duration, progress: progress, cancellation: cancellation)
    }

    /// Stream-copy arguments when the target container accepts the source codecs, otherwise nil.
    static func remuxArguments(for target: FileFormat, info: MediaInfo) -> [String]? {
        let video = info.videoCodec
        let audio = info.audioCodec
        func audioFits(_ codecs: Set<String>) -> Bool { audio.map(codecs.contains) ?? true }

        switch target {
        case .mp4, .mov:
            guard let video, ["h264", "hevc"].contains(video), audioFits(["aac", "mp3", "alac"]) else { return nil }
            var arguments = ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
            if video == "hevc" { arguments += ["-tag:v", "hvc1"] }
            if target == .mp4 { arguments += ["-movflags", "+faststart"] }
            return arguments
        case .mkv:
            guard info.hasVideo else { return nil }
            return ["-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-c", "copy"]
        case .webm:
            guard let video, ["vp8", "vp9", "av1"].contains(video), audioFits(["opus", "vorbis"]) else { return nil }
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        case .m4a:
            return ["aac", "alac"].contains(audio ?? "") ? ["-vn", "-c:a", "copy"] : nil
        case .opus:
            return audio == "opus" ? ["-vn", "-c:a", "copy"] : nil
        case .ogg:
            return ["vorbis", "opus"].contains(audio ?? "") ? ["-vn", "-c:a", "copy"] : nil
        case .flac:
            return audio == "flac" ? ["-vn", "-c:a", "copy"] : nil
        case .mp3:
            return audio == "mp3" ? ["-vn", "-c:a", "copy"] : nil
        default:
            return nil
        }
    }

    /// Re-encoding arguments for each target.
    /// `videoFilters` run before the even-size scaling; `audioFilters` apply when there is an audio track.
    static func encodeArguments(for target: FileFormat, info: MediaInfo,
                                videoFilters: [String] = [], audioFilters: [String] = []) -> [String] {
        let audio = info.hasAudio && !audioFilters.isEmpty ? ["-af", audioFilters.joined(separator: ",")] : []
        return videoCodecArguments(for: target, info: info, videoFilters: videoFilters) + audio
    }

    private static func videoCodecArguments(for target: FileFormat, info: MediaInfo, videoFilters: [String]) -> [String] {
        // H.264 and the other 4:2:0 encoders need even dimensions.
        let evenSize = ["-vf", (videoFilters + ["scale=trunc(iw/2)*2:trunc(ih/2)*2"]).joined(separator: ",")]
        let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"] + evenSize
        let aac = ["-c:a", "aac", "-b:a", "192k"]
        switch target {
        case .mp4:
            return ["-map", "0:v:0", "-map", "0:a?"] + h264 + aac + ["-movflags", "+faststart"]
        case .mov, .mkv:
            return ["-map", "0:v:0", "-map", "0:a?"] + h264 + aac
        case .webm:
            return ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0",
                    "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p",
                    "-c:a", "libopus", "-b:a", "128k"] + evenSize
        case .avi:
            return ["-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg4", "-q:v", "3",
                    "-c:a", "libmp3lame", "-q:a", "3"] + evenSize
        case .wmv:
            return ["-map", "0:v:0", "-map", "0:a?", "-c:v", "wmv2", "-q:v", "3",
                    "-c:a", "wmav2", "-b:a", "192k"] + evenSize
        case .gif:
            return ["-an", "-vf",
                    videoFilters.map { $0 + "," }.joined() + "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"]
        case .mp3:
            return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a:
            return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .wav:
            return ["-vn", "-c:a", "pcm_s16le"]
        case .aiff:
            return ["-vn", "-c:a", "pcm_s16be"]
        case .flac:
            return ["-vn", "-c:a", "flac"]
        case .ogg:
            // The built-in Vorbis encoder is marked experimental and only supports stereo.
            return ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", "192k"]
        case .opus:
            return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case .wma:
            return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default:
            return []
        }
    }

    /// Runs ffmpeg with progress reporting. `codecArguments` go between the input and the output.
    static func run(input: URL, output: URL, codecArguments: [String], duration: Double?,
                    extraInputArguments: [String] = [],
                    progress: ((Double) -> Void)?, cancellation: CancellationToken?) throws {
        try runFFmpeg(extraInputArguments + ["-i", input.path] + codecArguments + ["-map_metadata", "0"],
                      output: output, duration: duration, progress: progress, cancellation: cancellation)
    }

    /// Runs ffmpeg with `arguments` (inputs, filters, codecs) and progress reporting against `duration`.
    static func runFFmpeg(_ arguments: [String], output: URL, duration: Double?,
                          progress: ((Double) -> Void)?, cancellation: CancellationToken?) throws {
        try cancellation?.throwIfCancelled()
        let arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
            + arguments
            + ["-progress", "pipe:1", "-nostats", output.path]
        try ExternalTool.runStreaming("ffmpeg", arguments, cancellation: cancellation) { line in
            guard let progress, let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)) else {
                return
            }
            progress(min(max(microseconds / 1_000_000 / duration, 0), 1))
        }
        progress?(1)
    }
}
