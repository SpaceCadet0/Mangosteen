import SwiftUI

/// Redact video: draw or detect areas on the picture, give each its own time range on the timeline,
/// hide them with a colour, blur or pixels. "Проверить кадр" shows the real result for the current frame.
struct VideoRedactView: View {
    let close: () -> Void

    @StateObject private var model: MediaPlayerModel
    @State private var regions: [VideoRedactor.Region] = []
    @State private var selected: UUID?
    @State private var style = RedactionStyle.solid
    @State private var color = RGBAColor(red: 0, green: 0, blue: 0)
    @State private var frameSize = CGSize(width: 16, height: 9)
    @State private var draft: CGRect?
    @State private var dragStart: CGRect?
    @State private var checkedFrame: CGImage?
    @State private var busy = false
    @State private var message = ""

    init(urls: [URL], close: @escaping () -> Void) {
        self.close = close
        let video = urls.first { FileFormat.detect($0)?.category == .video } ?? urls[0]
        _model = StateObject(wrappedValue: MediaPlayerModel(url: video))
    }

    private var selectedIndex: Int? { regions.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            ZStack {
                MediaPreview(model: model)
                regionsOverlay
            }
            .frame(minWidth: 680, idealWidth: 800, minHeight: 340, idealHeight: 440)
            TimelineFrame(model: model, onScrub: { checkedFrame = nil }) { width, height in
                timelineOverlay(width: width, height: height)
            }
            HStack(spacing: 8) {
                TransportBar(model: model)
                Spacer(minLength: 12)
                if let index = selectedIndex {
                    Text("\(MediaTools.timecode(regions[index].start)) – \(MediaTools.timecode(regions[index].end))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Начало = курсор") { setStart(model.currentTime) }
                    Button("Конец = курсор") { setEnd(model.currentTime) }
                    Button("Весь ролик") {
                        regions[index].start = 0
                        regions[index].end = model.duration
                    }
                }
            }
            .disabled(!model.isLoaded)
            HStack {
                Text(message.isEmpty
                     ? "Тяните по видео, чтобы добавить область. Время выбранной области — жёлтый диапазон на таймлайне."
                     : message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ToolFooter(fileCount: 1, actionTitle: regions.count > 1 ? "Скрыть на видео (\(regions.count))" : "Скрыть на видео",
                       actionDisabled: regions.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .onDeleteCommand(perform: deleteSelected)
        .task { await load() }
        .onChange(of: regions) { _ in checkedFrame = nil }
        .onChange(of: style) { _ in checkedFrame = nil }
        .onChange(of: model.isPlaying) { playing in if playing { checkedFrame = nil } }
        .onDisappear { model.pause() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { detect(.faces) } label: { Label("Найти лица", systemImage: "person.crop.square") }
            Button { detect(.text) } label: { Label("Найти текст", systemImage: "text.viewfinder") }
            Button(action: deleteSelected) { Label("Удалить", systemImage: "trash") }
                .disabled(selected == nil)
            Button(action: checkFrame) { Label("Проверить кадр", systemImage: "eye") }
                .disabled(regions.isEmpty)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Picker("Стиль", selection: $style) {
                ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if style == .solid {
                ColorPicker("Цвет", selection: Binding(get: { color.cgColor }, set: { color = RGBAColor($0) }),
                            supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .disabled(!model.isLoaded)
    }

    // MARK: Picture overlay

    /// Where the picture sits inside the preview (aspect fit, centred).
    private func fitted(in size: CGSize) -> CGRect {
        let scale = min(size.width / frameSize.width, size.height / frameSize.height)
        let fit = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
    }

    private func viewRect(_ normalized: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + normalized.minX * frame.width, y: frame.minY + normalized.minY * frame.height,
               width: normalized.width * frame.width, height: normalized.height * frame.height)
    }

    private var regionsOverlay: some View {
        GeometryReader { geometry in
            let frame = fitted(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: frame.width, height: frame.height)
                    .gesture(drawGesture(size: frame.size))
                    .position(x: frame.midX, y: frame.midY)
                if let checkedFrame {
                    Image(decorative: checkedFrame, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
                ForEach(regions) { region in
                    regionView(region, frame: frame)
                }
                if let draft {
                    let rect = viewRect(draft, in: frame)
                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func regionView(_ region: VideoRedactor.Region, frame: CGRect) -> some View {
        let rect = viewRect(region.rect, in: frame)
        let isSelected = region.id == selected
        let active = (region.start...region.end).contains(model.currentTime)
        let fill: Color = style == .solid ? Color(cgColor: color.cgColor).opacity(0.85) : Color.black.opacity(0.4)
        return ZStack {
            Rectangle()
                .fill(active && checkedFrame == nil ? fill : Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(isSelected ? Color.accentColor : Color.white.opacity(active ? 0.8 : 0.45),
                                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: active ? [] : [4, 3])))
                .overlay {
                    if active, style != .solid, checkedFrame == nil {
                        Image(systemName: style == .blur ? "drop.halffull" : "square.grid.3x3.fill")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture(region, size: frame.size))
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
                        .gesture(resizeGesture(region, handle: handle, size: frame.size))
                }
            }
        }
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                func normalized(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
                }
                let start = normalized(value.startLocation)
                let end = normalized(value.location)
                draft = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(end.x - start.x), height: abs(end.y - start.y))
            }
            .onEnded { _ in
                if let draft, draft.width > 0.01, draft.height > 0.01 {
                    let region = VideoRedactor.Region(rect: draft, start: 0, end: model.duration)
                    regions.append(region)
                    selected = region.id
                }
                draft = nil
            }
    }

    private func moveGesture(_ region: VideoRedactor.Region, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                selected = region.id
                guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
                let start = dragStart ?? region.rect
                dragStart = start
                var moved = start
                moved.origin.x = min(max(start.minX + value.translation.width / size.width, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + value.translation.height / size.height, 0), 1 - start.height)
                regions[index].rect = moved
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ region: VideoRedactor.Region, handle: ImageCropper.Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
                let start = dragStart ?? region.rect
                dragStart = start
                if let resized = ImageCropper.resize(start, handle: handle, dx: value.translation.width / size.width,
                                                     dy: value.translation.height / size.height, aspect: nil, minSize: 0.02) {
                    regions[index].rect = resized
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Timeline overlay

    @ViewBuilder
    private func timelineOverlay(width: CGFloat, height: CGFloat) -> some View {
        // Every area's time as a thin bar at the bottom; the selected one as a range with handles.
        ForEach(regions) { region in
            let start = model.x(for: region.start, width: width)
            let end = model.x(for: region.end, width: width)
            Capsule()
                .fill(region.id == selected ? Color.yellow : Color.accentColor.opacity(0.85))
                .frame(width: max(end - start, 3), height: 5)
                .position(x: (start + end) / 2, y: height - 5)
                .allowsHitTesting(false)
        }
        if let index = selectedIndex {
            let start = model.x(for: regions[index].start, width: width)
            let end = model.x(for: regions[index].end, width: width)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.yellow.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.yellow, lineWidth: 2.5))
                .frame(width: max(end - start, 2), height: height)
                .position(x: (start + end) / 2, y: height / 2)
                .allowsHitTesting(false)
            timeHandle(isStart: true, at: start, width: width, height: height)
            timeHandle(isStart: false, at: end, width: width, height: height)
        }
    }

    private func timeHandle(isStart: Bool, at position: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 10, height: height + 8)
            .overlay(Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
            .frame(width: 26, height: height + 8)
            .contentShape(Rectangle())
            .position(x: position, y: height / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)).onChanged { value in
                let seconds = model.time(at: value.location.x, width: width)
                if isStart { setStart(seconds) } else { setEnd(seconds) }
                model.pause()
                model.seek(to: seconds)
            })
    }

    private func setStart(_ seconds: Double) {
        guard let index = selectedIndex else { return }
        regions[index].start = min(max(seconds, 0), regions[index].end - 0.05)
    }

    private func setEnd(_ seconds: Double) {
        guard let index = selectedIndex else { return }
        regions[index].end = max(min(seconds, model.duration), regions[index].start + 0.05)
    }

    // MARK: Actions

    private func deleteSelected() {
        regions.removeAll { $0.id == selected }
        selected = nil
    }

    private func detect(_ kind: Redactor.Detection) {
        let url = model.url
        let time = model.currentTime
        let duration = model.duration
        busy = true
        message = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Redactor.detect(kind, in: MediaTools.frame(url, at: time, maxHeight: 1080)) }
            }.value
            busy = false
            switch result {
            case .success(let boxes):
                // Faces move, so they get a short span around the playhead; captions often stay put.
                let start = kind == .faces ? max(time - 0.5, 0) : 0
                let end = kind == .faces ? min(time + 2.5, duration) : duration
                let found = boxes.map { VideoRedactor.Region(rect: $0, start: start, end: end) }
                regions += found
                selected = found.last?.id ?? selected
                message = found.isEmpty ? (kind == .faces ? "Лица на этом кадре не найдены." : "Текст на этом кадре не найден.")
                    : "Найдено областей: \(found.count). Проверьте их время на таймлайне."
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func checkFrame() {
        model.pause()
        let url = model.url
        let regions = regions
        let style = style
        let color = color
        let size = frameSize
        let time = model.currentTime
        busy = true
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                try? VideoRedactor.previewFrame(url, regions: regions, style: style, color: color, frameSize: size, at: time)
            }.value
            busy = false
            checkedFrame = image
            message = image == nil ? "Не удалось построить кадр." : "Так будет выглядеть этот кадр. Кадр сбросится при перемотке."
        }
    }

    private func load() async {
        await model.load()
        let url = model.url
        if let size = await Task.detached(priority: .userInitiated, operation: { try? VideoRedactor.frameSize(url) }).value {
            frameSize = size
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
            regions = [
                VideoRedactor.Region(rect: CGRect(x: 0.08, y: 0.1, width: 0.25, height: 0.22), start: 0, end: model.duration),
                VideoRedactor.Region(rect: CGRect(x: 0.6, y: 0.3, width: 0.22, height: 0.3),
                                     start: model.duration * 0.3, end: model.duration * 0.6),
            ]
            selected = regions[1].id
            model.seek(to: model.duration * 0.4)
        }
        #endif
    }

    private func run() {
        model.pause()
        let regions = regions
        let style = style
        let color = color
        ConversionService.shared.runEach("Скрытие на видео", inputs: [model.url], maxConcurrent: 1) { url, progress, cancellation in
            try VideoRedactor.redact(url, regions: regions, style: style, color: color,
                                     progress: progress, cancellation: cancellation)
        }
        close()
    }
}
