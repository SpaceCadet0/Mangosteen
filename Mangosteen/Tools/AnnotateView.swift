import SwiftUI
import UniformTypeIdentifiers

/// Annotate tool: arrows, shapes, text, numbered callouts, pen, highlighter, magnifier and pictures.
/// Works on the first image of the selection.
struct AnnotateView: View {
    let urls: [URL]
    let close: () -> Void

    private enum Interaction {
        case none
        case creating(UUID, start: CGPoint)
        case moving(Annotation, start: CGPoint)
        case handle(Annotation, AnnotationHandle)
        case placing
    }

    private enum StrokePreset: String, CaseIterable, Identifiable {
        case thin, medium, thick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .thin: String(localized: "Тонкая")
            case .medium: String(localized: "Средняя")
            case .thick: String(localized: "Толстая")
            }
        }
        /// Fraction of the image's longer side.
        var fraction: CGFloat {
            switch self {
            case .thin: 0.003
            case .medium: 0.006
            case .thick: 0.011
            }
        }
    }

    private struct RenderKey: Equatable {
        var annotations: [Annotation]
        var pictures: Int
        var loaded: Bool
    }

    private static let palette: [RGBAColor] = [
        RGBAColor(red: 0.96, green: 0.23, blue: 0.19), RGBAColor(red: 1, green: 0.58, blue: 0),
        RGBAColor(red: 1, green: 0.84, blue: 0.04), RGBAColor(red: 0.2, green: 0.78, blue: 0.35),
        RGBAColor(red: 0.04, green: 0.52, blue: 1), RGBAColor(red: 0.69, green: 0.32, blue: 0.87),
        RGBAColor(red: 0, green: 0, blue: 0), RGBAColor(red: 1, green: 1, blue: 1),
    ]

    @State private var preview: CGImage?
    @State private var fullSize = CGSize(width: 1, height: 1)
    @State private var rendered: NSImage?
    @State private var annotations: [Annotation] = []
    @State private var history: [[Annotation]] = []
    @State private var pictures: [URL: CGImage] = [:]
    @State private var tool = AnnotationTool.pen
    @State private var color = palette[0]
    @State private var stroke = StrokePreset.medium
    @State private var textScale = 0.045
    @State private var selected: UUID?
    @State private var interaction = Interaction.none
    @FocusState private var textFieldFocused: Bool

    private var image: URL? { urls.first { FileFormat.detect($0)?.category == .image } }
    private var longestSide: CGFloat { max(fullSize.width, fullSize.height) }
    private var selectedAnnotation: Annotation? { annotations.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                canvas
                    .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 540)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                inspector
                    .frame(width: 250)
            }
            ToolFooter(fileCount: image == nil ? 0 : 1, actionTitle: String(localized: "Сохранить"),
                       actionDisabled: annotations.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .onDeleteCommand(perform: deleteSelected)
        .task { await load() }
        .task(id: RenderKey(annotations: annotations, pictures: pictures.count, loaded: preview != nil)) {
            await renderPreview()
        }
        .onChange(of: color) { newColor in updateSelected { $0.color = newColor } }
        .onChange(of: stroke) { newStroke in updateSelected { $0.lineWidth = newStroke.fraction * longestSide } }
        .onChange(of: textScale) { newScale in updateSelected { $0.fontSize = CGFloat(newScale) * longestSide } }
    }

    // MARK: Canvas

    private static let canvasSpace = "annotateCanvas"

    /// Every layer is placed with `.position` inside a full-size ZStack, so the canvas origin is fixed at the
    /// top-left and never shifts when the selection outline appears or changes size.
    private var canvas: some View {
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let rendered {
                    Image(nsImage: rendered)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                } else {
                    ProgressView()
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                if let annotation = selectedAnnotation {
                    selectionOverlay(annotation, frame: frame)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.canvasSpace)
            .gesture(canvasGesture(frame))
            .clipped()
        }
    }

    private func fittedFrame(in container: CGSize) -> CGRect {
        let inset: CGFloat = 16
        guard container.width > inset * 2, container.height > inset * 2 else { return .zero }
        let scale = min((container.width - inset * 2) / fullSize.width, (container.height - inset * 2) / fullSize.height)
        let size = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func toView(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x / fullSize.width * frame.width,
                y: frame.minY + point.y / fullSize.height * frame.height)
    }

    private func toPixels(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / frame.width * fullSize.width,
                y: (point.y - frame.minY) / frame.height * fullSize.height)
    }

    private func selectionOverlay(_ annotation: Annotation, frame: CGRect) -> some View {
        let bounds = AnnotationGeometry.bounds(annotation)
        let topLeft = toView(bounds.origin, frame)
        let bottomRight = toView(CGPoint(x: bounds.maxX, y: bounds.maxY), frame)
        let box = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            .insetBy(dx: -6, dy: -6)
        return Group {
            Rectangle()
                .stroke(Brand.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
            ForEach(AnnotationGeometry.handles(annotation), id: \.0) { _, point in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Brand.color, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .position(toView(point, frame))
                    .allowsHitTesting(false)
            }
        }
    }

    private func canvasGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard frame.width > 0 else { return }
                let point = toPixels(value.location, frame)
                if case .none = interaction {
                    begin(at: toPixels(value.startLocation, frame), frame: frame)
                }
                update(to: point)
            }
            .onEnded { value in
                finish(at: toPixels(value.location, frame), frame: frame)
            }
    }

    private func begin(at point: CGPoint, frame: CGRect) {
        let tolerance = 10 / frame.width * fullSize.width
        if let current = selectedAnnotation,
           let (handle, _) = AnnotationGeometry.handles(current).first(where: {
               hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance
           }) {
            pushHistory()
            interaction = .handle(current, handle)
            return
        }
        switch tool {
        case .select:
            if let id = AnnotationGeometry.hitTest(annotations, at: point, tolerance: tolerance),
               let hit = annotations.first(where: { $0.id == id }) {
                select(hit)
                pushHistory()
                interaction = .moving(hit, start: point)
            } else {
                selected = nil
                interaction = .placing
            }
        case .text, .number, .image:
            interaction = .placing
        case .arrow, .rectangle, .ellipse, .pen, .highlight, .magnifier:
            pushHistory()
            let annotation = Annotation(shape: initialShape(at: point), color: color,
                                        lineWidth: stroke.fraction * longestSide,
                                        fontSize: CGFloat(textScale) * longestSide)
            annotations.append(annotation)
            selected = annotation.id
            interaction = .creating(annotation.id, start: point)
        }
    }

    private func initialShape(at point: CGPoint) -> Annotation.Shape {
        switch tool {
        case .arrow: .arrow(point, point)
        case .rectangle: .rectangle(CGRect(origin: point, size: .zero))
        case .ellipse: .ellipse(CGRect(origin: point, size: .zero))
        case .pen: .pen([point])
        case .highlight: .highlight([point])
        default: .magnifier(point, 10)
        }
    }

    private func update(to point: CGPoint) {
        switch interaction {
        case .creating(let id, let start):
            replace(id) { annotation in
                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                  width: abs(point.x - start.x), height: abs(point.y - start.y))
                switch annotation.shape {
                case .arrow: annotation.shape = .arrow(start, point)
                case .rectangle: annotation.shape = .rectangle(rect)
                case .ellipse: annotation.shape = .ellipse(rect)
                case .pen(let points): annotation.shape = .pen(points + [point])
                case .highlight(let points): annotation.shape = .highlight(points + [point])
                case .magnifier: annotation.shape = .magnifier(start, max(hypot(point.x - start.x, point.y - start.y), 10))
                default: break
                }
            }
        case .moving(let original, let start):
            replace(original.id) {
                $0 = AnnotationGeometry.translated(original, by: CGVector(dx: point.x - start.x, dy: point.y - start.y))
            }
        case .handle(let original, let handle):
            var aspect: CGFloat?
            if case .image(_, let url) = original.shape, let picture = pictures[url] {
                aspect = CGFloat(picture.width) / CGFloat(max(picture.height, 1))
            }
            replace(original.id) { $0 = AnnotationGeometry.moving(original, handle: handle, to: point, imageAspect: aspect) }
        case .none, .placing:
            break
        }
    }

    private func finish(at point: CGPoint, frame: CGRect) {
        defer { interaction = .none }
        switch interaction {
        case .creating(let id, _):
            guard let annotation = annotations.first(where: { $0.id == id }) else { return }
            let minimum = 6 / frame.width * fullSize.width
            let bounds = AnnotationGeometry.bounds(annotation)
            let isLine: Bool = {
                if case .pen = annotation.shape { return true }
                if case .highlight = annotation.shape { return true }
                return false
            }()
            if !isLine, max(bounds.width, bounds.height) < minimum {
                // A click without dragging: undo the empty shape.
                annotations.removeAll { $0.id == id }
                _ = history.popLast()
            }
            // Keep drawing freely; colour changes must not recolour the mark just made.
            // Marks are adjusted with the Select tool.
            selected = nil
        case .placing:
            place(at: point)
        default:
            break
        }
    }

    private func place(at point: CGPoint) {
        guard (0...fullSize.width).contains(point.x), (0...fullSize.height).contains(point.y) else { return }
        let lineWidth = stroke.fraction * longestSide
        let fontSize = CGFloat(textScale) * longestSide
        switch tool {
        case .text:
            pushHistory()
            let annotation = Annotation(shape: .text(point, String(localized: "Текст")), color: color, lineWidth: lineWidth, fontSize: fontSize)
            annotations.append(annotation)
            selected = annotation.id
            textFieldFocused = true
        case .number:
            pushHistory()
            let next = annotations.compactMap { annotation -> Int? in
                if case .number(_, let value) = annotation.shape { return value }
                return nil
            }.max().map { $0 + 1 } ?? 1
            let annotation = Annotation(shape: .number(point, next), color: color, lineWidth: lineWidth, fontSize: fontSize)
            annotations.append(annotation)
        case .image:
            insertPicture(at: point)
        default:
            break
        }
    }

    private func insertPicture(at point: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let picture = try? ImageConverter.load(url, maxPixelSize: 2048).image else {
            return
        }
        pictures[url] = picture
        let width = fullSize.width * 0.3
        let height = width * CGFloat(picture.height) / CGFloat(max(picture.width, 1))
        pushHistory()
        let annotation = Annotation(shape: .image(CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), url),
                                    color: color, lineWidth: stroke.fraction * longestSide, fontSize: CGFloat(textScale) * longestSide)
        annotations.append(annotation)
        selected = annotation.id
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 5), spacing: 4) {
                ForEach(AnnotationTool.allCases) { item in
                    Button { tool = item } label: {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 15))
                            .frame(width: 44, height: 36)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(tool == item ? Brand.color.opacity(0.3) : Color.primary.opacity(0.06)))
                            // The whole tile is clickable, not only the glyph.
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
            Text(tool.title).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Цвет")).font(.callout)
                HStack(spacing: 6) {
                    ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, swatch in
                        Circle()
                            .fill(Color(cgColor: swatch.cgColor))
                            .overlay(Circle().stroke(swatch == color ? Brand.color : Color.secondary.opacity(0.4),
                                                     lineWidth: swatch == color ? 2.5 : 1))
                            .frame(width: 20, height: 20)
                            .onTapGesture { color = swatch }
                    }
                }
                ColorPicker(String(localized: "Другой цвет"), selection: Binding(get: { color.cgColor }, set: { color = RGBAColor($0) }),
                            supportsOpacity: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Линия")).font(.callout)
                Picker(String(localized: "Линия"), selection: $stroke) {
                    ForEach(StrokePreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Размер текста и номеров")).font(.callout)
                Slider(value: $textScale, in: 0.015...0.15)
            }

            if let annotation = selectedAnnotation, case .text(_, let string) = annotation.shape {
                TextField(String(localized: "Текст"), text: Binding(get: { string }, set: { newValue in
                    replace(annotation.id) { item in
                        if case .text(let origin, _) = item.shape { item.shape = .text(origin, newValue) }
                    }
                }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($textFieldFocused)
            }

            HStack {
                Button(String(localized: "Отменить")) { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(history.isEmpty)
                Button(String(localized: "Удалить"), action: deleteSelected)
                    .disabled(selected == nil)
                Button(String(localized: "Очистить")) {
                    pushHistory()
                    annotations = []
                    selected = nil
                }
                .disabled(annotations.isEmpty)
            }
            Spacer()
            Text((urls.count > 1 ? String(localized: "Пометки добавляются к первому изображению. ") : "")
                 + String(localized: "Чтобы передвинуть или изменить пометку, выберите инструмент «Выбор». ⌫ удаляет выделенное, ⌘Z — отмена."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: State

    private func select(_ annotation: Annotation) {
        selected = annotation.id
        if color != annotation.color { color = annotation.color }
    }

    private func replace(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[index])
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let selected, let index = annotations.firstIndex(where: { $0.id == selected }) else { return }
        var updated = annotations[index]
        change(&updated)
        if updated != annotations[index] {
            pushHistory()
            annotations[index] = updated
        }
    }

    private func pushHistory() {
        history.append(annotations)
        if history.count > 100 { history.removeFirst() }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        annotations = previous
        if !annotations.contains(where: { $0.id == selected }) { selected = nil }
    }

    private func deleteSelected() {
        guard let selected else { return }
        pushHistory()
        annotations.removeAll { $0.id == selected }
        self.selected = nil
    }

    // MARK: Work

    private func load() async {
        guard let image else { return }
        let result = await Task.detached(priority: .userInitiated) {
            try? (ImageConverter.load(image, maxPixelSize: 1800).image, ImageCropper.uprightSize(image))
        }.value
        if let (preview, size) = result {
            fullSize = size
            self.preview = preview
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil { addDemoAnnotations() }
            #endif
        }
    }

    #if DEBUG
    /// Marks used by snapshot checks: the selected arrow's handles must sit exactly on its ends.
    private func addDemoAnnotations() {
        let w = fullSize.width, h = fullSize.height, longest = longestSide
        func make(_ shape: Annotation.Shape, _ color: RGBAColor) -> Annotation {
            Annotation(shape: shape, color: color, lineWidth: 0.006 * longest, fontSize: 0.05 * longest)
        }
        let arrow = make(.arrow(CGPoint(x: w * 0.1, y: h * 0.15), CGPoint(x: w * 0.45, y: h * 0.5)), Self.palette[0])
        annotations = [
            arrow,
            make(.rectangle(CGRect(x: w * 0.55, y: h * 0.2, width: w * 0.3, height: h * 0.3)), Self.palette[4]),
            make(.text(CGPoint(x: w * 0.1, y: h * 0.7), String(localized: "Проверка")), Self.palette[2]),
            make(.number(CGPoint(x: w * 0.8, y: h * 0.75), 1), Self.palette[0]),
            make(.magnifier(CGPoint(x: w * 0.5, y: h * 0.75), longest * 0.08), Self.palette[3]),
        ]
        selected = arrow.id
    }
    #endif

    private func renderPreview() async {
        guard let preview else { return }
        let annotations = annotations
        let pictures = pictures
        let fullSize = fullSize
        let output = await Task.detached(priority: .userInitiated) {
            try? AnnotationRenderer.render(annotations, on: preview, fullSize: fullSize, images: pictures)
        }.value
        guard !Task.isCancelled else { return }
        rendered = NSImage(cgImage: output ?? preview, size: .zero)
    }

    private func run() {
        guard let image else { return }
        let annotations = annotations
        let pictures = pictures
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach(String(localized: "Пометки"), inputs: [image]) {
            try AnnotationRenderer.applyFile($0, annotations: annotations, images: pictures, options: options)
        }
        close()
    }
}
