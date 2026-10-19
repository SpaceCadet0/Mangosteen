import SwiftUI

/// "How to use" window, shown on first launch and from the status menu.
struct WelcomeView: View {
    let close: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    static let shownKey = "welcomeShown"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: MangosteenArt.appIcon(size: 96))
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Добро пожаловать в Mangosteen")).font(.title2.weight(.semibold))
                    Text(String(localized: "Конвертация и инструменты для файлов прямо во время перетаскивания. Всё работает на этом Mac, без ограничений."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, String(localized: "Начните тащить файл — из Finder, с рабочего стола или из любого приложения."))
                step(2, String(localized: "Не отпуская кнопку, коротко нажмите клавишу — у курсора откроется колесо."))
                step(3, String(localized: "Бросьте файл на нужный сегмент. Результат появится рядом с оригиналом, оригинал не меняется."))
            }

            HStack(alignment: .top, spacing: 12) {
                card(settings.convertModifier, String(localized: "Конвертация"),
                     String(localized: "Изображения, PDF, документы, видео, аудио, субтитры, таблицы и архивы в другие форматы."))
                card(settings.toolsModifier, String(localized: "Инструменты"),
                     String(localized: "Сжатие, обрезка, редактор фото, пометки, скрытие, коллаж, а для видео и аудио — обрезка, скорость, громкость и другое."))
                card(settings.actionsModifier, String(localized: "Действия"),
                     String(localized: "Полка Float, AirDrop, копирование, перемещение, путь к файлу, терминал."))
            }

            Label(String(localized: "Без перетаскивания: значок долек в строке меню → выберите колесо → укажите файлы и кликните по сегменту. Клавиши меняются в настройках."),
                  systemImage: "lightbulb")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle(String(localized: "Запускать Mangosteen при входе в систему"), isOn: $settings.launchAtLogin)
                Spacer()
                Button(String(localized: "Начать"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear { UserDefaults.standard.set(true, forKey: Self.shownKey) }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Brand.color))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ key: ModifierChoice, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(key.symbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
                Text(title).font(.headline)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}
