import AppKit

/// The three wheels that can be opened while dragging.
enum WheelKind: String, CaseIterable, Identifiable {
    case convert
    case tools
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: String(localized: "Конвертация")
        case .tools: String(localized: "Инструменты")
        case .actions: String(localized: "Действия")
        }
    }
}

/// A modifier key the user can tap mid-drag to open a wheel.
enum ModifierChoice: String, CaseIterable, Identifiable {
    case shift, command, control, option, none

    var id: String { rawValue }

    static let relevantFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        case .none: nil
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .none: "—"
        }
    }

    var title: String {
        switch self {
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .none: String(localized: "Выключено")
        }
    }
}
