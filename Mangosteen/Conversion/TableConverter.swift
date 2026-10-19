import Foundation

/// CSV, TSV (RFC 4180 quoting) and XLSX. An XLSX source contributes its first sheet; `Converter` splits
/// workbooks with several sheets into a folder.
enum TableConverter {
    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL) throws {
        let rows = source == .xlsx
            ? try XLSX.read(input).first { !$0.rows.isEmpty }?.rows ?? []
            : parse(try DocumentConverter.readText(input), separator: separator(for: source))
        try write(rows, as: target, sheetName: OutputNaming.baseName(of: input), to: output)
    }

    static func write(_ rows: [[String]], as target: FileFormat, sheetName: String, to output: URL) throws {
        if target == .xlsx {
            try XLSX.write(rows: rows, sheetName: sheetName).write(to: output)
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
