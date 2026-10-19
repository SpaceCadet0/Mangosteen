import AppKit
import PDFKit

enum PDFToolError: LocalizedError {
    case unreadable(URL)
    case locked(URL)
    case nothingToDo
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): String(localized: "Не удалось открыть «\(url.lastPathComponent)».")
        case .locked(let url): String(localized: "«\(url.lastPathComponent)» защищён паролем.")
        case .nothingToDo: String(localized: "Нет подходящих файлов.")
        case .writeFailed: String(localized: "Не удалось сохранить PDF.")
        }
    }
}

/// Multi-file PDF tools. Results are written next to the first file.
enum PDFTools {
    /// One page per image, page size equal to the image size in points (72 dpi).
    static func createPDF(fromImages urls: [URL]) throws -> URL {
        let images = urls.filter { FileFormat.detect($0)?.category == .image && FileFormat.detect($0) != .svg }
        guard let first = images.first else { throw PDFToolError.nothingToDo }
        let document = PDFDocument()
        for url in images {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = ImageConverter.orientedImage(source, at: CGImageSourceGetPrimaryImageIndex(source)) else {
                throw PDFToolError.unreadable(url)
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let page = PDFPage(image: image) else { throw PDFToolError.unreadable(url) }
            document.insert(page, at: document.pageCount)
        }
        let baseName = images.count == 1 ? OutputNaming.baseName(of: first) : "Images"
        return try write(document, nextTo: first, baseName: baseName)
    }

    /// Concatenates PDFs in the given order.
    static func merge(_ urls: [URL]) throws -> URL {
        let pdfs = urls.filter { FileFormat.detect($0) == .pdf }
        guard let first = pdfs.first else { throw PDFToolError.nothingToDo }
        let merged = PDFDocument()
        for url in pdfs {
            guard let document = PDFDocument(url: url) else { throw PDFToolError.unreadable(url) }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        return try write(merged, nextTo: first, baseName: "Merged")
    }

    private static func write(_ document: PDFDocument, nextTo url: URL, baseName: String) throws -> URL {
        try OutputNaming.writeAtomically(
            directory: url.deletingLastPathComponent(), baseName: baseName, pathExtension: "pdf"
        ) { output in
            guard document.write(to: output) else { throw PDFToolError.writeFailed }
        }
    }
}
