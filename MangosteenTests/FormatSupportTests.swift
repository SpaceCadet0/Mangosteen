import XCTest

/// Formats added in 0.10.5: archives read by the system tar, a single gzipped file, camera RAW and JPEG XL,
/// and video and audio containers read through ffmpeg.
final class FormatSupportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Detection

    func testDetectsNewFormatsByName() throws {
        let expected: [String: FileFormat] = [
            "a.7z": .sevenZip, "a.rar": .rar, "a.iso": .iso,
            "a.tar.xz": .txz, "a.txz": .txz, "a.tar.bz2": .tbz, "a.tbz2": .tbz, "a.tbz": .tbz,
            "a.tar.gz": .tgz, "a.tgz": .tgz, "notes.txt.gz": .gz,
            "a.flv": .flv, "a.mpeg": .mpg, "a.mpg": .mpg, "a.vob": .vob, "a.3gp": .threeGP, "a.ogv": .ogv,
            "a.ape": .ape, "a.wv": .wv, "a.amr": .amr, "a.ac3": .ac3, "a.dts": .dts,
        ]
        for (name, format) in expected {
            XCTAssertEqual(FileFormat.detect(directory.appendingPathComponent(name)), format, name)
        }
        XCTAssertEqual(FileFormat.detect(directory.appendingPathComponent("IMG_0001.CR2")), .raw)
        XCTAssertEqual(FileFormat.detect(directory.appendingPathComponent("photo.dng")), .raw)
        XCTAssertEqual(FileFormat.detect(directory.appendingPathComponent("photo.jxl")), .jxl)
    }

    func testTypeScriptSourcesAreNotVideo() throws {
        XCTAssertNil(FileFormat.detect(try file("index.ts", "export const a: number = 1;\n")))
        XCTAssertNil(FileFormat.detect(try file("module.mts", "export default {};\n")))
        XCTAssertNil(FileFormat.detect(try file("empty.ts", "")))
    }

    func testReadOnlyFormatsOfferWritableTargets() {
        XCTAssertEqual(FormatCatalog.targets(for: [directory.appendingPathComponent("a.7z")]), [.zip, .tar, .tgz, .iso])
        XCTAssertEqual(FormatCatalog.targets(for: [directory.appendingPathComponent("a.CR2")]), FormatCatalog.imageOutputs)
        XCTAssertEqual(FormatCatalog.targets(for: [directory.appendingPathComponent("a.flv")]), FormatCatalog.videoOutputs)
        XCTAssertEqual(FormatCatalog.targets(for: [directory.appendingPathComponent("a.ape")]), FormatCatalog.audioOutputs)

        XCTAssertEqual(FormatCatalog.editedFormat(for: .raw), .heic, "RAW edits are saved as HEIC")
        XCTAssertEqual(FormatCatalog.editedFormat(for: .jxl), .heic)
        XCTAssertEqual(FormatCatalog.editedFormat(for: .jpg), .jpg)
        XCTAssertEqual(FormatCatalog.editedFormat(for: .svg), .png)

        XCTAssertTrue(FileFormat.jpg.canRewriteImageMetadata)
        XCTAssertFalse(FileFormat.raw.canRewriteImageMetadata, "ImageIO cannot write RAW")
        XCTAssertFalse(FileFormat.jxl.canRewriteImageMetadata)
        XCTAssertFalse(FileFormat.svg.canRewriteImageMetadata)

        XCTAssertEqual(MediaTools.outputFormat(for: .vob), .mp4)
        XCTAssertEqual(MediaTools.outputFormat(for: .ape), .flac, "lossless stays lossless")
        XCTAssertEqual(MediaTools.outputFormat(for: .ac3), .m4a)
        XCTAssertFalse(MediaTools.canCopyStreams(from: .flv, to: .mp4))
        XCTAssertTrue(MediaTools.canCopyStreams(from: .m4v, to: .mp4))
    }

    // MARK: Archives

    /// A folder with a file and a sub folder, packed the way real tools pack it.
    private func source() throws -> URL {
        let folder = directory.appendingPathComponent("src")
        _ = try file("src/a.txt", "hello")
        _ = try file("src/sub/b.txt", "deep")
        return folder
    }

    private func assertExtracted(_ folder: URL, file line: UInt = #line) throws {
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "hello", line: line)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("sub/b.txt"), encoding: .utf8), "deep", line: line)
    }

    func testExtractsArchivesTheSystemTarReads() throws {
        let folder = try source()
        let archives: [(String, [String])] = [
            ("pack.7z", ["--format", "7zip", "--options", "7zip:compression=lzma2", "-cf"]),
            ("pack.tar.xz", ["-cJf"]),
            ("pack.tar.bz2", ["-cjf"]),
        ]
        for (name, options) in archives {
            let archive = directory.appendingPathComponent(name)
            try ExternalTool.run(ArchiveConverter.tar, options + [archive.path, "-C", folder.path, "."])
            try assertExtracted(ArchiveConverter.extractNextToArchive(archive))
        }

        let iso = directory.appendingPathComponent("disc.iso")
        try ExternalTool.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", iso.path, folder.path])
        try assertExtracted(ArchiveConverter.extractNextToArchive(iso))

        // Repacking goes through the same extraction.
        let zip = try XCTUnwrap(Converter.convert(directory.appendingPathComponent("pack.7z"), to: .zip, options: ConversionOptions()))
        let unzipped = directory.appendingPathComponent("unzipped")
        try ExternalTool.run("ditto", ["-x", "-k", zip.path, unzipped.path])
        try assertExtracted(unzipped)
    }

    func testUDFOnlyDiscImageSaysSoInsteadOfExtractingNothing() throws {
        let iso = directory.appendingPathComponent("windows.iso")
        try ExternalTool.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-udf", "-o", iso.path, source().path])
        XCTAssertThrowsError(try ArchiveConverter.extractNextToArchive(iso)) { error in
            guard case ArchiveError.nothingExtracted = error else { return XCTFail("\(error)") }
        }

        // An empty archive of another kind says it is empty, not that it is a UDF disc.
        let empty = directory.appendingPathComponent("empty.7z")
        let nothing = directory.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(at: nothing, withIntermediateDirectories: true)
        try ExternalTool.run(ArchiveConverter.tar, ["--format", "7zip", "-cf", empty.path, "-C", nothing.path, "."])
        XCTAssertThrowsError(try ArchiveConverter.extractNextToArchive(empty)) { error in
            guard case ArchiveError.empty = error else { return XCTFail("\(error)") }
        }
    }

    func testSingleGzippedFileBecomesThatFile() throws {
        let original = try file("notes.txt", "plain text inside")
        try ExternalTool.run("/usr/bin/gzip", ["-k", original.path])
        let gz = directory.appendingPathComponent("notes.txt.gz")
        XCTAssertEqual(FileFormat.detect(gz), .gz)

        let output = try ArchiveConverter.extractNextToArchive(gz)
        XCTAssertEqual(output.lastPathComponent, "notes 2.txt", "the original's name is taken, so a number goes before the extension")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "plain text inside")

        let zip = try XCTUnwrap(Converter.convert(gz, to: .zip, options: ConversionOptions()))
        let unzipped = directory.appendingPathComponent("unzipped")
        try ExternalTool.run("ditto", ["-x", "-k", zip.path, unzipped.path])
        XCTAssertEqual(try String(contentsOf: unzipped.appendingPathComponent("notes.txt"), encoding: .utf8), "plain text inside")
    }

    // MARK: Video and audio

    private func makeMedia(_ name: String, _ arguments: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                                        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2",
                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-shortest"]
                                + arguments + [url.path])
        return url
    }

    private func makeAudio(_ name: String, _ arguments: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ac", "2"]
                                + arguments + [url.path])
        return url
    }

    func testReadOnlyVideoConvertsAndWorksInTools() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let clips = [
            try makeMedia("flash.flv", ["-c:v", "flv1", "-c:a", "libmp3lame", "-ar", "44100"]),
            try makeMedia("program.mpg", ["-c:v", "mpeg1video", "-c:a", "mp2"]),
            try makeMedia("dvd.vob", ["-c:v", "mpeg2video", "-c:a", "ac3", "-f", "vob"]),
            try makeMedia("phone.3gp", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "16000"]),
            try makeMedia("broadcast.ts", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
        ]
        for clip in clips {
            let name = clip.lastPathComponent
            XCTAssertEqual(FileFormat.detect(clip)?.category, .video, name)
            let mp4 = try XCTUnwrap(Converter.convert(clip, to: .mp4, options: ConversionOptions()), name)
            XCTAssertTrue(try MediaConverter.probe(mp4).hasVideo, name)
        }
        XCTAssertEqual(FileFormat.detect(clips[4]), .ts, "a real transport stream is still video")

        // The first frame of an FLV is the real picture (seeking it to 0 used to give a nearly black, broken one):
        // the test pattern's first frame averages about half brightness.
        let first = try MediaTools.frame(clips[0], at: 0)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .medium
        context.draw(first, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]), 200, "average colour of the first FLV frame")

        // Trimming saves MP4 and re-encodes, since FLV streams cannot be copied into MP4.
        let trimmed = try MediaTools.trim(clips[0], start: 0.5, end: 1.5, fast: true)
        XCTAssertEqual(trimmed.pathExtension, "mp4")
        XCTAssertEqual(try MediaConverter.probe(trimmed).duration ?? 0, 1, accuracy: 0.2)

        // Sound tools copy the picture only where the container allows it.
        let louder = try AudioTools.normalize(clips[0], target: AudioTools.LoudnessTarget())
        XCTAssertEqual(louder.pathExtension, "mp4")
        XCTAssertTrue(try MediaConverter.probe(louder).hasVideo)

        // Hiding areas re-encodes the AC-3 sound of a VOB for MP4.
        let region = VideoRedactor.Region(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), start: 0, end: 2)
        let hidden = try VideoRedactor.redact(clips[2], regions: [region], style: .solid, color: .white)
        XCTAssertEqual(try MediaConverter.probe(hidden).audioCodec, "aac")
    }

    func testReadOnlyAudioConvertsAndTrimsLosslessToFLAC() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let wavpack = try makeAudio("song.wv", ["-c:a", "wavpack"])
        let ac3 = try makeAudio("film.ac3", ["-c:a", "ac3"])
        for source in [wavpack, ac3] {
            XCTAssertEqual(FileFormat.detect(source)?.category, .audio)
            let mp3 = try XCTUnwrap(Converter.convert(source, to: .mp3, options: ConversionOptions()))
            XCTAssertEqual(try MediaConverter.probe(mp3).audioCodec, "mp3")
        }
        let trimmed = try MediaTools.trim(wavpack, start: 0.5, end: 1.5, fast: false)
        XCTAssertEqual(trimmed.pathExtension, "flac", "WavPack has no encoder target here; it stays lossless as FLAC")
        XCTAssertEqual(try MediaConverter.probe(trimmed).audioCodec, "flac")
        XCTAssertEqual(try MediaTools.trim(ac3, start: 0, end: 1, fast: false).pathExtension, "m4a")
    }
}
