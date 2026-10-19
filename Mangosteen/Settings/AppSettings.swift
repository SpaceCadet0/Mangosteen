import AppKit
import ServiceManagement

enum TerminalChoice: String, CaseIterable, Identifiable {
    case terminal, iterm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let convertModifier = "convertModifier"
        static let toolsModifier = "toolsModifier"
        static let actionsModifier = "actionsModifier"
        static let playSounds = "playSounds"
        static let haptics = "haptics"
        static let revealInFinder = "revealInFinder"
        static let jpegQuality = "jpegQuality"
        static let heicQuality = "heicQuality"
        static let avifQuality = "avifQuality"
        static let webpQuality = "webpQuality"
        static let preserveMetadata = "preserveMetadata"
        static let terminalApp = "terminalApp"
    }

    private let defaults: UserDefaults

    @Published var convertModifier: ModifierChoice { didSet { defaults.set(convertModifier.rawValue, forKey: Key.convertModifier) } }
    @Published var toolsModifier: ModifierChoice { didSet { defaults.set(toolsModifier.rawValue, forKey: Key.toolsModifier) } }
    @Published var actionsModifier: ModifierChoice { didSet { defaults.set(actionsModifier.rawValue, forKey: Key.actionsModifier) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: Key.revealInFinder) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var heicQuality: Double { didSet { defaults.set(heicQuality, forKey: Key.heicQuality) } }
    @Published var avifQuality: Double { didSet { defaults.set(avifQuality, forKey: Key.avifQuality) } }
    @Published var webpQuality: Int { didSet { defaults.set(webpQuality, forKey: Key.webpQuality) } }
    @Published var preserveMetadata: Bool { didSet { defaults.set(preserveMetadata, forKey: Key.preserveMetadata) } }
    @Published var terminalApp: TerminalChoice { didSet { defaults.set(terminalApp.rawValue, forKey: Key.terminalApp) } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Feedback.showError("Автозапуск", error)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = ConversionOptions()
        defaults.register(defaults: [
            Key.convertModifier: ModifierChoice.shift.rawValue,
            Key.toolsModifier: ModifierChoice.command.rawValue,
            Key.actionsModifier: ModifierChoice.control.rawValue,
            Key.playSounds: true,
            Key.haptics: true,
            Key.revealInFinder: false,
            Key.jpegQuality: fallback.jpegQuality,
            Key.heicQuality: fallback.heicQuality,
            Key.avifQuality: fallback.avifQuality,
            Key.webpQuality: fallback.webpQuality,
            Key.preserveMetadata: fallback.preserveMetadata,
            Key.terminalApp: TerminalChoice.terminal.rawValue,
        ])
        convertModifier = ModifierChoice(rawValue: defaults.string(forKey: Key.convertModifier) ?? "") ?? .shift
        toolsModifier = ModifierChoice(rawValue: defaults.string(forKey: Key.toolsModifier) ?? "") ?? .command
        actionsModifier = ModifierChoice(rawValue: defaults.string(forKey: Key.actionsModifier) ?? "") ?? .control
        playSounds = defaults.bool(forKey: Key.playSounds)
        haptics = defaults.bool(forKey: Key.haptics)
        revealInFinder = defaults.bool(forKey: Key.revealInFinder)
        jpegQuality = defaults.double(forKey: Key.jpegQuality)
        heicQuality = defaults.double(forKey: Key.heicQuality)
        avifQuality = defaults.double(forKey: Key.avifQuality)
        webpQuality = defaults.integer(forKey: Key.webpQuality)
        preserveMetadata = defaults.bool(forKey: Key.preserveMetadata)
        terminalApp = TerminalChoice(rawValue: defaults.string(forKey: Key.terminalApp) ?? "") ?? .terminal
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The wheel opened by tapping exactly `flags`. The first matching wheel wins if two share a key.
    func wheelKind(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        let assignments: [(ModifierChoice, WheelKind)] = [
            (convertModifier, .convert), (toolsModifier, .tools), (actionsModifier, .actions),
        ]
        return assignments.first { $0.0.flags == flags }?.1
    }

    var conversionOptions: ConversionOptions {
        ConversionOptions(jpegQuality: jpegQuality, heicQuality: heicQuality, avifQuality: avifQuality,
                          webpQuality: webpQuality, preserveMetadata: preserveMetadata)
    }
}
