import XCTest

/// Splitting a wheel's slices into its face and its back.
final class WheelLayoutTests: XCTestCase {
    private func split(_ ids: [String], _ choices: [String: SlicePlacement] = [:]) -> (front: [String], back: [String]) {
        WheelLayout.split(ids, id: { $0 }, choices: choices)
    }

    func testDefaultsKeepTheFamiliarFace() {
        let video = ["tool.trimMedia", "tool.splitMedia", "tool.frames", "tool.extractSubtitles"]
        let sides = split(video)
        XCTAssertEqual(sides.front, ["tool.trimMedia", "tool.splitMedia", "tool.frames"])
        XCTAssertEqual(sides.back, ["tool.extractSubtitles"], "a new slice starts on the back")
        XCTAssertEqual(split(["convert.png", "convert.jpg"]).back, [], "no back side unless something is on it")
    }

    func testUserChoicesWinAndHiddenSlicesDisappear() {
        let sides = split(["a", "b", "c", "tool.extractSubtitles"],
                          ["b": .back, "c": .hidden, "tool.extractSubtitles": .front])
        XCTAssertEqual(sides.front, ["a", "tool.extractSubtitles"])
        XCTAssertEqual(sides.back, ["b"])
    }

    func testAFullFaceSpillsOntoTheBack() {
        let ids = (1...13).map { "s\($0)" }
        let sides = split(ids, ["s2": .back])
        XCTAssertEqual(sides.front.count, WheelLayout.maxFront)
        XCTAssertEqual(sides.front.first, "s1")
        XCTAssertEqual(sides.back, ["s12", "s13", "s2"], "the overflow comes first, then the slices put there")
    }

    func testAnEmptyFaceShowsTheBack() {
        let sides = split(["a", "b"], ["a": .back, "b": .back])
        XCTAssertEqual(sides.front, ["a", "b"])
        XCTAssertEqual(sides.back, [])
        XCTAssertEqual(split(["a"], ["a": .hidden]).front, [], "everything hidden leaves an empty wheel")

        let many = (1...12).map { "m\($0)" }
        let allBack = split(many, Dictionary(uniqueKeysWithValues: many.map { ($0, .back) }))
        XCTAssertEqual(allBack.front.count, WheelLayout.maxFront, "the back shown as the face still holds at most 10")
        XCTAssertEqual(allBack.back, ["m11", "m12"])
    }
}
