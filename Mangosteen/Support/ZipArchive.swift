import Compression
import Foundation

/// A minimal in-memory ZIP reader and writer (stored and deflated entries, no ZIP64), enough for
/// Office Open XML packages such as XLSX.
enum ZipArchive {
    enum Failure: Error {
        case malformed
        case unsupportedMethod(UInt16)
        case inflateFailed(String)
    }

    /// Reads every file entry of the archive into memory, keyed by its path inside the archive.
    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let end = endOfCentralDirectory(in: bytes) else { throw Failure.malformed }
        let count = Int(bytes.uint16(at: end + 10))
        var cursor = Int(bytes.uint32(at: end + 16))
        var entries: [String: Data] = [:]
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.uint32(at: cursor) == 0x0201_4B50 else { throw Failure.malformed }
            let method = bytes.uint16(at: cursor + 10)
            let compressedSize = Int(bytes.uint32(at: cursor + 20))
            let size = Int(bytes.uint32(at: cursor + 24))
            let nameLength = Int(bytes.uint16(at: cursor + 28))
            let extraLength = Int(bytes.uint16(at: cursor + 30))
            let commentLength = Int(bytes.uint16(at: cursor + 32))
            let localHeader = Int(bytes.uint32(at: cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw Failure.malformed }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard !name.hasSuffix("/") else { continue }
            guard localHeader + 30 <= bytes.count, bytes.uint32(at: localHeader) == 0x0403_4B50 else {
                throw Failure.malformed
            }
            let start = localHeader + 30 + Int(bytes.uint16(at: localHeader + 26)) + Int(bytes.uint16(at: localHeader + 28))
            guard start + compressedSize <= bytes.count else { throw Failure.malformed }
            let payload = bytes[start..<(start + compressedSize)]
            switch method {
            case 0: entries[name] = Data(payload)
            case 8: entries[name] = try inflate(payload, size: size, name: name)
            default: throw Failure.unsupportedMethod(method)
            }
        }
        return entries
    }

    /// Builds an archive from `(path, contents)` pairs, in the given order, deflating each entry.
    static func write(_ entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for (path, contents) in entries {
            let name = Data(path.utf8)
            let deflated = deflate(contents)
            let useDeflate = deflated.map { $0.count < contents.count } ?? false
            let payload = useDeflate ? deflated! : contents
            let crc = CRC32.checksum(contents)
            let offset = UInt32(archive.count)

            func common(_ data: inout Data) {
                data.append(uint16: 20) // version needed: 2.0
                data.append(uint16: 0x0800) // flags: UTF-8 names
                data.append(uint16: useDeflate ? 8 : 0)
                data.append(uint16: 0) // time
                data.append(uint16: 0x21) // date: 1980-01-01
                data.append(uint32: crc)
                data.append(uint32: UInt32(payload.count))
                data.append(uint32: UInt32(contents.count))
                data.append(uint16: UInt16(name.count))
                data.append(uint16: 0) // extra
            }

            archive.append(uint32: 0x0403_4B50)
            common(&archive)
            archive.append(name)
            archive.append(payload)

            directory.append(uint32: 0x0201_4B50)
            directory.append(uint16: 20) // made by
            common(&directory)
            directory.append(uint16: 0) // comment
            directory.append(uint16: 0) // disk
            directory.append(uint16: 0) // internal attributes
            directory.append(uint32: 0) // external attributes
            directory.append(uint32: offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(uint32: 0x0605_4B50)
        archive.append(uint16: 0)
        archive.append(uint16: 0)
        archive.append(uint16: UInt16(entries.count))
        archive.append(uint16: UInt16(entries.count))
        archive.append(uint32: UInt32(directory.count))
        archive.append(uint32: directoryOffset)
        archive.append(uint16: 0)
        return archive
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65_535)
        var index = bytes.count - 22
        while index >= lowest {
            if bytes.uint32(at: index) == 0x0605_4B50 { return index }
            index -= 1
        }
        return nil
    }

    /// Raw DEFLATE (what ZIP stores) is Compression's `COMPRESSION_ZLIB`.
    private static func inflate(_ payload: ArraySlice<UInt8>, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        guard !payload.isEmpty else { throw Failure.inflateFailed(name) }
        var output = [UInt8](repeating: 0, count: size)
        let written = payload.withUnsafeBufferPointer { source in
            compression_decode_buffer(&output, size, source.baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw Failure.inflateFailed(name) }
        return Data(output)
    }

    private static func deflate(_ contents: Data) -> Data? {
        guard !contents.isEmpty else { return nil }
        let capacity = contents.count + contents.count / 10 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = contents.withUnsafeBytes { source in
            compression_encode_buffer(&output, capacity, source.bindMemory(to: UInt8.self).baseAddress!,
                                      contents.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(output[0..<written]) : nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Array where Element == UInt8 {
    func uint16(at index: Int) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func uint32(at index: Int) -> UInt32 {
        UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
