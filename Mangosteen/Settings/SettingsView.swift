import SwiftUI

/// Settings in four tabs: general options, saving (folder, names, presets), the wheels (keys and where each slice
/// sits) and their appearance.
struct SettingsView: View {
    enum Tab: String { case general, saving, wheels, appearance }

    @ObservedObject private var settings = AppSettings.shared
    /// The window opens on the tab used last time.
    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(settings: settings)
                .tabItem { Label(String(localized: "Основные"), systemImage: "gearshape") }
                .tag(Tab.general)
            SavingSettings(settings: settings)
                .tabItem { Label(String(localized: "Сохранение"), systemImage: "square.and.arrow.down") }
                .tag(Tab.saving)
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

// MARK: - Saving

private struct SavingSettings: View {
    @ObservedObject var settings: AppSettings

    private var activeIndex: Int? {
        settings.activePresetID.flatMap { id in settings.presets.firstIndex { $0.id == id } }
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Набор"), selection: $settings.activePresetID) {
                    Text(String(localized: "Стандартный")).tag(UUID?.none)
                    ForEach(settings.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                HStack {
                    Button(String(localized: "Новый набор")) { addPreset() }
                    if let index = activeIndex {
                        Button(String(localized: "Удалить набор"), role: .destructive) {
                            settings.presets.remove(at: index)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Набор настроек"))
            } footer: {
                Text(String(localized: "Выбранный набор действует на все конвертации, пока его не сменить. «Стандартный» берёт качество картинок и метаданные с вкладки «Основные»."))
            }

            if let index = activeIndex {
                PresetQualitySection(preset: $settings.presets[index])
                SaveOptionsSections(mode: $settings.presets[index].saveMode, folder: $settings.presets[index].folderPath,
                                    template: $settings.presets[index].nameTemplate,
                                    keepDates: $settings.presets[index].keepDates)
            } else {
                SaveOptionsSections(mode: $settings.saveMode, folder: $settings.saveFolder,
                                    template: $settings.nameTemplate, keepDates: $settings.keepDates)
            }
        }
        .formStyle(.grouped)
    }

    /// A new preset starts from the standard settings, so only what differs needs changing.
    private func addPreset() {
        var preset = ConversionPreset(name: String(localized: "Набор \(settings.presets.count + 1)"))
        preset.quality = settings.jpegQuality
        preset.preserveMetadata = settings.preserveMetadata
        preset.saveMode = settings.saveMode
        preset.folderPath = settings.saveFolder
        preset.nameTemplate = settings.nameTemplate
        preset.keepDates = settings.keepDates
        settings.presets.append(preset)
        settings.activePresetID = preset.id
    }
}

private struct PresetQualitySection: View {
    @Binding var preset: ConversionPreset
    private static let sizes = [0, 3840, 2560, 1920, 1280, 1024, 800]

    var body: some View {
        Section(String(localized: "Картинки")) {
            TextField(String(localized: "Название"), text: $preset.name)
            LabeledContent(String(localized: "Качество")) {
                HStack {
                    Slider(value: $preset.quality, in: 0.1...1)
                    Text("\(Int((preset.quality * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Picker(String(localized: "Размер"), selection: $preset.maxPixelSize) {
                ForEach(Self.sizes, id: \.self) { size in
                    Text(size == 0 ? String(localized: "Не менять") : String(localized: "Не больше \(size) пикс.")).tag(size)
                }
            }
            Toggle(String(localized: "Сохранять метаданные (EXIF, GPS, цветовой профиль)"), isOn: $preset.preserveMetadata)
        }
    }
}

/// Where results go, what they are called and whether they keep the original's dates; shared by the standard
/// settings and every preset.
private struct SaveOptionsSections: View {
    @Binding var mode: SaveMode
    @Binding var folder: String
    @Binding var template: String
    @Binding var keepDates: Bool

    var body: some View {
        Section {
            Picker(String(localized: "Куда"), selection: $mode) {
                Text(String(localized: "Рядом с оригиналом")).tag(SaveMode.nextToOriginal)
                Text(String(localized: "В выбранную папку")).tag(SaveMode.folder)
                Text(String(localized: "Спрашивать каждый раз")).tag(SaveMode.ask)
            }
            if mode == .folder {
                LabeledContent(String(localized: "Папка")) {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "не выбрана")
                                            : (folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(folder.isEmpty ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(String(localized: "Выбрать…")) { chooseFolder() }
                    }
                }
            }
        } header: {
            Text(String(localized: "Куда сохранять"))
        } footer: {
            Text(String(localized: "Если в папку нельзя записывать, например это образ диска, результат сохраняется в «Загрузки». Оригинал никогда не меняется."))
        }

        Section {
            TextField(String(localized: "Шаблон"), text: $template)
            HStack {
                tokenButton(String(localized: "Имя"), "{name}")
                tokenButton(String(localized: "Дата"), "{date}")
                tokenButton(String(localized: "Время"), "{time}")
                tokenButton(String(localized: "Формат"), "{format}")
                Spacer()
                Button(String(localized: "Сбросить")) { template = OutputLocation.defaultTemplate }
                    .disabled(template == OutputLocation.defaultTemplate)
            }
            LabeledContent(String(localized: "Пример")) {
                Text(OutputLocation.name(String(localized: "фото"), pathExtension: "jpg", template: template) + ".jpg")
                    .foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Сохранять даты создания и изменения оригинала"), isOn: $keepDates)
        } header: {
            Text(String(localized: "Имя результата"))
        } footer: {
            Text(String(localized: "{name} — имя оригинала, {date} — дата, {time} — время, {format} — формат результата. Если имя занято, добавляется номер: «фото 2»."))
        }
    }

    private func tokenButton(_ title: String, _ token: String) -> some View {
        Button(title) { template += template.isEmpty || template.hasSuffix(" ") ? token : " " + token }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Выбрать")
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
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
                Text(String(localized: "Если у колеса есть обратная сторона, в его центре видно «↻ ещё N». Чтобы перевернуть колесо, прокрутите над ним колёсико мыши или нажмите Tab, пока держите файл; без файла можно щёлкнуть по центру. Сторона дольки общая для всех файлов: например, PNG стоит одинаково для фото и для PDF. На лицевой стороне помещается до 10 долек, остальные уходят назад."))
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
                    Text(String(localized: "Без стекла то, что под колесом, размывается, а непрозрачность решает, сколько его видно. Со стеклом каждая долька — системное Liquid Glass: ниже 70% оно прозрачное, выше — матовое."))
                } else {
                    Text(String(localized: "То, что под колесом, размывается; чем ниже непрозрачность, тем больше его видно."))
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
        var backdrop: WheelBackdrop?

        /// SwiftUI sizes the view after it is made; keep the wheel and the glass centred in whatever it gets.
        override func layout() {
            super.layout()
            let side = WheelView.diameter
            wheel.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            backdrop?.frame = wheel.frame
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
        // As on screen: a blur without the glass effect, shaped glass with it.
        if view.backdrop == nil || view.backdrop?.isGlass != glass {
            view.backdrop?.removeFromSuperview()
            let backdrop = WheelBackdrop(frame: view.wheel.frame, glass: glass)
            view.addSubview(backdrop, positioned: .below, relativeTo: view.wheel)
            view.backdrop = backdrop
        }
        view.needsLayout = true
        view.wheel.hasBackdrop = true
        view.wheel.glassBehind = view.backdrop?.isGlass ?? false
        view.backdrop?.update(segments: view.wheel.items.count, opacity: opacity)
        // The accent is read while drawing.
        view.wheel.needsDisplay = true
    }
}
