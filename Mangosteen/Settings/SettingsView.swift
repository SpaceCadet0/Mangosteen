import SwiftUI

/// Settings in three tabs: general options, the wheels (keys and where each slice sits) and their appearance.
struct SettingsView: View {
    enum Tab: String { case general, wheels, appearance }

    @ObservedObject private var settings = AppSettings.shared
    /// The window opens on the tab used last time.
    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(settings: settings)
                .tabItem { Label(String(localized: "Основные"), systemImage: "gearshape") }
                .tag(Tab.general)
            WheelSettings(settings: settings)
                .tabItem { Label(String(localized: "Колёса"), systemImage: "circle.circle") }
                .tag(Tab.wheels)
            AppearanceSettings(settings: settings)
                .tabItem { Label(String(localized: "Оформление"), systemImage: "paintpalette") }
                .tag(Tab.appearance)
        }
        .frame(width: 540, height: 660)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var language = AppLanguage.current
    /// Not read here: this view is rebuilt whenever a setting changes, and the hint must compare with the start.
    private var launchLanguage: AppLanguage { AppLanguage.atLaunch }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Язык"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { $0.apply() }
                if language != launchLanguage {
                    HStack {
                        Text(String(localized: "Язык изменится после перезапуска."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Перезапустить")) { AppLanguage.relaunch() }
                    }
                }
            } header: {
                Text(verbatim: "Язык · Language · Idioma")
            }

            Section(String(localized: "Отклик")) {
                Toggle(String(localized: "Звуки"), isOn: $settings.playSounds)
                Toggle(String(localized: "Тактильный отклик трекпада"), isOn: $settings.haptics)
                Toggle(String(localized: "Показывать результат в Finder"), isOn: $settings.revealInFinder)
            }

            Section(String(localized: "Качество изображений")) {
                qualitySlider("JPG", value: $settings.jpegQuality)
                qualitySlider("HEIC", value: $settings.heicQuality)
                qualitySlider("AVIF", value: $settings.avifQuality)
                qualitySlider("WebP", value: Binding(
                    get: { Double(settings.webpQuality) / 100 },
                    set: { settings.webpQuality = Int(($0 * 100).rounded()) }
                ))
                Toggle(String(localized: "Сохранять метаданные (EXIF, GPS, цветовой профиль)"), isOn: $settings.preserveMetadata)
            }

            Section {
                Picker(String(localized: "Кодек"), selection: $settings.videoCodec) {
                    ForEach(VideoEncoding.Codec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                Toggle(String(localized: "Аппаратное кодирование"), isOn: $settings.hardwareVideoEncoding)
            } header: {
                Text(String(localized: "Видео"))
            } footer: {
                Text(String(localized: "Для видео, которое перекодируется в MP4, MOV или MKV. H.264 открывается везде; HEVC даёт файл меньше; AV1 — самый маленький, но кодируется дольше, а MOV с ним сохраняется в H.264. Аппаратное кодирование в разы быстрее, файлы чуть больше; для AV1 его нет. Видео, которое можно скопировать без перекодирования, копируется как есть. У «Сжать» свои настройки."))
            }

            Section(String(localized: "Система")) {
                Picker(String(localized: "Терминал"), selection: $settings.terminalApp) {
                    ForEach(TerminalChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle(String(localized: "Запускать при входе в систему"), isOn: $settings.launchAtLogin)
            }

            Section {
                ForEach(["ffmpeg", "ffprobe", "cwebp", "gif2webp"], id: \.self) { tool in
                    LabeledContent(tool) {
                        if let path = ExternalTool.locate(tool)?.path {
                            Text(path).foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "не найдено — brew install \(ExternalTool.Missing.formula(for: tool))"))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Утилиты"))
            }
        }
        .formStyle(.grouped)
    }

    private func qualitySlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0.1...1)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Wheels

private struct WheelSettings: View {
    @ObservedObject var settings: AppSettings
    /// Every slice of each wheel, grouped by the files that bring it.
    private let catalogs = WheelKind.allCases.map { ($0, WheelItemProvider.catalog(for: $0)) }

    var body: some View {
        Form {
            Section {
                modifierPicker(String(localized: "Конвертация"), selection: $settings.convertModifier)
                modifierPicker(String(localized: "Инструменты"), selection: $settings.toolsModifier)
                modifierPicker(String(localized: "Действия"), selection: $settings.actionsModifier)
            } header: {
                Text(String(localized: "Клавиши"))
            } footer: {
                Text(String(localized: "Начните перетаскивать файл и коротко нажмите клавишу. Колесо останется открытым, пока вы не отпустите файл."))
            }

            Section {
                Text(String(localized: "Если у колеса есть обратная сторона, в его центре видно «↻ ещё N». Чтобы перевернуть колесо, прокрутите колёсико мыши или трекпад над ним, задержите файл над центром или щёлкните по центру. Сторона дольки общая для всех файлов: например, PNG стоит одинаково для фото и для PDF. На лицевой стороне помещается до 10 долек, остальные уходят назад."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Вернуть как было")) { settings.slicePlacements = [:] }
                    .disabled(settings.slicePlacements.isEmpty)
            } header: {
                Text(String(localized: "Две стороны колеса"))
            }

            ForEach(catalogs, id: \.0) { kind, groups in
                Section(kind.title) {
                    ForEach(groups, id: \.group) { group in
                        Text(group.group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(group.items, id: \.id) { item in
                            placementRow(item)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modifierPicker(_ title: String, selection: Binding<ModifierChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) }
        }
    }

    private func placementRow(_ item: WheelItem) -> some View {
        let binding = Binding<SlicePlacement>(
            get: { WheelLayout.placement(of: item.id, choices: settings.slicePlacements) },
            set: { value in
                // Choosing the default again forgets the choice, so a later default change still applies.
                if value == WheelLayout.placement(of: item.id, choices: [:]) {
                    settings.slicePlacements[item.id] = nil
                } else {
                    settings.slicePlacements[item.id] = value
                }
            }
        )
        return HStack {
            Image(systemName: item.symbolName)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker(item.title, selection: binding) {
                ForEach(SlicePlacement.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                WheelPreview(accentHex: settings.accentHex, opacity: settings.wheelOpacity, glass: settings.wheelGlass)
                    .frame(width: WheelView.diameter, height: WheelView.diameter)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(Brand.presets) { preset in
                        swatch(preset)
                    }
                }
                ColorPicker(String(localized: "Свой цвет"), selection: Binding(
                    get: { Brand.nsColor.cgColor },
                    set: { settings.accentHex = Brand.hex(NSColor(cgColor: $0) ?? Brand.wine) }
                ), supportsOpacity: false)
            } header: {
                Text(String(localized: "Цвет акцента"))
            } footer: {
                Text(String(localized: "Подсветка дольки, строк меню и кнопок в окнах. Текст на нём становится белым или чёрным — каким лучше видно. Уже открытые окна примут цвет после повторного открытия."))
            }

            Section {
                LabeledContent(String(localized: "Непрозрачность")) {
                    HStack {
                        Slider(value: $settings.wheelOpacity, in: 0.4...1)
                        Text("\(Int((settings.wheelOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(String(localized: "Эффект стекла"), isOn: $settings.wheelGlass)
            } header: {
                Text(String(localized: "Колесо"))
            } footer: {
                if #available(macOS 26.0, *) {
                    Text(String(localized: "Стекло — системное Liquid Glass. С ним колесо можно сделать прозрачнее: то, что под ним, размывается."))
                } else {
                    Text(String(localized: "Стекло размывает то, что под колесом. С ним колесо можно сделать прозрачнее."))
                }
            }

            Section {
                Button(String(localized: "Вернуть как было")) {
                    settings.accentHex = ""
                    settings.wheelOpacity = 0.96
                    settings.wheelGlass = false
                }
                .disabled(settings.accentHex.isEmpty && settings.wheelOpacity == 0.96 && !settings.wheelGlass)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ preset: Brand.Preset) -> some View {
        let selected = settings.accentHex.uppercased() == preset.hex.uppercased()
        return Button {
            settings.accentHex = preset.hex
        } label: {
            Circle()
                .fill(Color(nsColor: preset.color))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 2 : 0).padding(-3))
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A live wheel with the chosen accent, opacity and glass, as it will look over the desktop.
private struct WheelPreview: NSViewRepresentable {
    let accentHex: String
    let opacity: Double
    let glass: Bool

    final class Container: NSView {
        let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.diameter, height: WheelView.diameter))
        var backdrop: NSView?

        /// SwiftUI sizes the view after it is made; keep the wheel and the glass centred in whatever it gets.
        override func layout() {
            super.layout()
            let side = WheelView.diameter
            wheel.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            let ring = WheelView.outerRadius * 2
            backdrop?.frame = NSRect(x: bounds.midX - ring / 2, y: bounds.midY - ring / 2, width: ring, height: ring)
        }
    }

    func makeNSView(context: Context) -> Container {
        let view = Container(frame: NSRect(x: 0, y: 0, width: WheelView.diameter, height: WheelView.diameter))
        view.addSubview(view.wheel)
        view.wheel.unregisterDraggedTypes()
        let sample = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photo.jpg")
        view.wheel.configure(kind: .convert, front: WheelItemProvider.items(for: .convert, urls: [sample]), fileCount: 1)
        view.wheel.showHighlight(1)
        return view
    }

    func updateNSView(_ view: Container, context: Context) {
        view.wheel.backgroundOpacity = opacity
        if glass, view.backdrop == nil {
            let backdrop = WheelView.makeBackdrop(in: view.bounds)
            view.addSubview(backdrop, positioned: .below, relativeTo: view.wheel)
            view.backdrop = backdrop
        } else if !glass, let backdrop = view.backdrop {
            backdrop.removeFromSuperview()
            view.backdrop = nil
        }
        view.needsLayout = true
        view.wheel.hasBackdrop = view.backdrop != nil
        // The accent is read while drawing.
        view.wheel.needsDisplay = true
    }
}
