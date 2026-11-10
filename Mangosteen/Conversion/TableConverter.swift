import Foundation

/// CSV, TSV (RFC 4180 quoting) and XLSX. An XLSX source contributes its first sheet; `Converter` splits
/// workbooks with several sheets into a folder.
enum TableConverter {
    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws {
        let rows: [[String]]
        if source == .xlsx {
            rows = try XLSX.read(input).first { !$0.rows.isEmpty }?.rows ?? []
        } else if source == .json {
            rows = try JSONTable.rows(from: DocumentConverter.readText(input), source: input)
        } else {
            let text = try DocumentConverter.readText(input)
            rows = parse(text, separator: source == .csv ? detectedSeparator(in: text) : separator(for: source))
        }
        try write(rows, as: target, sheetName: OutputNaming.baseName(of: input), to: output)
    }

    /// The separator a CSV file really uses. Spreadsheets in locales with a decimal comma (Russian, Spanish…)
    /// save "CSV" with semicolons, and some tools write tabs. The one that splits the first line into the most
    /// fields wins (counted outside quotes); a comma when there is no difference.
    static func detectedSeparator(in text: String) -> Character {
        let firstLine = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for character in firstLine {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, counts[character] != nil {
                counts[character, default: 0] += 1
            }
        }
        var best: Character = ","
        for candidate: Character in [";", "\t"] where counts[candidate, default: 0] > counts[best, default: 0] {
            best = candidate
        }
        return best
    }

    static func write(_ rows: [[String]], as target: FileFormat, sheetName: String, to output: URL) throws {
        if target == .xlsx {
            try XLSX.write(rows: rows, sheetName: sheetName).write(to: output)
        } else if target == .json {
            try JSONTable.json(from: rows).write(to: output, atomically: false, encoding: .utf8)
        } else {
            try serialize(rows, separator: separator(for: target)).write(to: output, atomically: false, encoding: .utf8)
        }
    }

    /// A workbook with several non-empty sheets becomes a folder with one file per sheet.
    static func writeSheets(_ sheets: [XLSX.Sheet], as target: FileFormat, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sheet in sheets {
            let name = sheet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let baseName = name.hasPrefix(".") || name.isEmpty ? "_" + name : name
            let file = OutputNaming.uniqueURL(in: folder, baseName: baseName, pathExtension: target.fileExtension)
            try write(sheet.rows, as: target, sheetName: sheet.name, to: file)
        }
    }

    static func separator(for format: FileFormat) -> Character {
        format == .tsv ? "\t" : ","
    }

    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func serialize(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }
}
