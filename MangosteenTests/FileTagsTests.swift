import PDFKit
import XCTest

/// Metadata of audio, video and PDF: read, change, clear and remove, always in a copy.
final class FileTagsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func media(_ name: String, _ arguments: [String]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path])
        return url
    }

    func testAudioTagsAreChangedWithoutReencoding() throws {
        let song = try media("song.mp3", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame",
                                          "-metadata", "title=Old", "-metadata", "artist=Someone", "-metadata", "genre=Rock"])
        XCTAssertEqual(try FileTags.read(song)[.title], "Old")
        let output = try FileTags.write(song, changes: [.title: "Новое название", .genre: "", .album: "Альбом"], removeAll: false)
        XCTAssertEqual(output.lastPathComponent, "song (метаданные).mp3")
        let tags = try FileTags.read(output)
        XCTAssertEqual(tags[.title], "Новое название")
        XCTAssertEqual(tags[.artist], "Someone", "untouched fields stay")
        XCTAssertEqual(tags[.album], "Альбом")
        XCTAssertNil(tags[.genre], "an emptied field is cleared")
        XCTAssertEqual(try FileTags.read(song)[.title], "Old", "the original is not changed")

        let bare = try FileTags.write(song, changes: [:], removeAll: true)
        XCTAssertTrue(try FileTags.read(bare).isEmpty)
    }

    func testVideoTagsInMP4() throws {
        let video = try media("clip.mp4", ["-f", "lavfi", "-i", "testsrc=size=160x120:duration=1", "-c:v", "libx264",
                                           "-pix_fmt", "yuv420p"])
        let output = try FileTags.write(video, changes: [.title: "Отпуск", .date: "2026", .comment: "Море"], removeAll: false)
        let tags = try FileTags.read(output)
        XCTAssertEqual(tags[.title], "Отпуск")
        XCTAssertEqual(tags[.date], "2026")
        XCTAssertEqual(tags[.comment], "Море")
        XCTAssertEqual(FileTags.fields(for: .mp4), [.title, .artist, .date, .comment])
    }

    func testPDFProperties() throws {
        let url = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Old"] as CFDictionary)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        XCTAssertEqual(try FileTags.read(url)[.title], "Old")
        let output = try FileTags.write(url, changes: [.title: "Отчёт", .artist: "Отдел", .keywords: "план, итоги"], removeAll: false)
        let tags = try FileTags.read(output)
        XCTAssertEqual(tags[.title], "Отчёт")
        XCTAssertEqual(tags[.artist], "Отдел")
        XCTAssertEqual(tags[.keywords], "план, итоги")
    }
}
