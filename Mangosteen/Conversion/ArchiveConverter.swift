import Foundation

enum ArchiveError: LocalizedError {
    /// A disc image whose files are only in its UDF part (libarchive reads ISO 9660 only).
    case nothingExtracted(URL)
    case empty(URL)

    var errorDescription: String? {
        switch self {
        case .nothingExtracted(let url):
            String(localized: "В «\(url.lastPathComponent)» не нашлось файлов, которые можно распаковать. Образы дисков только в формате UDF, например установочные образы Windows, не поддерживаются.")
        case .empty(let url):
            String(localized: "Архив «\(url.lastPathComponent)» пуст.")
        }
    }
}

/// ZIP, TAR and TAR.GZ via the system `ditto` and `tar`; 7Z, RAR, ISO, TAR.XZ and TAR.BZ2 are read by the system
/// `tar` (libarchive), a single gzipped file by `gzip`.
enum ArchiveConverter {
    /// Always the system tar: a GNU tar from Homebrew earlier in the search path cannot read 7z, RAR or ISO.
    static let tar = "/usr/bin/tar"

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

    /// Extracts into a new folder named after the archive, next to it. A single gzipped file (`notes.txt.gz`)
    /// becomes that file (`notes.txt`) instead.
    static func extractNextToArchive(_ archive: URL) throws -> URL {
        guard let format = FileFormat.detect(archive), format.category == .archive else {
            throw ConversionError.unrecognized(archive)
        }
        let directory = archive.deletingLastPathComponent()
        if format == .gz {
            // "notes.txt.gz" → "notes" + "txt", so a taken name becomes "notes 2.txt", not "notes.txt 2".
            let inner = archive.deletingPathExtension()
            return try OutputNaming.writeAtomically(
                directory: directory, baseName: inner.deletingPathExtension().lastPathComponent,
                pathExtension: inner.pathExtension
            ) { output in
                try gunzip(archive, to: output)
            }
        }
        return try OutputNaming.writeAtomically(
            directory: directory, baseName: OutputNaming.baseName(of: archive), pathExtension: ""
        ) { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try extract(archive, as: format, into: folder)
        }
    }

    static func extract(_ archive: URL, as format: FileFormat, into folder: URL) throws {
        switch format {
        case .zip:
            try ExternalTool.run("ditto", ["-x", "-k", archive.path, folder.path])
        case .tar, .tgz, .txz, .tbz, .sevenZip, .rar, .iso:
            try ExternalTool.run(tar, ["-xf", archive.path, "-C", folder.path])
        case .gz:
            try gunzip(archive, to: folder.appendingPathComponent(archive.deletingPathExtension().lastPathComponent))
        default:
            throw ConversionError.unrecognized(archive)
        }
        try checkSomethingExtracted(from: archive, into: folder)
    }

    /// libarchive reads only the ISO 9660 part of a disc image. A UDF-only image extracts to nothing, and a Windows
    /// installation image to a single README that says the disc needs UDF; both are reported instead of "done".
    private static func checkSomethingExtracted(from archive: URL, into folder: URL) throws {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let isDiscImage = FileFormat.detect(archive) == .iso
        if items.isEmpty { throw isDiscImage ? ArchiveError.nothingExtracted(archive) : ArchiveError.empty(archive) }
        if isDiscImage, items.count == 1, items[0].lastPathComponent.uppercased() == "README.TXT",
           let text = try? String(contentsOf: items[0], encoding: .ascii), text.contains("UDF") {
            throw ArchiveError.nothingExtracted(archive)
        }
    }

    /// Decompresses a single gzipped file into `output`, streaming, so a large one never sits in memory.
    private static func gunzip(_ archive: URL, to output: URL) throws {
        try ExternalTool.runToFile("/usr/bin/gzip", ["-d", "-c", archive.path], output: output)
    }

    /// Puts exactly the selected files and folders (from one or several folders) into one ZIP next to the first,
    /// named after their folder. They are staged as APFS clones in a hidden folder, so nothing else from the
    /// folder gets in and nothing large is copied.
    static func archiveSelection(_ items: [URL]) throws -> URL {
        guard let first = items.first else { throw ConversionError.encodeFailed(.zip) }
        let directory = first.deletingLastPathComponent()
        let name = items.count == 1 ? OutputNaming.baseName(of: first)
            : (directory.lastPathComponent.isEmpty || directory.path == "/" ? "Archive" : directory.lastPathComponent)
        let fileManager = FileManager.default
        let staging = directory.appendingPathComponent(".mangosteen-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        for item in items {
            let destination = OutputNaming.uniqueURL(in: staging, baseName: item.deletingPathExtension().lastPathComponent,
                                                     pathExtension: item.pathExtension)
            try fileManager.copyItem(at: item, to: destination)
        }
        return try OutputNaming.writeAtomically(directory: directory, baseName: name, pathExtension: "zip") { output in
            try ExternalTool.run("ditto", ["-c", "-k", "--sequesterRsrc", staging.path, output.path])
        }
    }

    /// All items must share a parent folder.
    private static func pack(items: [URL], as target: FileFormat, to output: URL) throws {
        guard let parent = items.first?.deletingLastPathComponent() else { throw ConversionError.encodeFailed(target) }
        // "./" keeps names that start with "-" from being read as options.
        let names = items.map { "./" + $0.lastPathComponent }
        switch target {
        case .zip where items.count == 1:
            // A folder keeps its own name as the top entry. For a single file --keepParent would add the name of the
            // folder it sits in (a temporary one when repacking), so a file goes in on its own.
            let isFolder = (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try ExternalTool.run("ditto", ["-c", "-k", "--sequesterRsrc"] + (isFolder ? ["--keepParent"] : [])
                                 + [items[0].path, output.path])
        case .zip:
            // ditto takes one source; zip the parent folder's contents instead.
            try ExternalTool.run("ditto", ["-c", "-k", "--sequesterRsrc", parent.path, output.path])
        case .tar:
            try ExternalTool.run(tar, ["-cf", output.path, "-C", parent.path] + names)
        case .tgz:
            try ExternalTool.run(tar, ["-czf", output.path, "-C", parent.path] + names)
        default:
            throw ConversionError.encodeFailed(target)
        }
    }
}
