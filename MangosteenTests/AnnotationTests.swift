import ImageIO
import XCTest

final class AnnotationTests: XCTestCase {
    private func makeImage(width: Int = 400, height: Int = 300) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 50, width: 50, height: 50)) // blue square at the top-left
        return context.makeImage()!
    }

    /// RGB at (x, y) with y measured from the top.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func annotation(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: red, lineWidth: 6, fontSize: 30)
    }

    func testRectangleIsDrawnWithTopLeftCoordinates() throws {
        let base = makeImage()
        let result = try AnnotationRenderer.render([annotation(.rectangle(CGRect(x: 100, y: 20, width: 200, height: 100)))],
                                                   on: base, fullSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(pixel(result, 200, 20).0, 255)   // top edge, red
        XCTAssertEqual(pixel(result, 200, 20).1, 0)
        XCTAssertEqual(pixel(result, 200, 70).1, 255)   // inside stays white
    }

    func testPreviewScaleMatchesFullSize() throws {
        // A half-size preview draws the same mark at half the coordinates.
        let preview = makeImage(width: 200, height: 150)
        let result = try AnnotationRenderer.render([annotation(.rectangle(CGRect(x: 100, y: 20, width: 200, height: 100)))],
                                                   on: preview, fullSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(pixel(result, 100, 10).1, 0)
    }

    func testMagnifierShowsZoomedSourceUpright() throws {
        // Magnify around the blue square's corner; the upper-left of the loupe must be blue.
        let result = try AnnotationRenderer.render([annotation(.magnifier(CGPoint(x: 50, y: 50), 40))],
                                                   on: makeImage(), fullSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(pixel(result, 35, 35).2, 255)
        XCTAssertLessThan(pixel(result, 35, 35).0, 30) // allow interpolation at the zoomed edge
        XCTAssertEqual(pixel(result, 65, 65).0, 255) // lower-right shows white
    }

    func testEveryShapeRenders() throws {
        let shapes: [Annotation.Shape] = [
            .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 150)),
            .ellipse(CGRect(x: 20, y: 20, width: 100, height: 60)),
            .text(CGPoint(x: 30, y: 200), "Привет"),
            .number(CGPoint(x: 300, y: 50), 3),
            .pen([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80), CGPoint(x: 120, y: 30)]),
            .highlight([CGPoint(x: 10, y: 250), CGPoint(x: 300, y: 250)]),
        ]
        let result = try AnnotationRenderer.render(shapes.map(annotation), on: makeImage(),
                                                   fullSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(result.width, 400)
    }

    func testHitTestMoveAndHandles() {
        let arrow = annotation(.arrow(CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)))
        let box = annotation(.rectangle(CGRect(x: 200, y: 200, width: 50, height: 50)))
        XCTAssertEqual(AnnotationGeometry.hitTest([arrow, box], at: CGPoint(x: 220, y: 220), tolerance: 4), box.id)
        XCTAssertNil(AnnotationGeometry.hitTest([arrow, box], at: CGPoint(x: 350, y: 20), tolerance: 4))

        let moved = AnnotationGeometry.translated(box, by: CGVector(dx: 10, dy: -5))
        XCTAssertEqual(AnnotationGeometry.bounds(moved).origin, CGPoint(x: 210, y: 195))

        let stretched = AnnotationGeometry.moving(arrow, handle: .end, to: CGPoint(x: 300, y: 40))
        XCTAssertEqual(stretched.shape, .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 40)))

        let resized = AnnotationGeometry.moving(box, handle: .corner(.bottomRight), to: CGPoint(x: 300, y: 260))
        XCTAssertEqual(AnnotationGeometry.bounds(resized), CGRect(x: 200, y: 200, width: 100, height: 60))
    }
}
