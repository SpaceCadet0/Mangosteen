import Foundation
import ImageIO

/// Hides areas of a video, each for its own time range, with a solid colour, blur or pixels.
enum VideoRedactor {
    struct Region: Identifiable, Equatable {
        var id = UUID()
        /// Normalised (0…1, top-left origin) against the upright frame.
        var rect: CGRect
        var start: Double
        var end: Double
    }

    /// The filter graph; the result is labelled `[v]`. `frameSize` is the upright frame in pixels.
    static func filterGraph(regions: [Region], style: RedactionStyle, color: RGBAColor, frameSize: CGSize) -> String {
        var chains: [String] = []
        var current = "[0:v]"
        for (index, region) in regions.enumerated() {
            let pixels = ImageCropper.pixelRect(region.rect, imageSize: frameSize)
            let x = Int(pixels.minX) / 2 * 2
            let y = Int(pixels.minY) / 2 * 2
            let width = max(Int(pixels.width) / 2 * 2, 2)
            let height = max(Int(pixels.height) / 2 * 2, 2)
            let enable = "between(t,\(String(format: "%.3f", region.start)),\(String(format: "%.3f", region.end)))"
            let output = "[v\(index)]"
            switch style {
            case .solid:
                chains.append("\(current)drawbox=x=\(x):y=\(y):w=\(width):h=\(height):color=\(AudioTools.hex(color))@1:t=fill:enable='\(enable)'\(output)")
            case .blur, .pixelate:
                // Pixelating first destroys the detail, so even the blur cannot be undone.
                let block = max(max(width, height) / 10, 4)
                var effect = "crop=\(width):\(height):\(x):\(y),scale=\(max(width / block, 2)):\(max(height / block, 2)),"
                    + "scale=\(width):\(height):flags=neighbor"
                if style == .blur { effect += ",gblur=sigma=\(Double(block) * 0.9)" }
                chains.append("\(current)split[main\(index)][part\(index)]")
                chains.append("[part\(index)]\(effect)[hidden\(index)]")
                chains.append("[main\(index)][hidden\(index)]overlay=\(x):\(y):enable='\(enable)'\(output)")
            }
            current = output
        }
        chains.append("\(current)format=yuv420p[v]")
        return chains.joined(separator: ";")
    }

    static func videoCodecArguments(for format: FileFormat) -> [String] {
        switch format {
        case .webm: ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
        case .avi: ["-c:v", "mpeg4", "-q:v", "2"]
        case .wmv: ["-c:v", "wmv2", "-q:v", "2"]
        default: ["-c:v", "libx264", "-preset", "medium", "-crf", "18"]
        }
    }

    /// The upright frame size ffmpeg filters see (rotation applied).
    static func frameSize(_ input: URL) throws -> CGSize {
        let frame = try MediaTools.frame(input, at: 0)
        return CGSize(width: frame.width, height: frame.height)
    }

    /// Writes `<name> (скрыто).<ext>`; the sound is copied unchanged.
    static func redact(_ input: URL, regions: [Region], style: RedactionStyle, color: RGBAColor,
                       progress: ((Double) -> Void)? = nil, cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category == .video else { throw MediaError.noVideo(input) }
        guard !regions.isEmpty else { throw PDFToolError.nothingToDo }
        let info = try MediaConverter.probe(input)
        let format = MediaTools.outputFormat(for: source)
        let graph = filterGraph(regions: regions, style: style, color: color, frameSize: try frameSize(input))
        var arguments = ["-i", input.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a?"]
            + videoCodecArguments(for: format) + ["-c:a", "copy"]
        if format == .mp4 { arguments += ["-movflags", "+faststart"] }
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (скрыто)",
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.runFFmpeg(arguments, output: output, duration: info.duration,
                                         progress: progress, cancellation: cancellation)
        }
    }

    /// The processed frame at `time`, to check the result before saving.
    static func previewFrame(_ input: URL, regions: [Region], style: RedactionStyle, color: RGBAColor,
                             frameSize: CGSize, at time: Double) throws -> CGImage {
        let graph = filterGraph(regions: regions, style: style, color: color, frameSize: frameSize)
        // -copyts keeps the original timestamps so the time ranges in the graph still match.
        let data = try ExternalTool.runData("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-copyts",
            "-i", input.path, "-filter_complex", graph, "-map", "[v]", "-frames:v", "1",
            "-f", "image2pipe", "-c:v", "png", "-",
        ])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.unreadable(input)
        }
        return image
    }
}
