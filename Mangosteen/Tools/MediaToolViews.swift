import SwiftUI

private func firstMedia(_ urls: [URL]) -> URL {
    urls.first { FileFormat.detect($0)?.category.isMedia == true } ?? urls[0]
}

// MARK: - Trim

/// Keep one section of a video or recording.
struct TrimMediaView: View {
    let close: () -> Void
    @StateObject private var model: MediaPlayerModel
    @State private var range: ClosedRange<Double> = 0...0
    @State private var fast = false

    init(urls: [URL], close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: MediaPlayerModel(url: firstMedia(urls)))
    }

    private var startBinding: Binding<Double> {
        Binding(get: { range.lowerBound },
                set: { range = min($0, range.upperBound - 0.05)...range.upperBound; model.seek(to: range.lowerBound) })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { range.upperBound },
                set: { range = range.lowerBound...max($0, range.lowerBound + 0.05); model.seek(to: range.upperBound) })
    }

    var body: some View {
        VStack(spacing: 12) {
            MediaPreview(model: model)
                .frame(minWidth: 640, idealWidth: 760, minHeight: model.isVideo ? 300 : 120,
                       idealHeight: model.isVideo ? 420 : 140)
            TimelineStrip(model: model, range: $range)
            HStack(spacing: 10) {
                TransportBar(model: model)
                Spacer(minLength: 12)
                TimecodeField(title: "Начало", value: startBinding, range: 0...model.duration)
                Button("По курсору") { startBinding.wrappedValue = model.currentTime }
                    .help("Начало = положение курсора")
                TimecodeField(title: "Конец", value: endBinding, range: 0...model.duration)
                Button("По курсору") { endBinding.wrappedValue = model.currentTime }
                    .help("Конец = положение курсора")
            }
            .disabled(!model.isLoaded)
            HStack {
                if model.isVideo {
                    Toggle("Быстро, без перекодирования (разрез по ближайшему ключевому кадру)", isOn: $fast)
                }
                Spacer()
                Text("Останется: \(MediaTools.timecode(range.upperBound - range.lowerBound))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ToolFooter(fileCount: 1, actionTitle: "Обрезать",
                       actionDisabled: !model.isLoaded || range.upperBound - range.lowerBound < 0.05,
                       cancel: close, action: run)
        }
        .padding(20)
        .task {
            await model.load()
            range = 0...model.duration
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                range = model.duration * 0.2...model.duration * 0.7
                model.seek(to: model.duration * 0.35)
            }
            if ProcessInfo.processInfo.environment["MANGOSTEEN_ZOOM_STRESS"] != nil {
                // Drag the zoom slider to the maximum and scroll around, as fast as a user could.
                for step in 0...60 {
                    model.setZoom(pow(2, Double(step) / 10))
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
                for _ in 0..<40 {
                    model.pan(by: model.viewLength * 0.3)
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
            #endif
            model.loopRange = range
        }
        .onChange(of: range) { model.loopRange = $0 }
        .onDisappear { model.pause() }
    }

    private func run() {
        let url = model.url
        let start = range.lowerBound
        let end = range.upperBound
        let fast = fast
        model.pause()
        ConversionService.shared.runEach("Обрезка", inputs: [url], maxConcurrent: 1) { url, progress, cancellation in
            try MediaTools.trim(url, start: start, end: end, fast: fast, progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Split

/// Divide one file into clips at chosen points or into equal parts.
struct SplitMediaView: View {
    let close: () -> Void
    @StateObject private var model: MediaPlayerModel
    @State private var points: [Double] = []
    @State private var equalParts = 2
    @State private var fast = false

    init(urls: [URL], close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: MediaPlayerModel(url: firstMedia(urls)))
    }

    private var bounds: [Double] { [0] + points.sorted() + [model.duration] }

    var body: some View {
        VStack(spacing: 12) {
            MediaPreview(model: model)
                .frame(minWidth: 640, idealWidth: 760, minHeight: model.isVideo ? 280 : 120,
                       idealHeight: model.isVideo ? 380 : 140)
            TimelineStrip(model: model, markers: points, markerColor: .orange)
            HStack(spacing: 10) {
                TransportBar(model: model)
                Spacer(minLength: 12)
                Button { addCut() } label: { Label("Разрез по курсору", systemImage: "scissors") }
                    .keyboardShortcut(.return, modifiers: [])
                Button { removeNearestCut() } label: { Label("Убрать ближайший", systemImage: "minus.circle") }
                    .disabled(points.isEmpty)
            }
            .disabled(!model.isLoaded)
            HStack(spacing: 10) {
                Stepper("Равных частей: \(equalParts)", value: $equalParts, in: 2...50)
                    .fixedSize()
                Button("Разделить поровну") {
                    points = MediaTools.equalSplitPoints(duration: model.duration, parts: equalParts)
                }
                Spacer()
                if model.isVideo {
                    Toggle("Быстро, без перекодирования", isOn: $fast)
                }
            }
            .disabled(!model.isLoaded)
            partsList
            ToolFooter(fileCount: 1, actionTitle: "Разделить на \(bounds.count - 1)",
                       actionDisabled: points.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .task {
            await model.load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                points = MediaTools.equalSplitPoints(duration: model.duration, parts: 3)
            }
            #endif
        }
        .onDisappear { model.pause() }
    }

    private var partsList: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(0..<(bounds.count - 1), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Часть \(index + 1)").font(.caption.weight(.semibold))
                        Text("\(MediaTools.timecode(bounds[index])) – \(MediaTools.timecode(bounds[index + 1]))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .onTapGesture { model.seek(to: bounds[index]) }
                }
            }
        }
        .frame(height: 44)
    }

    private func addCut() {
        let time = model.currentTime
        guard time > 0.05, time < model.duration - 0.05,
              !points.contains(where: { abs($0 - time) < 0.05 }) else { return }
        points.append(time)
        points.sort()
    }

    private func removeNearestCut() {
        guard let nearest = points.min(by: { abs($0 - model.currentTime) < abs($1 - model.currentTime) }) else { return }
        points.removeAll { $0 == nearest }
    }

    private func run() {
        let url = model.url
        let points = points
        let fast = fast
        model.pause()
        ConversionService.shared.runEach("Разделение", inputs: [url], maxConcurrent: 1) { url, progress, cancellation in
            try MediaTools.split(url, at: points, fast: fast, progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Frames

/// Pick exact frames and export them as full-resolution PNGs.
struct FramesView: View {
    let close: () -> Void
    @StateObject private var model: MediaPlayerModel
    @State private var frames: [Double] = []

    init(urls: [URL], close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: MediaPlayerModel(url: urls.first { FileFormat.detect($0)?.category == .video } ?? urls[0]))
    }

    var body: some View {
        VStack(spacing: 12) {
            MediaPreview(model: model)
                .frame(minWidth: 640, idealWidth: 760, minHeight: 300, idealHeight: 420)
            TimelineStrip(model: model, markers: frames, markerColor: .green)
            HStack(spacing: 10) {
                TransportBar(model: model)
                Spacer(minLength: 12)
                Button { addFrame() } label: { Label("Добавить кадр", systemImage: "plus.rectangle.on.rectangle") }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .disabled(!model.isLoaded)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if frames.isEmpty {
                        Text("Найдите кадр (пробел — воспроизведение, ⏎ — добавить, кнопки ◀︎▶︎ — по одному кадру).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(frames, id: \.self) { time in
                        HStack(spacing: 4) {
                            Text(MediaTools.timecode(time)).font(.caption.monospacedDigit())
                            Button { frames.removeAll { $0 == time } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.18)))
                        .onTapGesture { model.seek(to: time) }
                    }
                }
            }
            .frame(height: 32)
            ToolFooter(fileCount: 1, actionTitle: frames.count > 1 ? "Сохранить кадры (\(frames.count))" : "Сохранить кадр",
                       actionDisabled: frames.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .task {
            await model.load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                frames = [model.duration * 0.25, model.duration * 0.6]
                model.seek(to: model.duration * 0.6)
            }
            #endif
        }
        .onDisappear { model.pause() }
    }

    private func addFrame() {
        let time = model.currentTime
        guard !frames.contains(where: { abs($0 - time) < model.frameDuration / 2 }) else { return }
        frames.append(time)
        frames.sort()
    }

    private func run() {
        let url = model.url
        let frames = frames
        model.pause()
        ConversionService.shared.runBatch("Сохранение кадров", inputs: [url]) { _ in
            [try MediaTools.saveFrames(url, at: frames)]
        }
        close()
    }
}
