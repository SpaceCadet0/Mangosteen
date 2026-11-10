import XCTest

/// 0.10.7: ASS/SSA subtitles, subtitles taken out of videos, and JSON ↔ tables.
final class SubtitlesJSONTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("subjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello, <i>world</i>

    2
    00:00:03,000 --> 00:00:04,000
    Second line
    and a third

    """

    // MARK: ASS

    func testParsesASSFieldsByTheirFormatLine() {
        let ass = """
        [Script Info]
        Title: test

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,not shown
        Dialogue: 0,0:00:01.50,0:00:03.25,Default,Ann,0,0,0,,Hi, {\\i1}there{\\i0}, friend\\Nsecond line
        Dialogue: 0,0:01:02.00,0:01:04.00,Default,,0,0,0,,{\\pos(10,10)\\b1}Bold{\\b0} move
        """
        let cues = SubtitleConverter.parseASS(ass)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SubtitleConverter.Cue(start: 1.5, end: 3.25, text: "Hi, <i>there</i>, friend\nsecond line"))
        XCTAssertEqual(cues[1].start, 62)
        XCTAssertEqual(cues[1].text, "<b>Bold</b> move", "other override tags are dropped")

        // Old SSA names its first field "Marked"; the order still comes from the Format line.
        let ssa = "[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            + "Dialogue: Marked=0,0:00:05.00,0:00:06.00,Default,,0000,0000,0000,,Old style"
        XCTAssertEqual(SubtitleConverter.parseASS(ssa), [SubtitleConverter.Cue(start: 5, end: 6, text: "Old style")])
        XCTAssertEqual(SubtitleConverter.assTime(3725.37), "1:02:05.37")
    }

    func testASSRoundTripsAndFFmpegAgrees() throws {
        let source = try write("talk.srt", srt)
        let ass = try XCTUnwrap(Converter.convert(source, to: .ass, options: ConversionOptions()))
        XCTAssertEqual(FileFormat.detect(ass), .ass)
        let back = try XCTUnwrap(Converter.convert(ass, to: .srt, options: ConversionOptions()))
        XCTAssertEqual(SubtitleConverter.parse(try String(contentsOf: back, encoding: .utf8)), SubtitleConverter.parse(srt))

        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg"), "ffmpeg is not installed")
        // ffmpeg reads our ASS…
        let viaFFmpeg = directory.appendingPathComponent("ffmpeg.srt")
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", ass.path, viaFFmpeg.path])
        let fromOurs = SubtitleConverter.parse(try String(contentsOf: viaFFmpeg, encoding: .utf8))
        XCTAssertEqual(fromOurs.map(\.start), [1, 3])
        XCTAssertEqual(fromOurs.map(\.end), [2.5, 4])
        // …and we read ffmpeg's.
        let theirs = directory.appendingPathComponent("theirs.ass")
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path, theirs.path])
        let cues = SubtitleConverter.parseASS(try String(contentsOf: theirs, encoding: .utf8))
        XCTAssertEqual(cues.map(\.start), [1, 3])
        XCTAssertEqual(cues[1].text, "Second line\nand a third")
        XCTAssertEqual(cues[0].text, "Hello, <i>world</i>")
    }

    // MARK: Subtitles from video

    private func video(_ name: String, subtitles: [(URL, String)], codec: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var arguments = ["-hide_banner", "-loglevel", "error", "-y",
                         "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=5"]
        for (file, _) in subtitles { arguments += ["-i", file.path] }
        arguments += ["-map", "0:v"]
        for index in subtitles.indices { arguments += ["-map", "\(index + 1):s"] }
        for (index, (_, language)) in subtitles.enumerated() { arguments += ["-metadata:s:s:\(index)", "language=\(language)"] }
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", codec, url.path]
        try ExternalTool.run("ffmpeg", arguments)
        return url
    }

    func testTakesTextSubtitlesOutOfVideos() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("ffmpeg") && ExternalTool.isAvailable("ffprobe"), "ffmpeg is not installed")
        let english = try write("en.srt", srt)
        let russian = try write("ru.srt", srt.replacingOccurrences(of: "Second line", with: "Вторая строка"))

        let mkv = try video("film.mkv", subtitles: [(english, "eng")], codec: "srt")
        let single = try MediaTools.extractSubtitles(mkv)
        XCTAssertEqual(single.lastPathComponent, "film (субтитры).srt")
        XCTAssertEqual(SubtitleConverter.parse(try String(contentsOf: single, encoding: .utf8)).count, 2)

        let mp4 = try video("clip.mp4", subtitles: [(english, "eng"), (russian, "rus")], codec: "mov_text")
        XCTAssertEqual(try MediaConverter.probe(mp4).subtitles.map(\.codec), ["mov_text", "mov_text"])
        let folder = try MediaTools.extractSubtitles(mp4)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["clip 1 eng.srt", "clip 2 rus.srt"])
        let second = try String(contentsOf: folder.appendingPathComponent("clip 2 rus.srt"), encoding: .utf8)
        XCTAssertTrue(second.contains("Вторая строка"))

        let silent = try video("plain.mp4", subtitles: [], codec: "mov_text")
        XCTAssertThrowsError(try MediaTools.extractSubtitles(silent)) { error in
            guard case MediaTools.SubtitleError.none = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(MediaInfo.SubtitleTrack(index: 2, codec: "dvd_subtitle").isText)
        XCTAssertFalse(MediaInfo.SubtitleTrack(index: 2, codec: "hdmv_pgs_subtitle").isText)
    }

    // MARK: JSON

    func testJSONBecomesRowsInTheFilesOwnOrder() throws {
        let text = """
        [
          {"name": "Чай", "zeta": 1.50, "alpha": true, "code": "007", "size": {"w": 10, "h": 20}, "tags": ["a", "b"]},
          {"name": "Кофе \\"Арабика\\" \\u2615", "zeta": 12345678901234567890, "alpha": null, "extra": "only here"}
        ]
        """
        let rows = try JSONTable.rows(from: text)
        XCTAssertEqual(rows[0], ["name", "zeta", "alpha", "code", "size.w", "size.h", "tags", "extra"])
        XCTAssertEqual(rows[1], ["Чай", "1.50", "true", "007", "10", "20", "[\"a\",\"b\"]", ""])
        XCTAssertEqual(rows[2], ["Кофе \"Арабика\" ☕", "12345678901234567890", "", "", "", "", "", "only here"])

        XCTAssertEqual(try JSONTable.rows(from: "[[\"a\", 1], [\"b\", 2]]"), [["a", "1"], ["b", "2"]])
        XCTAssertThrowsError(try JSONTable.rows(from: "{\"items\": []}")) { error in
            guard case JSONTableError.notTable = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try JSONTable.rows(from: "[{\"a\": 1,}]")) { error in
            guard case JSONTableError.malformed = error else { return XCTFail("\(error)") }
        }
    }

    func testTablesBecomeFlatJSONAndBack() throws {
        let csv = try write("prices.csv", "name;price;code;in stock\nЧай;1.5;007;true\nКофе;12;;false\n")
        let json = try XCTUnwrap(Converter.convert(csv, to: .json, options: ConversionOptions()))
        let text = try String(contentsOf: json, encoding: .utf8)
        XCTAssertTrue(text.contains("\"price\": 1.5"), text)
        XCTAssertTrue(text.contains("\"code\": \"007\""), "an ID keeps its zeros as text")
        XCTAssertTrue(text.contains("\"in stock\": true"))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2)

        let back = try XCTUnwrap(Converter.convert(json, to: .csv, options: ConversionOptions()))
        XCTAssertEqual(TableConverter.parse(try String(contentsOf: back, encoding: .utf8), separator: ","),
                       [["name", "price", "code", "in stock"], ["Чай", "1.5", "007", "true"], ["Кофе", "12", "", "false"]])

        XCTAssertEqual(FormatCatalog.targets(for: [json]), [.csv, .tsv, .xlsx])
        XCTAssertEqual(FormatCatalog.targets(for: [directory.appendingPathComponent("a.ass")]), [.srt, .vtt, .txt])
        XCTAssertEqual(FileFormat.detect(directory.appendingPathComponent("old.ssa")), .ass)
    }
}
