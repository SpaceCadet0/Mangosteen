import Foundation

enum JSONTableError: LocalizedError {
    case notTable(URL?)
    case malformed(URL?)

    var errorDescription: String? {
        switch self {
        case .notTable(let url):
            String(localized: "В «\(url?.lastPathComponent ?? "JSON")» данные не в виде таблицы. Нужен массив записей, например [{\"имя\": \"Чай\", \"цена\": 1.5}].")
        case .malformed(let url):
            String(localized: "«\(url?.lastPathComponent ?? "JSON")» не читается как JSON.")
        }
    }
}

/// JSON ↔ table rows. Reading keeps the order of keys as they appear in the file (Foundation's parser does not), so
/// columns come out in the author's order. Nested objects become `a.b` columns; arrays inside a record are kept as
/// JSON text. Writing makes one flat object per row, keyed by the first row.
enum JSONTable {
    indirect enum Value: Equatable {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        /// The number exactly as written, so "1.50" and big integers survive.
        case number(String)
        case bool(Bool)
        case null

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.object(let a), .object(let b)): a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
            case (.array(let a), .array(let b)): a == b
            case (.string(let a), .string(let b)), (.number(let a), .number(let b)): a == b
            case (.bool(let a), .bool(let b)): a == b
            case (.null, .null): true
            default: false
            }
        }
    }

    // MARK: Reading

    static func rows(from text: String, source: URL? = nil) throws -> [[String]] {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        guard let value = try? parser.parseDocument() else { throw JSONTableError.malformed(source) }
        guard case .array(let items) = value, !items.isEmpty else { throw JSONTableError.notTable(source) }

        // An array of arrays is already rows.
        if items.allSatisfy({ if case .array = $0 { true } else { false } }) {
            return items.map { item in
                guard case .array(let cells) = item else { return [] }
                return cells.map(cellText)
            }
        }
        guard items.allSatisfy({ if case .object = $0 { true } else { false } }) else { throw JSONTableError.notTable(source) }

        var columns: [String] = []
        var seen: Set<String> = []
        let records: [[String: String]] = items.map { item in
            var record: [String: String] = [:]
            flatten(item, prefix: nil, into: &record) { key in
                if seen.insert(key).inserted { columns.append(key) }
            }
            return record
        }
        return [columns] + records.map { record in columns.map { record[$0] ?? "" } }
    }

    private static func flatten(_ value: Value, prefix: String?, into record: inout [String: String],
                                newColumn: (String) -> Void) {
        if case .object(let pairs) = value {
            for (key, nested) in pairs {
                let name = prefix.map { "\($0).\(key)" } ?? key
                if case .object(let inner) = nested, !inner.isEmpty {
                    flatten(nested, prefix: name, into: &record, newColumn: newColumn)
                } else {
                    newColumn(name)
                    record[name] = cellText(nested)
                }
            }
        }
    }

    /// The text of one cell: strings as they are, numbers as written, true/false, empty for null, JSON for the rest.
    static func cellText(_ value: Value) -> String {
        switch value {
        case .string(let text): text
        case .number(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        case .array, .object: serialize(value)
        }
    }

    // MARK: Writing

    /// The first row names the keys. Plain decimal numbers and true/false become JSON numbers and booleans; text
    /// such as "007" stays a string, as does everything else.
    static func json(from rows: [[String]]) -> String {
        guard let header = rows.first else { return "[]\n" }
        let keys = header.enumerated().map { index, name in name.isEmpty ? "column\(index + 1)" : name }
        let objects = rows.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            "  {\n" + keys.enumerated().map { index, key in
                let cell = index < row.count ? row[index] : ""
                let value: Value = XLSX.isPlainNumber(cell) ? .number(cell)
                    : cell == "true" ? .bool(true) : cell == "false" ? .bool(false) : .string(cell)
                return "    \(serialize(.string(key))): \(serialize(value))"
            }.joined(separator: ",\n") + "\n  }"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    static func serialize(_ value: Value) -> String {
        switch value {
        case .string(let text):
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                default:
                    if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) } else { result.unicodeScalars.append(scalar) }
                }
            }
            return result + "\""
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(serialize).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { "\(serialize(.string($0.0))):\(serialize($0.1))" }.joined(separator: ",") + "}"
        }
    }

    // MARK: Parser

    private struct Parser {
        struct Failure: Error {}
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func parseDocument() throws -> Value {
            if scalars.first == "\u{FEFF}" { index = 1 }
            let value = try parseValue()
            skipSpace()
            guard index == scalars.count else { throw Failure() }
            return value
        }

        private mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        private mutating func expect(_ scalar: Unicode.Scalar) throws {
            skipSpace()
            guard index < scalars.count, scalars[index] == scalar else { throw Failure() }
            index += 1
        }

        private mutating func parseValue() throws -> Value {
            skipSpace()
            guard index < scalars.count else { throw Failure() }
            switch scalars[index] {
            case "{":
                index += 1
                var pairs: [(String, Value)] = []
                skipSpace()
                if index < scalars.count, scalars[index] == "}" { index += 1; return .object(pairs) }
                repeat {
                    skipSpace()
                    let key = try parseString()
                    try expect(":")
                    pairs.append((key, try parseValue()))
                    skipSpace()
                } while try nextItem(closing: "}")
                return .object(pairs)
            case "[":
                index += 1
                var items: [Value] = []
                skipSpace()
                if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
                repeat {
                    items.append(try parseValue())
                    skipSpace()
                } while try nextItem(closing: "]")
                return .array(items)
            case "\"":
                return .string(try parseString())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default:
                return .number(try parseNumber())
            }
        }

        /// After an item: a comma means another follows, the closing bracket ends the list.
        private mutating func nextItem(closing: Unicode.Scalar) throws -> Bool {
            guard index < scalars.count else { throw Failure() }
            if scalars[index] == "," { index += 1; return true }
            if scalars[index] == closing { index += 1; return false }
            throw Failure()
        }

        private mutating func literal(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw Failure() }
                index += 1
            }
        }

        private mutating func parseNumber() throws -> String {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard !text.isEmpty, Double(text) != nil else { throw Failure() }
            return text
        }

        private mutating func parseString() throws -> String {
            guard index < scalars.count, scalars[index] == "\"" else { throw Failure() }
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"": return String(result)
                case "\\":
                    guard index < scalars.count else { throw Failure() }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "u":
                        var code = try hex4()
                        // A surrogate pair encodes one character outside the Basic Multilingual Plane.
                        if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let character = Unicode.Scalar(code) else { throw Failure() }
                        result.append(character)
                    default: result.append(escaped)
                    }
                default:
                    result.append(scalar)
                }
            }
            throw Failure()
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count,
                  let value = UInt32(String(String.UnicodeScalarView(scalars[index..<(index + 4)])), radix: 16) else { throw Failure() }
            index += 4
            return value
        }
    }
}
