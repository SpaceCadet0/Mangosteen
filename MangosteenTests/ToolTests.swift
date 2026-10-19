import ImageIO
import XCTest

final class ToolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A noisy 1200×800 JPEG at maximum quality, so compression has something to remove.
    private func makePhoto(width: Int = 1200, height: Int = 800, format: FileFormat = .jpg) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 32) {
            for x in stride(from: 0, to: width, by: 32) {
                context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: CGFloat(x) / CGFloat(width),
                                             blue: CGFloat(y) / CGFloat(height), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 32, height: 32))
            }
        }
        let url = directory.appendingPathComponent("photo.\(format.fileExtension)")
        try ImageConverter.encode(context.makeImage()!, as: format, quality: 1).write(to: url)
        return url
    }

    private func pixelSize(_ url: URL) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    func testPresetCompressionShrinksFile() throws {
        let input = try makePhoto()
        let output = try ImageCompression.compressFile(input, settings: CompressionSettings())
        XCTAssertEqual(output.lastPathComponent, "photo (сжатый).jpg")
        XCTAssertLessThan(ImageCompression.fileSize(output), ImageCompression.fileSize(input))
    }

    func testTargetSizeIsRespected() throws {
        let input = try makePhoto()
        var settings = CompressionSettings()
        settings.mode = .targetSize
        settings.targetBytes = 60_000
        let output = try ImageCompression.compressFile(input, settings: settings)
        XCTAssertLessThanOrEqual(ImageCompression.fileSize(output), 60_000)
    }

    func testMaxPixelSizeResizes() throws {
        let input = try makePhoto()
        var settings = CompressionSettings()
        settings.mode = .quality
        settings.maxPixelSize = 600
        let output = try ImageCompression.compressFile(input, settings: settings)
        let (width, height) = try pixelSize(output)
        XCTAssertEqual(width, 600)
        XCTAssertEqual(height, 400)
    }

    func testCompressionRefusesToGrowFile() throws {
        let input = try makePhoto(width: 64, height: 64)
        var settings = CompressionSettings()
        settings.mode = .quality
        settings.quality = 1
        settings.format = .tiff
        XCTAssertThrowsError(try ImageCompression.compressFile(input, settings: settings))
    }

    func testCenteredRectMatchesAspect() {
        let rect = ImageCropper.centeredRect(aspect: 1, imageSize: CGSize(width: 1200, height: 800))
        XCTAssertEqual(rect.width * 1200, rect.height * 800, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.001)
    }

    func testHandleResizeKeepsAspectAndBounds() throws {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let free = try XCTUnwrap(ImageCropper.resize(start, handle: .bottomRight, dx: 0.1, dy: 0.05, aspect: nil))
        XCTAssertEqual(free.width, 0.6, accuracy: 0.0001)
        XCTAssertEqual(free.height, 0.55, accuracy: 0.0001)

        let locked = try XCTUnwrap(ImageCropper.resize(start, handle: .topLeft, dx: -0.1, dy: 0, aspect: 1))
        XCTAssertEqual(locked.width, locked.height, accuracy: 0.0001)
        XCTAssertEqual(locked.maxX, start.maxX, accuracy: 0.0001)
        XCTAssertEqual(locked.maxY, start.maxY, accuracy: 0.0001)

        XCTAssertNil(ImageCropper.resize(start, handle: .left, dx: -0.4, dy: 0, aspect: nil))
        XCTAssertNil(ImageCropper.resize(start, handle: .right, dx: -0.49, dy: 0, aspect: nil))
    }

    func testCropWritesExactArea() throws {
        let input = try makePhoto(format: .png)
        let output = try ImageCropper.cropFile(input, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                               outputSize: nil, options: ConversionOptions())
        XCTAssertEqual(output.lastPathComponent, "photo (обрезано).png")
        let (width, height) = try pixelSize(output)
        XCTAssertEqual(width, 600)
        XCTAssertEqual(height, 400)
    }

    func testCropScalesToOutputSize() throws {
        let input = try makePhoto()
        let rect = ImageCropper.centeredRect(aspect: 1, imageSize: CGSize(width: 1200, height: 800))
        let output = try ImageCropper.cropFile(input, rect: rect, outputSize: CGSize(width: 300, height: 300),
                                               options: ConversionOptions())
        let (width, height) = try pixelSize(output)
        XCTAssertEqual(width, 300)
        XCTAssertEqual(height, 300)
    }
}
