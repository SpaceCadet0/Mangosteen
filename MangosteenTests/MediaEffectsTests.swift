import XCTest

final class MediaEffectsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeVideo(_ name: String, size: String = "320x240", seconds: Int = 4, audio: Bool = true,
                           bitrate: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var arguments = ["-hide_banner", "-loglevel", "error", "-y",
                         "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=\(seconds)"]
        if audio { arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:a", "aac", "-shortest"] }
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if let bitrate { arguments += ["-b:v", bitrate] }
        try ExternalTool.run("ffmpeg", arguments + [url.path])
        return url
    }

    private func makeAudio() throws -> URL {
        let url = directory.appendingPathComponent("tone.wav")
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-ac", "2", url.path])
        return url
    }

    private func probe(_ url: URL) throws -> MediaInfo { try MediaConverter.probe(url) }

    func testAtempoChainStaysInRange() {
        XCTAssertEqual(MediaEffects.atempoChain(4), ["atempo=2", "atempo=2"])
        XCTAssertEqual(MediaEffects.atempoChain(0.25), ["atempo=0.5", "atempo=0.5"])
        XCTAssertEqual(MediaEffects.atempoChain(1.5), ["atempo=1.5"])
        XCTAssertEqual(MediaEffects.speedLabel(1.5), "×1,5")
    }

    func testSpeedChangesDuration() throws {
        let input = try makeVideo("clip.mp4")
        let faster = try MediaEffects.changeSpeed(input, factor: 2, preservePitch: true)
        XCTAssertEqual(faster.lastPathComponent, "clip (скорость ×2).mp4")
        let info = try probe(faster)
        XCTAssertEqual(try XCTUnwrap(info.duration), 2, accuracy: 0.15)
        XCTAssertNotNil(info.audioCodec)

        let slower = try MediaEffects.changeSpeed(makeAudio(), factor: 0.5, preservePitch: false)
        XCTAssertEqual(try XCTUnwrap(probe(slower).duration), 12, accuracy: 0.2)
    }

    func testSpeedWorksForSilentVideo() throws {
        let output = try MediaEffects.changeSpeed(makeVideo("silent.mp4", audio: false), factor: 0.5, preservePitch: true)
        XCTAssertEqual(try XCTUnwrap(probe(output).duration), 8, accuracy: 0.2)
    }

    func testJoinFitsClipsIntoFirstCanvas() throws {
        let first = try makeVideo("a.mp4", size: "640x360", seconds: 2)
        let second = try makeVideo("b.mp4", size: "320x240", seconds: 3, audio: false)
        let output = try MediaEffects.join([first, second])
        XCTAssertEqual(output.lastPathComponent, "Объединено.mp4")
        let info = try probe(output)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(try XCTUnwrap(info.duration), 5, accuracy: 0.2)
    }

    func testCropVideo() throws {
        let input = try makeVideo("wide.mp4", size: "640x360")
        let output = try MediaEffects.cropVideo(input, rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1), outputSize: nil)
        XCTAssertEqual(output.lastPathComponent, "wide (кадрирование).mp4")
        let info = try probe(output)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 360)
        XCTAssertNotNil(info.audioCodec)

        let scaled = try MediaEffects.cropVideo(input, rect: CGRect(x: 0, y: 0, width: 0.5625, height: 1),
                                                outputSize: CGSize(width: 180, height: 320))
        XCTAssertEqual(try probe(scaled).width, 180)
    }

    func testCompressVideoAndRespectTarget() throws {
        let input = try makeVideo("big.mp4", size: "1280x720", seconds: 4, bitrate: "8M")
        var settings = MediaEffects.CompressionSettings()
        settings.maxHeight = 480
        let output = try MediaEffects.compress(input, settings: settings)
        XCTAssertEqual(try probe(output).height, 480)
        XCTAssertLessThan(ImageCompression.fileSize(output), ImageCompression.fileSize(input))
        try FileManager.default.removeItem(at: output)

        settings = MediaEffects.CompressionSettings()
        settings.useTargetSize = true
        settings.targetBytes = 600_000
        let targeted = try MediaEffects.compress(input, settings: settings)
        XCTAssertLessThan(ImageCompression.fileSize(targeted), 800_000)
    }

    func testCompressLosslessAudioBecomesAAC() throws {
        let output = try MediaEffects.compress(makeAudio(), settings: MediaEffects.CompressionSettings())
        XCTAssertEqual(output.pathExtension, "m4a")
        XCTAssertEqual(try probe(output).audioCodec, "aac")
    }
}
