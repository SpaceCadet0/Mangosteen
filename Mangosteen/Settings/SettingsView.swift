import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var language = AppLanguage.current
    private let launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            Section {
                modifierPicker(String(localized: "Конвертация"), selection: $settings.convertModifier)
                modifierPicker(String(localized: "Инструменты"), selection: $settings.toolsModifier)
                modifierPicker(String(localized: "Действия"), selection: $settings.actionsModifier)
            } header: {
                Text(String(localized: "Колёса"))
            } footer: {
                Text(String(localized: "Начните перетаскивать файл и коротко нажмите клавишу. Колесо останется открытым, пока вы не отпустите файл."))
            }

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

            Section(String(localized: "Система")) {
                Picker(String(localized: "Терминал"), selection: $settings.terminalApp) {
                    ForEach(TerminalChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle(String(localized: "Запускать при входе в систему"), isOn: $settings.launchAtLogin)
            }

            Section {
                ForEach(["cwebp", "ffmpeg", "exiftool"], id: \.self) { tool in
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
        .frame(width: 520, height: 640)
    }

    private func modifierPicker(_ title: String, selection: Binding<ModifierChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) }
        }
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
