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
            return String(localized: "\(tool) завершился с кодом \(status)") + (details.isEmpty ? "" : ": \(details)")
        }
    }

    struct Missing: LocalizedError {
        let tool: String
        var errorDescription: String? {
            String(localized: "Не найдена утилита «\(tool)». Установите её: brew install \(Self.formula(for: tool))")
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

    /// Runs the tool, delivering each stdout line as it arrives (used for ffmpeg `-progress pipe:1`).
    /// Stderr is kept for the error message. The process is terminated when `cancellation` fires,
    /// and the call then throws `CancellationError`.
    static func runStreaming(_ name: String, _ arguments: [String], cancellation: CancellationToken? = nil,
                             onLine: @escaping (String) -> Void) throws {
        guard let executable = locate(name) else { throw Missing(tool: name) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        var pending = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            pending.append(handle.availableData)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                onLine(String(decoding: line, as: UTF8.self))
            }
        }
        let errorLock = NSLock()
        var errorData = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorLock.withLock { errorData.append(data) }
        }

        try process.run()
        cancellation?.onCancel {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let rest = errors.fileHandleForReading.readDataToEndOfFile()
        errorLock.withLock { errorData.append(rest) }

        if cancellation?.isCancelled == true { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = errorLock.withLock { String(decoding: errorData, as: UTF8.self) }
            throw Failure(tool: name, status: process.terminationStatus, output: String(message.suffix(800)))
        }
    }

    /// Runs the tool and returns its raw stdout (images or samples piped by ffmpeg).
    static func runData(_ name: String, _ arguments: [String]) throws -> Data {
        guard let executable = locate(name) else { throw Missing(tool: name) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorLock = NSLock()
        var errorData = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorLock.withLock { errorData.append(data) }
        }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let message = errorLock.withLock { String(decoding: errorData, as: UTF8.self) }
            throw Failure(tool: name, status: process.terminationStatus, output: String(message.suffix(800)))
        }
        return data
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
