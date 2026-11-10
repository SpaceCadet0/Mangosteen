import Foundation

/// Where results are saved.
enum SaveMode: String, CaseIterable, Codable, Identifiable {
    /// Next to the original, as Mangosteen always did.
    case nextToOriginal
    /// Into one chosen folder.
    case folder
    /// A folder is asked for before each job.
    case ask

    var id: String { rawValue }
}

/// How results are placed and named: the save folder, the name template and whether the original's dates are kept.
/// Settings (the standard values or the active preset) hand it to `OutputLocation.policy`; jobs read it there.
struct OutputPolicy: Equatable {
    var mode = SaveMode.nextToOriginal
    /// The folder for `.folder`.
    var folder: URL?
    /// Tokens: {name}, {date}, {time}, {format}.
    var nameTemplate = OutputLocation.defaultTemplate
    /// The result gets the original's creation and modification dates.
    var keepDates = false
}

/// A named set of conversion settings. The standard settings are not a preset; when a preset is active, its values
/// replace them for every conversion.
struct ConversionPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// 0.1…1 for every lossy picture format (JPG, HEIC, AVIF, WebP).
    var quality = 0.85
    /// Longest side of converted pictures in pixels; 0 keeps their size.
    var maxPixelSize = 0
    var preserveMetadata = true
    var saveMode = SaveMode.nextToOriginal
    var folderPath = ""
    var nameTemplate = OutputLocation.defaultTemplate
    var keepDates = false

    var policy: OutputPolicy {
        OutputPolicy(mode: saveMode, folder: folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath),
                     nameTemplate: nameTemplate, keepDates: keepDates)
    }
}

enum OutputLocation {
    static let defaultTemplate = "{name}"
    static let tokens = ["{name}", "{date}", "{time}", "{format}"]

    private static let lock = NSLock()
    private static var currentPolicy = OutputPolicy()
    private static var currentAskedFolder: URL?

    /// The policy jobs follow; settings set it whenever it changes.
    static var policy: OutputPolicy {
        get { lock.withLock { currentPolicy } }
        set { lock.withLock { currentPolicy = newValue } }
    }

    /// The folder picked for the job being started when the policy is `.ask`. Jobs that run at the same time share
    /// it: the folder picked last wins.
    static var askedFolder: URL? {
        get { lock.withLock { currentAskedFolder } }
        set { lock.withLock { currentAskedFolder = newValue } }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The folder a result of a file in `directory` goes to. Results go to the chosen (or asked) folder, except when
    /// `directory` is already inside it: then they stay put, so a job's own subfolders keep their contents. A folder
    /// that cannot be written to (a disk image, a shared folder) sends the result to Downloads instead.
    static func directory(for directory: URL, policy: OutputPolicy = OutputLocation.policy,
                          asked: URL? = OutputLocation.askedFolder,
                          fileManager: FileManager = .default) -> URL {
        let root: URL? = switch policy.mode {
        case .nextToOriginal: nil
        case .folder: policy.folder
        case .ask: asked
        }
        if let root, !isInside(directory, root) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            if fileManager.isWritableFile(atPath: root.path) { return root }
        }
        if isWritable(directory, fileManager: fileManager) { return directory }
        return downloads
    }

    /// A folder that does not exist yet counts as writable when its nearest existing parent is.
    private static func isWritable(_ folder: URL, fileManager: FileManager) -> Bool {
        var current = folder.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return fileManager.isWritableFile(atPath: current.path)
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// `baseName` put through the template: "photo" with "{name} {date}" → "photo 2026-11-10". Slashes and colons,
    /// which Finder cannot show in a name, become dashes; an empty result falls back to `baseName`.
    static func name(_ baseName: String, pathExtension: String, template: String = OutputLocation.policy.nameTemplate,
                     date: Date = Date()) -> String {
        guard template != defaultTemplate, !template.isEmpty else { return baseName }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH-mm-ss"
        let format = pathExtension.split(separator: ".").last.map { $0.uppercased() } ?? ""
        let filled = template
            .replacingOccurrences(of: "{name}", with: baseName)
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date))
            .replacingOccurrences(of: "{format}", with: format)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        // A name starting with a dot would be hidden.
        let visible = filled.hasPrefix(".") ? "_" + filled : filled
        return visible.isEmpty ? baseName : visible
    }

    /// Gives `output` the creation and modification dates of `original` when the policy says so.
    static func keepDates(of original: URL, on output: URL, policy: OutputPolicy = OutputLocation.policy) {
        guard policy.keepDates,
              let attributes = try? FileManager.default.attributesOfItem(atPath: original.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]
        dates[.modificationDate] = attributes[.modificationDate]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: output.path)
    }
}
