import SwiftUI

/// Subtitles from speech: pick the spoken language and the subtitle format, then every video and audio file gets
/// "<name> (речь).srt" next to it (or where Settings → Saving says).
struct SpeechSubtitlesView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var languages: [SpeechSubtitles.Language] = []
    @State private var language: SpeechSubtitles.Language?
    @State private var format = FileFormat.srt
    @State private var loaded = false

    private var media: [URL] {
        urls.filter { FileFormat.detect($0)?.category.isMedia == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Picker(String(localized: "Язык речи"), selection: $language) {
                    ForEach(languages) { Text($0.title).tag(SpeechSubtitles.Language?.some($0)) }
                }
                .disabled(languages.isEmpty)
                Picker(String(localized: "Формат"), selection: $format) {
                    ForEach([FileFormat.srt, .vtt, .ass, .txt]) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 112)

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ToolFooter(fileCount: media.count, actionTitle: String(localized: "Создать субтитры"),
                       actionDisabled: language == nil || media.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 520)
        .task {
            languages = await SpeechSubtitles.languages()
            language = SpeechSubtitles.preferred(in: languages)
            loaded = true
        }
    }

    private var note: String {
        if loaded, languages.isEmpty {
            return String(localized: "На этом Mac нет языков для распознавания речи без сети. Добавьте язык в «Системные настройки → Клавиатура → Диктовка».")
        }
        return String(localized: "Речь распознаётся на этом Mac, ничего не отправляется в сеть. Модель языка система может один раз скачать сама. Точность зависит от записи: музыка и шум мешают.")
    }

    private func run() {
        guard let language else { return }
        let target = format
        close()
        ConversionService.shared.runEach(String(localized: "Субтитры из речи"), inputs: media, maxConcurrent: 1) {
            try SpeechSubtitles.makeSubtitles($0, language: language, as: target, progress: $1, cancellation: $2)
        }
    }
}
