import AppKit
import ServiceManagement

/// The interface language. Applied by writing AppleLanguages for this app; takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en, es

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever the current language is.
    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .ru: "Русский"
        case .en: "English"
        case .es: "Español"
        }
    }

    static var current: AppLanguage {
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return stored?.first.flatMap { code in allCases.first { code.hasPrefix($0.rawValue) && $0 != .system } } ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Starts a fresh copy of the app and quits this one.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

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
        static let floatMovesFiles = "floatMovesFiles"
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
    /// Dragging out of Float moves the original instead of copying it.
    @Published var floatMovesFiles: Bool { didSet { defaults.set(floatMovesFiles, forKey: Key.floatMovesFiles) } }

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
                Feedback.showError(String(localized: "Автозапуск"), error)
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
        floatMovesFiles = defaults.bool(forKey: Key.floatMovesFiles)
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
