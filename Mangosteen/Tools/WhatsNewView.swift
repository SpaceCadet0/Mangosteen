import SwiftUI

/// "What's new": a few slides about the latest release, shown once after an update and from the menu. The pictures
/// are system symbols, so the slides add nothing to the app's size.
enum WhatsNew {
    struct Slide: Identifiable {
        let symbol: String
        let title: String
        let text: String
        var id: String { symbol + title }
    }

    /// The release these slides describe; they are shown once to people updating from an older version.
    static let version = "0.10.7"
    static let seenKey = "whatsNewSeenVersion"

    static var slides: [Slide] {
        [
            Slide(symbol: "square.and.arrow.down.on.square", title: String(localized: "Куда сохранять и как называть"),
                  text: String(localized: "Новая вкладка «Сохранение» в настройках: рядом с оригиналом, в выбранную папку или спрашивать каждый раз; шаблон имени с датой и временем; даты оригинала. Наборы настроек запоминают качество, размер и папку.")),
            Slide(symbol: "waveform.and.mic", title: String(localized: "Субтитры из речи"),
                  text: String(localized: "«Речь в текст» на колесе инструментов делает SRT, VTT или ASS из того, что говорят в видео и аудио. Речь распознаётся на этом Mac, ничего не отправляется в сеть.")),
            Slide(symbol: "scribble.variable", title: String(localized: "Картинка в вектор"),
                  text: String(localized: "«В вектор» превращает логотип, рисунок или скан в SVG — чёрно-белый или до 16 цветов, с белым фоном или без него. В предпросмотре оригинал и результат рядом: колёсико приближает, перетаскивание двигает, чтобы сравнить детали.")),
            Slide(symbol: "wrench.and.screwdriver", title: String(localized: "Мелкие инструменты"),
                  text: String(localized: "Несколько страниц PDF на листе и деление по диапазонам «1-3, 8, 12-»; видео без чёрных полос и HDR → SDR; метаданные видео, аудио и PDF; видео из Live Photo; миниатюры и «Открыть в» в недавних результатах.")),
            Slide(symbol: "doc.badge.plus", title: String(localized: "Новые форматы и языки"),
                  text: String(localized: "Чтение DDS, DICOM, CAB и DMG; запись ICO, ICNS, PSD, TGA, EXR, 7Z и ISO. Интерфейс теперь ещё и на немецком, французском, португальском, китайском и японском.")),
        ]
    }

    /// True when this copy is at least `version` and its slides have not been seen yet.
    static func shouldShow(current: String, seen: String?) -> Bool {
        guard !AppVersion.isNewer(version, than: current) else { return false }
        guard let seen else { return true }
        return AppVersion.isNewer(version, than: seen)
    }
}

struct WhatsNewView: View {
    let close: () -> Void
    #if DEBUG
    /// Snapshots open on the slide in MANGOSTEEN_SLIDE.
    @State private var index = Int(ProcessInfo.processInfo.environment["MANGOSTEEN_SLIDE"] ?? "") ?? 0
    #else
    @State private var index = 0
    #endif
    private let slides = WhatsNew.slides

    var body: some View {
        VStack(spacing: 18) {
            Text(String(localized: "Что нового в Mangosteen \(WhatsNew.version)"))
                .font(.title2.weight(.semibold))
            let slide = slides[index]
            VStack(spacing: 14) {
                Image(systemName: slide.symbol)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Brand.color)
                    .frame(height: 70)
                Text(slide.title)
                    .font(.headline)
                Text(slide.text)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 440, height: 220)
            .id(index)
            .transition(.opacity)
            HStack(spacing: 6) {
                ForEach(slides.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Brand.color : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            HStack {
                Button(String(localized: "Назад")) { withAnimation { index -= 1 } }
                    .disabled(index == 0)
                Spacer()
                if index < slides.count - 1 {
                    Button(String(localized: "Далее")) { withAnimation { index += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Готово"), action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
