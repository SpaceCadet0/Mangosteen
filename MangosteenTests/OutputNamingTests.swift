import XCTest

final class OutputNamingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testUsesPlainNameWhenFree() {
        let url = OutputNaming.uniqueURL(in: directory, baseName: "photo", pathExtension: "png")
        XCTAssertEqual(url.lastPathComponent, "photo.png")
    }

    func testAppendsCounterWhenTaken() throws {
        try Data().write(to: directory.appendingPathComponent("photo.png"))
        try Data().write(to: directory.appendingPathComponent("photo 2.png"))
        let url = OutputNaming.uniqueURL(in: directory, baseName: "photo", pathExtension: "png")
        XCTAssertEqual(url.lastPathComponent, "photo 3.png")
    }

    func testWriteAtomicallyLeavesNoTemporaryFiles() throws {
        let result = try OutputNaming.writeAtomically(directory: directory, baseName: "out", pathExtension: "txt") {
            try Data("hello".utf8).write(to: $0)
        }
        XCTAssertEqual(result.lastPathComponent, "out.txt")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["out.txt"])
    }

    func testWriteAtomicallyCleansUpOnFailure() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try OutputNaming.writeAtomically(directory: directory, baseName: "out", pathExtension: "txt") {
            try Data("partial".utf8).write(to: $0)
            throw Boom()
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testFormatDetectionHandlesAliases() {
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/a/b.JPEG")), .jpg)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/a/b.tif")), .tiff)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/a/b.heif")), .heic)
    }

    func testCatalogOffersFormatsCommonToMixedSelection() {
        let urls = [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.jpg")]
        let targets = FormatCatalog.targets(for: urls)
        XCTAssertTrue(targets.contains(.png))
        XCTAssertTrue(targets.contains(.jpg))
        XCTAssertTrue(targets.contains(.webp))
    }

    func testCatalogExcludesSourceFormatForUniformSelection() {
        let targets = FormatCatalog.targets(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.png")])
        XCTAssertFalse(targets.contains(.png))
        XCTAssertTrue(targets.contains(.jpg))
    }
}
