import AVFoundation
import SwiftUI

/// "How to use" window, shown on first launch and from the status menu.
struct WelcomeView: View {
    let close: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    static let shownKey = "welcomeShown"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    steps
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DemoVideo(resource: "demo")
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    .accessibilityLabel(String(localized: "Как пользоваться Mangosteen"))
            }
            cards
            tip
            footer
        }
        .padding(24)
        .frame(width: 720)
        .onAppear { UserDefaults.standard.set(true, forKey: Self.shownKey) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: MangosteenArt.appIcon(size: 96))
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Добро пожаловать в Mangosteen"))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "Конвертация и инструменты для файлов прямо во время перетаскивания. Всё работает локально, без сторонних сервисов, без ограничений."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, String(localized: "Начните тащить файл — из Finder, с рабочего стола или из любого приложения."))
            step(2, String(localized: "Не отпуская кнопку, коротко нажмите клавишу — у курсора откроется колесо."))
            step(3, String(localized: "Бросьте файл на нужный сегмент. Результат появится рядом с оригиналом файла, сам оригинал никогда не меняется."))
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            card(settings.convertModifier, String(localized: "Конвертация"),
                 String(localized: "Изображения, PDF, документы, видео, аудио, субтитры, таблицы и архивы в другие форматы."))
            card(settings.toolsModifier, String(localized: "Инструменты"),
                 String(localized: "Сжатие, обрезка и размер в пикселях, редактор фото, пометки, скрытие, коллаж, а для видео и аудио — обрезка, скорость, громкость и другое."))
            card(settings.actionsModifier, String(localized: "Действия"),
                 String(localized: "Полка Float, AirDrop, копирование, перемещение, путь к файлу, терминал."))
        }
    }

    private var tip: some View {
        Label(String(localized: "Без перетаскивания: значок долек в строке меню → выберите колесо → укажите файлы и кликните по сегменту. Клавиши меняются в настройках."),
              systemImage: "lightbulb")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Toggle(String(localized: "Запускать Mangosteen при входе в систему"), isOn: $settings.launchAtLogin)
            Spacer()
            Button(String(localized: "Начать"), action: close)
                .keyboardShortcut(.defaultAction)
        }
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

/// The demo animation from the README, looping silently with no controls; it stops when the window closes.
private struct DemoVideo: NSViewRepresentable {
    let resource: String

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL?) {
            super.init(frame: .zero)
            wantsLayer = true
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
            player.isMuted = true
            if let url {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { player.pause() } else { player.play() }
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(url: Bundle.main.url(forResource: resource, withExtension: "mp4"))
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player.pause()
        view.player.removeAllItems()
    }
}
