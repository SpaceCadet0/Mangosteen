import AVFoundation
import AVKit
import SwiftUI

/// Playback state shared by the media tools. Uses AVPlayer when AVFoundation can play the file;
/// otherwise shows frames decoded by ffmpeg at the playhead. Also owns the timeline viewport (zoom and
/// scroll) so every strip and control agrees on what part of the file is visible.
/// Main-actor isolated: its async loading must publish on the main thread or SwiftUI misses the updates.
@MainActor
final class MediaPlayerModel: ObservableObject {
    struct Tile {
        let image: CGImage
        let range: ClosedRange<Double>
    }

    let url: URL
    let isVideo: Bool

    @Published private(set) var duration: Double = 0
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var poster: CGImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false
    /// Whether AVFoundation can play the original file (MKV, WebM, OGG… cannot).
    @Published private(set) var canPlayOriginal = false

    // Viewport
    static let maxZoom = 64.0
    @Published private(set) var zoom = 1.0
    @Published private(set) var viewStart = 0.0
    @Published private var detailWaveform: [Float] = []
    @Published private var detailTiles: [Tile] = []
    @Published private var detailWindow: ClosedRange<Double>?

    /// While playing, wrap around inside this range (the trim selection).
    var loopRange: ClosedRange<Double>?

    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var posterTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailCancellation: CancellationToken?
    private var lastPosterUpdate = Date.distantPast

    init(url: URL) {
        self.url = url
        isVideo = FileFormat.detect(url)?.category == .video
    }

    var frameDuration: Double { 1 / max(frameRate, 1) }
    var viewLength: Double { duration / zoom }
    var waveformPeak: Float { max(waveform.max() ?? 1, 0.001) }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        let url = url
        let info = await Task.detached(priority: .userInitiated) { try? MediaConverter.probe(url) }.value
        guard let info, let duration = info.duration, duration > 0 else {
            loadError = String(localized: "Не удалось прочитать файл")
            return
        }
        self.duration = duration
        frameRate = info.frameRate ?? 30

        // Precise timing: without it AVFoundation estimates positions in VBR MP3 from byte offsets,
        // so the sound heard after a seek drifts away from the waveform.
        let asset = Self.preciseAsset(url)
        self.asset = asset
        if (try? await asset.load(.isPlayable)) == true {
            canPlayOriginal = true
            attachPlayer(item: AVPlayerItem(asset: asset))
        } else if isVideo {
            updatePoster()
        }
        isLoaded = true

        if isVideo {
            thumbnails = await Task.detached(priority: .utility) {
                MediaTools.thumbnails(url, duration: duration, count: 12, height: 90)
            }.value
        } else {
            waveform = await Task.detached(priority: .utility) {
                (try? MediaTools.waveform(url, duration: duration, buckets: 1600)) ?? []
            }.value
        }
    }

    private static func preciseAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    private func attachPlayer(item: AVPlayerItem) {
        if let player {
            player.replaceCurrentItem(with: item)
            return
        }
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        self.player = player
    }

    /// Plays `audio` in place of the file's own sound, keeping the original picture (used to hear an edit
    /// before saving). `nil` restores the original. The playhead position is kept.
    func setAudioOverride(_ audio: URL?) async throws {
        let time = currentTime
        pause()
        let item: AVPlayerItem
        if let audio {
            if isVideo, canPlayOriginal, let asset {
                let composition = AVMutableComposition()
                let length = try await asset.load(.duration)
                if let video = try await asset.loadTracks(withMediaType: .video).first,
                   let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: video, at: .zero)
                    track.preferredTransform = try await video.load(.preferredTransform)
                }
                let sound = Self.preciseAsset(audio)
                if let audioTrack = try await sound.loadTracks(withMediaType: .audio).first,
                   let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let soundLength = try await sound.load(.duration)
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: soundLength), of: audioTrack, at: .zero)
                }
                item = AVPlayerItem(asset: composition)
            } else {
                // Audio files, and videos AVFoundation cannot show (their frames come from ffmpeg).
                item = AVPlayerItem(asset: Self.preciseAsset(audio))
            }
        } else {
            guard canPlayOriginal, let asset else { return }
            item = AVPlayerItem(asset: asset)
        }
        attachPlayer(item: item)
        seek(to: time)
    }

    // MARK: Playback

    private func tick(_ seconds: Double) {
        guard isPlaying, seconds.isFinite else { return }
        currentTime = seconds
        if let loopRange, seconds >= loopRange.upperBound {
            seek(to: loopRange.lowerBound)
            player?.play()
        } else if seconds >= duration - 0.02 {
            pause()
        }
        followPlayhead()
        if !canPlayOriginal, isVideo, Date().timeIntervalSince(lastPosterUpdate) > 0.4 {
            lastPosterUpdate = Date()
            updatePoster(debounce: false)
        }
    }

    func seek(to seconds: Double) {
        let time = min(max(seconds, 0), duration)
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if !canPlayOriginal, isVideo { updatePoster() }
        if zoom > 1, time < viewStart || time > viewStart + viewLength {
            setViewStart(time - viewLength * 0.1)
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            pause()
            return
        }
        if let loopRange, !loopRange.contains(currentTime) || currentTime >= loopRange.upperBound - 0.05 {
            seek(to: loopRange.lowerBound)
        } else if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        isPlaying = true
        player.play()
    }

    func pause() {
        let wasPlaying = isPlaying
        isPlaying = false
        player?.pause()
        // Detail is not fetched while playing; catch up now.
        if wasPlaying { scheduleDetail() }
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    /// Decodes the frame under the playhead for files AVFoundation cannot play.
    private func updatePoster(debounce: Bool = true) {
        posterTask?.cancel()
        let url = url
        let time = currentTime
        posterTask = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { try? MediaTools.frame(url, at: time, maxHeight: 720) }.value
            guard !Task.isCancelled, let image else { return }
            self?.poster = image
        }
    }

    // MARK: Viewport

    func x(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat((seconds - viewStart) / max(viewLength, 0.0001)) * width
    }

    func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return viewStart }
        return min(max(viewStart + Double(x / width) * viewLength, 0), duration)
    }

    /// Zooms keeping `anchor` (seconds) at `anchorFraction` of the width; by default around the playhead.
    func setZoom(_ newZoom: Double, anchor: Double? = nil, anchorFraction: Double? = nil) {
        guard duration > 0 else { return }
        let anchorTime = anchor ?? currentTime
        let fraction = anchorFraction ?? min(max((anchorTime - viewStart) / max(viewLength, 0.0001), 0), 1)
        zoom = min(max(newZoom, 1), Self.maxZoom)
        setViewStart(anchorTime - fraction * viewLength)
    }

    func pan(by seconds: Double) {
        setViewStart(viewStart + seconds)
    }

    private func setViewStart(_ start: Double) {
        viewStart = min(max(start, 0), max(duration - viewLength, 0))
        scheduleDetail()
    }

    /// Keeps the playhead on screen while playing.
    private func followPlayhead() {
        guard zoom > 1 else { return }
        if currentTime > viewStart + viewLength * 0.95 || currentTime < viewStart {
            setViewStart(currentTime - viewLength * 0.05)
        }
    }

    private var currentWindow: ClosedRange<Double> { viewStart...(viewStart + viewLength) }

    private func detailMatches() -> Bool {
        guard let detailWindow else { return false }
        let tolerance = viewLength * 0.002
        return abs(detailWindow.lowerBound - viewStart) < tolerance && abs(detailWindow.upperBound - (viewStart + viewLength)) < tolerance
    }

    /// Re-reads frames or audio for the visible window so zooming in shows real detail. Only one fetch runs
    /// at a time: a newer viewport cancels the previous one between frames, and nothing is fetched while
    /// playing (the window moves too often), so zooming or scrolling cannot pile up ffmpeg processes.
    private func scheduleDetail() {
        detailTask?.cancel()
        detailCancellation?.cancel()
        guard zoom > 1.01, isLoaded else {
            detailWindow = nil
            return
        }
        guard !isPlaying else { return }
        let window = currentWindow
        let url = url
        let isVideo = isVideo
        let token = CancellationToken()
        detailCancellation = token
        detailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, !token.isCancelled else { return }
            let length = window.upperBound - window.lowerBound
            if isVideo {
                let images = await Task.detached(priority: .utility) {
                    MediaTools.thumbnails(url, start: window.lowerBound, duration: length, count: 12, height: 90,
                                          cancellation: token)
                }.value
                guard !Task.isCancelled, !token.isCancelled, let self, images.count == 12 else { return }
                let step = length / 12
                self.detailTiles = images.enumerated().map { index, image in
                    Tile(image: image, range: (window.lowerBound + Double(index) * step)...(window.lowerBound + Double(index + 1) * step))
                }
            } else {
                let peaks = await Task.detached(priority: .utility) {
                    (try? MediaTools.waveform(url, duration: length, buckets: 800, start: window.lowerBound)) ?? []
                }.value
                guard !Task.isCancelled, !token.isCancelled, let self, !peaks.isEmpty else { return }
                self.detailWaveform = peaks
            }
            self?.detailWindow = window
        }
    }

    /// Thumbnails covering the visible window.
    var visibleTiles: [Tile] {
        if detailMatches(), !detailTiles.isEmpty { return detailTiles }
        guard !thumbnails.isEmpty, duration > 0 else { return [] }
        let step = duration / Double(thumbnails.count)
        let window = currentWindow
        return thumbnails.enumerated().compactMap { index, image in
            let range = (Double(index) * step)...(Double(index + 1) * step)
            return range.overlaps(window) ? Tile(image: image, range: range) : nil
        }
    }

    /// Waveform peaks for the visible window, aligned to its edges.
    var visiblePeaks: [Float] {
        if detailMatches(), !detailWaveform.isEmpty { return detailWaveform }
        guard !waveform.isEmpty, duration > 0 else { return [] }
        let count = Double(waveform.count)
        let first = min(max(Int(viewStart / duration * count), 0), waveform.count - 1)
        let last = min(max(Int(((viewStart + viewLength) / duration * count).rounded(.up)), first + 1), waveform.count)
        return Array(waveform[first..<last])
    }
}

// MARK: - Preview

/// Video picture (or a large waveform for audio).
struct MediaPreview: View {
    @ObservedObject var model: MediaPlayerModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(model.isVideo ? 0.9 : 0.25))
            if let error = model.loadError {
                Text(error).foregroundStyle(.secondary)
            } else if model.isVideo {
                if model.canPlayOriginal, let player = model.player {
                    PlayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let poster = model.poster {
                    Image(decorative: poster, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            } else {
                VStack(spacing: 8) {
                    if model.waveform.isEmpty {
                        ProgressView().frame(maxHeight: .infinity)
                    } else {
                        WaveformView(peaks: model.waveform)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    Label(model.url.lastPathComponent, systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
            }
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct WaveformView: View {
    let peaks: [Float]
    /// The level drawn at full height; defaults to the loudest of `peaks`.
    var reference: Float?

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            // Scale to the loudest peak so quiet recordings are still readable.
            let loudest = CGFloat(max(reference ?? peaks.max() ?? 1, 0.001))
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(min(CGFloat(peak) / loudest, 1) * size.height * 0.92, 1)
                path.addRect(CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                    width: max(step - 0.5, 0.5), height: height))
            }
            context.fill(path, with: .color(Brand.light))
        }
    }
}

// MARK: - Timeline

let timelineSpace = "timeline"

/// Thumbnails or waveform of the visible window.
struct TimelineBackground: View {
    @ObservedObject var model: MediaPlayerModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.07)
                if model.isVideo {
                    ForEach(Array(model.visibleTiles.enumerated()), id: \.offset) { _, tile in
                        let start = model.x(for: tile.range.lowerBound, width: width)
                        let end = model.x(for: tile.range.upperBound, width: width)
                        Image(decorative: tile.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: max(end - start, 1), height: height)
                            .clipped()
                            .position(x: (start + end) / 2, y: height / 2)
                    }
                } else {
                    WaveformView(peaks: model.visiblePeaks, reference: model.waveformPeak)
                        .frame(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }
}

/// Clips sideways only, so handles and the playhead may stick out above and below the strip.
private struct HorizontalClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 30, width: rect.width, height: rect.height + 60))
    }
}

/// The shared timeline: background, playhead, click-to-seek, zoom (pinch, ⌘/⌥ + wheel, zoom bar) and
/// scrolling. Tools draw their own marks in `overlay(width, height)` using `model.x(for:width:)`.
struct TimelineFrame<Overlay: View>: View {
    @ObservedObject var model: MediaPlayerModel
    var onScrub: (() -> Void)?
    @ViewBuilder let overlay: (CGFloat, CGFloat) -> Overlay

    @State private var pinchStart: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ZStack(alignment: .topLeading) {
                    Color.clear
                    TimelineBackground(model: model)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .position(x: width / 2, y: height / 2)
                    overlay(width, height)
                    let playhead = model.x(for: model.currentTime, width: width)
                    if (-2...(width + 2)).contains(playhead) {
                        Rectangle().fill(Color.white)
                            .frame(width: 2, height: height + 10)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .position(x: playhead, y: height / 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(HorizontalClip())
                .contentShape(Rectangle())
                .coordinateSpace(name: timelineSpace)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)).onChanged { value in
                    onScrub?()
                    model.pause()
                    model.seek(to: model.time(at: value.location.x, width: width))
                })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { scale in
                        let start = pinchStart ?? model.zoom
                        pinchStart = start
                        model.setZoom(start * Double(scale))
                    }
                    .onEnded { _ in pinchStart = nil })
                .background(ScrollCatcher { event, x in handleScroll(event, x: x, width: width) })
            }
            .frame(height: 64)
            .padding(.vertical, 5)
            HStack(spacing: 8) {
                Spacer()
                Text(String(localized: "Масштаб: щипок, ⌘ или ⌥ + колёсико; прокрутка — сдвиг"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ZoomBar(model: model)
            }
        }
    }

    private func handleScroll(_ event: NSEvent, x: CGFloat, width: CGFloat) -> Bool {
        let flags = event.modifierFlags
        let precise = event.hasPreciseScrollingDeltas
        if flags.contains(.command) || flags.contains(.option) {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            let factor = pow(1.012, Double(delta) * (precise ? 1 : 10))
            let fraction = Double(min(max(x / max(width, 1), 0), 1))
            model.setZoom(model.zoom * factor, anchor: model.time(at: x, width: width), anchorFraction: fraction)
            return true
        }
        guard model.zoom > 1 else { return false }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        model.pan(by: -Double(delta) * (precise ? 1 : 10) / Double(max(width, 1)) * model.viewLength)
        return true
    }
}

/// Catches scroll-wheel events over its area without blocking clicks.
private struct ScrollCatcher: NSViewRepresentable {
    /// Returns true when the event was used.
    let onScroll: (NSEvent, CGFloat) -> Bool

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((NSEvent, CGFloat) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point), self.onScroll?(event, point.x) == true else { return event }
                    return nil
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

/// − slider + and a reset, for the timeline zoom.
struct ZoomBar: View {
    @ObservedObject var model: MediaPlayerModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.setZoom(model.zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .disabled(model.zoom <= 1)
            Slider(value: Binding(get: { log2(model.zoom) }, set: { model.setZoom(pow(2, $0)) }),
                   in: 0...log2(MediaPlayerModel.maxZoom))
                .frame(width: 130)
            Button { model.setZoom(model.zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .disabled(model.zoom >= MediaPlayerModel.maxZoom)
            Text(verbatim: "×" + String(format: model.zoom < 10 ? "%.1f" : "%.0f", model.zoom))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Button(String(localized: "Весь файл")) { model.setZoom(1) }
                .controlSize(.small)
                .opacity(model.zoom > 1 ? 1 : 0)
                .disabled(model.zoom <= 1)
        }
        .controlSize(.small)
        .disabled(!model.isLoaded)
    }
}

/// Timeline with an optional selected range (trim) and point markers (split, frames).
struct TimelineStrip: View {
    @ObservedObject var model: MediaPlayerModel
    var range: Binding<ClosedRange<Double>>?
    var markers: [Double] = []
    var markerColor: Color = .yellow

    var body: some View {
        TimelineFrame(model: model) { width, height in
            if let range {
                let start = model.x(for: range.wrappedValue.lowerBound, width: width)
                let end = model.x(for: range.wrappedValue.upperBound, width: width)
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: min(max(start, 0), width), height: height)
                    .position(x: min(max(start, 0), width) / 2, y: height / 2)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(width - max(end, 0), 0), height: height)
                    .position(x: (max(end, 0) + width) / 2, y: height / 2)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(end - start, 1), height: height)
                    .position(x: (start + end) / 2, y: height / 2)
                    .allowsHitTesting(false)
                handle(range: range, isStart: true, at: start, width: width, height: height)
                handle(range: range, isStart: false, at: end, width: width, height: height)
            }
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                // Thick, outlined and capped so it stands out on busy thumbnails.
                ZStack(alignment: .top) {
                    Rectangle().fill(markerColor).frame(width: 3, height: height + 6)
                    Circle().fill(markerColor).frame(width: 11, height: 11).offset(y: -8)
                }
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .position(x: model.x(for: marker, width: width), y: height / 2)
                .allowsHitTesting(false)
            }
        }
    }

    private func handle(range: Binding<ClosedRange<Double>>, isStart: Bool, at position: CGFloat,
                        width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 10, height: height + 8)
            .overlay(Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
            .frame(width: 26, height: height + 8)
            .contentShape(Rectangle())
            .position(x: position, y: height / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)).onChanged { value in
                let minimum = max(model.frameDuration, 0.05)
                let seconds = model.time(at: value.location.x, width: width)
                let current = range.wrappedValue
                if isStart {
                    range.wrappedValue = min(seconds, current.upperBound - minimum)...current.upperBound
                } else {
                    range.wrappedValue = current.lowerBound...max(seconds, current.lowerBound + minimum)
                }
                model.pause()
                model.seek(to: isStart ? range.wrappedValue.lowerBound : range.wrappedValue.upperBound)
            })
    }
}

// MARK: - Controls

/// Play/pause (Space), frame stepping and the current time. `onPlay` replaces the default play action
/// (Bleep plays its processed sound); `isBusy` shows that the sound is being prepared.
struct TransportBar: View {
    @ObservedObject var model: MediaPlayerModel
    var onPlay: (() -> Void)?
    var isBusy = false

    var body: some View {
        HStack(spacing: 6) {
            Button { (onPlay ?? model.togglePlay)() } label: {
                ZStack {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(onPlay == nil && model.player == nil)
            .help(onPlay == nil && model.player == nil ? String(localized: "Этот формат можно просматривать только по кадрам") : String(localized: "Воспроизведение (пробел)"))
            if model.isVideo {
                Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help(String(localized: "Кадр назад"))
                Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help(String(localized: "Кадр вперёд"))
            }
            Text("\(MediaTools.timecode(model.currentTime)) / \(MediaTools.timecode(model.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .disabled(!model.isLoaded)
    }
}

/// A text field for `HH:MM:SS.mmm` that commits on Return or when focus leaves.
struct TimecodeField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            TextField("", text: $text)
                .font(.body.monospacedDigit())
                .frame(width: 104)
                .focused($focused)
                .onSubmit(commit)
        }
        .onAppear { text = MediaTools.timecode(value) }
        .onChange(of: value) { newValue in
            if !focused { text = MediaTools.timecode(newValue) }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        if let seconds = MediaTools.parseTimecode(text) {
            value = min(max(seconds, range.lowerBound), range.upperBound)
        }
        text = MediaTools.timecode(value)
    }
}
