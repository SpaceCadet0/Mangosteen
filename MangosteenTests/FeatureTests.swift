import AppKit
import PDFKit
import XCTest

/// Background removal, text recognition and the operation history.
final class FeatureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Black text on white, as a scan would look.
    private func textImage(_ lines: [String]) throws -> CGImage {
        let size = NSSize(width: 1400, height: 160 * CGFloat(lines.count) + 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: size.height - 140 - CGFloat(index) * 160), withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .medium), .foregroundColor: NSColor.black,
            ])
        }
        image.unlockFocus()
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    // MARK: Text recognition

    func testRecognizesRussianAndEnglishText() throws {
        let text = try TextRecognizer.recognize(textImage(["Мангостин сочный", "Mangosteen converter"]))
        XCTAssertTrue(text.contains("Мангостин"), text)
        XCTAssertTrue(text.contains("Mangosteen"), text)
    }

    func testScannedPDFBecomesTextFile() throws {
        let document = PDFDocument()
        for (index, words) in [["Page one text"], ["Вторая страница"]].enumerated() {
            let image = NSImage(cgImage: try textImage(words), size: .zero)
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let pdf = directory.appendingPathComponent("scan.pdf")
        XCTAssertTrue(document.write(to: pdf))
        let output = try TextRecognizer.recognizeFile(pdf)
        XCTAssertEqual(output.lastPathComponent, String(localized: "scan (текст)") + ".txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
        XCTAssertTrue(words.contains("page") && words.contains("one"), text)
        XCTAssertTrue(text.contains("страница"), text)
        XCTAssertTrue(text.contains("\u{0C}"), "pages are separated by a page break")
    }

    func testBlankImageHasNoText() throws {
        let url = directory.appendingPathComponent("blank.png")
        try ImageConverter.write(textImage([""]), as: .png, to: url, options: ConversionOptions(), metadata: nil)
        XCTAssertThrowsError(try TextRecognizer.recognizeFile(url)) { error in
            guard case TextRecognizer.Failure.noText = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Background removal

    private var photo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("promo/public/icons/photo-thumb.png")
    }

    private func alphaRange(_ image: CGImage) -> (transparent: Int, opaque: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var transparent = 0, opaque = 0
        for index in stride(from: 3, to: bytes.count, by: 4) {
            if bytes[index] < 10 { transparent += 1 } else if bytes[index] > 245 { opaque += 1 }
        }
        return (transparent, opaque)
    }

    func testRemovesBackgroundFromPhoto() throws {
        let source = try ImageConverter.load(photo).image
        let cutout = try BackgroundRemover.cutout(source, cropToSubject: false)
        XCTAssertEqual(cutout.width, source.width)
        let alpha = alphaRange(cutout)
        XCTAssertGreaterThan(alpha.transparent, source.width * source.height / 10, "background became transparent")
        XCTAssertGreaterThan(alpha.opaque, source.width * source.height / 20, "the subject stayed")

        let filled = try BackgroundRemover.compose(cutout, fill: RGBAColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(alphaRange(filled).transparent, 0)

        let copy = directory.appendingPathComponent("fruit.png")
        try FileManager.default.copyItem(at: photo, to: copy)
        let output = try BackgroundRemover.removeFile(copy, options: .init(), conversion: ConversionOptions())
        XCTAssertEqual(output.lastPathComponent, String(localized: "fruit (без фона)") + ".png")
    }

    // MARK: Archive of a selection

    func testArchiveHoldsOnlyTheSelectedItems() throws {
        let photo = directory.appendingPathComponent("photo.jpg")
        let notes = directory.appendingPathComponent("notes.txt")
        let other = directory.appendingPathComponent("other.txt")
        for url in [photo, notes, other] { try Data(url.lastPathComponent.utf8).write(to: url) }

        let archive = try ArchiveConverter.archiveSelection([photo, notes])
        XCTAssertEqual(archive.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(archive.lastPathComponent, directory.lastPathComponent + ".zip")

        let listing = Process()
        let pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        listing.arguments = ["-1", archive.path]
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX/") }
        XCTAssertEqual(Set(names), ["photo.jpg", "notes.txt"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".mangosteen") }
        XCTAssertTrue(leftovers.isEmpty, "the staging folder is removed")
    }

    // MARK: History

    func testHistoryKeepsRecentExistingResults() throws {
        let suite = "dev.mangosteen.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = OperationHistory(defaults: defaults)
        let kept = directory.appendingPathComponent("kept.txt")
        let gone = directory.appendingPathComponent("gone.txt")
        try Data("a".utf8).write(to: kept)
        history.record("Convert", outputs: [kept, gone])
        history.record("Nothing", outputs: [])
        for index in 0..<25 { history.record("Op \(index)", outputs: [gone]) }
        XCTAssertEqual(history.entries.count, OperationHistory.limit)

        history.record("Convert", outputs: [kept, gone])
        let current = history.current()
        XCTAssertEqual(current.count, 1, "entries without files disappear")
        XCTAssertEqual(current.first?.outputs, [kept])
        XCTAssertEqual(OperationHistory(defaults: defaults).entries.first?.title, "Convert", "saved across launches")

        history.clear()
        XCTAssertTrue(history.current().isEmpty)
    }
}
