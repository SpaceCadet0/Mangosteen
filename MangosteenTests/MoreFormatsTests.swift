import ImageIO
import XCTest

/// The rest of the "formats without new libraries" list: icons and other pictures ImageIO writes, a size limit for
/// presets, 7Z and ISO written by the system tar, and Mac disk images read through hdiutil.
final class MoreFormatsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("more-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func picture(width: Int, height: Int, name: String = "picture.png") throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func sizes(of url: URL) -> [CGSize] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: width, height: height)
        }
    }

    func testPicturesBecomeSquareIconsAtSeveralSizes() throws {
        let wide = try picture(width: 600, height: 300)
        let ico = try XCTUnwrap(Converter.convert(wide, to: .ico, options: ConversionOptions()))
        let icoSizes = sizes(of: ico)
        XCTAssertEqual(icoSizes.map(\.width).sorted(), [16, 32, 48, 64, 128, 256].map(CGFloat.init))
        XCTAssertTrue(icoSizes.allSatisfy { $0.width == $0.height })

        let icns = try XCTUnwrap(Converter.convert(wide, to: .icns, options: ConversionOptions()))
        let icnsSides = Set(sizes(of: icns).map(\.width))
        XCTAssertTrue(icnsSides.isSuperset(of: [16, 32, 128, 256, 512]), "\(icnsSides)")
        XCTAssertFalse(icnsSides.contains(1024), "a 600-pixel picture is not blown up to 1024")
    }

    func testLayeredAndHDRFormatsAreWritten() throws {
        let source = try picture(width: 40, height: 30)
        for target in [FileFormat.psd, .tga, .exr] {
            let output = try XCTUnwrap(Converter.convert(source, to: target, options: ConversionOptions()))
            XCTAssertEqual(output.pathExtension, target.fileExtension)
            XCTAssertEqual(sizes(of: output).first, CGSize(width: 40, height: 30), target.rawValue)
        }
    }

    func testAPresetSizeLimitShrinksOnlyLargerPictures() throws {
        var options = ConversionOptions()
        options.maxPixelSize = 100
        let large = try picture(width: 400, height: 200, name: "large.png")
        let small = try picture(width: 80, height: 60, name: "small.png")
        let shrunk = try XCTUnwrap(Converter.convert(large, to: .jpg, options: options))
        XCTAssertEqual(sizes(of: shrunk).first, CGSize(width: 100, height: 50))
        let kept = try XCTUnwrap(Converter.convert(small, to: .jpg, options: options))
        XCTAssertEqual(sizes(of: kept).first, CGSize(width: 80, height: 60))
        options.maxPixelSize = 120
        let webp = try XCTUnwrap(Converter.convert(large, to: .webp, options: options))
        XCTAssertEqual(sizes(of: webp).first, CGSize(width: 120, height: 60))
    }

    func testFoldersPackInto7ZAndISOAndBack() throws {
        let content = folder.appendingPathComponent("Отчёт")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try "текст".write(to: content.appendingPathComponent("заметка с длинным именем.txt"), atomically: true, encoding: .utf8)
        for target in [FileFormat.sevenZip, .iso] {
            let archive = try XCTUnwrap(Converter.convert(content, to: target, options: ConversionOptions()))
            let unpacked = try ArchiveConverter.extractNextToArchive(archive)
            let note = unpacked.appendingPathComponent("Отчёт/заметка с длинным именем.txt")
            XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "текст", target.rawValue)
        }
    }

    func testAMacDiskImageIsUnpacked() throws {
        let content = folder.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try "внутри".write(to: content.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let image = folder.appendingPathComponent("Disk.dmg")
        try ExternalTool.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", content.path, "-format", "UDZO",
                                                  "-volname", "Disk", image.path])
        XCTAssertEqual(FileFormat.detect(image), .dmg)
        let unpacked = try ArchiveConverter.extractNextToArchive(image)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("readme.txt"), encoding: .utf8), "внутри")
        XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: unpacked.path).first { $0.hasPrefix(".") })
    }

    func testNewReadOnlyFormatsAreRecognised() {
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/scan.dcm")), .dicom)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/texture.dds")), .dds)
        XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/setup.cab")), .cab)
        XCTAssertTrue(FormatCatalog.targets(for: .dicom).contains(.png))
        XCTAssertFalse(FormatCatalog.targets(for: .dicom).contains(.dicom))
        XCTAssertTrue(FormatCatalog.targets(for: .dmg).contains(.zip))
        // New slices start on the back so the familiar faces stay as they were.
        XCTAssertEqual(WheelLayout.placement(of: "convert.icns", choices: [:]), .back)
        XCTAssertEqual(WheelLayout.placement(of: "convert.png", choices: [:]), .front)
    }
}
