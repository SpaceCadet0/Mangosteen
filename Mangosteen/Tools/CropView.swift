import SwiftUI

/// Crop tool: drag the frame or its handles, pick an aspect ratio, or enter exact output pixels.
/// With several images, the frame drawn on the first one is used as is; the others get a centred
/// crop of the same aspect ratio.
struct CropView: View {
    let urls: [URL]
    let close: () -> Void

    enum AspectChoice: String, CaseIterable, Identifiable {
        case free, original, square, r4x3, r3x2, r16x9, r9x16, r3x4, r2x3, r4x5, exact
        var id: String { rawValue }

        var title: String {
            switch self {
            case .free: String(localized: "Свободно")
            case .original: String(localized: "Как у оригинала")
            case .square: "1:1"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            case .r9x16: "9:16"
            case .r3x4: "3:4"
            case .r2x3: "2:3"
            case .r4x5: "4:5"
            case .exact: String(localized: "Точный размер…")
            }
        }

        var fixedRatio: CGFloat? {
            switch self {
            case .square: 1
            case .r4x3: 4.0 / 3
            case .r3x2: 3.0 / 2
            case .r16x9: 16.0 / 9
            case .r9x16: 9.0 / 16
            case .r3x4: 3.0 / 4
            case .r2x3: 2.0 / 3
            case .r4x5: 4.0 / 5
            default: nil
            }
        }
    }

    @State private var displayImage: CGImage?
    @State private var imageSize = CGSize(width: 1, height: 1)
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspectChoice = AspectChoice.free
    @State private var exactWidth = 1080
    @State private var exactHeight = 1080
    @State private var loadError: String?

    private var images: [URL] { urls.filter { FileFormat.detect($0)?.category == .image } }

    /// Locked aspect (width / height in pixels) for an image of `size`.
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
        VStack(spacing: 14) {
            canvas
                .frame(minWidth: 620, minHeight: 420)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            controls
            ToolFooter(fileCount: images.count, actionTitle: String(localized: "Обрезать"),
                       actionDisabled: displayImage == nil, cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .onChange(of: aspectChoice) { _ in applyAspect() }
        .onChange(of: exactWidth) { _ in applyAspect() }
        .onChange(of: exactHeight) { _ in applyAspect() }
    }

    // MARK: Canvas

    private var canvas: some View {
        CropCanvas(image: displayImage, imageSize: imageSize, rect: $rect, aspect: normalizedAspect, message: loadError)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "Пропорции"), selection: $aspectChoice) {
                ForEach(AspectChoice.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 260)

            if aspectChoice == .exact {
                TextField(String(localized: "Ширина"), value: $exactWidth, format: .number.grouping(.never))
                    .frame(width: 70)
                Text("×")
                TextField(String(localized: "Высота"), value: $exactHeight, format: .number.grouping(.never))
                    .frame(width: 70)
                Text("px").foregroundStyle(.secondary)
            }

            Spacer()

            let pixels = ImageCropper.pixelRect(rect, imageSize: imageSize)
            Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height)) px")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(String(localized: "Сбросить")) {
                aspectChoice = .free
                rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
    }

    private func applyAspect() {
        guard let aspect = pixelAspect(for: imageSize) else { return }
        rect = ImageCropper.centeredRect(aspect: aspect, imageSize: imageSize)
    }

    // MARK: Work

    private func load() async {
        guard let first = images.first else {
            loadError = String(localized: "Нет изображений")
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { (try ImageConverter.load(first, maxPixelSize: 1800).image, try ImageCropper.uprightSize(first)) }
        }.value
        switch result {
        case .success(let (image, size)):
            imageSize = size
            displayImage = image
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func run() {
        guard let first = images.first else { return }
        let firstRect = rect
        let choice = aspectChoice
        let exact = CGSize(width: exactWidth, height: exactHeight)
        let outputSize: CGSize? = choice == .exact ? exact : nil
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach(String(localized: "Обрезка"), inputs: images) { url in
            var cropRect = firstRect
            if url != first, choice != .free {
                let size = try ImageCropper.uprightSize(url)
                let aspect: CGFloat = switch choice {
                case .original: size.width / size.height
                case .exact: exact.width / max(exact.height, 1)
                default: choice.fixedRatio ?? size.width / size.height
                }
                cropRect = ImageCropper.centeredRect(aspect: aspect, imageSize: size)
            }
            return try ImageCropper.cropFile(url, rect: cropRect, outputSize: outputSize, options: options)
        }
        close()
    }
}
