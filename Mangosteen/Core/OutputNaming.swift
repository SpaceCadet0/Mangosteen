import Foundation

/// Chooses where results go: next to the original, never overwriting anything.
enum OutputNaming {
    /// `photo.png` → `photo.png`, or `photo 2.png`, `photo 3.png`… when taken.
    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String,
                          fileManager: FileManager = .default) -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? baseName : "\(baseName) \(index)"
            let url = directory.appendingPathComponent(name)
            return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
        }
        var index = 1
        while fileManager.fileExists(atPath: candidate(index).path) {
            index += 1
        }
        return candidate(index)
    }

    /// 1-based number of a part, zero-padded to the width of `count` so parts sort in order: "03" of 12.
    static func partNumber(_ index: Int, of count: Int) -> String {
        let number = String(index + 1)
        return String(repeating: "0", count: max(String(count).count - number.count, 0)) + number
    }

    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for doubleExtension in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(doubleExtension) {
            return String(name.dropLast(doubleExtension.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Runs `produce` against a hidden temporary file in `directory`, then moves the result to a unique
    /// final name. Nothing visible is left behind if `produce` throws.
    @discardableResult
    static func writeAtomically(directory: URL, baseName: String, pathExtension: String,
                                fileManager: FileManager = .default,
                                produce: (URL) throws -> Void) throws -> URL {
        var temp = directory.appendingPathComponent(".mangosteen-\(UUID().uuidString)")
        if !pathExtension.isEmpty {
            temp.appendPathExtension(pathExtension)
        }
        defer { try? fileManager.removeItem(at: temp) }
        try produce(temp)
        guard fileManager.fileExists(atPath: temp.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Another job may claim the same name between choosing and moving; retry with the next one.
        for _ in 0..<20 {
            let final = uniqueURL(in: directory, baseName: baseName, pathExtension: pathExtension,
                                  fileManager: fileManager)
            do {
                try fileManager.moveItem(at: temp, to: final)
                return final
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
