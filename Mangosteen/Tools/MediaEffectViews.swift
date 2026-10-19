import SwiftUI

private func media(_ urls: [URL]) -> [URL] {
    urls.filter { FileFormat.detect($0)?.category.isMedia == true }
}

private func videos(_ urls: [URL]) -> [URL] {
    urls.filter { FileFormat.detect($0)?.category == .video }
}

// MARK: - Speed

/// Make a slower or faster copy of videos or recordings.
struct SpeedView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var factor = 2.0
    @State private var preservePitch = true
    @State private var firstDuration: Double?

    private static let presets = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Скорость")).font(.headline)
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { preset in
                    if abs(factor - preset) < 0.001 {
                        Button(MediaEffects.speedLabel(preset)) { factor = preset }.buttonStyle(.borderedProminent)
                    } else {
                        Button(MediaEffects.speedLabel(preset)) { factor = preset }.buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                Slider(value: $factor, in: 0.25...4)
                Text(MediaEffects.speedLabel(factor))
                    .font(.body.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(String(localized: "Сохранять высоту звука"), isOn: $preservePitch)
                Text(preservePitch ? String(localized: "Голос звучит естественно при любой скорости.")
                                   : String(localized: "Как на плёнке: ускорение повышает тон, замедление понижает."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let firstDuration, let first = media(urls).first {
                Text("\(first.lastPathComponent): \(MediaTools.timecode(firstDuration)) → \(MediaTools.timecode(firstDuration / factor))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ToolFooter(fileCount: media(urls).count, actionTitle: String(localized: "Изменить скорость"),
                       actionDisabled: abs(factor - 1) < 0.01 || media(urls).isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 600)
        .task {
            guard let first = media(urls).first else { return }
            firstDuration = await Task.detached { try? MediaConverter.probe(first).duration }.value ?? nil
        }
    }

    private func run() {
        let factor = (factor * 100).rounded() / 100
        let preservePitch = preservePitch
        ConversionService.shared.runEach(String(localized: "Скорость \(MediaEffects.speedLabel(factor))"), inputs: media(urls),
                                         maxConcurrent: 2) { url, progress, cancellation in
            try MediaEffects.changeSpeed(url, factor: factor, preservePitch: preservePitch,
                                         progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Join

/// Arrange clips and combine them into one MP4.
struct JoinView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var order: [URL] = []
    @State private var infos: [URL: MediaInfo] = [:]
    @State private var thumbnails: [URL: CGImage] = [:]

    private var total: Double { order.compactMap { infos[$0]?.duration }.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Порядок клипов — перетаскивайте строки. Размер кадра и частота берутся у первого клипа, ")
                 + String(localized: "остальные вписываются в него с полями."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(order, id: \.self) { url in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(Color.black)
                            if let image = thumbnails[url] {
                                Image(decorative: image, scale: 1).resizable().scaledToFit()
                            }
                        }
                        .frame(width: 80, height: 45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(details(url)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if url == order.first {
                            Text(String(localized: "холст")).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Brand.color.opacity(0.25)))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 260)
            HStack {
                Text(String(localized: "Итого: \(MediaTools.timecode(total))")).font(.callout.monospacedDigit())
                if let first = order.first, let width = infos[first]?.width, let height = infos[first]?.height {
                    Text(verbatim: "· \(width)×\(height) · MP4").font(.callout).foregroundStyle(.secondary)
                }
            }
            ToolFooter(fileCount: order.count, actionTitle: String(localized: "Объединить"), actionDisabled: order.count < 2,
                       cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 620)
        .task { await load() }
    }

    private func details(_ url: URL) -> String {
        guard let info = infos[url] else { return "…" }
        var parts = [MediaTools.timecode(info.duration ?? 0)]
        if let width = info.width, let height = info.height { parts.append("\(width)×\(height)") }
        if !info.hasAudio { parts.append(String(localized: "без звука")) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        order = videos(urls)
        for url in order {
            let (info, thumbnail) = await Task.detached(priority: .userInitiated) { () -> (MediaInfo?, CGImage?) in
                let info = try? MediaConverter.probe(url)
                let time = min(1, (info?.duration ?? 0) / 2)
                return (info, try? MediaTools.frame(url, at: time, maxHeight: 90))
            }.value
            infos[url] = info
            thumbnails[url] = thumbnail
        }
    }

    private func run() {
        let order = order
        guard let first = order.first else { return }
        ConversionService.shared.runEach(String(localized: "Склейка видео"), inputs: [first], maxConcurrent: 1) { _, progress, cancellation in
            try MediaEffects.join(order, progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Crop video

/// Reframe a video; the audio is kept.
struct VideoCropView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var frame: CGImage?
    @State private var imageSize = CGSize(width: 1, height: 1)
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspectChoice = CropView.AspectChoice.free
    @State private var exactWidth = 1080
    @State private var exactHeight = 1920
    @State private var duration = 0.0
    @State private var previewTime = 0.0
    @State private var loadError: String?
    @State private var frameTask: Task<Void, Never>?

    private var clips: [URL] { videos(urls) }

    private func pixelAspect(for size: CGSize) -> CGFloat? {
        switch aspectChoice {
        case .free: nil
        case .original: size.width / size.height
        case .exact: CGFloat(max(exactWidth, 1)) / CGFloat(max(exactHeight, 1))
        default: aspectChoice.fixedRatio
        }
    }

    private var normalizedAspect: CGFloat? {
        pixelAspect(for: imageSize).map { $0 * imageSize.height / imageSize.width }
    }

    var body: some View {
        VStack(spacing: 12) {
            CropCanvas(image: frame, imageSize: imageSize, rect: $rect, aspect: normalizedAspect, message: loadError)
                .frame(minWidth: 620, idealWidth: 720, minHeight: 380, idealHeight: 460)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            HStack(spacing: 8) {
                Text(String(localized: "Кадр для предпросмотра")).foregroundStyle(.secondary).fixedSize()
                Slider(value: $previewTime, in: 0...max(duration, 0.1))
                Text(MediaTools.timecode(previewTime)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .disabled(duration == 0)
            HStack(spacing: 12) {
                Picker(String(localized: "Пропорции"), selection: $aspectChoice) {
                    ForEach(CropView.AspectChoice.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 260)
                if aspectChoice == .exact {
                    TextField(String(localized: "Ширина"), value: $exactWidth, format: .number.grouping(.never)).frame(width: 70)
                    Text("×")
                    TextField(String(localized: "Высота"), value: $exactHeight, format: .number.grouping(.never)).frame(width: 70)
                    Text("px").foregroundStyle(.secondary)
                }
                Spacer()
                let pixels = ImageCropper.pixelRect(rect, imageSize: imageSize)
                Text(verbatim: "\(Int(pixels.width) / 2 * 2) × \(Int(pixels.height) / 2 * 2) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(String(localized: "Сбросить")) {
                    aspectChoice = .free
                    rect = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
            ToolFooter(fileCount: clips.count, actionTitle: String(localized: "Кадрировать"), actionDisabled: frame == nil,
                       cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .onChange(of: aspectChoice) { _ in applyAspect() }
        .onChange(of: exactWidth) { _ in applyAspect() }
        .onChange(of: exactHeight) { _ in applyAspect() }
        .onChange(of: previewTime) { time in loadFrame(at: time) }
    }

    private func applyAspect() {
        guard let aspect = pixelAspect(for: imageSize) else { return }
        rect = ImageCropper.centeredRect(aspect: aspect, imageSize: imageSize)
    }

    private func load() async {
        guard let first = clips.first else {
            loadError = String(localized: "Нет видео")
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (Double, CGImage)? in
            guard let duration = try? MediaConverter.probe(first).duration,
                  let image = try? MediaTools.frame(first, at: duration * 0.3) else { return nil }
            return (duration, image)
        }.value
        guard let (duration, image) = result else {
            loadError = String(localized: "Не удалось прочитать видео")
            return
        }
        self.duration = duration
        imageSize = CGSize(width: image.width, height: image.height)
        frame = image
        previewTime = duration * 0.3
    }

    private func loadFrame(at time: Double) {
        guard let first = clips.first, duration > 0 else { return }
        frameTask?.cancel()
        frameTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { try? MediaTools.frame(first, at: time) }.value
            guard !Task.isCancelled, let image else { return }
            frame = image
        }
    }

    private func run() {
        guard let first = clips.first else { return }
        let firstRect = rect
        let choice = aspectChoice
        let exact = CGSize(width: exactWidth, height: exactHeight)
        let outputSize: CGSize? = choice == .exact ? exact : nil
        ConversionService.shared.runEach(String(localized: "Кадрирование видео"), inputs: clips, maxConcurrent: 1) { url, progress, cancellation in
            var cropRect = firstRect
            if url != first, choice != .free {
                let image = try MediaTools.frame(url, at: 0)
                let size = CGSize(width: image.width, height: image.height)
                let aspect: CGFloat = switch choice {
                case .original: size.width / size.height
                case .exact: exact.width / max(exact.height, 1)
                default: choice.fixedRatio ?? size.width / size.height
                }
                cropRect = ImageCropper.centeredRect(aspect: aspect, imageSize: size)
            }
            return try MediaEffects.cropVideo(url, rect: cropRect, outputSize: outputSize,
                                              progress: progress, cancellation: cancellation)
        }
        close()
    }
}

// MARK: - Compress media

/// Reduce the size of videos and recordings.
struct MediaCompressView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var settings = MediaEffects.CompressionSettings()
    @State private var targetMegabytes = 25.0
    @State private var summary = ""
    @State private var estimate = ""
    @State private var estimateIsWarning = false
    @State private var estimating = false

    private static let heights: [Int?] = [nil, 2160, 1440, 1080, 720, 480]
    private var files: [URL] { media(urls) }
    private var hasVideo: Bool { !videos(urls).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(String(localized: "Качество"), selection: $settings.quality) {
                    ForEach(MediaEffects.CompressionSettings.Quality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(settings.useTargetSize)
                if hasVideo {
                    Picker(String(localized: "Высота кадра"), selection: $settings.maxHeight) {
                        ForEach(Self.heights, id: \.self) { height in
                            Text(height.map { String(localized: "до \($0) px") } ?? String(localized: "Без изменений")).tag(height)
                        }
                    }
                    .fixedSize()
                    Toggle(String(localized: "HEVC (H.265) — меньше файл, сжатие дольше"), isOn: $settings.hevc)
                }
                Toggle(String(localized: "Уложиться в размер файла"), isOn: $settings.useTargetSize)
                if settings.useTargetSize {
                    HStack {
                        Text(String(localized: "Не больше"))
                        TextField("", value: $targetMegabytes, format: .number).frame(width: 80)
                        Text(String(localized: "МБ"))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            if let first = files.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(first.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: summary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if estimating {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Оцениваю размер…")).font(.callout).foregroundStyle(.secondary)
                        } else if !estimate.isEmpty {
                            Text(verbatim: estimate)
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(estimateIsWarning ? Color.orange : Color.primary)
                        }
                    }
                    .frame(height: 18)
                    if files.count > 1 {
                        Text(String(localized: "Оценка для первого файла.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(hasVideo ? String(localized: "Видео сохраняется в MP4 (MOV и MKV остаются в своём формате).")
                          : String(localized: "WAV, FLAC и AIFF сохраняются в M4A (AAC), остальные — в своём формате."))
                .font(.caption)
                .foregroundStyle(.secondary)
            ToolFooter(fileCount: files.count, actionTitle: String(localized: "Сжать"), actionDisabled: files.isEmpty,
                       cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 560)
        .task { await describe() }
        .task(id: settings) { await updateEstimate() }
        .onChange(of: targetMegabytes) { value in settings.targetBytes = Int64(max(value, 0.1) * 1_000_000) }
    }

    private func describe() async {
        guard let first = files.first else { return }
        let info = await Task.detached { try? MediaConverter.probe(first) }.value
        var parts = [ByteCountFormatter().string(fromByteCount: ImageCompression.fileSize(first))]
        if let width = info?.width, let height = info?.height { parts.append("\(width)×\(height)") }
        if let duration = info?.duration { parts.append(MediaTools.timecode(duration)) }
        summary = parts.joined(separator: " · ")
    }

    /// Re-estimates after settings settle; a newer change cancels the running sample encode.
    private func updateEstimate() async {
        guard let first = files.first else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        estimating = true
        let settings = settings
        let token = CancellationToken()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Result { try MediaEffects.estimateCompressedSize(first, settings: settings, cancellation: token) }
            }.value
        } onCancel: {
            token.cancel()
        }
        guard !Task.isCancelled else { return }
        estimating = false
        switch result {
        case .success(let bytes):
            let original = ImageCompression.fileSize(first)
            let formatter = ByteCountFormatter()
            let change = original > 0 ? Int((Double(bytes) / Double(original) - 1) * 100) : 0
            let sign = change > 0 ? "+" : "−"
            let prefix = settings.useTargetSize ? "≤" : "≈"
            estimate = "\(formatter.string(fromByteCount: original)) → \(prefix) \(formatter.string(fromByteCount: bytes)) (\(sign)\(abs(change))%)"
            estimateIsWarning = bytes >= original
            if estimateIsWarning {
                estimate += String(localized: " — не меньше оригинала, файл не будет сохранён")
            }
        case .failure:
            estimate = ""
        }
    }

    private func run() {
        let settings = settings
        ConversionService.shared.runEach(String(localized: "Сжатие"), inputs: files, maxConcurrent: hasVideo ? 1 : 2) { url, progress, cancellation in
            try MediaEffects.compress(url, settings: settings, progress: progress, cancellation: cancellation)
        }
        close()
    }
}
