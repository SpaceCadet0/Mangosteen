import ImageIO
import XCTest

final class CompositionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage(_ name: String, width: Int, height: Int) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent(name)
        try ImageConverter.encode(context.makeImage()!, as: .jpg, quality: 0.9).write(to: url)
        return url
    }

    private func size(_ url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Background

    func testCanvasAddsMarginAndHonoursAspect() {
        var settings = FrameSettings()
        settings.padding = 0.1
        XCTAssertEqual(FrameComposer.canvasSize(photo: CGSize(width: 1000, height: 500), settings: settings),
                       CGSize(width: 1200, height: 700))
        settings.aspect = .square
        XCTAssertEqual(FrameComposer.canvasSize(photo: CGSize(width: 1000, height: 500), settings: settings),
                       CGSize(width: 1200, height: 1200))
    }

    func testEveryBackgroundRenders() throws {
        let input = try makeImage("photo.jpg", width: 400, height: 300)
        for background in FrameSettings.Background.allCases {
            var settings = FrameSettings()
            settings.background = background
            settings.backgroundImage = background == .image ? input : nil
            let output = try FrameComposer.composeFile(input, settings: settings, options: ConversionOptions())
            XCTAssertEqual(try size(output), FrameComposer.canvasSize(photo: CGSize(width: 400, height: 300), settings: settings))
            try FileManager.default.removeItem(at: output)
        }
    }

    // MARK: Collage

    func testGridLayoutCentresShortLastRow() {
        var settings = CollageSettings()
        settings.width = 1000
        settings.spacing = 0
        settings.aspect = .square
        let (size, cells) = CollageComposer.layout(aspects: [1, 1, 1], settings: settings)
        XCTAssertEqual(size, CGSize(width: 1000, height: 1000))
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[2].midX, 500, accuracy: 0.5)
    }

    func testAutoRowKeepsPhotosWhole() {
        var settings = CollageSettings()
        settings.layout = .row
        settings.width = 1000
        settings.spacing = 0
        let (size, cells) = CollageComposer.layout(aspects: [2, 0.5], settings: settings)
        XCTAssertEqual(cells[0].width / cells[0].height, 2, accuracy: 0.01)
        XCTAssertEqual(cells[1].width / cells[1].height, 0.5, accuracy: 0.01)
        XCTAssertEqual(cells[1].maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(size.height, cells[0].height, accuracy: 1)
    }

    func testEveryLayoutWritesCollage() throws {
        let urls = [try makeImage("a.jpg", width: 400, height: 300), try makeImage("b.jpg", width: 300, height: 400),
                    try makeImage("c.jpg", width: 500, height: 500)]
        for layout in CollageSettings.Layout.allCases {
            var settings = CollageSettings()
            settings.layout = layout
            settings.width = 1200
            settings.cornerRadius = 0.05
            let output = try CollageComposer.composeFile(urls, settings: settings, options: ConversionOptions())
            XCTAssertEqual(try size(output).width, 1200)
            try FileManager.default.removeItem(at: output)
        }
    }
}
