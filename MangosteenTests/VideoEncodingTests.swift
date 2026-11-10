import XCTest

/// 0.10.6: the video codec chosen in Settings (H.264, HEVC, AV1, Apple's hardware encoders).
final class VideoEncodingTests: XCTestCase {
    private var directory: URL!
    private var saved = VideoEncoding()

    override func setUpWithError() throws {
        saved = VideoEncoding.current
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        VideoEncoding.current = saved
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testDefaultsKeepTheEarlierArguments() {
        XCTAssertEqual(VideoEncoding().arguments(for: .mp4),
                       ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"])
        XCTAssertEqual(VideoEncoding().arguments(for: .mp4, crf: 18)[5], "18")
    }

    func testChoicesAndTheirLimits() {
        let av1 = VideoEncoding(codec: .av1, hardware: true)
        XCTAssertEqual(av1.arguments(for: .mp4)[1], "libsvtav1", "there is no hardware AV1 encoder")
        XCTAssertEqual(av1.arguments(for: .mov)[1], "h264_videotoolbox", "MOV cannot hold AV1")
        XCTAssertEqual(VideoEncoding(codec: .av1).arguments(for: .mov)[1], "libx264")

        let hevc = VideoEncoding(codec: .hevc)
        XCTAssertTrue(hevc.arguments(for: .mp4).contains("hvc1"), "QuickTime needs the hvc1 tag")
        XCTAssertFalse(hevc.arguments(for: .mkv).contains("hvc1"))
        XCTAssertEqual(VideoEncoding(codec: .hevc, hardware: true).arguments(for: .mov)[1], "hevc_videotoolbox")
    }

    /// A WebM source, so converting to MP4, MOV or MKV always re-encodes the picture.
    private func source() throws -> URL {
        let url = directory.appendingPathComponent("source.webm")
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                                        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2",
                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-shortest",
                                        "-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", url.path])
        return url
    }

    func testEachChoiceEncodesWithThatCodec() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let input = try source()
        let cases: [(VideoEncoding, FileFormat, String)] = [
            (VideoEncoding(), .mp4, "h264"),
            (VideoEncoding(codec: .h264, hardware: true), .mp4, "h264"),
            (VideoEncoding(codec: .hevc), .mp4, "hevc"),
            (VideoEncoding(codec: .hevc, hardware: true), .mov, "hevc"),
            (VideoEncoding(codec: .av1), .mp4, "av1"),
            (VideoEncoding(codec: .av1), .mov, "h264"),
            // MKV takes any codec, so the picture is copied as it is whatever the setting.
            (VideoEncoding(codec: .av1), .mkv, "vp9"),
        ]
        for (encoding, container, codec) in cases {
            VideoEncoding.current = encoding
            let output = try XCTUnwrap(Converter.convert(input, to: container, options: ConversionOptions()))
            XCTAssertEqual(try MediaConverter.probe(output).videoCodec, codec, "\(encoding) → \(container)")
            try FileManager.default.removeItem(at: output)
        }
    }

    func testJoiningFollowsTheChoice() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let clip = try source()
        VideoEncoding.current = VideoEncoding(codec: .hevc, hardware: true)
        let joined = try MediaEffects.join([clip, clip])
        XCTAssertEqual(try MediaConverter.probe(joined).videoCodec, "hevc")
    }

    func testToolsThatReencodeMKVFollowTheChoice() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let mkv = try XCTUnwrap(Converter.convert(try source(), to: .mkv, options: ConversionOptions()))
        let region = VideoRedactor.Region(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), start: 0, end: 2)
        for (codec, expected) in [(VideoEncoding.Codec.av1, "av1"), (.hevc, "hevc")] {
            VideoEncoding.current = VideoEncoding(codec: codec)
            let hidden = try VideoRedactor.redact(mkv, regions: [region], style: .solid, color: .white)
            XCTAssertEqual(hidden.pathExtension, "mkv")
            XCTAssertEqual(try MediaConverter.probe(hidden).videoCodec, expected)
            try FileManager.default.removeItem(at: hidden)
        }
    }
}
