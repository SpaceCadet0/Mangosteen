import XCTest

final class CropTransformTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 3 × 2 image, top row red-green-blue, bottom row white-black-yellow (as seen on screen).
    private func sample() -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255], [0, 0, 0], [255, 255, 0]]
        var bytes = [UInt8]()
        for color in colors { bytes += color + [255] }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Pixel colours row by row from the top-left, as names.
    private func names(_ image: CGImage) -> [[String]] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let table: [String: String] = ["255,0,0": "R", "0,255,0": "G", "0,0,255": "B", "255,255,255": "W", "0,0,0": "K", "255,255,0": "Y"]
        return (0..<height).map { row in
            (0..<width).map { column in
                let index = (row * width + column) * 4
                return table["\(bytes[index]),\(bytes[index + 1]),\(bytes[index + 2])"] ?? "?"
            }
        }
    }

    func testIdentityKeepsPixels() throws {
        XCTAssertEqual(names(try ImageCropper.apply(.init(), to: sample())), [["R", "G", "B"], ["W", "K", "Y"]])
    }

    func testRotations() throws {
        var transform = ImageCropper.Transform()
        transform.rotate(clockwise: true)
        XCTAssertEqual(names(try ImageCropper.apply(transform, to: sample())), [["W", "R"], ["K", "G"], ["Y", "B"]])
        transform.rotate(clockwise: true)
        XCTAssertEqual(names(try ImageCropper.apply(transform, to: sample())), [["Y", "K", "W"], ["B", "G", "R"]])
        var left = ImageCropper.Transform()
        left.rotate(clockwise: false)
        XCTAssertEqual(names(try ImageCropper.apply(left, to: sample())), [["B", "Y"], ["G", "K"], ["R", "W"]])
    }

    func testMirrors() throws {
        var horizontal = ImageCropper.Transform()
        horizontal.flipHorizontal = true
        XCTAssertEqual(names(try ImageCropper.apply(horizontal, to: sample())), [["B", "G", "R"], ["Y", "K", "W"]])
        var vertical = ImageCropper.Transform()
        vertical.flipVertical = true
        XCTAssertEqual(names(try ImageCropper.apply(vertical, to: sample())), [["W", "K", "Y"], ["R", "G", "B"]])
    }

    /// Each button acts on what is on screen: mirror, then turn, equals turning the mirrored picture.
    func testMirrorThenTurnActsOnScreenImage() throws {
        var transform = ImageCropper.Transform()
        transform.flipHorizontal = true // B G R / Y K W
        transform.rotate(clockwise: true) // turn that clockwise
        XCTAssertEqual(names(try ImageCropper.apply(transform, to: sample())), [["Y", "B"], ["K", "G"], ["W", "R"]])
        XCTAssertEqual(transform.size(for: CGSize(width: 3, height: 2)), CGSize(width: 2, height: 3))
    }

    func testTilesCoverEveryPixel() {
        let tiles = ImageCropper.tiles(sample(), columns: 2, rows: 2)
        XCTAssertEqual(tiles.map(\.width), [2, 1, 2, 1])
        XCTAssertEqual(tiles.map(\.height), [1, 1, 1, 1])
        XCTAssertEqual(tiles.map { names($0) }, [[["R", "G"]], [["B"]], [["W", "K"]], [["Y"]]])
    }

    /// Moved lines cut where they are drawn, rounded to whole pixels.
    func testTilesAtMovedCuts() {
        let tiles = ImageCropper.tiles(sample(), columnCuts: [0.7], rowCuts: [])
        XCTAssertEqual(tiles.map { names($0) }, [[["R", "G"], ["W", "K"]], [["B"], ["Y"]]])
        XCTAssertEqual(ImageCropper.evenCuts(4), [0.25, 0.5, 0.75])
        XCTAssertEqual(ImageCropper.evenCuts(1), [])
    }

    func testSplitWritesNumberedPartsInFolder() throws {
        let input = directory.appendingPathComponent("photo.png")
        try ImageConverter.write(sample(), as: .png, to: input, options: ConversionOptions(), metadata: nil)
        var transform = ImageCropper.Transform()
        transform.rotate(clockwise: true)
        let folder = try ImageCropper.cropFile(input, rect: CGRect(x: 0, y: 0, width: 1, height: 1), outputSize: nil,
                                               transform: transform, columns: 1, rows: 3, options: ConversionOptions())
        XCTAssertEqual(folder.lastPathComponent, String(localized: "photo (части)"))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["photo 1.png", "photo 2.png", "photo 3.png"])
        let first = try ImageConverter.load(folder.appendingPathComponent("photo 1.png")).image
        XCTAssertEqual(names(first), [["W", "R"]])
    }

    func testTurnOnlyIsNamedChanged() throws {
        let input = directory.appendingPathComponent("photo.png")
        try ImageConverter.write(sample(), as: .png, to: input, options: ConversionOptions(), metadata: nil)
        var transform = ImageCropper.Transform()
        transform.flipVertical = true
        let output = try ImageCropper.cropFile(input, rect: CGRect(x: 0, y: 0, width: 1, height: 1), outputSize: nil,
                                               transform: transform, options: ConversionOptions())
        XCTAssertEqual(output.lastPathComponent, String(localized: "photo (изменено)") + ".png")
    }
}
