import SwiftUI

/// Redact tool: detect faces or text, draw and adjust areas, cover them with a colour, blur or pixels.
/// Each image in the selection has its own areas.
struct RedactView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var index = 0
    @State private var previews: [URL: CGImage] = [:]
    @State private var regions: [URL: [RedactionRegion]] = [:]
    @State private var rendered: NSImage?
    @State private var selected: UUID?
    @State private var style = RedactionStyle.solid
    @State private var color = RGBAColor(red: 0, green: 0, blue: 0)
    @State private var draft: CGRect?
    @State private var dragStart: CGRect?
    @State private var detecting = false
    @State private var message = ""

    private struct RenderKey: Equatable {
        var url: URL?
        var regions: [RedactionRegion]
        var style: RedactionStyle
        var color: RGBAColor
        var loaded: Bool
    }

    private var images: [URL] { urls.filter { FileFormat.detect($0)?.category == .image } }
    private var current: URL? { images.indices.contains(index) ? images[index] : nil }
    private var currentRegions: [RedactionRegion] { current.flatMap { regions[$0] } ?? [] }
    private var imagesWithRegions: [URL] { images.filter { !(regions[$0] ?? []).isEmpty } }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            canvas
                .frame(minWidth: 620, idealWidth: 760, minHeight: 400, idealHeight: 520)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            HStack(spacing: 12) {
                Text("Стиль")
                    .fixedSize()
                Picker("Стиль", selection: $style) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if style == .solid {
                    ColorPicker("Цвет", selection: Binding(get: { color.cgColor }, set: { color = RGBAColor($0) }),
                                supportsOpacity: false)
                        .fixedSize()
                }
                Spacer(minLength: 12)
                Text(message.isEmpty ? "Тяните по фото, чтобы добавить область. Метаданные в результате удаляются." : message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .layoutPriority(-1)
            }
            ToolFooter(fileCount: imagesWithRegions.count, actionTitle: "Сохранить",
                       actionDisabled: imagesWithRegions.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .onDeleteCommand(perform: deleteSelected)
        .task(id: index) { await loadCurrent() }
        .task(id: RenderKey(url: current, regions: currentRegions, style: style, color: color,
                            loaded: current.map { previews[$0] != nil } ?? false)) {
            await renderPreview()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { detect(.faces) } label: { Label("Найти лица", systemImage: "person.crop.square") }
            Button { detect(.text) } label: { Label("Найти текст", systemImage: "text.viewfinder") }
            if detecting {
                ProgressView().controlSize(.small)
            }
            Button(action: deleteSelected) { Label("Удалить область", systemImage: "trash") }
                .disabled(selected == nil)
            Button("Очистить") { setRegions([]) }
                .disabled(currentRegions.isEmpty)
            Spacer()
            if images.count > 1 {
                Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1) из \(images.count)").monospacedDigit()
                Button { index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= images.count - 1)
            }
        }
        .disabled(current.flatMap { previews[$0] } == nil)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                if let image = rendered {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .gesture(drawGesture(frame))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(currentRegions) { region in
                    regionView(region, frame: frame)
                }
                if let draft {
                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: draft.width * frame.width, height: draft.height * frame.height)
                        .offset(x: frame.minX + draft.minX * frame.width, y: frame.minY + draft.minY * frame.height)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func fittedFrame(in container: CGSize) -> CGRect {
        guard let image = current.flatMap({ previews[$0] }) else { return .zero }
        let inset: CGFloat = 16
        let scale = min((container.width - inset * 2) / CGFloat(image.width), (container.height - inset * 2) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func regionView(_ region: RedactionRegion, frame: CGRect) -> some View {
        let rect = CGRect(x: frame.minX + region.rect.minX * frame.width, y: frame.minY + region.rect.minY * frame.height,
                          width: region.rect.width * frame.width, height: region.rect.height * frame.height)
        let isSelected = region.id == selected
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(isSelected ? Color.accentColor : Color.white.opacity(0.7),
                                            lineWidth: isSelected ? 2 : 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture(region, frame: frame))
                .onTapGesture { selected = region.id }
            if isSelected {
                ForEach(ImageCropper.Handle.allCases, id: \.self) { handle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .shadow(radius: 1)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .position(handle.point(in: rect))
                        .gesture(resizeGesture(region, handle: handle, frame: frame))
                }
            }
        }
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func drawGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                // The image view's local space starts at its own origin.
                let origin = CGRect(origin: .zero, size: frame.size)
                let start = normalized(value.startLocation, in: origin)
                let end = normalized(value.location, in: origin)
                draft = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(end.x - start.x), height: abs(end.y - start.y))
            }
            .onEnded { _ in
                if let draft, draft.width > 0.01, draft.height > 0.01 {
                    let region = RedactionRegion(rect: draft)
                    setRegions(currentRegions + [region])
                    selected = region.id
                }
                draft = nil
            }
    }

    private func moveGesture(_ region: RedactionRegion, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                selected = region.id
                let start = dragStart ?? region.rect
                dragStart = start
                var moved = start
                moved.origin.x = min(max(start.minX + value.translation.width / frame.width, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + value.translation.height / frame.height, 0), 1 - start.height)
                update(region.id, rect: moved)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ region: RedactionRegion, handle: ImageCropper.Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? region.rect
                dragStart = start
                if let resized = ImageCropper.resize(start, handle: handle, dx: value.translation.width / frame.width,
                                                     dy: value.translation.height / frame.height, aspect: nil, minSize: 0.01) {
                    update(region.id, rect: resized)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: State

    private func setRegions(_ newRegions: [RedactionRegion]) {
        guard let current else { return }
        regions[current] = newRegions
        if !newRegions.contains(where: { $0.id == selected }) { selected = nil }
    }

    private func update(_ id: UUID, rect: CGRect) {
        setRegions(currentRegions.map { region in
            var region = region
            if region.id == id { region.rect = rect }
            return region
        })
    }

    private func deleteSelected() {
        guard let selected else { return }
        setRegions(currentRegions.filter { $0.id != selected })
    }

    private func detect(_ kind: Redactor.Detection) {
        guard let current, let image = previews[current] else { return }
        detecting = true
        message = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Redactor.detect(kind, in: image) }
            }.value
            detecting = false
            switch result {
            case .success(let boxes):
                setRegions(currentRegions + boxes.map { RedactionRegion(rect: $0) })
                message = boxes.isEmpty ? (kind == .faces ? "Лица не найдены" : "Текст не найден")
                    : "Найдено областей: \(boxes.count)"
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func loadCurrent() async {
        selected = nil
        guard let current, previews[current] == nil else { return }
        let image = await Task.detached(priority: .userInitiated) {
            try? ImageConverter.load(current, maxPixelSize: 1600).image
        }.value
        if let image { previews[current] = image }
    }

    private func renderPreview() async {
        guard let current, let image = previews[current] else {
            rendered = nil
            return
        }
        let rects = currentRegions.map(\.rect)
        let style = style
        let color = color
        let output = await Task.detached(priority: .userInitiated) {
            try? Redactor.apply(rects, style: style, color: color, to: image)
        }.value
        guard !Task.isCancelled else { return }
        rendered = NSImage(cgImage: output ?? image, size: .zero)
    }

    private func run() {
        let jobs = imagesWithRegions.map { ($0, (regions[$0] ?? []).map(\.rect)) }
        let lookup = Dictionary(uniqueKeysWithValues: jobs)
        let style = style
        let color = color
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach("Скрытие", inputs: jobs.map(\.0)) { url in
            try Redactor.applyFile(url, regions: lookup[url] ?? [], style: style, color: color, options: options)
        }
        close()
    }
}
