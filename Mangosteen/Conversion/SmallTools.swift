import AVFoundation
import CoreGraphics
import Foundation

enum SmallToolError: LocalizedError {
    case noBlackBars(URL)
    case notHDR(URL)
    case noLiveVideo(URL)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBlackBars(let url): String(localized: "В «\(url.lastPathComponent)» нет чёрных полос.")
        case .notHDR(let url): String(localized: "«\(url.lastPathComponent)» снято не в HDR — переводить нечего.")
        case .noLiveVideo(let url): String(localized: "Рядом с «\(url.lastPathComponent)» нет видео Live Photo (файла .mov с тем же именем).")
        case .exportFailed(let reason): String(localized: "Не удалось сохранить видео: \(reason)")
        }
    }
}

// MARK: - PDF: several pages on a sheet

enum PDFLayout {
    /// Columns × rows for each choice; 2 and 6 turn the sheet to landscape so the pages stay upright and large.
    static func grid(perSheet: Int) -> (columns: Int, rows: Int, landscape: Bool) {
        switch perSheet {
        case 2: (2, 1, true)
        case 4: (2, 2, false)
        case 6: (3, 2, true)
        case 9: (3, 3, false)
        default: (1, 1, false)
        }
    }

    /// Writes "<name> (N на листе).pdf": pages drawn as PDF (text stays text, lines stay sharp), in reading order,
    /// on sheets the size of the first page.
    static func pagesPerSheet(_ input: URL, perSheet: Int) throws -> URL {
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else {
            throw PDFToolError.unreadable(input)
        }
        guard !document.isEncrypted || document.isUnlocked else { throw PDFToolError.locked(input) }
        let (columns, rows, landscape) = grid(perSheet: perSheet)
        let first = document.page(at: 1)!
        var pageSize = first.getBoxRect(.mediaBox).size
        if first.rotationAngle % 180 != 0 { pageSize = CGSize(width: pageSize.height, height: pageSize.width) }
        let portrait = CGSize(width: min(pageSize.width, pageSize.height), height: max(pageSize.width, pageSize.height))
        var sheet = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        if pageSize.width > pageSize.height { sheet = CGSize(width: sheet.height, height: sheet.width) }
        let margin = min(sheet.width, sheet.height) * 0.03
        let gap = margin / 2
        let cell = CGSize(width: (sheet.width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns),
                          height: (sheet.height - 2 * margin - CGFloat(rows - 1) * gap) / CGFloat(rows))
        let perSheet = columns * rows

        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (\(perSheet) на листе)"),
            pathExtension: "pdf"
        ) { output in
            var box = CGRect(origin: .zero, size: sheet)
            guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw PDFToolError.writeFailed }
            for start in stride(from: 1, through: document.numberOfPages, by: perSheet) {
                context.beginPDFPage(nil)
                for slot in 0..<perSheet {
                    guard let page = document.page(at: start + slot) else { break }
                    let column = slot % columns, row = slot / columns
                    // PDF's y runs up; the first row is at the top.
                    let rect = CGRect(x: margin + CGFloat(column) * (cell.width + gap),
                                      y: sheet.height - margin - CGFloat(row + 1) * cell.height - CGFloat(row) * gap,
                                      width: cell.width, height: cell.height)
                    context.saveGState()
                    context.clip(to: rect)
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                    context.restoreGState()
                }
                context.endPDFPage()
            }
            context.closePDF()
        }
    }
}

// MARK: - Video

enum VideoFixes {
    /// The picture area without the black bars, in upright frame pixels, or nil when there are none. Three moments
    /// of the video are checked so a dark opening scene does not eat into the picture.
    static func blackBarsCrop(_ input: URL) throws -> CGRect? {
        let info = try MediaConverter.probe(input)
        let frame = try MediaTools.frame(input, at: 0)
        let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let duration = info.duration ?? 0
        var found: [CGRect] = []
        for fraction in [0.2, 0.5, 0.8] {
            let start = duration > 4 ? duration * fraction : 0
            let output = try ExternalTool.run("ffmpeg", ["-hide_banner", "-nostdin", "-ss", String(format: "%.2f", start),
                                                         "-i", input.path, "-t", "2", "-vf", "cropdetect=limit=24:round=2:reset=0",
                                                         "-an", "-f", "null", "-"])
            if let rect = lastCrop(in: output) { found.append(rect) }
        }
        guard var union = found.first else { return nil }
        for rect in found.dropFirst() { union = union.union(rect) }
        union = union.intersection(full)
        // Bars thinner than 1% of the frame are noise or a few dark pixels at the edge.
        let trimmed = full.width - union.width + full.height - union.height
        guard trimmed >= min(full.width, full.height) * 0.02, union.width >= 16, union.height >= 16 else { return nil }
        return union
    }

    /// The last "crop=w:h:x:y" cropdetect printed.
    static func lastCrop(in output: String) -> CGRect? {
        guard let match = output.matches(of: /crop=(\d+):(\d+):(\d+):(\d+)/).last,
              let width = Double(match.1), let height = Double(match.2), let x = Double(match.3), let y = Double(match.4),
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Writes "<name> (без полос).<ext>".
    static func removeBlackBars(_ input: URL, progress: ((Double) -> Void)? = nil,
                                cancellation: CancellationToken? = nil) throws -> URL {
        guard let source = FileFormat.detect(input), source.category == .video else { throw MediaError.noVideo(input) }
        guard let crop = try blackBarsCrop(input) else { throw SmallToolError.noBlackBars(input) }
        let info = try MediaConverter.probe(input)
        let width = Int(crop.width) / 2 * 2, height = Int(crop.height) / 2 * 2
        let format = MediaTools.outputFormat(for: source)
        let arguments = MediaConverter.encodeArguments(for: format, info: info,
                                                       videoFilters: ["crop=\(width):\(height):\(Int(crop.minX)):\(Int(crop.minY))"])
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (без полос)"),
            pathExtension: format.fileExtension
        ) { output in
            try MediaConverter.run(input: input, output: output, codecArguments: arguments, duration: info.duration,
                                   progress: progress, cancellation: cancellation)
        }
    }

    /// Writes "<name> (SDR).mp4": HDR video (HDR10, HLG, Dolby Vision) brought to ordinary brightness and colour
    /// by the system's own tone mapping, the way Photos exports it for sharing.
    static func hdrToSDR(_ input: URL, progress: ((Double) -> Void)? = nil,
                         cancellation: CancellationToken? = nil) throws -> URL {
        let asset = AVURLAsset(url: input)
        let isHDR = try wait { try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo).isEmpty == false }
        guard isHDR else { throw SmallToolError.notHDR(input) }
        let composition = try wait { try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (SDR)", pathExtension: "mp4"
        ) { output in
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw SmallToolError.exportFailed("AVAssetExportSession")
            }
            session.videoComposition = composition
            session.outputURL = output
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            try export(session, progress: progress, cancellation: cancellation)
        }
    }

    /// Writes "<name> (Live).mp4" from the video half of a Live Photo: the .mov of the same name next to the picture.
    static func livePhotoVideo(_ input: URL, progress: ((Double) -> Void)? = nil,
                               cancellation: CancellationToken? = nil) throws -> URL {
        guard let movie = livePhotoMovie(for: input) else { throw SmallToolError.noLiveVideo(input) }
        let info = try MediaConverter.probe(movie)
        let arguments = MediaConverter.encodeArguments(for: .mp4, info: info, videoFilters: [])
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (Live)", pathExtension: "mp4"
        ) { output in
            try MediaConverter.run(input: movie, output: output, codecArguments: arguments, duration: info.duration,
                                   progress: progress, cancellation: cancellation)
        }
    }

    /// The .mov saved beside a Live Photo's picture (IMG_0001.HEIC + IMG_0001.MOV), whatever the letter case.
    static func livePhotoMovie(for picture: URL) -> URL? {
        let folder = picture.deletingLastPathComponent()
        let name = picture.deletingPathExtension().lastPathComponent
        for ext in ["mov", "MOV", "Mov"] {
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func export(_ session: AVAssetExportSession, progress: ((Double) -> Void)?,
                               cancellation: CancellationToken?) throws {
        cancellation?.onCancel { session.cancelExport() }
        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            progress?(Double(session.progress))
        }
        try cancellation?.throwIfCancelled()
        guard session.status == .completed else {
            throw SmallToolError.exportFailed(session.error?.localizedDescription ?? "\(session.status.rawValue)")
        }
    }

    /// Runs async work from a job's background thread.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
