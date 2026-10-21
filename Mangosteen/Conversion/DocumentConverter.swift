import AppKit

/// Text documents, converted through NSAttributedString (the same engine TextEdit uses).
enum DocumentConverter {
    static let bodyFont = NSFont.systemFont(ofSize: 12)

    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws {
        try write(read(input, as: source), as: target, to: output)
    }

    // MARK: - Reading

    static func read(_ url: URL, as format: FileFormat) throws -> NSAttributedString {
        switch format {
        case .txt:
            return NSAttributedString(string: try readText(url), attributes: [.font: bodyFont])
        case .md:
            return try readHTML(Data(Markdown.html(from: try readText(url)).utf8), baseURL: url.deletingLastPathComponent())
        case .html:
            return try readHTML(Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
        case .rtf, .rtfd, .docx, .doc, .odt:
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType(for: format)!]
            do {
                return try NSAttributedString(url: url, options: options, documentAttributes: nil)
            } catch {
                throw ConversionError.unreadable(url)
            }
        default:
            throw ConversionError.unreadable(url)
        }
    }

    /// UTF-8 (with or without BOM), UTF-16 with BOM, then Windows-1251 and Latin-1 as fallbacks.
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        if let text = String(data: data, encoding: cp1251) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The HTML importer uses WebKit and must run on the main thread. The page is made offline first: WebKit would
    /// otherwise fetch remote pictures and stylesheets (a tracking pixel learns when the file was opened) and embed
    /// local files from anywhere on disk.
    private static func readHTML(_ data: Data, baseURL: URL) throws -> NSAttributedString {
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let data = Data(offlineHTML(html, folder: baseURL).utf8)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .baseURL: baseURL,
        ]
        let read = { try NSAttributedString(data: data, options: options, documentAttributes: nil) }
        if Thread.isMainThread {
            return try read()
        }
        return try DispatchQueue.main.sync(execute: read)
    }

    /// Removes everything that would make WebKit load a resource from the network or from outside `folder`:
    /// remote, `file:` and absolute URLs in resource attributes, `<base>`, `<meta http-equiv=refresh>`, and CSS
    /// `url(…)`/`@import`. Relative resources inside the folder, `data:` URIs and plain links stay.
    static func offlineHTML(_ html: String, folder: URL) -> String {
        let root = folder.standardizedFileURL.path
        func isLocal(_ raw: String) -> Bool {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") || value.lowercased().hasPrefix("data:") { return true }
            if value.hasPrefix("/") || value.hasPrefix("\\") { return false }
            if value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return false }
            let path = folder.appendingPathComponent(value.components(separatedBy: CharacterSet(charactersIn: "?#"))[0])
                .standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
        func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                return text
            }
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let groups = (0..<match.numberOfRanges).map {
                    match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0))
                }
                result += transform(groups)
                last = match.range.location + match.range.length
            }
            return result + source.substring(from: last)
        }

        var text = replace(#"<base\b[^>]*>"#, in: html) { _ in "" }
        text = replace(#"<meta\b[^>]*http-equiv\s*=\s*["']?refresh[^>]*>"#, in: text) { _ in "" }
        // Resource attributes: src, srcset, poster, background, data (object) and href on <link>.
        text = replace(#"(\s(?:src|poster|background|data)\s*=\s*)(["'])(.*?)\2"#, in: text) { groups in
            isLocal(groups[3]) ? groups[0] : "\(groups[1])\(groups[2])\(groups[2])"
        }
        text = replace(#"(\ssrcset\s*=\s*)(["'])(.*?)\2"#, in: text) { groups in
            let kept = groups[3].split(separator: ",").filter { candidate in
                isLocal(candidate.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
            }
            return "\(groups[1])\(groups[2])\(kept.joined(separator: ","))\(groups[2])"
        }
        text = replace(#"(\s(?:src|poster|background|data)\s*=\s*)([^\s"'>]+)"#, in: text) { groups in
            isLocal(groups[2]) ? groups[0] : "\(groups[1])\"\""
        }
        text = replace(#"<link\b[^>]*>"#, in: text) { groups in
            let href = groups[0].range(of: #"href\s*=\s*["']?([^"'\s>]+)"#, options: [.regularExpression, .caseInsensitive])
                .map { String(groups[0][$0]) } ?? ""
            let value = href.replacingOccurrences(of: #"^href\s*=\s*["']?"#, with: "", options: [.regularExpression, .caseInsensitive])
            return isLocal(value) ? groups[0] : ""
        }
        // CSS in <style> blocks and style attributes.
        text = replace(#"@import\s+(?:url\()?\s*["']?([^"')\s;]+)["']?\s*\)?[^;]*;"#, in: text) { groups in
            isLocal(groups[1]) ? groups[0] : ""
        }
        text = replace(#"url\(\s*(["']?)([^"')]+)\1\s*\)"#, in: text) { groups in
            isLocal(groups[2]) ? groups[0] : "none"
        }
        return text
    }

    // MARK: - Writing

    static func write(_ text: NSAttributedString, as format: FileFormat, to url: URL) throws {
        switch format {
        case .txt:
            try text.string.write(to: url, atomically: false, encoding: .utf8)
        case .md:
            try Markdown.markdown(from: text).write(to: url, atomically: false, encoding: .utf8)
        case .pdf:
            try renderPDF(text, to: url)
        case .rtfd:
            let range = NSRange(location: 0, length: text.length)
            let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case .html, .rtf, .docx, .doc, .odt:
            let range = NSRange(location: 0, length: text.length)
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: documentType(for: format)!]
            if format == .html {
                attributes[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            let data = try text.data(from: range, documentAttributes: attributes)
            try data.write(to: url)
        default:
            throw ConversionError.encodeFailed(format)
        }
    }

    private static func documentType(for format: FileFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        case .html: .html
        default: nil
        }
    }

    // MARK: - PDF

    static let pageSize = CGSize(width: 595, height: 842) // A4 in points
    static let pageMargin: CGFloat = 56

    /// Lays the text out over as many A4 pages as needed.
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.encodeFailed(.pdf)
        }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let containerSize = CGSize(width: pageSize.width - pageMargin * 2, height: pageSize.height - pageMargin * 2)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: containerSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0 || NSMaxRange(range) >= layoutManager.numberOfGlyphs { break }
        } while containers.count < 10_000

        let origin = CGPoint(x: pageMargin, y: pageMargin)
        for container in containers {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let range = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: range, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}
