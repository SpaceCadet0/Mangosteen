import CoreImage
import SwiftUI

/// A slider where a double-click toggles between the default value and the last changed value.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        /// The changed value to bring back on the next double-click.
        var stashed: Double?

        init(_ parent: ResettableSlider) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSlider) {
            parent.value = sender.doubleValue
        }

        /// `intended` is the value before the double-click began; its first click may have moved the knob.
        func toggle(from intended: Double, slider: NSSlider) {
            let isDefault = abs(intended - parent.defaultValue) < 0.0001
            let target: Double
            if !isDefault {
                stashed = intended
                target = parent.defaultValue
            } else {
                target = stashed ?? parent.defaultValue
            }
            slider.doubleValue = target
            parent.value = target
        }
    }

    final class Slider: NSSlider {
        var onDoubleClick: ((Double) -> Void)?
        private var valueBeforeClick: Double = 0

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick?(valueBeforeClick)
                return
            }
            valueBeforeClick = doubleValue
            super.mouseDown(with: event)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> Slider {
        let slider = Slider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.onDoubleClick = { [weak slider, coordinator = context.coordinator] intended in
            guard let slider else { return }
            coordinator.toggle(from: intended, slider: slider)
        }
        return slider
    }

    func updateNSView(_ slider: Slider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }
}

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
                Button(String(localized: "Сбросить всё")) { adjustments = PhotoAdjustments() }
                    .disabled(adjustments.isIdentity)
                Spacer()
            }
            ToolFooter(fileCount: images.count, actionTitle: String(localized: "Сохранить"),
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
                Text(showOriginal ? String(localized: "Оригинал") : String(localized: "Удерживайте, чтобы сравнить с оригиналом"))
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
            section(String(localized: "Свет")) {
                slider(String(localized: "Экспозиция"), \.exposure, -2...2)
                slider(String(localized: "Яркость"), \.brightness, -1...1)
                slider(String(localized: "Контраст"), \.contrast, -1...1)
                slider(String(localized: "Светлые участки"), \.highlights, -1...0)
                slider(String(localized: "Тени"), \.shadows, 0...1)
            }
            section(String(localized: "Цвет")) {
                slider(String(localized: "Температура"), \.temperature, -1...1)
                slider(String(localized: "Оттенок"), \.tint, -1...1)
                slider(String(localized: "Насыщенность"), \.saturation, -1...1)
                slider(String(localized: "Сочность"), \.vibrance, -1...1)
            }
            section(String(localized: "Детали")) {
                slider(String(localized: "Резкость"), \.sharpness, 0...1)
                slider(String(localized: "Чёткость"), \.clarity, 0...1)
                slider(String(localized: "Шумоподавление"), \.noiseReduction, 0...1)
                slider(String(localized: "Убрать дымку"), \.dehaze, 0...1)
            }
            section(String(localized: "Эффекты")) {
                Picker(String(localized: "Фильтр"), selection: $adjustments.effect) {
                    ForEach(PhotoAdjustments.Effect.allCases) { Text($0.title).tag($0) }
                }
                slider(String(localized: "Виньетка"), \.vignette, 0...1)
                slider(String(localized: "Зерно"), \.grain, 0...1)
            }
            Text(String(localized: "Двойной клик по ползунку сбрасывает его, повторный — возвращает изменённое значение."))
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
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            ResettableSlider(value: value, range: range, defaultValue: PhotoAdjustments()[keyPath: keyPath])
        }
    }

    private func load() async {
        guard let first = images.first else {
            loadError = String(localized: "Нет изображений")
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
        ConversionService.shared.runEach(String(localized: "Редактирование"), inputs: images) {
            try PhotoEditor.applyFile($0, adjustments: adjustments, options: options)
        }
        close()
    }
}
