import Foundation

/// Which encoder makes the picture when video is re-encoded into MP4, MOV or MKV. Every tool that re-encodes video
/// asks here, so the choice in Settings applies everywhere. Compression keeps its own HEVC option, and a source the
/// container already accepts is still copied without re-encoding.
struct VideoEncoding: Equatable {
    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc, av1
        var id: String { rawValue }
        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC (H.265)"
            case .av1: "AV1"
            }
        }
    }

    var codec = Codec.h264
    /// VideoToolbox: several times faster and lighter on the processor, files somewhat larger. There is no hardware
    /// AV1 encoder, so AV1 is always encoded in software.
    var hardware = false

    /// The setting in effect; the app updates it when Settings change. Read once when a job starts.
    static var current: VideoEncoding {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    private static let lock = NSLock()
    private static var stored = VideoEncoding()

    /// Encoder arguments for `container` (MP4, MOV, MKV and the formats saved as one of them). `crf` is the quality
    /// in libx264 terms (lower is better); the other encoders get the matching value. MOV cannot hold AV1, so AV1
    /// for MOV is saved as H.264.
    func arguments(for container: FileFormat, crf: Int = 20) -> [String] {
        let codec = self.codec == .av1 && container == .mov ? Codec.h264 : self.codec
        // Apple's encoders take a quality from 1 to 100; 65 gives about the size of libx264 at CRF 20.
        let quality = String(min(max(65 + (20 - crf) * 2, 1), 100))
        let tag = container == .mkv ? [] : ["-tag:v", "hvc1"]
        switch (codec, hardware) {
        case (.h264, false):
            return ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf), "-pix_fmt", "yuv420p"]
        case (.h264, true):
            return ["-c:v", "h264_videotoolbox", "-q:v", quality, "-pix_fmt", "yuv420p"]
        case (.hevc, false):
            return ["-c:v", "libx265", "-preset", "medium", "-crf", String(crf + 4), "-pix_fmt", "yuv420p"] + tag
        case (.hevc, true):
            return ["-c:v", "hevc_videotoolbox", "-q:v", quality, "-pix_fmt", "yuv420p"] + tag
        case (.av1, _):
            return ["-c:v", "libsvtav1", "-preset", "8", "-crf", String(crf + 12), "-pix_fmt", "yuv420p"]
        }
    }
}
