import PDFKit
import XCTest

final class DocumentConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func convert(_ url: URL, _ target: FileFormat) throws -> URL {
        try XCTUnwrap(Converter.convert(url, to: target, options: ConversionOptions()))
    }

    // MARK: Documents

    func testMarkdownConvertsToEveryDocumentFormat() throws {
        let input = try file("notes.md", "# Заголовок\n\nТекст с **жирным** и *курсивом*.\n\n- один\n- два\n")
        for target in FormatCatalog.targets(for: .md) {
            let output = try convert(input, target)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(target)")
        }
        let text = try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Заголовок"))
        XCTAssertTrue(text.contains("жирным"))
    }

    func testDocxRoundTripKeepsText() throws {
        let input = try file("letter.txt", "Привет, мир!\nВторая строка.")
        let docx = try convert(input, .docx)
        let back = try DocumentConverter.read(docx, as: .docx)
        XCTAssertTrue(back.string.contains("Привет, мир!"))
        XCTAssertTrue(back.string.contains("Вторая строка."))
    }

    func testLongTextPaginatesIntoSeveralPDFPages() throws {
        let line = "Строка текста для проверки разбиения на страницы.\n"
        let input = try file("long.txt", String(repeating: line, count: 400))
        let pdf = try convert(input, .pdf)
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: pdf)).pageCount, 3)
    }

    func testMarkdownInlineFormatting() {
        XCTAssertEqual(Markdown.inline("a **b** *c* `d` [e](f)"),
                       "a <strong>b</strong> <em>c</em> <code>d</code> <a href=\"f\">e</a>")
        XCTAssertEqual(Markdown.inline("<x> & y"), "&lt;x&gt; &amp; y")
    }

    // MARK: PDF

    private func makePDF(pages: Int) throws -> URL {
        let text = (1...pages).map { "Страница \($0)" }.joined(separator: String(repeating: "\n", count: 80))
        return try convert(try file("source.txt", text), .pdf)
    }

    func testPDFPagesBecomeFolderOfImages() throws {
        let pdf = try makePDF(pages: 3)
        let pageCount = try XCTUnwrap(PDFDocument(url: pdf)).pageCount
        XCTAssertGreaterThan(pageCount, 1)
        let folder = try convert(pdf, .png)
        XCTAssertEqual(folder.lastPathComponent, "source (PNG)")
        let images = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(images.count, pageCount)
        XCTAssertTrue(images[0].hasPrefix("source 1"))
    }

    func testSinglePagePDFBecomesOneImageAt300DPI() throws {
        let pdf = try makePDF(pages: 1)
        let png = try convert(pdf, .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int((DocumentConverter.pageSize.width * 300 / 72).rounded()))
    }

    func testPDFTextLayerExports() throws {
        let pdf = try makePDF(pages: 1)
        let text = try String(contentsOf: convert(pdf, .txt), encoding: .utf8)
        XCTAssertTrue(text.contains("Страница 1"))
    }

    // MARK: Subtitles, tables, archives

    func testSubtitlesRoundTrip() throws {
        let srt = "1\n00:00:01,500 --> 00:00:03,000\n<i>Привет</i>\n\n2\n00:01:02,000 --> 00:01:04,250\nМир\n"
        let input = try file("movie.srt", srt)
        let vtt = try String(contentsOf: convert(input, .vtt), encoding: .utf8)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:01:02.000 --> 00:01:04.250"))
        let cues = SubtitleConverter.parse(vtt)
        XCTAssertEqual(cues, SubtitleConverter.parse(srt))
        let text = try String(contentsOf: convert(input, .txt), encoding: .utf8)
        XCTAssertEqual(text, "Привет\nМир\n")
    }

    func testCSVToTSVHandlesQuotes() throws {
        let input = try file("table.csv", "name,note\n\"Smith, J\",\"said \"\"hi\"\"\"\nplain,\"multi\nline\"\n")
        let rows = TableConverter.parse(try String(contentsOf: convert(input, .tsv), encoding: .utf8), separator: "\t")
        XCTAssertEqual(rows, [["name", "note"], ["Smith, J", "said \"hi\""], ["plain", "multi\nline"]])
    }

    func testFolderZipsAndArchivesRepack() throws {
        let folder = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let zip = try convert(folder, .zip)
        XCTAssertEqual(zip.lastPathComponent, "Photos.zip")
        let tgz = try convert(zip, .tgz)
        XCTAssertEqual(tgz.lastPathComponent, "Photos.tar.gz")
        XCTAssertEqual(FileFormat.detect(tgz), .tgz)

        try FileManager.default.removeItem(at: folder)
        let extracted = try ArchiveConverter.extractNextToArchive(tgz)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Photos/a.txt").path))
    }

    func testSVGRastersAndKeepsVectorsInPDF() throws {
        let svg = try file("logo.svg", #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="50" height="50" fill="red"/></svg>"#)
        let png = try convert(svg, .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(ImageConverter.svgMinimumPixelSize))
        XCTAssertEqual(image.height, Int(ImageConverter.svgMinimumPixelSize) / 2)
        let pdf = try convert(svg, .pdf)
        XCTAssertEqual(PDFDocument(url: pdf)?.page(at: 0)?.bounds(for: .mediaBox).width, 100)
    }
}
