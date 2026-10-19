import AVFoundation
import AVKit
import SwiftUI

/// Playback state shared by the media tools. Uses AVPlayer when AVFoundation can play the file;
/// otherwise shows frames decoded by ffmpeg at the playhead.
final class MediaPlayerModel: ObservableObject {
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

    /// While playing, wrap around inside this range (the trim selection).
    var loopRange: ClosedRange<Double>?

    private var timeObserver: Any?
    private var posterTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        isVideo = FileFormat.detect(url)?.category == .video
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
    }

    var frameDuration: Double { 1 / max(frameRate, 1) }

    func load() async {
        guard !isLoaded else { return }
        let url = url
        let info = await Task.detached(priority: .userInitiated) { try? MediaConverter.probe(url) }.value
        guard let info, let duration = info.duration, duration > 0 else {
            loadError = "Не удалось прочитать файл"
            return
        }
        self.duration = duration
        frameRate = info.frameRate ?? 30

        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true {
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                self?.tick(time.seconds)
            }
            self.player = player
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
                (try? MediaTools.waveform(url, duration: duration, buckets: 800)) ?? []
            }.value
        }
    }

    private func tick(_ seconds: Double) {
        guard isPlaying, seconds.isFinite else { return }
        currentTime = seconds
        if let loopRange, seconds >= loopRange.upperBound {
            seek(to: loopRange.lowerBound)
            player?.play()
        } else if seconds >= duration - 0.02 {
            pause()
        }
    }

    func seek(to seconds: Double) {
        let time = min(max(seconds, 0), duration)
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if player == nil, isVideo { updatePoster() }
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
        isPlaying = false
        player?.pause()
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    /// Decodes the frame under the playhead for files AVFoundation cannot play (debounced).
    private func updatePoster() {
        posterTask?.cancel()
        let url = url
        let time = currentTime
        posterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { try? MediaTools.frame(url, at: time, maxHeight: 720) }.value
            guard !Task.isCancelled, let image else { return }
            self?.poster = image
        }
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
                if let player = model.player {
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

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            // Scale to the loudest peak so quiet recordings are still readable.
            let loudest = CGFloat(max(peaks.max() ?? 1, 0.001))
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(CGFloat(peak) / loudest * size.height * 0.92, 1)
                path.addRect(CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                    width: max(step - 0.5, 0.5), height: height))
            }
            context.fill(path, with: .color(.accentColor.opacity(0.75)))
        }
    }
}

// MARK: - Timeline

/// Thumbnails or waveform with the playhead, an optional selected range with handles, and markers.
/// Click or drag anywhere to move the playhead.
struct TimelineStrip: View {
    @ObservedObject var model: MediaPlayerModel
    var range: Binding<ClosedRange<Double>>?
    var markers: [Double] = []
    var markerColor: Color = .yellow

    private static let space = "timeline"

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                Color.clear
                strip(width: width, height: height)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .position(x: width / 2, y: height / 2)

                if let range {
                    let start = x(range.wrappedValue.lowerBound, width)
                    let end = x(range.wrappedValue.upperBound, width)
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: max(start, 0), height: height)
                        .position(x: start / 2, y: height / 2)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: max(width - end, 0), height: height)
                        .position(x: (end + width) / 2, y: height / 2)
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
                        Rectangle().fill(markerColor)
                            .frame(width: 3, height: height + 6)
                        Circle().fill(markerColor)
                            .frame(width: 11, height: 11)
                            .offset(y: -8)
                    }
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
                    .position(x: x(marker, width), y: height / 2)
                    .allowsHitTesting(false)
                }

                Rectangle().fill(Color.white)
                    .frame(width: 2, height: height + 10)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .position(x: x(model.currentTime, width), y: height / 2)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                model.pause()
                model.seek(to: time(value.location.x, width))
            })
        }
        .frame(height: 64)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        if model.isVideo, !model.thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(model.thumbnails.count), height: height)
                        .clipped()
                }
            }
        } else {
            WaveformView(peaks: model.waveform)
                .background(Color.primary.opacity(0.07))
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
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                let minimum = max(model.frameDuration, 0.05)
                let seconds = time(value.location.x, width)
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

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(seconds / model.duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width) * model.duration, 0), model.duration)
    }
}

// MARK: - Controls

/// Play/pause (Space), frame stepping and the current time.
struct TransportBar: View {
    @ObservedObject var model: MediaPlayerModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.player == nil)
            .help(model.player == nil ? "Этот формат можно просматривать только по кадрам" : "Воспроизведение (пробел)")
            if model.isVideo {
                Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Кадр назад")
                Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Кадр вперёд")
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
