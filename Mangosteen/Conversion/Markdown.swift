import AppKit

/// A small CommonMark subset: headings, paragraphs, emphasis, code, links, images, lists, quotes, rules.
enum Markdown {
    // MARK: - Markdown → HTML

    static func html(from markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }
        func closeList() {
            if let tag = listTag {
                html.append("</\(tag)>")
                listTag = nil
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                    code.removeAll()
                } else {
                    flushParagraph()
                    closeList()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph()
                closeList()
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if ["---", "***", "___"].contains(line) {
                flushParagraph()
                closeList()
                html.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph()
                closeList()
                html.append("<blockquote>\(inline(line.dropFirst().trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if let item = listItem(line) {
                flushParagraph()
                if listTag != item.tag {
                    closeList()
                    html.append("<\(item.tag)>")
                    listTag = item.tag
                }
                html.append("<li>\(inline(item.text))</li>")
            } else {
                if listTag != nil { closeList() }
                paragraph.append(line)
            }
        }
        if inCode {
            html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        closeList()

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 12pt; }
        code, pre { font-family: Menlo, monospace; font-size: 10.5pt; }
        blockquote { color: #555; }
        </style></head><body>
        \(html.joined(separator: "\n"))
        </body></html>
        """
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let inlineRules: [(NSRegularExpression, String)] = [
        (#"`([^`]+)`"#, "<code>$1</code>"),
        (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
        (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
        (#"__([^_]+)__"#, "<strong>$1</strong>"),
        (#"\*([^*]+)\*"#, "<em>$1</em>"),
        (#"(?<![\w])_([^_]+)_(?![\w])"#, "<em>$1</em>"),
        (#"~~([^~]+)~~"#, "<del>$1</del>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func inline(_ text: String) -> String {
        var result = escape(text)
        for (regex, template) in inlineRules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: template)
        }
        return result
    }

    // MARK: - Attributed text → Markdown

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else {
                lines.append("")
                return
            }
            var line = ""
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                var run = string.substring(with: runRange)
                let trimmed = run.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    line += run
                    return
                }
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                if traits.contains(.bold), !isHeading(attributes) { run = "**\(trimmed)**" }
                if traits.contains(.italic) { run = "*\(run.trimmingCharacters(in: .whitespaces))*" }
                if let link = attributes[.link] {
                    let target = (link as? URL)?.absoluteString ?? "\(link)"
                    run = "[\(run)](\(target))"
                }
                line += run
            }
            let first = text.attributes(at: range.location, effectiveRange: nil)
            if let level = headingLevel(for: first) {
                line = String(repeating: "#", count: level) + " " + line.trimmingCharacters(in: .whitespaces)
            } else if let style = first[.paragraphStyle] as? NSParagraphStyle, let list = style.textLists.last {
                let marker = list.markerFormat == .decimal ? "1." : "-"
                // The list marker itself is part of the text ("•\t…"); drop it.
                let body = line.drop { "•◦▪-–\t0123456789. ".contains($0) }
                line = "\(marker) \(body)"
            }
            lines.append(line)
            lines.append("")
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func headingLevel(for attributes: [NSAttributedString.Key: Any]) -> Int? {
        guard let font = attributes[.font] as? NSFont else { return nil }
        switch font.pointSize {
        case 22...: return 1
        case 17..<22: return 2
        case 14.5..<17 where font.fontDescriptor.symbolicTraits.contains(.bold): return 3
        default: return nil
        }
    }

    private static func isHeading(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        headingLevel(for: attributes) != nil
    }
}
