import PDFKit

/// Splits one PDF into several: `cuts` holds the page indices a new document starts after, `excluded` the pages
/// left out. Pages keep their order; empty documents (every page excluded) are skipped.
enum PDFSplitter {
    /// Page indices of each resulting document.
    static func groups(pageCount: Int, cuts: Set<Int>, excluded: Set<Int>) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        for page in 0..<max(pageCount, 0) {
            if !excluded.contains(page) { current.append(page) }
            if cuts.contains(page) || page == pageCount - 1 {
                if !current.isEmpty { groups.append(current) }
                current = []
            }
        }
        return groups
    }

    /// Cuts after every `size` pages: [2, 5, …] for size 3.
    static func cuts(every size: Int, pageCount: Int) -> Set<Int> {
        guard size > 0 else { return [] }
        return Set(stride(from: size - 1, to: pageCount - 1, by: size))
    }

    /// A cut in the middle; the first half gets the extra page of an odd count.
    static func halfCut(pageCount: Int) -> Set<Int> {
        pageCount > 1 ? [(pageCount + 1) / 2 - 1] : []
    }

    /// 1-based page ranges, e.g. "1–3, 5".
    static func rangesText(_ pages: [Int]) -> String {
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        for page in pages + [Int.min] {
            if let last = previous, page == last + 1 {
                previous = page
                continue
            }
            if let first = start, let last = previous {
                parts.append(first == last ? "\(first + 1)" : "\(first + 1)–\(last + 1)")
            }
            start = page
            previous = page
        }
        return parts.joined(separator: ", ")
    }

    /// Writes the documents next to the original: several go into a `<name> (части)` folder as
    /// `<name> 1.pdf`, `<name> 2.pdf`…; a single one becomes `<name> (страницы).pdf`.
    static func split(_ url: URL, cuts: Set<Int>, excluded: Set<Int>) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        guard !document.isLocked else { throw PDFToolError.writeFailed }
        let groups = groups(pageCount: document.pageCount, cuts: cuts, excluded: excluded)
        guard !groups.isEmpty else { throw PDFToolError.nothingToDo }
        let baseName = OutputNaming.baseName(of: url)
        let directory = url.deletingLastPathComponent()

        func build(_ pages: [Int]) throws -> PDFDocument {
            let result = PDFDocument()
            for index in pages {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFToolError.writeFailed }
                result.insert(page, at: result.pageCount)
            }
            return result
        }

        if groups.count == 1 {
            let part = try build(groups[0])
            return try OutputNaming.writeAtomically(
                directory: directory, baseName: String(localized: "\(baseName) (страницы)"), pathExtension: "pdf"
            ) { output in
                guard part.write(to: output) else { throw PDFToolError.writeFailed }
            }
        }
        let digits = String(groups.count).count
        return try OutputNaming.writeAtomically(
            directory: directory, baseName: String(localized: "\(baseName) (части)"), pathExtension: ""
        ) { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, pages) in groups.enumerated() {
                let number = String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
                let file = folder.appendingPathComponent("\(baseName) \(number)").appendingPathExtension("pdf")
                guard try build(pages).write(to: file) else { throw PDFToolError.writeFailed }
            }
        }
    }
}
