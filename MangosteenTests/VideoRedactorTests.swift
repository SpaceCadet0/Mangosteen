import XCTest

final class VideoRedactorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vredact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeVideo() throws -> URL {
        let url = directory.appendingPathComponent("clip.mp4")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
        return url
    }

    /// Red channel at the centre of the frame at `time`.
    private func centreRed(_ url: URL, at time: Double) throws -> UInt8 {
        let image = try MediaTools.frame(url, at: time)
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return bytes[offset]
    }

    func testSolidRegionOnlyDuringItsTimeRange() throws {
        let input = try makeVideo()
        let region = VideoRedactor.Region(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), start: 1, end: 2.5)
        let output = try VideoRedactor.redact(input, regions: [region], style: .solid,
                                              color: RGBAColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(output.lastPathComponent, "clip (скрыто).mp4")
        XCTAssertGreaterThan(try centreRed(output, at: 1.8), 230)
        let info = try MediaConverter.probe(output)
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(try XCTUnwrap(info.duration), 4, accuracy: 0.2)
        // Outside the range the picture is the original.
        let before = try centreRed(input, at: 0.5)
        XCTAssertEqual(Int(try centreRed(output, at: 0.5)), Int(before), accuracy: 25)
    }

    func testBlurAndPixelateAndPreview() throws {
        let input = try makeVideo()
        let regions = [
            VideoRedactor.Region(rect: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), start: 0, end: 4),
            VideoRedactor.Region(rect: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), start: 2, end: 3),
        ]
        for style in [RedactionStyle.blur, .pixelate] {
            let output = try VideoRedactor.redact(input, regions: regions, style: style, color: .white)
            XCTAssertEqual(try MediaConverter.probe(output).width, 320, "\(style)")
            try FileManager.default.removeItem(at: output)
        }
        let frame = try VideoRedactor.previewFrame(input, regions: regions, style: .solid,
                                                   color: RGBAColor(red: 1, green: 0, blue: 0),
                                                   frameSize: CGSize(width: 320, height: 240), at: 2.5)
        XCTAssertEqual(frame.width, 320)
    }
}
