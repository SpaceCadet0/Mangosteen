import AppKit
import XCTest

/// Pictures dragged out of a browser: what counts as one, and how it becomes a file.
final class WebImageDropTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("webdrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
    }

    override func tearDownWithError() throws {
        pasteboard?.releaseGlobally()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func pictureData(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: type, properties: [:]))
    }

    private func receive() throws -> URL {
        let done = expectation(description: "received")
        var result: Result<URL, Error>?
        WebImageDrop.receive(from: pasteboard, into: directory) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    func testPictureDataBecomesAFileThatNeverOverwrites() throws {
        let png = try pictureData(.png)
        pasteboard.setData(png, forType: .png)
        let drop = try XCTUnwrap(WebImageDrop.detect(on: pasteboard))
        XCTAssertEqual(drop.format, .png)
        XCTAssertTrue(WebImageDrop.isPlaceholder(drop.placeholder))
        XCTAssertEqual(FileFormat.detect(drop.placeholder), .png, "the wheel is built for the picture's format")

        let first = try receive()
        XCTAssertEqual(try Data(contentsOf: first), png)
        let second = try receive()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), png, "the first file is untouched")
    }

    func testATIFFRenderingIsSavedAsPNG() throws {
        pasteboard.setData(try pictureData(.tiff), forType: .tiff)
        XCTAssertEqual(WebImageDrop.detect(on: pasteboard)?.format, .png)
        let file = try receive()
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: file).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testLinksTextAndFilesAreNotBrowserPictures() throws {
        pasteboard.setString("https://example.com/picture.jpg", forType: .URL)
        pasteboard.setString("some text", forType: .string)
        XCTAssertNil(WebImageDrop.detect(on: pasteboard), "a link alone is not downloaded")

        pasteboard.clearContents()
        let file = directory.appendingPathComponent("photo.png")
        try pictureData(.png).write(to: file)
        pasteboard.writeObjects([file as NSURL])
        XCTAssertNil(WebImageDrop.detect(on: pasteboard), "files go the usual way")
    }

    /// What Safari and Chrome put on the pasteboard for a dragged picture: a promise to write the file.
    private final class Promiser: NSObject, NSFilePromiseProviderDelegate {
        let data: Data
        init(data: Data) { self.data = data }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "cat.jpg" }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            do {
                try data.write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    /// Only the detection can be tested: macOS lets a promise be received only inside a real drop
    /// (`performDragOperation`), which is where the wheel receives it.
    func testAFilePromiseIsRecognisedByItsType() throws {
        let promiser = Promiser(data: try pictureData(.jpeg))
        pasteboard.writeObjects([NSFilePromiseProvider(fileType: "public.jpeg", delegate: promiser)])
        XCTAssertEqual(WebImageDrop.detect(on: pasteboard)?.format, .jpg)

        pasteboard.clearContents()
        pasteboard.writeObjects([NSFilePromiseProvider(fileType: "com.adobe.pdf", delegate: promiser)])
        XCTAssertNil(WebImageDrop.detect(on: pasteboard), "a promised PDF is not a picture")
    }
}
