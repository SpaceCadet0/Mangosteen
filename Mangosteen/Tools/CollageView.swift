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
    /// Canvas size, cells and order of the rendered preview, to find the photo under the pointer.
    @State private var previewLayout: (size: CGSize, cells: [CGRect], order: [URL])?
    /// Index in `previewLayout` of the photo being dragged in the preview, and where the pointer is.
    @State private var dragSource: Int?
    @State private var dragLocation: CGPoint?

    private static let widths = [1080, 1600, 2048, 3000, 4096, 6000]
    private static let formats: [FileFormat] = [.jpg, .png, .heic, .webp]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    if let rendered {
                        GeometryReader { geometry in
                            preview(rendered, in: geometry.size)
                        }
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
            Picker(String(localized: "Фон"), selection: $settings.fill) {
                ForEach(CollageSettings.Fill.allCases) { Text($0.title).tag($0) }
            }
            switch settings.fill {
            case .color:
                ColorPicker(String(localized: "Цвет"), selection: color(\.background), supportsOpacity: false)
            case .gradient:
                ColorPicker(String(localized: "Начало"), selection: color(\.gradientStart), supportsOpacity: false)
                ColorPicker(String(localized: "Конец"), selection: color(\.gradientEnd), supportsOpacity: false)
                slider(String(localized: "Угол"), value: $settings.gradientAngle, range: 0...360)
            }
            slider(String(localized: "Тень"), value: $settings.shadow, range: 0...1)
            Picker(String(localized: "Формат"), selection: $settings.format) {
                ForEach(Self.formats) { Text($0.displayName).tag($0) }
            }
        }
        .toolForm()
        // Tall enough for every row, so nothing hides behind an inner scroll bar.
        .frame(height: 24 + 39 * CGFloat(rowCount))
    }

    private var rowCount: Int {
        8 + (settings.layout == .grid ? 1 : 0) + (settings.fill == .gradient ? 3 : 1)
    }

    private func color(_ keyPath: WritableKeyPath<CollageSettings, RGBAColor>) -> Binding<CGColor> {
        Binding(get: { settings[keyPath: keyPath].cgColor }, set: { settings[keyPath: keyPath] = RGBAColor($0) })
    }

    // MARK: - Reordering in the preview

    /// The rendered collage fitted into `size`, with photos that can be dragged onto another photo's place.
    private func preview(_ image: NSImage, in size: CGSize) -> some View {
        let frame = fittedFrame(in: size)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            if let source = dragSource, let rect = cellRect(source, in: frame) {
                Rectangle().fill(Color.black.opacity(0.4))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if dragSource != nil, let location = dragLocation, let target = cellIndex(at: location, in: frame),
               target != dragSource, let rect = cellRect(target, in: frame) {
                Rectangle().stroke(Brand.color, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if let source = dragSource, let location = dragLocation, let layout = previewLayout,
               let thumbnail = thumbnails[layout.order[source]] {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 6)
                    .opacity(0.9)
                    .offset(x: location.x - 36, y: location.y - 36)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragSource == nil { dragSource = cellIndex(at: value.startLocation, in: frame) }
                    dragLocation = value.location
                }
                .onEnded { value in
                    if let source = dragSource, let target = cellIndex(at: value.location, in: frame) {
                        move(source, onto: target)
                    }
                    dragSource = nil
                    dragLocation = nil
                }
        )
    }

    /// Where the preview image sits in a container of `size`: fitted, centred, 10 pt from the edges.
    private func fittedFrame(in size: CGSize) -> CGRect {
        guard let canvas = previewLayout?.size, canvas.width > 0, canvas.height > 0 else { return .zero }
        let available = CGSize(width: max(size.width - 20, 1), height: max(size.height - 20, 1))
        let scale = min(available.width / canvas.width, available.height / canvas.height)
        let fitted = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func cellRect(_ index: Int, in frame: CGRect) -> CGRect? {
        guard let layout = previewLayout, layout.cells.indices.contains(index), layout.size.width > 0 else { return nil }
        let scale = frame.width / layout.size.width
        let cell = layout.cells[index]
        return CGRect(x: frame.minX + cell.minX * scale, y: frame.minY + cell.minY * scale,
                      width: cell.width * scale, height: cell.height * scale)
    }

    private func cellIndex(at point: CGPoint, in frame: CGRect) -> Int? {
        guard let layout = previewLayout else { return nil }
        return layout.cells.indices.first { cellRect($0, in: frame)?.contains(point) ?? false }
    }

    /// Puts the dragged photo where the target photo is; the photos in between shift, as in the list.
    private func move(_ source: Int, onto target: Int) {
        guard let layout = previewLayout, source != target,
              let from = order.firstIndex(of: layout.order[source]),
              let to = order.firstIndex(of: layout.order[target]) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
        }
    }

    private var orderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Порядок — перетаскивайте строки или фото в превью")).font(.caption).foregroundStyle(.secondary)
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
        let order = order
        let images = order.compactMap { thumbnails[$0] }
        guard images.count == order.count, !images.isEmpty else { return }
        // Spacing and corners are relative, so a narrower preview looks the same.
        var preview = settings
        preview.width = 1000
        let image = await Task.detached(priority: .userInitiated) {
            try? CollageComposer.compose(images, settings: preview)
        }.value
        guard !Task.isCancelled, let image else { return }
        let aspects = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
        let layout = CollageComposer.layout(aspects: aspects, settings: preview)
        previewLayout = (layout.size, layout.cells, order)
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
