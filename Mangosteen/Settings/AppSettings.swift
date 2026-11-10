import AppKit
import ServiceManagement

/// The interface language. Applied by writing AppleLanguages for this app; takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en, es, de, fr
    case ptBR = "pt-BR"
    case zhHans = "zh-Hans"
    case ja

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever the current language is.
    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .ru: "Русский"
        case .en: "English"
        case .es: "Español"
        case .de: "Deutsch"
        case .fr: "Français"
        case .ptBR: "Português (Brasil)"
        case .zhHans: "简体中文"
        case .ja: "日本語"
        }
    }

    /// The language the app started in; a different choice takes effect after a relaunch. Read first at launch.
    static let atLaunch = current

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
        static let videoCodec = "videoCodec"
        static let hardwareVideoEncoding = "hardwareVideoEncoding"
        static let slicePlacements = "slicePlacements"
        static let accentHex = "accentHex"
        static let wheelOpacity = "wheelOpacity"
        static let wheelGlass = "wheelGlass"
        static let saveMode = "saveMode"
        static let saveFolder = "saveFolder"
        static let nameTemplate = "nameTemplate"
        static let keepDates = "keepDates"
        static let presets = "conversionPresets"
        static let activePreset = "activePreset"
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
    /// The encoder for re-encoded video; jobs read it through `VideoEncoding.current` when they start.
    @Published var videoCodec: VideoEncoding.Codec {
        didSet { defaults.set(videoCodec.rawValue, forKey: Key.videoCodec); VideoEncoding.current = videoEncoding }
    }
    @Published var hardwareVideoEncoding: Bool {
        didSet { defaults.set(hardwareVideoEncoding, forKey: Key.hardwareVideoEncoding); VideoEncoding.current = videoEncoding }
    }

    var videoEncoding: VideoEncoding { VideoEncoding(codec: videoCodec, hardware: hardwareVideoEncoding) }

    /// The user's side for each slice id that was moved; slices not listed follow `WheelLayout`'s defaults.
    @Published var slicePlacements: [String: SlicePlacement] {
        didSet { defaults.set(slicePlacements.mapValues(\.rawValue), forKey: Key.slicePlacements) }
    }
    /// "#RRGGBB" of the accent, or empty for the brand's own colour.
    @Published var accentHex: String { didSet { defaults.set(accentHex, forKey: Key.accentHex) } }
    /// Opacity of the wheel's background, 0.4…1.
    @Published var wheelOpacity: Double { didSet { defaults.set(wheelOpacity, forKey: Key.wheelOpacity) } }
    /// Frosted glass behind the wheel.
    @Published var wheelGlass: Bool { didSet { defaults.set(wheelGlass, forKey: Key.wheelGlass) } }

    // Saving: the standard values, used while no preset is active.
    @Published var saveMode: SaveMode { didSet { defaults.set(saveMode.rawValue, forKey: Key.saveMode); applyOutputPolicy() } }
    /// Path of the folder for `SaveMode.folder`; empty until one is chosen.
    @Published var saveFolder: String { didSet { defaults.set(saveFolder, forKey: Key.saveFolder); applyOutputPolicy() } }
    @Published var nameTemplate: String { didSet { defaults.set(nameTemplate, forKey: Key.nameTemplate); applyOutputPolicy() } }
    @Published var keepDates: Bool { didSet { defaults.set(keepDates, forKey: Key.keepDates); applyOutputPolicy() } }

    /// The user's presets, and the active one (nil: the standard settings).
    @Published var presets: [ConversionPreset] {
        didSet {
            defaults.set(try? JSONEncoder().encode(presets), forKey: Key.presets)
            if let id = activePresetID, !presets.contains(where: { $0.id == id }) { activePresetID = nil }
            applyOutputPolicy()
        }
    }
    @Published var activePresetID: UUID? {
        didSet { defaults.set(activePresetID?.uuidString, forKey: Key.activePreset); applyOutputPolicy() }
    }

    var activePreset: ConversionPreset? { activePresetID.flatMap { id in presets.first { $0.id == id } } }

    /// Save folder, name and dates from the active preset or the standard settings.
    var outputPolicy: OutputPolicy {
        if let activePreset { return activePreset.policy }
        return OutputPolicy(mode: saveMode, folder: saveFolder.isEmpty ? nil : URL(fileURLWithPath: saveFolder),
                            nameTemplate: nameTemplate, keepDates: keepDates)
    }

    private func applyOutputPolicy() { OutputLocation.policy = outputPolicy }

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
            Key.wheelOpacity: 0.96,
            Key.nameTemplate: OutputLocation.defaultTemplate,
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
        videoCodec = VideoEncoding.Codec(rawValue: defaults.string(forKey: Key.videoCodec) ?? "") ?? .h264
        hardwareVideoEncoding = defaults.bool(forKey: Key.hardwareVideoEncoding)
        slicePlacements = (defaults.dictionary(forKey: Key.slicePlacements) as? [String: String] ?? [:])
            .compactMapValues(SlicePlacement.init(rawValue:))
        accentHex = defaults.string(forKey: Key.accentHex) ?? ""
        wheelOpacity = min(max(defaults.double(forKey: Key.wheelOpacity), 0.4), 1)
        wheelGlass = defaults.bool(forKey: Key.wheelGlass)
        saveMode = SaveMode(rawValue: defaults.string(forKey: Key.saveMode) ?? "") ?? .nextToOriginal
        saveFolder = defaults.string(forKey: Key.saveFolder) ?? ""
        nameTemplate = defaults.string(forKey: Key.nameTemplate) ?? OutputLocation.defaultTemplate
        keepDates = defaults.bool(forKey: Key.keepDates)
        presets = defaults.data(forKey: Key.presets).flatMap { try? JSONDecoder().decode([ConversionPreset].self, from: $0) } ?? []
        activePresetID = defaults.string(forKey: Key.activePreset).flatMap(UUID.init(uuidString:))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // didSet does not run in init; hand the saved choices to the converters now.
        VideoEncoding.current = videoEncoding
        if let id = activePresetID, !presets.contains(where: { $0.id == id }) { activePresetID = nil }
        applyOutputPolicy()
    }

    /// The wheel opened by tapping exactly `flags`. The first matching wheel wins if two share a key.
    func wheelKind(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        let assignments: [(ModifierChoice, WheelKind)] = [
            (convertModifier, .convert), (toolsModifier, .tools), (actionsModifier, .actions),
        ]
        return assignments.first { $0.0.flags == flags }?.1
    }

    /// Picture quality, size and metadata from the active preset, or the standard settings.
    var conversionOptions: ConversionOptions {
        if let preset = activePreset {
            return ConversionOptions(jpegQuality: preset.quality, heicQuality: preset.quality, avifQuality: preset.quality,
                                     webpQuality: Int((preset.quality * 100).rounded()),
                                     preserveMetadata: preset.preserveMetadata,
                                     maxPixelSize: preset.maxPixelSize > 0 ? preset.maxPixelSize : nil)
        }
        return ConversionOptions(jpegQuality: jpegQuality, heicQuality: heicQuality, avifQuality: avifQuality,
                                 webpQuality: webpQuality, preserveMetadata: preserveMetadata)
    }
}
