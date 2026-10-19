import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                modifierPicker("Конвертация", selection: $settings.convertModifier)
                modifierPicker("Инструменты", selection: $settings.toolsModifier)
                modifierPicker("Действия", selection: $settings.actionsModifier)
            } header: {
                Text("Колёса")
            } footer: {
                Text("Начните перетаскивать файл и коротко нажмите клавишу. Колесо останется открытым, пока вы не отпустите файл.")
            }

            Section("Отклик") {
                Toggle("Звуки", isOn: $settings.playSounds)
                Toggle("Тактильный отклик трекпада", isOn: $settings.haptics)
                Toggle("Показывать результат в Finder", isOn: $settings.revealInFinder)
            }

            Section("Качество изображений") {
                qualitySlider("JPG", value: $settings.jpegQuality)
                qualitySlider("HEIC", value: $settings.heicQuality)
                qualitySlider("AVIF", value: $settings.avifQuality)
                qualitySlider("WebP", value: Binding(
                    get: { Double(settings.webpQuality) / 100 },
                    set: { settings.webpQuality = Int(($0 * 100).rounded()) }
                ))
                Toggle("Сохранять метаданные (EXIF, GPS, цветовой профиль)", isOn: $settings.preserveMetadata)
            }

            Section("Система") {
                Picker("Терминал", selection: $settings.terminalApp) {
                    ForEach(TerminalChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
            }

            Section {
                ForEach(["cwebp", "ffmpeg", "exiftool"], id: \.self) { tool in
                    LabeledContent(tool) {
                        if let path = ExternalTool.locate(tool)?.path {
                            Text(path).foregroundStyle(.secondary)
                        } else {
                            Text("не найдено — brew install \(ExternalTool.Missing.formula(for: tool))")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Утилиты")
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
