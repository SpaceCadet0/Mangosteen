import ImageIO
import XCTest

final class EditorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("editors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 200×100 JPEG with camera, date and GPS metadata.
    private func makeTaggedJPEG() throws -> URL {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let url = directory.appendingPathComponent("tagged.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 37.62, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Metadata

    func testReadsCommonFields() throws {
        let properties = MetadataEditor.properties(of: try makeTaggedJPEG())
        XCTAssertEqual(MetadataEditor.text(.make, in: properties), "Canon")
        XCTAssertNotNil(MetadataEditor.dateTaken(in: properties))
        let location = try XCTUnwrap(MetadataEditor.location(in: properties))
        XCTAssertEqual(location.latitude, 55.75, accuracy: 0.001)
    }

    func testEditsAndRemovesFields() throws {
        let input = try makeTaggedJPEG()
        var changes = MetadataChanges()
        changes.text[.author] = "Тестовый автор"
        changes.text[.make] = ""
        changes.latitude = -33.86
        changes.longitude = 151.21
        let output = try MetadataEditor.apply(changes, to: input)
        XCTAssertEqual(output.lastPathComponent, "tagged (метаданные).jpg")

        let properties = MetadataEditor.properties(of: output)
        XCTAssertEqual(MetadataEditor.text(.author, in: properties), "Тестовый автор")
        XCTAssertEqual(MetadataEditor.text(.make, in: properties), "")
        XCTAssertEqual(MetadataEditor.text(.model, in: properties), "EOS")
        let location = try XCTUnwrap(MetadataEditor.location(in: properties))
        XCTAssertEqual(location.latitude, -33.86, accuracy: 0.001)
        XCTAssertEqual(location.longitude, 151.21, accuracy: 0.001)
    }

    func testRemoveLocationKeepsOtherFields() throws {
        var changes = MetadataChanges()
        changes.removeLocation = true
        let properties = MetadataEditor.properties(of: try MetadataEditor.apply(changes, to: makeTaggedJPEG()))
        XCTAssertNil(MetadataEditor.location(in: properties))
        XCTAssertEqual(MetadataEditor.text(.make, in: properties), "Canon")
    }

    // MARK: Photo editor

    private func averageRed(_ image: CGImage) -> Double {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(context.data!.load(as: UInt8.self))
    }

    func testIdentityAdjustmentsKeepPixels() throws {
        let (image, _) = try ImageConverter.load(makeTaggedJPEG())
        let result = try PhotoEditor.render(PhotoEditor.apply(PhotoAdjustments(), to: CIImage(cgImage: image)))
        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(averageRed(result), averageRed(image), accuracy: 2)
    }

    func testExposureBrightensAndEveryControlRenders() throws {
        let (image, _) = try ImageConverter.load(makeTaggedJPEG())
        var brighter = PhotoAdjustments()
        brighter.exposure = 1
        let result = try PhotoEditor.render(PhotoEditor.apply(brighter, to: CIImage(cgImage: image)))
        XCTAssertGreaterThan(averageRed(result), averageRed(image) + 10)

        var everything = PhotoAdjustments(
            exposure: 0.3, brightness: 0.2, contrast: 0.3, highlights: -0.5, shadows: 0.5, temperature: 0.4,
            tint: -0.2, saturation: 0.3, vibrance: 0.4, sharpness: 0.5, clarity: 0.5, noiseReduction: 0.5,
            dehaze: 0.5, effect: .chrome, vignette: 0.5, grain: 0.5)
        everything.effect = .noir
        let all = try PhotoEditor.render(PhotoEditor.apply(everything, to: CIImage(cgImage: image)))
        XCTAssertEqual(all.width, image.width)
        XCTAssertEqual(all.height, image.height)
    }

    func testApplyFileKeepsFormat() throws {
        var adjustments = PhotoAdjustments()
        adjustments.effect = .mono
        let output = try PhotoEditor.applyFile(makeTaggedJPEG(), adjustments: adjustments, options: ConversionOptions())
        XCTAssertEqual(output.lastPathComponent, "tagged (изменено).jpg")
        XCTAssertEqual(MetadataEditor.text(.make, in: MetadataEditor.properties(of: output)), "Canon")
    }

    func testRemoveAllStripsMetadata() throws {
        var changes = MetadataChanges()
        changes.removeAll = true
        let properties = MetadataEditor.properties(of: try MetadataEditor.apply(changes, to: makeTaggedJPEG()))
        XCTAssertNil(MetadataEditor.location(in: properties))
        XCTAssertEqual(MetadataEditor.text(.make, in: properties), "")
        XCTAssertNil(MetadataEditor.dateTaken(in: properties))
    }
}
