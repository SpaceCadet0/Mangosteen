import Foundation

/// Where a slice sits: on the face of the wheel, on its back (shown by flipping it), or nowhere.
enum SlicePlacement: String, CaseIterable, Identifiable {
    case front, back, hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .front: String(localized: "Лицевая")
        case .back: String(localized: "Обратная")
        case .hidden: String(localized: "Скрыта")
        }
    }
}

/// Splits a wheel's slices into its two sides. The user's choice for a slice id wins; without one a slice is on the
/// face, except the few new slices listed in `defaultBack`. A face with more than `maxFront` slices moves the rest
/// to the back, and a wheel whose face would be empty shows its back as the face.
enum WheelLayout {
    static let maxFront = 10
    /// Slices added after the wheels were settled; they start on the back so the familiar faces stay as they were.
    static let defaultBack: Set<String> = [
        "tool.extractSubtitles", "tool.speechSubtitles",
        "convert.ico", "convert.icns", "convert.psd", "convert.tga", "convert.exr", "convert.7z", "convert.iso",
    ]

    static func placement(of id: String, choices: [String: SlicePlacement]) -> SlicePlacement {
        choices[id] ?? (defaultBack.contains(id) ? .back : .front)
    }

    static func split<Item>(_ items: [Item], id: (Item) -> String,
                            choices: [String: SlicePlacement]) -> (front: [Item], back: [Item]) {
        var front: [Item] = []
        var back: [Item] = []
        for item in items {
            switch placement(of: id(item), choices: choices) {
            case .front: front.append(item)
            case .back: back.append(item)
            case .hidden: break
            }
        }
        // An empty face shows the back first; then any face holds at most `maxFront`, the rest going behind.
        if front.isEmpty { (front, back) = (back, []) }
        if front.count > maxFront {
            back = Array(front[maxFront...]) + back
            front = Array(front[..<maxFront])
        }
        return (front, back)
    }
}
