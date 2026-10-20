import XCTest

final class MediaConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// An H.264 + AAC MP4 with a test pattern and a tone.
    private func makeVideo(seconds: Int = 2, size: String = "320x240", name: String = "clip.mp4") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=\(size):rate=25:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
        return url
    }

    private func makeAudio() throws -> URL {
        let url = directory.appendingPathComponent("tone.wav")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ac", "2", url.path,
        ])
        return url
    }

    private func convert(_ url: URL, _ target: FileFormat, progress: ((Double) -> Void)? = nil,
                         cancellation: CancellationToken? = nil) throws -> URL {
        try XCTUnwrap(Converter.convert(url, to: target, options: ConversionOptions(),
                                        progress: progress, cancellation: cancellation))
    }

    func testProbeReadsCodecsAndDuration() throws {
        let info = try MediaConverter.probe(makeVideo())
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(try XCTUnwrap(info.duration), 2, accuracy: 0.2)
    }

    func testVideoConvertsToEveryTarget() throws {
        let input = try makeVideo()
        let expected: [FileFormat: (video: String?, audio: String?)] = [
            .mov: ("h264", "aac"), .mkv: ("h264", "aac"), .webm: ("vp9", "opus"), .avi: ("mpeg4", "mp3"),
            .wmv: ("wmv2", "wmav2"), .gif: ("gif", nil), .mp3: (nil, "mp3"),
        ]
        for (target, codecs) in expected {
            let output = try convert(input, target)
            XCTAssertEqual(output.pathExtension, target.fileExtension)
            let info = try MediaConverter.probe(output)
            XCTAssertEqual(info.videoCodec, codecs.video, "\(target) video")
            XCTAssertEqual(info.audioCodec, codecs.audio, "\(target) audio")
        }
    }

    func testContainerChangeCopiesStreams() throws {
        let info = MediaInfo(duration: 2, videoCodec: "h264", audioCodec: "aac")
        XCTAssertNotNil(MediaConverter.remuxArguments(for: .mov, info: info))
        XCTAssertNotNil(MediaConverter.remuxArguments(for: .mkv, info: info))
        XCTAssertNil(MediaConverter.remuxArguments(for: .webm, info: info))
        XCTAssertNil(MediaConverter.remuxArguments(for: .mp4, info: MediaInfo(videoCodec: "vp9", audioCodec: "opus")))
    }

    func testAudioConvertsToEveryTarget() throws {
        let input = try makeAudio()
        let expected: [FileFormat: String] = [
            .mp3: "mp3", .m4a: "aac", .flac: "flac", .ogg: "vorbis", .opus: "opus", .aiff: "pcm_s16be", .wma: "wmav2",
        ]
        for (target, codec) in expected {
            let info = try MediaConverter.probe(convert(input, target))
            XCTAssertEqual(info.audioCodec, codec, "\(target)")
            XCTAssertNil(info.videoCodec)
            XCTAssertEqual(try XCTUnwrap(info.duration), 2, accuracy: 0.2)
        }
    }

    func testAudioToVideoFormatIsNotOffered() throws {
        XCTAssertFalse(FormatCatalog.targets(for: [try makeAudio()]).contains(.mp4))
        XCTAssertEqual(FormatCatalog.targets(for: [try makeVideo()]).first, .mov)
    }

    func testProgressReachesTheEnd() throws {
        let lock = NSLock()
        var values: [Double] = []
        _ = try convert(makeVideo(seconds: 4), .webm) { value in lock.withLock { values.append(value) } }
        XCTAssertEqual(lock.withLock { values.last }, 1)
        XCTAssertTrue(lock.withLock { values.allSatisfy { (0...1).contains($0) } })
    }

    func testCancellationStopsFfmpegAndLeavesNothing() throws {
        let input = try makeVideo(seconds: 30, size: "1280x720")
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
        let started = Date()
        XCTAssertThrowsError(try Converter.convert(input, to: .webm, options: ConversionOptions(), cancellation: token)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [input.lastPathComponent])
    }

    /// A VBR MP3 without its Xing header makes ffprobe guess the length from the bitrate; the timeline must
    /// still get the real length, or the waveform is squeezed and drifts away from what plays.
    func testMP3WithoutVBRHeaderReportsRealDuration() throws {
        let encoded = directory.appendingPathComponent("vbr.mp3")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
            "-i", "aevalsrc='if(lt(mod(t\\,10)\\,0.05)\\,0.9*sin(2*PI*1000*t)\\,0.01*sin(2*PI*220*t))':s=44100:d=61.3",
            "-c:a", "libmp3lame", "-q:a", "2", encoded.path,
        ])
        let bare = directory.appendingPathComponent("bare.mp3")
        try ExternalTool.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y", "-i", encoded.path, "-c", "copy", "-write_xing", "0", bare.path,
        ])
        let duration = try XCTUnwrap(MediaConverter.probe(bare).duration)
        XCTAssertEqual(duration, 61.3, accuracy: 0.05)
    }

    /// Waveform buckets cover every sample, so a sound at 90 % of the file is drawn at 90 % of the timeline.
    func testWaveformPeaksCoverTheWholeLength() {
        var samples = [Float](repeating: 0, count: 10_799)
        samples[9_719] = 1 // 90 % in
        samples[10_798] = 0.5 // the very last sample
        let peaks = MediaTools.peaks(samples, buckets: 1_600)
        XCTAssertEqual(peaks.count, 1_600)
        XCTAssertEqual(peaks.firstIndex(of: 1), 1_440)
        XCTAssertEqual(peaks.last, 0.5)
    }
}
