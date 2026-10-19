import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private func firstMedia(_ urls: [URL]) -> URL {
    urls.first { FileFormat.detect($0)?.category.isMedia == true } ?? urls[0]
}

// MARK: - Listening to results

/// Renders processed sound to a temporary file and plays it, so a change can be heard before saving.
@MainActor
final class PreviewListener: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRendering = false
    /// What is playing now (a label chosen by the caller), nil when silent.
    @Published private(set) var playing: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var cancellation: CancellationToken?
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("mangosteen-preview-\(UUID().uuidString).m4a")

    func play(_ label: String, from time: Double = 0, render: @escaping (URL, CancellationToken) throws -> Void) {
        stop()
        isRendering = true
        let token = CancellationToken()
        cancellation = token
        let file = file
        task = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { (try? render(file, token)) != nil }.value
            guard let self, !Task.isCancelled else { return }
            self.isRendering = false
            guard rendered, let player = try? AVAudioPlayer(contentsOf: file) else { return }
            player.delegate = self
            player.currentTime = min(max(time, 0), max(player.duration - 0.1, 0))
            player.play()
            self.player = player
            self.playing = label
        }
    }

    func stop() {
        cancellation?.cancel()
        task?.cancel()
        player?.stop()
        player = nil
        playing = nil
        isRendering = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }

    deinit {
        try? FileManager.default.removeItem(at: file)
    }
}

/// A button that plays one variant, or stops it while it is playing.
private struct ListenButton: View {
    @ObservedObject var listener: PreviewListener
    let label: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            listener.playing == label ? listener.stop() : action()
        } label: {
            Label(title, systemImage: listener.playing == label ? "stop.fill" : "play.fill")
        }
    }
}

// MARK: - Loudness

struct NormalizeView: View {
    let urls: [URL]
    let close: () -> Void

    private enum Preset: String, CaseIterable, Identifiable {
        case streaming, podcast, broadcast, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .streaming: "Стриминг −14"
            case .podcast: "Подкаст −16"
            case .broadcast: "ТВ и радио −23"
            case .custom: "Своя"
            }
        }
        var loudness: Double? {
            switch self {
            case .streaming: -14
            case .podcast: -16
            case .broadcast: -23
            case .custom: nil
            }
        }
    }

    @State private var preset = Preset.streaming
    @State private var target = AudioTools.LoudnessTarget()
    @State private var measurement: AudioTools.LoudnessMeasurement?
    @State private var measureError = false

    private var files: [URL] { urls.filter { FileFormat.detect($0)?.category.isMedia == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Цель", selection: $preset) {
                ForEach(Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                row("Громкость", value: $target.integrated, range: -30...(-5), unit: "LUFS")
                row("Максимальный пик", value: $target.truePeak, range: -6...0, unit: "dBTP")
                row("Динамический диапазон", value: $target.range, range: 3...20, unit: "LU")
            }

            levels
            ToolFooter(fileCount: files.count, actionTitle: "Нормализовать", actionDisabled: files.isEmpty,
                       cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 580)
        .task { await measure() }
        .onChange(of: preset) { newPreset in
            if let loudness = newPreset.loudness { target.integrated = loudness }
        }
        .onChange(of: target.integrated) { value in
            if preset.loudness.map({ abs($0 - value) > 0.05 }) ?? false { preset = .custom }
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%.1f %@", value.wrappedValue, unit))
                .font(.body.monospacedDigit())
                .frame(width: 92, alignment: .trailing)
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = files.first {
                Text(first.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Громкость").foregroundStyle(.secondary)
                    Text("Пик").foregroundStyle(.secondary)
                    Text("Диапазон").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Сейчас").foregroundStyle(.secondary)
                    if let measurement {
                        Text(String(format: "%.1f LUFS", measurement.integrated))
                        Text(String(format: "%.1f dBTP", measurement.truePeak))
                        Text(String(format: "%.1f LU", measurement.range))
                    } else if measureError {
                        Text("не удалось измерить").foregroundStyle(.orange).gridCellColumns(3)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Измеряю…").foregroundStyle(.secondary)
                        }
                        .gridCellColumns(3)
                    }
                }
                GridRow {
                    Text("Станет").foregroundStyle(.secondary)
                    Text(String(format: "%.1f LUFS", target.integrated)).fontWeight(.semibold)
                    Text(String(format: "≤ %.1f dBTP", target.truePeak))
                    Text(String(format: "≤ %.1f LU", target.range))
                }
            }
            .font(.callout.monospacedDigit())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func measure() async {
        guard let first = files.first else { return }
        let result = await Task.detached(priority: .userInitiated) { try? AudioTools.measureLoudness(first) }.value
        measurement = result
        measureError = result == nil
    }

    private func run() {
        let target = target
        ConversionService.shared.runEach("Громкость", inputs: files, maxConcurrent: 2) { url, progress, cancellation in
            try AudioTools.normalize(url, target: target, progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Channels

struct ChannelsView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var settings = AudioTools.ChannelSettings()
    @State private var leftWave: [Float] = []
    @State private var rightWave: [Float] = []
    @State private var sourceChannels = 2
    @StateObject private var listener = PreviewListener()

    private var input: URL { firstMedia(urls) }
    private var filter: String { AudioTools.channelFilter(settings, sourceChannels: sourceChannels) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(input.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            VStack(spacing: 6) {
                channelRow("Л", leftWave)
                channelRow("П", rightWave)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            if sourceChannels < 2 {
                Text("Исходная запись моно: оба канала получают один и тот же звук.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("Результат")
                Picker("Результат", selection: $settings.layout) {
                    ForEach(AudioTools.ChannelSettings.Layout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("Поменять каналы местами", isOn: $settings.swap)
                    .disabled(sourceChannels < 2)
            }
            volumeRow("Левый канал", $settings.left)
            volumeRow("Правый канал", $settings.right)

            HStack(spacing: 8) {
                ListenButton(listener: listener, label: "result", title: "Результат") {
                    let filter = filter
                    listener.play("result") { try AudioTools.renderPreview(input, filter: filter, to: $0, cancellation: $1) }
                }
                if settings.layout == .stereo {
                    ListenButton(listener: listener, label: "left", title: "Только левый") {
                        let filter = filter + ",pan=stereo|c0=c0|c1=c0"
                        listener.play("left") { try AudioTools.renderPreview(input, filter: filter, to: $0, cancellation: $1) }
                    }
                    ListenButton(listener: listener, label: "right", title: "Только правый") {
                        let filter = filter + ",pan=stereo|c0=c1|c1=c1"
                        listener.play("right") { try AudioTools.renderPreview(input, filter: filter, to: $0, cancellation: $1) }
                    }
                }
                ListenButton(listener: listener, label: "original", title: "Оригинал") {
                    listener.play("original") { try AudioTools.renderPreview(input, to: $0, cancellation: $1) }
                }
                if listener.isRendering { ProgressView().controlSize(.small) }
            }
            ToolFooter(fileCount: 1, actionTitle: "Сохранить", cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 620)
        .task { await load() }
        .onChange(of: settings) { _ in listener.stop() }
        .onDisappear { listener.stop() }
    }

    private func channelRow(_ title: String, _ peaks: [Float]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 14)
            ZStack {
                if peaks.isEmpty { ProgressView().controlSize(.small) } else { WaveformView(peaks: peaks) }
            }
            .frame(height: 48)
        }
    }

    private func volumeRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: 0...2, step: 0.05)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.body.monospacedDigit())
                .frame(width: 50, alignment: .trailing)
        }
    }

    private func load() async {
        let input = input
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, [Float], [Float]) in
            let info = try? MediaConverter.probe(input)
            let duration = info?.duration ?? 0
            let channels = info?.audioChannels ?? 2
            let left = (try? MediaTools.waveform(input, duration: duration, buckets: 600, filter: "pan=mono|c0=c0")) ?? []
            let right = channels < 2 ? left
                : (try? MediaTools.waveform(input, duration: duration, buckets: 600, filter: "pan=mono|c0=c1")) ?? []
            return (channels, left, right)
        }.value
        (sourceChannels, leftWave, rightWave) = result
    }

    private func run() {
        listener.stop()
        let settings = settings
        ConversionService.shared.runEach("Каналы", inputs: [input], maxConcurrent: 1) { url, progress, cancellation in
            try AudioTools.convertChannels(url, settings: settings, progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Bleep

struct BleepView: View {
    let close: () -> Void
    @StateObject private var model: MediaPlayerModel
    @State private var ranges: [ClosedRange<Double>] = []
    @State private var selected: Int?
    @State private var frequency = 1000.0
    @State private var volume = 0.3
    @State private var version = Version.original
    @State private var rendering = false
    @State private var renderedKey: BleepKey?
    @State private var bleepedFile: URL?
    @State private var originalFile: URL?
    @State private var notice = ""

    private enum Version { case original, bleeped }

    private struct BleepKey: Equatable {
        var ranges: [ClosedRange<Double>]
        var frequency: Double
        var volume: Double
    }

    init(urls: [URL], close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: MediaPlayerModel(url: firstMedia(urls)))
    }

    private var key: BleepKey { BleepKey(ranges: ranges, frequency: frequency, volume: volume) }

    var body: some View {
        VStack(spacing: 12) {
            MediaPreview(model: model)
                .frame(minWidth: 640, idealWidth: 760, minHeight: model.isVideo ? 260 : 120,
                       idealHeight: model.isVideo ? 360 : 140)
            BleepStrip(model: model, ranges: $ranges, selected: $selected)
            HStack(spacing: 10) {
                TransportBar(model: model, onPlay: playBleeped, isBusy: rendering)
                Text(model.isPlaying ? (version == .bleeped ? "с пиками" : "оригинал") : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Spacer(minLength: 12)
                Button { addBleep() } label: { Label("Пик по курсору", systemImage: "plus") }
                    .keyboardShortcut(.return, modifiers: [])
                Button { removeSelected() } label: { Label("Удалить пик", systemImage: "minus") }
                    .disabled(selected == nil)
            }
            .disabled(!model.isLoaded)
            HStack(spacing: 12) {
                Text("Тон")
                Picker("Тон", selection: $frequency) {
                    Text("800 Гц").tag(800.0)
                    Text("1000 Гц").tag(1000.0)
                    Text("1500 Гц").tag(1500.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("Громкость")
                Slider(value: $volume, in: 0.05...1).frame(width: 120)
                Spacer()
                Button(action: playOriginal) {
                    Label("Оригинал", systemImage: model.isPlaying && version == .original ? "stop.fill" : "play.fill")
                }
                .disabled(!model.isLoaded || rendering)
            }
            HStack {
                Text(notice.isEmpty ? "Пробел — прослушать с пиками, ⏎ — пик по курсору." : notice)
                    .font(.caption)
                    .foregroundStyle(notice.isEmpty ? Color.secondary : Color.orange)
                Spacer()
            }
            ToolFooter(fileCount: 1, actionTitle: ranges.count > 1 ? "Запикать (\(ranges.count))" : "Запикать",
                       actionDisabled: ranges.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .task {
            await model.load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                ranges = [model.duration * 0.2...model.duration * 0.27, model.duration * 0.6...model.duration * 0.7]
                selected = 1
                model.setZoom(4, anchor: model.duration * 0.62, anchorFraction: 0.3)
                if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO_PLAY"] != nil {
                    model.seek(to: model.duration * 0.58)
                    playBleeped()
                }
            }
            #endif
        }
        .onChange(of: key) { _ in
            // The rendered sound no longer matches; stop rather than play stale bleeps.
            if version == .bleeped, model.isPlaying { model.pause() }
            notice = ""
        }
        .onDisappear {
            model.pause()
            [bleepedFile, originalFile].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mangosteen-bleep-\(UUID().uuidString).m4a")
    }

    /// Space: play (or pause) with the bleeps, preparing the processed sound when the bleeps changed.
    private func playBleeped() {
        if model.isPlaying {
            model.pause()
            return
        }
        guard !ranges.isEmpty else {
            playOriginal()
            return
        }
        Task {
            if renderedKey != key || bleepedFile == nil {
                rendering = true
                let file = temporaryFile()
                let input = model.url
                let graph = AudioTools.bleepGraph(ranges: ranges, frequency: frequency, volume: volume, duration: model.duration)
                let renderedFor = key
                let ok = await Task.detached(priority: .userInitiated) {
                    (try? AudioTools.renderPreview(input, graph: graph, to: file)) != nil
                }.value
                rendering = false
                guard ok else { return }
                if let old = bleepedFile { try? FileManager.default.removeItem(at: old) }
                bleepedFile = file
                renderedKey = renderedFor
                version = .original // force the swap below
            }
            if version != .bleeped, let bleepedFile {
                try? await model.setAudioOverride(bleepedFile)
                version = .bleeped
            }
            model.togglePlay()
        }
    }

    private func playOriginal() {
        if model.isPlaying {
            let wasOriginal = version == .original
            model.pause()
            if wasOriginal { return }
        }
        Task {
            if version != .original || model.player == nil {
                if model.canPlayOriginal {
                    try? await model.setAudioOverride(nil)
                } else {
                    // Formats AVFoundation cannot open: listen to the decoded original sound.
                    if originalFile == nil {
                        rendering = true
                        let file = temporaryFile()
                        let input = model.url
                        let ok = await Task.detached { (try? AudioTools.renderPreview(input, to: file)) != nil }.value
                        rendering = false
                        guard ok else { return }
                        originalFile = file
                    }
                    if let originalFile { try? await model.setAudioOverride(originalFile) }
                }
                version = .original
            }
            model.togglePlay()
        }
    }

    /// Adds a 0.6 s bleep at the playhead, never on top of another one.
    private func addBleep() {
        let start = model.currentTime
        if let existing = ranges.firstIndex(where: { $0.contains(start) }) {
            selected = existing
            notice = "Здесь уже есть пик — он выделен."
            return
        }
        let next = ranges.map(\.lowerBound).filter { $0 > start }.min() ?? model.duration
        let end = min(start + 0.6, next, model.duration)
        guard end - start >= 0.05 else {
            notice = "Слишком близко к соседнему пику."
            return
        }
        ranges.append(start...end)
        ranges.sort { $0.lowerBound < $1.lowerBound }
        selected = ranges.firstIndex { $0.lowerBound == start }
    }

    private func removeSelected() {
        guard let selected, ranges.indices.contains(selected) else { return }
        ranges.remove(at: selected)
        self.selected = nil
    }

    private func run() {
        model.pause()
        let ranges = ranges
        let frequency = frequency
        let volume = volume
        ConversionService.shared.runEach("Запикивание", inputs: [model.url], maxConcurrent: 1) { url, progress, cancellation in
            try AudioTools.bleep(url, ranges: ranges, frequency: frequency, volume: volume,
                                 progress: progress, cancellation: cancellation)
        }
        close()
    }
}

/// Bleep ranges on the shared timeline: click a range to select it, drag it to move, drag its edges to
/// resize. Ranges stay sorted and never overlap: moves and resizes stop at the neighbours.
private struct BleepStrip: View {
    @ObservedObject var model: MediaPlayerModel
    @Binding var ranges: [ClosedRange<Double>]
    @Binding var selected: Int?
    @State private var dragStart: ClosedRange<Double>?

    var body: some View {
        TimelineFrame(model: model, onScrub: { selected = nil }) { width, height in
            ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                let start = model.x(for: range.lowerBound, width: width)
                let end = model.x(for: range.upperBound, width: width)
                let isSelected = index == selected
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.red.opacity(isSelected ? 0.55 : 0.4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: isSelected ? 2.5 : 1))
                    .frame(width: max(end - start, 4), height: height)
                    .position(x: (start + end) / 2, y: height / 2)
                    .gesture(moveGesture(index, width: width))
                if isSelected {
                    edge(index, isStart: true, at: start, width: width, height: height)
                    edge(index, isStart: false, at: end, width: width, height: height)
                }
            }
        }
    }

    /// Free space around range `index`: from the previous range's end to the next range's start.
    private func limits(_ index: Int) -> ClosedRange<Double> {
        let lower = index > 0 ? ranges[index - 1].upperBound : 0
        let upper = index < ranges.count - 1 ? ranges[index + 1].lowerBound : model.duration
        return lower...max(upper, lower)
    }

    private func moveGesture(_ index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace))
            .onChanged { value in
                guard ranges.indices.contains(index) else { return }
                selected = index
                let start = dragStart ?? ranges[index]
                dragStart = start
                let length = start.upperBound - start.lowerBound
                let shift = Double(value.translation.width / max(width, 1)) * model.viewLength
                let bounds = limits(index)
                let lower = min(max(start.lowerBound + shift, bounds.lowerBound), bounds.upperBound - length)
                ranges[index] = lower...(lower + length)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func edge(_ index: Int, isStart: Bool, at position: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.red)
            .frame(width: 8, height: height + 8)
            .frame(width: 22, height: height + 8)
            .contentShape(Rectangle())
            .position(x: position, y: height / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)).onChanged { value in
                guard ranges.indices.contains(index) else { return }
                let seconds = model.time(at: value.location.x, width: width)
                let current = ranges[index]
                let bounds = limits(index)
                ranges[index] = isStart
                    ? max(min(seconds, current.upperBound - 0.05), bounds.lowerBound)...current.upperBound
                    : current.lowerBound...min(max(seconds, current.lowerBound + 0.05), bounds.upperBound)
            })
    }
}

// MARK: - Visualizer

struct VisualizerView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var settings = AudioTools.VisualizerSettings()
    @State private var preview: CGImage?
    @State private var duration = 0.0
    @State private var rendering = false

    private var files: [URL] { urls.filter { FileFormat.detect($0)?.category == .audio } }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black)
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(8)
                    }
                    if rendering { ProgressView() }
                }
                .frame(width: 420, height: 420)
                controls.frame(width: 300)
            }
            ToolFooter(fileCount: files.count, actionTitle: "Создать видео", actionDisabled: files.isEmpty,
                       cancel: close, action: run)
        }
        .padding(20)
        .task(id: settings) { await renderPreview() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Стиль").font(.callout)
                Picker("Стиль", selection: $settings.style) {
                    ForEach(AudioTools.VisualizerSettings.Style.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Формат видео").font(.callout)
                Picker("Формат видео", selection: $settings.orientation) {
                    ForEach(AudioTools.VisualizerSettings.Orientation.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            ColorPicker("Цвет волны", selection: Binding(get: { settings.waveColor.cgColor },
                                                         set: { settings.waveColor = RGBAColor($0) }),
                        supportsOpacity: false)
                .disabled(settings.style == .still)
            ColorPicker("Цвет фона", selection: Binding(get: { settings.background.cgColor },
                                                        set: { settings.background = RGBAColor($0) }),
                        supportsOpacity: false)
                .disabled(settings.image != nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("Фоновое изображение").font(.callout)
                HStack {
                    Button(settings.image?.lastPathComponent ?? "Выбрать…", action: chooseImage)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if settings.image != nil {
                        Button { settings.image = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text("Видео MP4 той же длительности, что и запись.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.image = url
    }

    private func renderPreview() async {
        guard let first = files.first else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        rendering = true
        let settings = settings
        let known = duration
        let result = await Task.detached(priority: .userInitiated) { () -> (Double, CGImage?) in
            let duration = known > 0 ? known : ((try? MediaConverter.probe(first).duration) ?? 0) ?? 0
            let frame = try? AudioTools.visualizerFrame(first, settings: settings, duration: duration, at: duration * 0.4)
            return (duration, frame)
        }.value
        guard !Task.isCancelled else { return }
        rendering = false
        duration = result.0
        if let frame = result.1 { preview = frame }
    }

    private func run() {
        let settings = settings
        ConversionService.shared.runEach("Визуализация", inputs: files, maxConcurrent: 1) { url, progress, cancellation in
            try AudioTools.visualize(url, settings: settings, progress: progress, cancellation: cancellation)
        }
        close()
    }
}
