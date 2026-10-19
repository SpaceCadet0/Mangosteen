import Foundation

/// Locates and runs command-line tools (cwebp, ffmpeg, exiftool…).
///
/// Lookup order: binaries bundled in `Contents/Resources/Tools`, then Homebrew, then system paths.
enum ExternalTool {
    struct Failure: LocalizedError {
        let tool: String
        let status: Int32
        let output: String

        var errorDescription: String? {
            let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) завершился с кодом \(status)" + (details.isEmpty ? "" : ": \(details)")
        }
    }

    struct Missing: LocalizedError {
        let tool: String
        var errorDescription: String? {
            "Не найдена утилита «\(tool)». Установите её: brew install \(Self.formula(for: tool))"
        }

        static func formula(for tool: String) -> String {
            switch tool {
            case "cwebp", "dwebp": "webp"
            default: tool
            }
        }
    }

    private static let searchDirectories: [URL] = {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Tools"))
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map {
            URL(fileURLWithPath: $0)
        }
        return directories
    }()

    static func locate(_ name: String) -> URL? {
        searchDirectories
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isAvailable(_ name: String) -> Bool {
        locate(name) != nil
    }

    /// Runs the tool synchronously and returns its combined output. Arguments are passed directly,
    /// never through a shell.
    @discardableResult
    static func run(_ name: String, _ arguments: [String]) throws -> String {
        guard let executable = locate(name) else { throw Missing(tool: name) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(tool: name, status: process.terminationStatus, output: output)
        }
        return output
    }
}
