import XCTest

final class MediaToolsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediatools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeVideo(seconds: Int = 6) throws -> URL {
        let url = directory.appendingPathComponent("clip.mp4")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
        return url
    }

    private func makeAudio() throws -> URL {
        let url = directory.appendingPathComponent("tone.mp3")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-c:a", "libmp3lame", url.path,
        ])
        return url
    }

    private func duration(_ url: URL) throws -> Double {
        try XCTUnwrap(MediaConverter.probe(url).duration)
    }

    func testTimecodes() {
        XCTAssertEqual(MediaTools.timecode(83.45), "00:01:23.450")
        XCTAssertEqual(MediaTools.parseTimecode("01:23.45"), 83.45)
        XCTAssertEqual(MediaTools.parseTimecode("1:00:00"), 3600)
        XCTAssertEqual(MediaTools.parseTimecode("12,5"), 12.5)
        XCTAssertNil(MediaTools.parseTimecode("abc"))
        XCTAssertEqual(MediaConverter.rate("30000/1001")!, 29.97, accuracy: 0.01)
    }

    func testPreciseTrimHasRequestedLength() throws {
        let output = try MediaTools.trim(makeVideo(), start: 1.5, end: 4, fast: false)
        XCTAssertEqual(output.lastPathComponent, "clip (обрезано).mp4")
        XCTAssertEqual(try duration(output), 2.5, accuracy: 0.1)
        XCTAssertEqual(try MediaConverter.probe(output).videoCodec, "h264")
    }

    func testFastTrimCopiesStreams() throws {
        let output = try MediaTools.trim(makeVideo(), start: 0, end: 3, fast: true)
        XCTAssertEqual(try duration(output), 3, accuracy: 0.6)
    }

    func testAudioTrim() throws {
        let output = try MediaTools.trim(makeAudio(), start: 1, end: 2, fast: false)
        XCTAssertEqual(output.pathExtension, "mp3")
        XCTAssertEqual(try duration(output), 1, accuracy: 0.1)
    }

    func testSplitIntoEqualParts() throws {
        let input = try makeVideo()
        let points = MediaTools.equalSplitPoints(duration: 6, parts: 3)
        XCTAssertEqual(points, [2, 4])
        let lock = NSLock()
        var last = 0.0
        let folder = try MediaTools.split(input, at: points, fast: false, progress: { value in lock.withLock { last = value } })
        XCTAssertEqual(folder.lastPathComponent, "clip (части)")
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(parts.map(\.lastPathComponent), ["clip 1.mp4", "clip 2.mp4", "clip 3.mp4"])
        for part in parts {
            XCTAssertEqual(try duration(part), 2, accuracy: 0.15)
        }
        XCTAssertEqual(lock.withLock { last }, 1, accuracy: 0.001)
    }

    func testSaveFramesFullResolution() throws {
        let input = try makeVideo()
        let single = try MediaTools.saveFrames(input, at: [1.0])
        XCTAssertEqual(single.lastPathComponent, "clip кадр 00-00-01.000.png")
        let image = try MediaTools.frame(input, at: 1)
        XCTAssertEqual(image.width, 320)

        let folder = try MediaTools.saveFrames(input, at: [3, 0.5])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testThumbnailsAndWaveform() throws {
        let input = try makeVideo()
        let thumbnails = MediaTools.thumbnails(input, duration: 6, count: 4, height: 60)
        XCTAssertEqual(thumbnails.count, 4)
        XCTAssertEqual(thumbnails.first?.height, 60)
        let peaks = try MediaTools.waveform(input, duration: 6, buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.05)
    }
}
