import PDFKit

/// One page in the organised document: which source page it comes from and how much to turn it.
struct PDFPageItem: Identifiable, Equatable {
    let id = UUID()
    let document: Int
    let page: Int
    /// Extra clockwise rotation in degrees (multiple of 90).
    var rotation = 0
}

/// Reorders, rotates, duplicates and removes pages across one or more PDFs.
enum PDFOrganizer {
    static func items(for documents: [PDFDocument]) -> [PDFPageItem] {
        documents.enumerated().flatMap { index, document in
            (0..<document.pageCount).map { PDFPageItem(document: index, page: $0) }
        }
    }

    static func build(_ items: [PDFPageItem], from documents: [PDFDocument]) throws -> PDFDocument {
        let result = PDFDocument()
        for item in items {
            guard documents.indices.contains(item.document),
                  let page = documents[item.document].page(at: item.page)?.copy() as? PDFPage else {
                throw PDFToolError.writeFailed
            }
            page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw PDFToolError.nothingToDo }
        return result
    }

    /// Writes `<first name> (страницы).pdf` next to the first PDF.
    static func save(_ items: [PDFPageItem], from documents: [PDFDocument], nextTo url: URL) throws -> URL {
        let document = try build(items, from: documents)
        return try OutputNaming.writeAtomically(
            directory: url.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: url)) (страницы)"),
            pathExtension: "pdf"
        ) { output in
            guard document.write(to: output) else { throw PDFToolError.writeFailed }
        }
    }
}
