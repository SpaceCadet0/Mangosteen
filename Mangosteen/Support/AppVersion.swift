import Foundation

/// Dotted version numbers as releases are tagged: "v0.10.2" or "0.10.2".
enum AppVersion {
    /// "v0.10.2" → "0.10.2".
    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Compares numerically, part by part: 0.10.1 is newer than 0.9.9, and 1.0 equals 1.0.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalized(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalized(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0, right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
