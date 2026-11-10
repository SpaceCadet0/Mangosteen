import XCTest

/// Settings → Saving: where results go, how they are named and whether they keep the original's dates.
final class OutputLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("output-location-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        OutputLocation.policy = OutputPolicy()
        OutputLocation.askedFolder = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testResultsGoToTheChosenFolderButAJobsOwnSubfoldersStay() throws {
        let originals = root.appendingPathComponent("Photos")
        let results = root.appendingPathComponent("Results")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let policy = OutputPolicy(mode: .folder, folder: results)
        XCTAssertEqual(OutputLocation.directory(for: originals, policy: policy).path, results.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results.path), "a missing folder is created")
        let part = results.appendingPathComponent("photo (PNG)")
        XCTAssertEqual(OutputLocation.directory(for: part, policy: policy).path, part.path)
        XCTAssertEqual(OutputLocation.directory(for: originals, policy: OutputPolicy()).path, originals.path)
    }

    func testAskModeUsesThePickedFolderAndFallsBackToTheOriginal() {
        let picked = root.appendingPathComponent("Picked")
        let policy = OutputPolicy(mode: .ask)
        XCTAssertEqual(OutputLocation.directory(for: root, policy: policy, asked: picked).path, picked.path)
        XCTAssertEqual(OutputLocation.directory(for: root, policy: policy, asked: nil).path, root.path)
    }

    func testAReadOnlyFolderSendsResultsToDownloads() throws {
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(OutputLocation.directory(for: locked, policy: OutputPolicy()).path, OutputLocation.downloads.path)
    }

    func testTheTemplateFillsTokensAndKeepsNamesSafe() {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 11, 10, 9, 5, 7)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "jpg", template: "{name}", date: date), "photo")
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "jpg", template: "{name} {date}", date: date), "photo 2026-11-10")
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "tar.gz", template: "{format}_{name}_{time}", date: date),
                       "GZ_photo_09-05-07")
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "png", template: "a/b:{name}", date: date), "a-b-photo")
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "png", template: ".{name}", date: date), "_.photo")
        XCTAssertEqual(OutputLocation.name("photo", pathExtension: "png", template: "   ", date: date), "photo")
    }

    func testWritingFollowsThePolicyAndKeepsDates() throws {
        let originals = root.appendingPathComponent("In")
        let results = root.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("note.txt")
        try "a".write(to: original, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: original.path)

        OutputLocation.policy = OutputPolicy(mode: .folder, folder: results, nameTemplate: "{name} copy", keepDates: true)
        let output = try OutputNaming.writeAtomically(directory: originals, baseName: "note", pathExtension: "md") {
            try "b".write(to: $0, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(output.path, results.appendingPathComponent("note copy.md").path)
        OutputLocation.keepDates(of: original, on: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, old)
        XCTAssertEqual(attributes[.creationDate] as? Date, old)
    }

    func testAPresetCarriesItsOwnSavingPolicy() throws {
        let preset = ConversionPreset(name: "Web", quality: 0.7, maxPixelSize: 1920, saveMode: .folder,
                                      folderPath: "/tmp/web", nameTemplate: "{name}-web", keepDates: true)
        XCTAssertEqual(preset.policy, OutputPolicy(mode: .folder, folder: URL(fileURLWithPath: "/tmp/web"),
                                                   nameTemplate: "{name}-web", keepDates: true))
        let decoded = try JSONDecoder().decode(ConversionPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded, preset)
    }
}
