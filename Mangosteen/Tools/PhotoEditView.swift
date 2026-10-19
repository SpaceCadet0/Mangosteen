import CoreImage
import SwiftUI

/// Photo editor: light, colour, detail and effects with a live preview. Hold the preview to see the original.
struct PhotoEditView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var adjustments = PhotoAdjustments()
    @State private var base: CIImage?
    @State private var original: NSImage?
    @State private var rendered: NSImage?
    @State private var previewScale = 1.0
    @State private var showOriginal = false
    @State private var loadError: String?

    private var images: [URL] { urls.filter { FileFormat.detect($0)?.category == .image } }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                preview
                ScrollView {
                    controls.padding(.trailing, 8)
                }
                .frame(width: 330)
            }
            HStack {
                Button("Сбросить всё") { adjustments = PhotoAdjustments() }
                    .disabled(adjustments.isIdentity)
                Spacer()
            }
            ToolFooter(fileCount: images.count, actionTitle: "Сохранить",
                       actionDisabled: adjustments.isIdentity || base == nil, cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .task(id: adjustments) { await renderPreview() }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image = showOriginal ? original : (rendered ?? original) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            VStack {
                Spacer()
                Text(showOriginal ? "Оригинал" : "Удерживайте, чтобы сравнить с оригиналом")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 520)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 50, perform: {}, onPressingChanged: { pressing in
            showOriginal = pressing
        })
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Свет") {
                slider("Экспозиция", \.exposure, -2...2)
                slider("Яркость", \.brightness, -1...1)
                slider("Контраст", \.contrast, -1...1)
                slider("Светлые участки", \.highlights, -1...0)
                slider("Тени", \.shadows, 0...1)
            }
            section("Цвет") {
                slider("Температура", \.temperature, -1...1)
                slider("Оттенок", \.tint, -1...1)
                slider("Насыщенность", \.saturation, -1...1)
                slider("Сочность", \.vibrance, -1...1)
            }
            section("Детали") {
                slider("Резкость", \.sharpness, 0...1)
                slider("Чёткость", \.clarity, 0...1)
                slider("Шумоподавление", \.noiseReduction, 0...1)
                slider("Убрать дымку", \.dehaze, 0...1)
            }
            section("Эффекты") {
                Picker("Фильтр", selection: $adjustments.effect) {
                    ForEach(PhotoAdjustments.Effect.allCases) { Text($0.title).tag($0) }
                }
                slider("Виньетка", \.vignette, 0...1)
                slider("Зерно", \.grain, 0...1)
            }
            Text("Двойной клик по названию сбрасывает ползунок.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<PhotoAdjustments, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        let value = Binding(get: { adjustments[keyPath: keyPath] }, set: { adjustments[keyPath: keyPath] = $0 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { adjustments[keyPath: keyPath] = PhotoAdjustments()[keyPath: keyPath] }
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func load() async {
        guard let first = images.first else {
            loadError = "Нет изображений"
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { (try ImageConverter.load(first, maxPixelSize: 1600).image, try ImageCropper.uprightSize(first)) }
        }.value
        switch result {
        case .success(let (image, fullSize)):
            previewScale = Double(image.width) / max(fullSize.width, 1)
            base = CIImage(cgImage: image)
            original = NSImage(cgImage: image, size: .zero)
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func renderPreview() async {
        guard let base else { return }
        if adjustments.isIdentity {
            rendered = nil
            return
        }
        let adjustments = adjustments
        let scale = previewScale
        let image = await Task.detached(priority: .userInitiated) {
            try? PhotoEditor.render(PhotoEditor.apply(adjustments, to: base, scale: scale))
        }.value
        guard !Task.isCancelled, let image else { return }
        rendered = NSImage(cgImage: image, size: .zero)
    }

    private func run() {
        let adjustments = adjustments
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach("Редактирование", inputs: images) {
            try PhotoEditor.applyFile($0, adjustments: adjustments, options: options)
        }
        close()
    }
}
