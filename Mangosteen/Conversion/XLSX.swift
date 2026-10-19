import Foundation

/// Native XLSX (Office Open XML spreadsheet) reading and writing. Only cell values travel: formulas
/// become their cached results, dates become ISO text, formatting is not kept.
enum XLSX {
    struct Sheet: Equatable {
        var name: String
        var rows: [[String]]
    }

    // MARK: Reading

    /// Every worksheet of the workbook, in tab order.
    static func read(_ url: URL) throws -> [Sheet] {
        do {
            return try read(parts: ZipArchive.read(Data(contentsOf: url)))
        } catch {
            throw ConversionError.unreadable(url)
        }
    }

    static func read(parts: [String: Data]) throws -> [Sheet] {
        let rootRelationships = relationships(of: "", in: parts)
        let workbookPath = rootRelationships.values.first { $0.type.hasSuffix("/officeDocument") }?.target ?? "xl/workbook.xml"
        guard let workbookData = parts[workbookPath], let workbook = Element.parse(workbookData) else {
            throw ConversionError.unreadable(URL(fileURLWithPath: workbookPath))
        }
        let workbookRelationships = relationships(of: workbookPath, in: parts)
        let date1904 = workbook.descendants("workbookPr").first.map { ["1", "true"].contains($0.attribute("date1904")) } ?? false
        let sharedStrings = workbookRelationships.values.first { $0.type.hasSuffix("/sharedStrings") }
            .flatMap { parts[$0.target] }.map(SharedStringsParser.parse) ?? []
        let dateStyles = workbookRelationships.values.first { $0.type.hasSuffix("/styles") }
            .flatMap { parts[$0.target] }.map(dateStyleIndices) ?? []

        return workbook.descendants("sheet").compactMap { sheet in
            guard let id = sheet.attribute("id"), let target = workbookRelationships[id]?.target,
                  let data = parts[target] else { return nil }
            let rows = SheetParser.parse(data, sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
            return Sheet(name: sheet.attribute("name") ?? "Sheet", rows: rows)
        }
    }

    private struct Relationship {
        var type: String
        var target: String
    }

    /// The relationships of a package part (`""` for the package itself), with targets resolved to part paths.
    private static func relationships(of part: String, in parts: [String: Data]) -> [String: Relationship] {
        let folder = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        let path = folder.isEmpty ? "_rels/\(name).rels" : "\(folder)/_rels/\(name).rels"
        guard let data = parts[path], let root = Element.parse(data) else { return [:] }
        var result: [String: Relationship] = [:]
        for relationship in root.descendants("Relationship") {
            guard let id = relationship.attribute("Id"), let target = relationship.attribute("Target"),
                  relationship.attribute("TargetMode") != "External" else { continue }
            result[id] = Relationship(type: relationship.attribute("Type") ?? "", target: resolve(target, from: folder))
        }
        return result
    }

    private static func resolve(_ target: String, from folder: String) -> String {
        let joined = target.hasPrefix("/") ? String(target.dropFirst()) : (folder.isEmpty ? target : "\(folder)/\(target)")
        var components: [String] = []
        for component in joined.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    /// Indices into `cellXfs` whose number format shows a date or time.
    private static func dateStyleIndices(_ data: Data) -> Set<Int> {
        guard let styles = Element.parse(data) else { return [] }
        var customFormats: [Int: String] = [:]
        for format in styles.descendants("numFmt") {
            if let id = format.attribute("numFmtId").flatMap(Int.init), let code = format.attribute("formatCode") {
                customFormats[id] = code
            }
        }
        guard let cellFormats = styles.descendants("cellXfs").first else { return [] }
        var result: Set<Int> = []
        for (index, format) in cellFormats.children.filter({ $0.name == "xf" }).enumerated() {
            guard let id = format.attribute("numFmtId").flatMap(Int.init) else { continue }
            let isDate = customFormats[id].map(isDateFormat) ?? builtInDateFormats.contains(id)
            if isDate { result.insert(index) }
        }
        return result
    }

    private static let builtInDateFormats: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    /// A format code shows a date when, outside quoted text, escapes and `[…]` blocks, it uses d, m, y, h or s.
    static func isDateFormat(_ code: String) -> Bool {
        let section = code.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? code
        var plain = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in section {
            if escaped { escaped = false; continue }
            if inQuotes { if character == "\"" { inQuotes = false }; continue }
            if inBrackets { if character == "]" { inBrackets = false }; continue }
            switch character {
            case "\\": escaped = true
            case "\"": inQuotes = true
            case "[": inBrackets = true
            default: plain.append(character)
            }
        }
        let lowered = plain.lowercased().replacingOccurrences(of: "general", with: "")
        return lowered.contains { "dmyhs".contains($0) }
    }

    /// Spreadsheet serial day number → ISO text: a date, a time, or both.
    static func dateText(serial: Double, date1904: Bool) -> String {
        let seconds = Int((serial * 86_400).rounded())
        let epoch = date1904 ? -2_082_844_800.0 : -2_209_161_600.0 // 1904-01-01 and 1899-12-30, UTC
        let date = Date(timeIntervalSince1970: epoch + Double(seconds))
        let hasTime = seconds % 86_400 != 0
        let format = serial < 1 ? "HH:mm:ss" : (hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Writing

    /// A one-sheet workbook. Plain decimal numbers become numeric cells, everything else stays text.
    static func write(rows: [[String]], sheetName: String) -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

        let contentTypes = header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """
        let packageRelationships = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationshipsNamespace)/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = header + """
        <workbook xmlns="\(main)" xmlns:r="\(relationshipsNamespace)">\
        <sheets><sheet name="\(escape(safeSheetName(sheetName)))" sheetId="1" r:id="rId1"/></sheets>\
        </workbook>
        """
        let workbookRelationships = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationshipsNamespace)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(relationshipsNamespace)/styles" Target="styles.xml"/>\
        </Relationships>
        """
        let styles = header + """
        <styleSheet xmlns="\(main)">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """

        // Column widths follow the longest value (in characters), so text is not cut off when opened.
        var widths: [Int] = []
        for row in rows {
            for (index, value) in row.enumerated() {
                if widths.count <= index { widths.append(0) }
                let longestLine = value.split(whereSeparator: \.isNewline).map(\.count).max() ?? 0
                widths[index] = max(widths[index], longestLine)
            }
        }
        var sheet = header + "<worksheet xmlns=\"\(main)\">"
        if !widths.isEmpty {
            sheet += "<cols>" + widths.enumerated().map { index, width in
                "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(min(max(width, 6), 60) + 2)\" customWidth=\"1\"/>"
            }.joined() + "</cols>"
        }
        sheet += "<sheetData>"
        for (rowIndex, row) in rows.enumerated() where row.contains(where: { !$0.isEmpty }) {
            sheet += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = columnName(columnIndex) + String(rowIndex + 1)
                if isPlainNumber(value) {
                    sheet += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                } else {
                    let preserve = value.first?.isWhitespace == true || value.last?.isWhitespace == true
                    sheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t\(preserve ? " xml:space=\"preserve\"" : "")>"
                        + escape(value) + "</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        return ZipArchive.write([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(packageRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    /// Decimal text a spreadsheet keeps exactly: no leading zeros (IDs, postcodes), at most 15 digits.
    static func isPlainNumber(_ text: String) -> Bool {
        guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
        return text.filter(\.isNumber).count <= 15
    }

    /// 0 → A, 25 → Z, 26 → AA.
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// A → 0, Z → 25, AA → 26 (the letters of a cell reference like "AB12").
    static func columnIndex(ofReference reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            index = index * 26 + Int(scalar.value & 0x1F)
            sawLetter = true
        }
        return sawLetter ? index - 1 : nil
    }

    private static func safeSheetName(_ name: String) -> String {
        let cleaned = name.filter { !"[]:*?/\\".contains($0) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "'").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Sheet1" : String(cleaned.prefix(31))
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                // Other control characters are not allowed in XML 1.0.
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

// MARK: - XML helpers

/// A small element tree for the short package parts (relationships, workbook, styles).
private final class Element {
    let name: String
    let attributes: [String: String]
    var children: [Element] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Looks an attribute up by its local name, whatever namespace prefix it has.
    func attribute(_ localName: String) -> String? {
        attributes[localName] ?? attributes.first { $0.key.hasSuffix(":" + localName) }?.value
    }

    func descendants(_ localName: String) -> [Element] {
        children.flatMap { ($0.name == localName ? [$0] : []) + $0.descendants(localName) }
    }

    static func parse(_ data: Data) -> Element? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = Element(name: localName(elementName), attributes: attributeDict)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

/// `xl/sharedStrings.xml`: one string per `<si>`, rich-text runs joined, phonetic hints skipped.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false
    private var phoneticDepth = 0

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "si": current = ""
        case "t": inText = true
        case "rPh": phoneticDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText && phoneticDepth == 0 { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName) {
        case "si": strings.append(current)
        case "t": inText = false
        case "rPh": phoneticDepth -= 1
        default: break
        }
    }
}

/// A worksheet's `<sheetData>` as a rectangular grid of display values.
private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let date1904: Bool

    private var rows: [[String]] = []
    private var rowNumber = 0
    private var column = -1
    private var type = ""
    private var style = 0
    private var value = ""
    private var inlineText = ""
    private var capturingValue = false
    private var capturingInline = false
    private var phoneticDepth = 0

    private init(sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
    }

    static func parse(_ data: Data, sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) -> [[String]] {
        let delegate = SheetParser(sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.grid()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "row":
            rowNumber = attributeDict["r"].flatMap(Int.init) ?? rowNumber + 1
            column = -1
        case "c":
            column = attributeDict["r"].flatMap(XLSX.columnIndex(ofReference:)) ?? column + 1
            type = attributeDict["t"] ?? "n"
            style = attributeDict["s"].flatMap(Int.init) ?? 0
            value = ""
            inlineText = ""
        case "v": capturingValue = true
        case "t": capturingInline = true
        case "rPh": phoneticDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingValue { value += string }
        if capturingInline && phoneticDepth == 0 { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName) {
        case "v": capturingValue = false
        case "t": capturingInline = false
        case "rPh": phoneticDepth -= 1
        case "c": store(displayValue())
        default: break
        }
    }

    private func displayValue() -> String {
        switch type {
        case "s": Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? ""
        case "inlineStr": inlineText
        case "b": value == "1" ? "TRUE" : "FALSE"
        case "str", "e", "d": value
        default:
            if dateStyles.contains(style), let serial = Double(value) {
                XLSX.dateText(serial: serial, date1904: date1904)
            } else {
                value
            }
        }
    }

    private func store(_ text: String) {
        guard !text.isEmpty, rowNumber > 0, column >= 0 else { return }
        while rows.count < rowNumber { rows.append([]) }
        while rows[rowNumber - 1].count <= column { rows[rowNumber - 1].append("") }
        rows[rowNumber - 1][column] = text
    }

    private func grid() -> [[String]] {
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}
