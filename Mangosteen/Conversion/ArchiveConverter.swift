import Foundation

/// ZIP, TAR and TAR.GZ via the system `ditto` and `tar`.
enum ArchiveConverter {
    /// Archives a file or folder, keeping its name as the top-level entry.
    static func pack(_ item: URL, as target: FileFormat, to output: URL) throws {
        try pack(items: [item], as: target, to: output)
    }

    /// Unpacks an archive and packs its contents again in another format.
    static func repack(_ archive: URL, from source: FileFormat, as target: FileFormat, to output: URL) throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("mangosteen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try extract(archive, as: source, into: workspace)
        let items = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard !items.isEmpty else { throw ConversionError.unreadable(archive) }
        try pack(items: items, as: target, to: output)
    }

    /// Extracts into a new folder named after the archive, next to it.
    static func extractNextToArchive(_ archive: URL) throws -> URL {
        guard let format = FileFormat.detect(archive), format.category == .archive else {
            throw ConversionError.unrecognized(archive)
        }
        return try OutputNaming.writeAtomically(
            directory: archive.deletingLastPathComponent(), baseName: OutputNaming.baseName(of: archive), pathExtension: ""
        ) { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try extract(archive, as: format, into: folder)
        }
    }

    static func extract(_ archive: URL, as format: FileFormat, into folder: URL) throws {
        switch format {
        case .zip:
            try ExternalTool.run("ditto", ["-x", "-k", archive.path, folder.path])
        case .tar, .tgz:
            try ExternalTool.run("tar", ["-xf", archive.path, "-C", folder.path])
        default:
            throw ConversionError.unrecognized(archive)
        }
    }

    /// All items must share a parent folder.
    private static func pack(items: [URL], as target: FileFormat, to output: URL) throws {
        guard let parent = items.first?.deletingLastPathComponent() else { throw ConversionError.encodeFailed(target) }
        // "./" keeps names that start with "-" from being read as options.
        let names = items.map { "./" + $0.lastPathComponent }
        switch target {
        case .zip where items.count == 1:
            try ExternalTool.run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].path, output.path])
        case .zip:
            // ditto takes one source; zip the parent folder's contents instead.
            try ExternalTool.run("ditto", ["-c", "-k", "--sequesterRsrc", parent.path, output.path])
        case .tar:
            try ExternalTool.run("tar", ["-cf", output.path, "-C", parent.path] + names)
        case .tgz:
            try ExternalTool.run("tar", ["-czf", output.path, "-C", parent.path] + names)
        default:
            throw ConversionError.encodeFailed(target)
        }
    }
}
