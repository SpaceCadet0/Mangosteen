import AppKit
import UniformTypeIdentifiers

enum WebImageDropError: LocalizedError {
    case nothingReceived

    var errorDescription: String? {
        switch self {
        case .nothingReceived: String(localized: "Браузер не отдал картинку. Сохраните её на диск и перетащите файл.")
        }
    }
}

/// A picture dragged out of a web browser. It is not a file yet: browsers offer either a file promise (the file is
/// written only when the drop lands) or the picture's data. Only these are accepted; a link or text is not, and
/// nothing is downloaded. The wheel is built for a placeholder name of the picture's format, and the picture is
/// saved to Downloads only once it is dropped on a slice.
struct WebImageDrop: Equatable {
    let format: FileFormat

    /// A name in the picture's format for building the wheel; no file exists there.
    var placeholder: URL {
        Self.placeholderFolder.appendingPathComponent("image").appendingPathExtension(format.fileExtension)
    }

    static let placeholderFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Mangosteen web drop")

    /// The format to offer a "keep as it is" slice in, when the wheel is for browser pictures only: conversion
    /// targets never include the source format, yet saving the picture unchanged is often all that is wanted.
    static func keptFormat(of urls: [URL]) -> FileFormat? {
        guard !urls.isEmpty, urls.allSatisfy(isPlaceholder) else { return nil }
        return urls.first.flatMap(FileFormat.detect)
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        // Paths, not URLs: a folder URL may or may not end in "/".
        url.deletingLastPathComponent().standardizedFileURL.path == placeholderFolder.standardizedFileURL.path
    }

    /// Picture data types a browser may put on the drag pasteboard, best first; TIFF is a rendering, saved as PNG.
    static let dataTypes: [(NSPasteboard.PasteboardType, FileFormat)] = [
        (.png, .png), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpg),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), .webp), (NSPasteboard.PasteboardType(UTType.gif.identifier), .gif),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic), (.tiff, .png),
    ]

    /// Types the wheel registers so a browser's picture can be dropped on it.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + dataTypes.map(\.0)
    }

    /// The picture on `pasteboard`, or nil when it carries files (handled as files) or no picture.
    static func detect(on pasteboard: NSPasteboard) -> WebImageDrop? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard files.isEmpty else { return nil }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] {
            for type in receivers.flatMap(\.fileTypes) {
                // Pictures only: PDF is among the image targets but a promised PDF is a document.
                if let utType = UTType(type),
                   let format = FormatCatalog.imageOutputs.first(where: { $0 != .pdf && utType.conforms(to: $0.utType) }) {
                    return WebImageDrop(format: format)
                }
                if let utType = UTType(type), utType.conforms(to: .image) { return WebImageDrop(format: .png) }
            }
        }
        let types = pasteboard.types ?? []
        return dataTypes.first { types.contains($0.0) }.map { WebImageDrop(format: $0.1) }
    }

    /// Saves the picture on `pasteboard` into `folder` under a name not yet taken and calls `completion` on the main
    /// thread. A file promise keeps the name the browser gives it; plain data is named "Картинка из браузера".
    static func receive(from pasteboard: NSPasteboard, into folder: URL,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        let finish: (Result<URL, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("mangosteen-drop-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return finish(.failure(error))
        }
        func move(_ file: URL) -> Result<URL, Error> {
            defer { try? FileManager.default.removeItem(at: staging) }
            let target = OutputNaming.uniqueURL(in: folder, baseName: file.deletingPathExtension().lastPathComponent,
                                                pathExtension: file.pathExtension)
            return Result { try FileManager.default.moveItem(at: file, to: target); return target }
        }

        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if let receiver = receivers.first {
            let queue = OperationQueue()
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) { url, error in
                finish(error.map { .failure($0) } ?? move(url))
            }
            return
        }
        guard let (type, format) = dataTypes.first(where: { pasteboard.types?.contains($0.0) == true }),
              var data = pasteboard.data(forType: type) else {
            return finish(.failure(WebImageDropError.nothingReceived))
        }
        if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { data = png }
        let file = staging.appendingPathComponent(String(localized: "Картинка из браузера")).appendingPathExtension(format.fileExtension)
        do {
            try data.write(to: file)
            finish(move(file))
        } catch {
            finish(.failure(error))
        }
    }

    // MARK: Keeping only the result

    private static let lock = NSLock()
    private static var savedOriginals: Set<String> = []

    /// Remembers a picture saved from a browser, so it can go to the Trash once a slice has made a file from it.
    static func rememberOriginal(_ url: URL) {
        lock.withLock { _ = savedOriginals.insert(url.standardizedFileURL.path) }
    }

    /// Moves the browser originals among `inputs` to the Trash: they were saved only so a slice could work on them,
    /// and the result is what was asked for. Other files are never touched. Returns the originals moved.
    @discardableResult
    static func discardOriginals(of inputs: [URL],
                                 remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [URL] {
        let originals = lock.withLock {
            inputs.filter { savedOriginals.remove($0.standardizedFileURL.path) != nil }
        }
        return originals.filter { (try? remove($0)) != nil }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
