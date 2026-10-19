import SwiftUI

/// Collage tool: arrange several images in a grid, row, column or featured layout.
struct CollageView: View {
    let urls: [URL]
    let close: () -> Void

    private struct PreviewKey: Equatable {
        var settings: CollageSettings
        var order: [URL]
        var loaded: Int
    }

    @State private var order: [URL] = []
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var settings = CollageSettings()
    @State private var rendered: NSImage?

    private static let widths = [1080, 1600, 2048, 3000, 4096, 6000]
    private static let formats: [FileFormat] = [.jpg, .png, .heic, .webp]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    if let rendered {
                        Image(nsImage: rendered).resizable().scaledToFit().padding(10)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 460, idealWidth: 560, minHeight: 420, idealHeight: 520)
                VStack(spacing: 10) {
                    controls
                    orderList
                }
                .frame(width: 340)
            }
            ToolFooter(fileCount: order.count, actionTitle: String(localized: "Создать коллаж"), actionDisabled: order.count < 2,
                       cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .task(id: PreviewKey(settings: settings, order: order, loaded: thumbnails.count)) { await renderPreview() }
    }

    private var controls: some View {
        Form {
            Picker(String(localized: "Раскладка"), selection: $settings.layout) {
                ForEach(CollageSettings.Layout.allCases) { Text($0.title).tag($0) }
            }
            if settings.layout == .grid {
                Stepper(value: $settings.columns, in: 0...max(order.count, 1)) {
                    Text(settings.columns == 0 ? String(localized: "Колонки: авто") : String(localized: "Колонки: \(settings.columns)"))
                }
            }
            Picker(String(localized: "Пропорции"), selection: $settings.aspect) {
                ForEach(CanvasAspect.allCases) { Text($0.title).tag($0) }
            }
            Picker(String(localized: "Ширина"), selection: $settings.width) {
                ForEach(Self.widths, id: \.self) { Text("\($0) px").tag($0) }
            }
            slider(String(localized: "Промежутки"), value: $settings.spacing, range: 0...0.06)
            slider(String(localized: "Скругление"), value: $settings.cornerRadius, range: 0...0.25)
            ColorPicker(String(localized: "Фон"), selection: Binding(get: { settings.background.cgColor },
                                                   set: { settings.background = RGBAColor($0) }),
                        supportsOpacity: false)
            Picker(String(localized: "Формат"), selection: $settings.format) {
                ForEach(Self.formats) { Text($0.displayName).tag($0) }
            }
        }
        .formStyle(.grouped)
        // Tall enough for every row, so nothing hides behind an inner scroll bar.
        .frame(height: settings.layout == .grid ? 430 : 385)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
        }
    }

    private var orderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Порядок — перетаскивайте строки")).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(order, id: \.self) { url in
                    HStack {
                        if let thumbnail = thumbnails[url] {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 110, idealHeight: 150)
        }
    }

    private func load() async {
        order = urls.filter { FileFormat.detect($0)?.category == .image }
        let urls = order
        let loaded = await Task.detached(priority: .userInitiated) { () -> [URL: CGImage] in
            var result: [URL: CGImage] = [:]
            for url in urls {
                result[url] = try? ImageConverter.load(url, maxPixelSize: 700).image
            }
            return result
        }.value
        thumbnails = loaded
    }

    private func renderPreview() async {
        let images = order.compactMap { thumbnails[$0] }
        guard images.count == order.count, !images.isEmpty else { return }
        // Spacing and corners are relative, so a narrower preview looks the same.
        var preview = settings
        preview.width = 1000
        let image = await Task.detached(priority: .userInitiated) {
            try? CollageComposer.compose(images, settings: preview)
        }.value
        guard !Task.isCancelled, let image else { return }
        rendered = NSImage(cgImage: image, size: .zero)
    }

    private func run() {
        let settings = settings
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runBatch(String(localized: "Коллаж"), inputs: order) {
            [try CollageComposer.composeFile($0, settings: settings, options: options)]
        }
        close()
    }
}
