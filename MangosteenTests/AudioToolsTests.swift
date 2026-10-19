import XCTest

final class AudioToolsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A quiet stereo tone: 440 Hz left, 880 Hz right.
    private func makeAudio(_ name: String = "voice.mp3", seconds: Int = 6) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=\(seconds)",
            "-filter_complex", "[0][1]amerge=inputs=2,volume=0.1[a]", "-map", "[a]", url.path,
        ])
        return url
    }

    private func makeVideo() throws -> URL {
        let url = directory.appendingPathComponent("talk.mp4")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
        return url
    }

    func testNormalizeReachesTargetLoudness() throws {
        let input = try makeAudio()
        let before = try AudioTools.measureLoudness(input)
        XCTAssertLessThan(before.integrated, -20)
        let output = try AudioTools.normalize(input, target: AudioTools.LoudnessTarget(integrated: -16, truePeak: -1, range: 11))
        XCTAssertEqual(output.lastPathComponent, "voice (громкость).mp3")
        let after = try AudioTools.measureLoudness(output)
        XCTAssertEqual(after.integrated, -16, accuracy: 1.5)
        XCTAssertEqual(try MediaConverter.probe(output).sampleRate, 44100)
    }

    func testNormalizeVideoKeepsPicture() throws {
        let output = try AudioTools.normalize(makeVideo(), target: AudioTools.LoudnessTarget())
        let info = try MediaConverter.probe(output)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
    }

    func testChannelFilters() {
        var settings = AudioTools.ChannelSettings()
        settings.swap = true
        settings.left = 0.5
        XCTAssertEqual(AudioTools.channelFilter(settings, sourceChannels: 2), "pan=stereo|c0=0.50*c1|c1=1.00*c0")
        settings.layout = .mono
        XCTAssertEqual(AudioTools.channelFilter(settings, sourceChannels: 1), "pan=mono|c0=0.25*c0+0.50*c0")
    }

    func testConvertChannels() throws {
        var settings = AudioTools.ChannelSettings()
        settings.layout = .mono
        let mono = try AudioTools.convertChannels(makeAudio(), settings: settings)
        XCTAssertEqual(try MediaConverter.probe(mono).audioChannels, 1)

        settings = AudioTools.ChannelSettings()
        settings.right = 0
        let leftOnly = try AudioTools.convertChannels(makeAudio("left.mp3"), settings: settings)
        let right = try MediaTools.waveform(leftOnly, duration: 6, buckets: 20, filter: "pan=mono|c0=c1")
        XCTAssertLessThan(right.max() ?? 1, 0.01)
    }

    func testBleepKeepsDurationAndAddsTone() throws {
        let input = try makeAudio()
        let output = try AudioTools.bleep(input, ranges: [1...2, 4...4.5])
        XCTAssertEqual(output.lastPathComponent, "voice (запикано).mp3")
        XCTAssertEqual(try XCTUnwrap(MediaConverter.probe(output).duration), 6, accuracy: 0.2)
        // The tone (0.3) is louder than the quiet source (0.1): the bleeped second peaks higher.
        let peaks = try MediaTools.waveform(output, duration: 6, buckets: 12)
        XCTAssertGreaterThan(peaks[3], peaks[0] * 1.5)
    }

    func testVisualizerEveryStyle() throws {
        let input = try makeAudio(seconds: 3)
        for style in AudioTools.VisualizerSettings.Style.allCases {
            var settings = AudioTools.VisualizerSettings()
            settings.style = style
            settings.orientation = .square
            let output = try AudioTools.visualize(input, settings: settings)
            let info = try MediaConverter.probe(output)
            XCTAssertEqual(info.width, 1080, "\(style)")
            XCTAssertEqual(info.videoCodec, "h264")
            XCTAssertEqual(try XCTUnwrap(info.duration), 3, accuracy: 0.3, "\(style)")
            try FileManager.default.removeItem(at: output)

            let frame = try AudioTools.visualizerFrame(input, settings: settings, duration: 3, at: 1)
            XCTAssertEqual(frame.width, 1080, "\(style)")
        }
    }
}
