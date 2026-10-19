import AppKit
import PDFKit

/// PDF → images (one per page) and PDF → text-based documents (from the text layer).
enum PDFConverter {
    static func pageCount(_ url: URL) throws -> Int {
        try document(url).pageCount
    }

    static func convert(_ input: URL, to target: FileFormat, output: URL, options: ConversionOptions) throws {
        let pdf = try document(input)
        switch target.category {
        case .image:
            guard let page = pdf.page(at: 0) else { throw ConversionError.unreadable(input) }
            try ImageConverter.write(render(page, dpi: options.pdfRenderDPI), as: target, to: output, options: options)
        case .document:
            if target == .txt || target == .md {
                let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
                try text.write(to: output, atomically: false, encoding: .utf8)
            } else {
                try DocumentConverter.write(attributedText(of: pdf), as: target, to: output)
            }
        default:
            throw ConversionError.unsupported(from: FileFormat.pdf.displayName, to: target)
        }
    }

    /// Writes `<baseName> 1.<ext>`, `<baseName> 2.<ext>`… into a new folder.
    static func renderPages(_ input: URL, as target: FileFormat, into folder: URL, baseName: String,
                            options: ConversionOptions) throws {
        let pdf = try document(input)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(pdf.pageCount).count
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            let url = folder.appendingPathComponent("\(baseName) \(number)").appendingPathExtension(target.fileExtension)
            try ImageConverter.write(render(page, dpi: options.pdfRenderDPI), as: target, to: url, options: options)
        }
    }

    /// Renders a page on white, honouring its rotation.
    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        guard let pageRef = page.pageRef else { throw ConversionError.encodeFailed(.png) }
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pointSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.png)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        let transform = pageRef.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: pointSize),
                                                    rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(pageRef)
        guard let image = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return image
    }

    static func attributedText(of pdf: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.attributedString else { continue }
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(page)
        }
        return result
    }

    private static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        if document.isLocked {
            throw PDFToolError.locked(url)
        }
        return document
    }
}
