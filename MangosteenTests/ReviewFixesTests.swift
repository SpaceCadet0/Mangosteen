import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

/// Regression tests for the fixes from the code and security review.
final class ReviewFixesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: ZIP limits

    /// Rewrites the uncompressed size of the named entry in the central directory.
    private func claimingSize(_ size: UInt32, for name: String, in archive: Data) -> Data {
        var bytes = [UInt8](archive)
        var index = 0
        while index + 46 <= bytes.count {
            let signature = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            if signature == 0x0201_4B50 {
                let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
                let entryName = String(decoding: bytes[(index + 46)..<(index + 46 + nameLength)], as: UTF8.self)
                if entryName == name {
                    for k in 0..<4 { bytes[index + 24 + k] = UInt8((size >> (8 * UInt32(k))) & 0xFF) }
                }
            }
            index += 1
        }
        return Data(bytes)
    }

    func testZipRefusesEntriesClaimingHugeSizes() throws {
        let archive = claimingSize(0xF000_0000, for: "bomb.xml",
                                   in: ZipArchive.write([("bomb.xml", Data(repeating: 65, count: 5000)), ("ok.txt", Data("ok".utf8))]))
        let reader = try ZipArchive.Reader(archive)
        XCTAssertEqual(try reader.data("ok.txt"), Data("ok".utf8))
        XCTAssertThrowsError(try reader.data("bomb.xml")) { error in
            guard case ZipArchive.Failure.tooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ZipArchive.read(archive))
    }

    func testWorkbookIgnoresPartsItDoesNotNeed() throws {
        let workbook = try ZipArchive.read(XLSX.write(rows: [["a", "1"]], sheetName: "S"))
        var entries = workbook.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        entries.append(("xl/media/huge.png", Data(repeating: 0, count: 4000)))
        let url = directory.appendingPathComponent("book.xlsx")
        try claimingSize(0xF000_0000, for: "xl/media/huge.png", in: ZipArchive.write(entries)).write(to: url)
        XCTAssertEqual(try XLSX.read(url).first?.rows, [["a", "1"]])
    }

    // MARK: XLSX dates in the 1900 system

    func testDatesAroundFictitiousLeapDay() {
        XCTAssertEqual(XLSX.dateText(serial: 1, date1904: false), "1900-01-01")
        XCTAssertEqual(XLSX.dateText(serial: 15, date1904: false), "1900-01-15")
        XCTAssertEqual(XLSX.dateText(serial: 59.5, date1904: false), "1900-02-28 12:00:00")
        XCTAssertEqual(XLSX.dateText(serial: 60, date1904: false), "1900-02-29")
        XCTAssertEqual(XLSX.dateText(serial: 61, date1904: false), "1900-03-01")
        XCTAssertEqual(XLSX.dateText(serial: 45000, date1904: false), "2023-03-15")
    }

    // MARK: Offline HTML

    func testHTMLLosesRemoteAndOutsideResources() {
        let folder = URL(fileURLWithPath: "/Users/me/Docs")
        let html = """
        <html><head><base href="http://evil/"><link rel="stylesheet" href="http://evil/s.css"><link rel="stylesheet" href="local.css">
        <meta http-equiv="refresh" content="0;url=http://evil"><style>@import url("http://evil/i.css"); p{background:url('http://evil/bg.png')} h1{background:url(pic.png)}</style></head>
        <body><a href="https://example.com">link</a>
        <img src="http://evil/pixel.gif"><img src='file:///etc/hosts'><img src="../secret.png"><img src="/abs.png"><img src=//evil/x.png>
        <img src="photos/ok.png"><img src="data:image/png;base64,AAAA"><img srcset="http://evil/a.png 1x, photos/b.png 2x"></body></html>
        """
        let clean = DocumentConverter.offlineHTML(html, folder: folder)
        for gone in ["evil/pixel", "/etc/hosts", "../secret.png", "/abs.png", "//evil/x.png", "<base", "refresh", "evil/s.css",
                     "evil/i.css", "evil/bg.png", "evil/a.png"] {
            XCTAssertFalse(clean.contains(gone), "still contains \(gone)")
        }
        for kept in ["https://example.com", "photos/ok.png", "data:image/png;base64,AAAA", "photos/b.png 2x", "local.css", "url(pic.png)"] {
            XCTAssertTrue(clean.contains(kept), "lost \(kept)")
        }
    }

    // MARK: Lossless turns

    private func image(bits: Int, space: CGColorSpace, alpha: CGImageAlphaInfo) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: bits, bytesPerRow: 0,
                                              space: space, bitmapInfo: alpha.rawValue))
        context.setFillColor(space.model == .cmyk ? CGColor(genericCMYKCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1)
                                                  : CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 4))
        return try XCTUnwrap(context.makeImage())
    }

    func testTurningKeepsDepthAndColourSpace() throws {
        var transform = ImageCropper.Transform()
        transform.rotate(clockwise: true)
        let cases: [(CGImage, Int, CGColorSpaceModel)] = [
            (try image(bits: 16, space: CGColorSpace(name: CGColorSpace.displayP3)!, alpha: .premultipliedLast), 16, .rgb),
            (try image(bits: 8, space: CGColorSpaceCreateDeviceCMYK(), alpha: .none), 8, .cmyk),
            (try image(bits: 8, space: CGColorSpaceCreateDeviceGray(), alpha: .none), 8, .monochrome),
        ]
        for (source, bits, model) in cases {
            let turned = try ImageCropper.apply(transform, to: source)
            XCTAssertEqual(turned.width, 4)
            XCTAssertEqual(turned.height, 6)
            XCTAssertEqual(turned.bitsPerComponent, bits)
            XCTAssertEqual(turned.colorSpace?.model, model)
        }
        let p3 = try image(bits: 16, space: CGColorSpace(name: CGColorSpace.displayP3)!, alpha: .premultipliedLast)
        XCTAssertEqual(try ImageCropper.apply(transform, to: p3).colorSpace?.name, CGColorSpace.displayP3)
    }

    // MARK: Small fixes

    func testPartNumbersArePadded() {
        XCTAssertEqual(OutputNaming.partNumber(0, of: 9), "1")
        XCTAssertEqual(OutputNaming.partNumber(2, of: 12), "03")
        XCTAssertEqual(OutputNaming.partNumber(99, of: 100), "100")
    }

    func testSplittingLockedPDFSaysItIsLocked() throws {
        let document = PDFDocument()
        let page = NSImage(size: NSSize(width: 100, height: 100))
        page.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); page.unlockFocus()
        document.insert(PDFPage(image: page)!, at: 0)
        document.insert(PDFPage(image: page)!, at: 1)
        let url = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        XCTAssertThrowsError(try PDFSplitter.split(url, cuts: [0], excluded: [])) { error in
            guard case PDFToolError.locked = error else { return XCTFail("\(error)") }
        }
    }
}
