import AVFoundation
import PDFKit
import XCTest

/// Small tools: page ranges typed as text, several PDF pages on a sheet, black bars, HDR → SDR and Live Photo video.
final class SmallToolsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("small-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: PDF

    func testPageRangesTypedAsText() throws {
        let selection = try XCTUnwrap(PDFSplitter.selection(fromRanges: "1-3, 8, 12-", pageCount: 14))
        XCTAssertEqual(PDFSplitter.groups(pageCount: 14, cuts: selection.cuts, excluded: selection.excluded),
                       [[0, 1, 2], [7], [11, 12, 13]])
        let dashes = try XCTUnwrap(PDFSplitter.selection(fromRanges: "–2; 3–4", pageCount: 5))
        XCTAssertEqual(PDFSplitter.groups(pageCount: 5, cuts: dashes.cuts, excluded: dashes.excluded), [[0, 1], [2, 3]])
        XCTAssertNil(PDFSplitter.selection(fromRanges: "3-1", pageCount: 5), "backwards")
        XCTAssertNil(PDFSplitter.selection(fromRanges: "1-3, 2", pageCount: 5), "overlapping")
        XCTAssertNil(PDFSplitter.selection(fromRanges: "9", pageCount: 5), "past the end")
        XCTAssertNil(PDFSplitter.selection(fromRanges: "abc", pageCount: 5))
    }

    private func pdf(pages: Int) throws -> URL {
        let url = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for number in 1...pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Page\(number)marker", attributes: [.font: NSFont.systemFont(ofSize: 40)])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: 80, y: 400))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testSeveralPagesGoOnASheetAndStayText() throws {
        let source = try pdf(pages: 5)
        let four = try PDFLayout.pagesPerSheet(source, perSheet: 4)
        let document = try XCTUnwrap(PDFDocument(url: four))
        XCTAssertEqual(document.pageCount, 2)
        let size = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, 595, accuracy: 1)
        XCTAssertEqual(size.height, 842, accuracy: 1)
        let text = document.string ?? ""
        for number in 1...5 { XCTAssertTrue(text.contains("Page\(number)marker"), "page \(number) is still text") }
        XCTAssertEqual(four.lastPathComponent, "doc (4 на листе).pdf")

        let two = try XCTUnwrap(PDFDocument(url: PDFLayout.pagesPerSheet(source, perSheet: 2)))
        XCTAssertEqual(two.pageCount, 3)
        let landscape = try XCTUnwrap(two.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertGreaterThan(landscape.width, landscape.height, "two pages side by side need a landscape sheet")
    }

    // MARK: Video

    private func ffmpeg(_ arguments: [String], output name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try ExternalTool.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path])
        return url
    }

    func testBlackBarsAreFoundAndCut() throws {
        let video = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25:duration=6",
                                "-vf", "pad=320:240:0:30:black", "-c:v", "libx264", "-pix_fmt", "yuv420p"], output: "bars.mp4")
        let crop = try XCTUnwrap(VideoFixes.blackBarsCrop(video))
        XCTAssertEqual(crop.width, 320, accuracy: 4)
        XCTAssertEqual(crop.height, 180, accuracy: 4)
        XCTAssertEqual(crop.minY, 30, accuracy: 4)
        let output = try VideoFixes.removeBlackBars(video)
        let info = try MediaConverter.probe(output)
        XCTAssertEqual(info.height ?? 0, 180, accuracy: 4)
        XCTAssertEqual(output.lastPathComponent, "bars (без полос).mp4")

        let clean = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=3", "-c:v", "libx264",
                                "-pix_fmt", "yuv420p"], output: "clean.mp4")
        XCTAssertNil(try VideoFixes.blackBarsCrop(clean))
        XCTAssertThrowsError(try VideoFixes.removeBlackBars(clean))
    }

    func testHDRVideoBecomesSDR() throws {
        let hdr = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=1",
                              "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
                              "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                              "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"],
                             output: "hdr.mov")
        let output = try VideoFixes.hdrToSDR(hdr)
        let probe = try ExternalTool.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                     "stream=color_transfer,pix_fmt", "-of", "default=nw=1", output.path])
        XCTAssertFalse(probe.contains("smpte2084"), probe)
        XCTAssertTrue(probe.contains("pix_fmt=yuv420p\n") || probe.hasSuffix("pix_fmt=yuv420p"), probe)
        XCTAssertEqual(output.lastPathComponent, "hdr (SDR).mp4")

        let sdr = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=1", "-c:v", "libx264",
                              "-pix_fmt", "yuv420p"], output: "sdr.mp4")
        XCTAssertThrowsError(try VideoFixes.hdrToSDR(sdr))
    }

    func testLivePhotoVideoIsSavedFromTheMovieBesideThePicture() throws {
        let picture = folder.appendingPathComponent("IMG_0001.HEIC")
        try Data([0]).write(to: picture)
        XCTAssertNil(VideoFixes.livePhotoMovie(for: picture))
        _ = try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=1", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p"], output: "IMG_0001.MOV")
        XCTAssertNotNil(VideoFixes.livePhotoMovie(for: picture))
        let video = try VideoFixes.livePhotoVideo(picture)
        XCTAssertEqual(video.lastPathComponent, "IMG_0001 (Live).mp4")
        XCTAssertEqual(try MediaConverter.probe(video).width, 320)
    }
}
