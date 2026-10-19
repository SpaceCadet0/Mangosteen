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
            case .free: "Свободно"
            case .original: "Как у оригинала"
            case .square: "1:1"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            case .r9x16: "9:16"
            case .r3x4: "3:4"
            case .r2x3: "2:3"
            case .r4x5: "4:5"
            case .exact: "Точный размер…"
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
    @State private var dragStart: CGRect?
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
            ToolFooter(fileCount: images.count, actionTitle: "Обрезать",
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
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            let crop = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                              width: rect.width * frame.width, height: rect.height * frame.height)
            ZStack(alignment: .topLeading) {
                if let displayImage {
                    Image(decorative: displayImage, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)

                    Path { path in
                        path.addRect(frame)
                        path.addRect(crop)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                    thirds(crop)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    Path { $0.addRect(crop) }
                        .stroke(Color.white, lineWidth: 1.5)

                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: crop.width, height: crop.height)
                        .position(x: crop.midX, y: crop.midY)
                        .gesture(moveGesture(frame))

                    ForEach(ImageCropper.Handle.allCases, id: \.self) { handle in
                        let point = handle.point(in: crop)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(radius: 1)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .position(point)
                            .gesture(resizeGesture(handle, frame: frame))
                    }
                } else if let loadError {
                    Text(loadError).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func fittedFrame(in container: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let available = CGSize(width: max(container.width - inset * 2, 1), height: max(container.height - inset * 2, 1))
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func thirds(_ crop: CGRect) -> Path {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                path.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                path.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                path.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
            }
        }
    }

    private func moveGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                var moved = start
                moved.origin.x = min(max(start.minX + value.translation.width / frame.width, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + value.translation.height / frame.height, 0), 1 - start.height)
                rect = moved
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: ImageCropper.Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                if let resized = ImageCropper.resize(start, handle: handle,
                                                     dx: value.translation.width / frame.width,
                                                     dy: value.translation.height / frame.height,
                                                     aspect: normalizedAspect) {
                    rect = resized
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Пропорции", selection: $aspectChoice) {
                ForEach(AspectChoice.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 260)

            if aspectChoice == .exact {
                TextField("Ширина", value: $exactWidth, format: .number.grouping(.never))
                    .frame(width: 70)
                Text("×")
                TextField("Высота", value: $exactHeight, format: .number.grouping(.never))
                    .frame(width: 70)
                Text("px").foregroundStyle(.secondary)
            }

            Spacer()

            let pixels = ImageCropper.pixelRect(rect, imageSize: imageSize)
            Text("\(Int(pixels.width)) × \(Int(pixels.height)) px")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Сбросить") {
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
            loadError = "Нет изображений"
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
        ConversionService.shared.runEach("Обрезка", inputs: images) { url in
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
