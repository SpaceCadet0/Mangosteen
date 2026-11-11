import SwiftUI

/// "To vector": the picture on the left, its trace on the right; black-and-white or up to 16 colours, how much detail,
/// smooth curves, and dropping the background. Saving writes "<name>.svg" for every picture.
struct VectorTraceView: View {
    let urls: [URL]
    let close: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case blackAndWhite, colors
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blackAndWhite: String(localized: "Чёрно-белый")
            case .colors: String(localized: "Цвета")
            }
        }
    }

    @State private var source: CGImage?
    @State private var result: VectorTracer.Result?
    @StateObject private var zoom = ZoomControl()
    @State private var shapes = 0
    @State private var message: String?
    @State private var mode = Mode.blackAndWhite
    @State private var colors = 6
    @State private var detail = 0.6
    @State private var smooth = true
    @State private var dropBackground = false
    @State private var busy = false

    private var images: [URL] {
        urls.filter { FileFormat.detect($0).map { $0.category == .image && $0 != .svg } ?? false }
    }

    private var options: VectorTracer.Options {
        VectorTracer.Options(colors: mode == .blackAndWhite ? 1 : colors, detail: detail, smooth: smooth,
                             dropBackground: dropBackground)
    }

    var body: some View {
        VStack(spacing: 14) {
            SyncedZoomPanes(image: source, result: result, control: zoom)
                .overlay { overlay }
                .frame(minWidth: 700, idealWidth: 820, minHeight: 380, idealHeight: 460)
            HStack(spacing: 12) {
                Text(String(localized: "Оригинал")).frame(maxWidth: .infinity)
                Text(String(localized: "Вектор")).frame(maxWidth: .infinity)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            zoomBar

            HStack(spacing: 16) {
                Picker(String(localized: "Режим"), selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                if mode == .colors {
                    Stepper(String(localized: "Цветов: \(colors)"), value: $colors, in: 2...16)
                        .fixedSize()
                }
                Toggle(String(localized: "Без фона"), isOn: $dropBackground)
                    .help(mode == .blackAndWhite ? String(localized: "Только чёрное, без белой бумаги под ним")
                                                 : String(localized: "Без цвета, которого больше всего по краям картинки"))
                Spacer()
            }
            HStack(spacing: 16) {
                LabeledContent(String(localized: "Детализация")) {
                    Slider(value: $detail, in: 0...1).frame(width: 220)
                }
                .fixedSize()
                Toggle(String(localized: "Плавные кривые"), isOn: $smooth)
                Spacer()
                if result != nil {
                    Text(String(localized: "Фигур: \(shapes)"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(String(localized: "Лучше всего для логотипов, иконок, рисунков и сканов текста. Фото превращается в плакат из цветных пятен."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ToolFooter(fileCount: images.count, actionTitle: String(localized: "Сохранить SVG"),
                       actionDisabled: result == nil, cancel: close, action: run)
        }
        .padding(20)
        .task(id: options) { await retrace() }
    }

    /// A message or a spinner over the panes while there is nothing (new) to show.
    @ViewBuilder private var overlay: some View {
        if let message {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else if source == nil || busy {
            ProgressView().controlSize(.large)
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help(String(localized: "Уменьшить"))
            Text("\(Int((zoom.magnification * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 52)
            Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help(String(localized: "Увеличить"))
            Button("1:1") { zoom.actualSize() }
                .help(String(localized: "Пиксель в пиксель"))
            Button(String(localized: "Вписать")) { zoom.fit() }
            Text(String(localized: "Колёсико — масштаб, перетаскивание — сдвиг. Оба окна двигаются вместе."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .disabled(source == nil)
    }

    private func retrace() async {
        guard let first = images.first else {
            message = String(localized: "Нет изображений")
            return
        }
        // Moving a slider retraces; a short pause lets the drag finish first.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        let options = options
        let loaded = source
        busy = true
        // A newer setting cancels this preview; the work in the background stops too instead of piling up.
        let work = Task.detached(priority: .userInitiated) { () -> Swift.Result<(CGImage, VectorTracer.Result, Int), Error> in
            Result {
                let image = try loaded ?? ImageConverter.load(first, maxPixelSize: VectorTracer.workingSize).image
                let trace = try VectorTracer.trace(image, options: options, isCancelled: { Task.isCancelled })
                return (image, trace, trace.layers.reduce(0) { $0 + $1.path.subpathCount })
            }
        }
        let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        busy = false
        switch outcome {
        case .success(let (image, trace, count)):
            #if DEBUG
            // Snapshots of a zoomed preview: both panes should show the same enlarged spot.
            if source == nil, ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { zoom.setMagnification(3) }
            }
            #endif
            source = image
            result = trace
            shapes = count
            message = nil
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func run() {
        let options = options
        ConversionService.shared.runEach(String(localized: "Векторизация"), inputs: images) {
            try VectorTracer.traceFile($0, options: options)
        }
        close()
    }
}

private extension CGPath {
    /// How many closed shapes (and holes) the path holds.
    var subpathCount: Int {
        var count = 0
        applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
        return count
    }
}
