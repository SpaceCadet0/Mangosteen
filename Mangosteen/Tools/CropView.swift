import SwiftUI

/// Crop tool: drag the frame or its handles, pick an aspect ratio, or enter exact output pixels; turn and
/// mirror the picture, and cut the result into a grid of parts.
/// With several images, the frame drawn on the first one is used as is; the others get a centred
/// crop of the same aspect ratio.
/// The Size tab scales whole pictures instead: by pixels, percent or the long side, one rule for every file.
struct CropView: View {
    let urls: [URL]
    let close: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case crop, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .crop: String(localized: "Обрезка")
            case .size: String(localized: "Размер")
            }
        }
    }

    static let longSides = [3840, 2560, 1920, 1280, 1080, 800]
    static let percents = [25, 50, 75]

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

    @State private var sourceImage: CGImage?
    @State private var sourceSize = CGSize(width: 1, height: 1)
    @State private var displayImage: CGImage?
    @State private var imageSize = CGSize(width: 1, height: 1)
    @State private var transform = ImageCropper.Transform()
    @State private var columns = 1
    @State private var rows = 1
    @State private var columnCuts: [CGFloat] = []
    @State private var rowCuts: [CGFloat] = []
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspectChoice = AspectChoice.free
    @State private var exactWidth = 1080
    @State private var exactHeight = 1080
    @State private var loadError: String?
    /// The window opens on the tab used last time.
    @AppStorage("cropToolMode") private var mode = Mode.crop
    @State private var resize = ImageCropper.Resize.percent(100)
    @State private var keepAspect = true

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
            Picker(String(localized: "Режим"), selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Group {
                if mode == .crop { canvas } else { sizePreview }
            }
            .frame(minWidth: 620, minHeight: 420)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            controls
            ToolFooter(fileCount: images.count, actionTitle: actionTitle,
                       actionDisabled: displayImage == nil, cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .onChange(of: aspectChoice) { _ in applyAspect() }
        .onChange(of: exactWidth) { _ in applyAspect() }
        .onChange(of: exactHeight) { _ in applyAspect() }
        .onChange(of: transform) { _ in updateDisplay() }
        .onChange(of: columns) { columnCuts = ImageCropper.evenCuts($0) }
        .onChange(of: rows) { rowCuts = ImageCropper.evenCuts($0) }
    }

    // MARK: Canvas

    private var canvas: some View {
        CropCanvas(image: displayImage, imageSize: imageSize, rect: $rect, aspect: normalizedAspect, message: loadError,
                   columnCuts: $columnCuts, rowCuts: $rowCuts)
    }

    // MARK: Controls

    private var actionTitle: String {
        if mode == .size { return String(localized: "Изменить размер") }
        return !columnCuts.isEmpty || !rowCuts.isEmpty ? String(localized: "Разрезать") : String(localized: "Сохранить")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if mode == .crop { cropControls } else { sizeControls }
            HStack(spacing: 6) {
                iconButton("rotate.left", String(localized: "Повернуть влево")) { transform.rotate(clockwise: false) }
                iconButton("rotate.right", String(localized: "Повернуть вправо")) { transform.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                           String(localized: "Отразить по горизонтали")) { transform.flipHorizontal.toggle() }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                           String(localized: "Отразить по вертикали")) { transform.flipVertical.toggle() }
                Spacer()
                if mode == .crop {
                    Text(String(localized: "Разрезать на части:"))
                    Stepper(value: $columns, in: 1...10) {
                        Text(String(localized: "\(columns) по ширине")).monospacedDigit()
                    }
                    Stepper(value: $rows, in: 1...10) {
                        Text(String(localized: "\(rows) по высоте")).monospacedDigit()
                    }
                } else {
                    ForEach(Self.percents, id: \.self) { percent in
                        Button { resize = .percent(Double(percent)) } label: { Text(verbatim: "\(percent)%") }
                    }
                    Menu(String(localized: "Длинная сторона")) {
                        ForEach(Self.longSides, id: \.self) { side in
                            Button { resize = .longSide(side) } label: { Text(verbatim: "\(side) px") }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Size

    private var resultSize: CGSize { resize.size(for: imageSize) }

    private var sizePreview: some View {
        ZStack(alignment: .bottomTrailing) {
            if let displayImage {
                Image(decorative: displayImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(loadError ?? "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if displayImage != nil {
                Text(verbatim: "\(Int(imageSize.width)) × \(Int(imageSize.height)) → \(Int(resultSize.width)) × \(Int(resultSize.height)) px")
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
        }
    }

    private var widthField: Binding<Int> {
        Binding(get: { Int(resultSize.width) }, set: { value in
            // The field commits what it shows on focus changes; only a real edit changes the rule.
            guard displayImage != nil, value != Int(resultSize.width) else { return }
            let width = min(max(value, 1), ImageCropper.Resize.maxSide)
            resize = keepAspect ? .width(width) : .exact(width: width, height: Int(resultSize.height))
        })
    }

    private var heightField: Binding<Int> {
        Binding(get: { Int(resultSize.height) }, set: { value in
            guard displayImage != nil, value != Int(resultSize.height) else { return }
            let height = min(max(value, 1), ImageCropper.Resize.maxSide)
            resize = keepAspect ? .height(height) : .exact(width: Int(resultSize.width), height: height)
        })
    }

    /// What happens to every file when there are several; the fields show the first one.
    private var batchNote: String {
        switch resize {
        case .percent(let percent): String(localized: "Все файлы: \(Int(percent))% от размера")
        case .longSide(let side): String(localized: "Все файлы: длинная сторона \(side) px")
        case .width(let width): String(localized: "Все файлы: ширина \(width) px, высота по пропорциям")
        case .height(let height): String(localized: "Все файлы: высота \(height) px, ширина по пропорциям")
        case .exact(let width, let height): String(localized: "Все файлы: \(width) × \(height) px")
        }
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            sizeFields
            if images.count > 1 {
                Text(batchNote).foregroundStyle(.secondary)
            }
        }
    }

    private var sizeFields: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Ширина"))
            TextField(String(localized: "Ширина"), value: widthField, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 70)
            iconButton(keepAspect ? "lock" : "lock.open", String(localized: "Сохранять пропорции")) {
                keepAspect.toggle()
                if keepAspect { resize = .width(Int(resultSize.width)) }
            }
            Text(String(localized: "Высота"))
            TextField(String(localized: "Высота"), value: heightField, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 70)
            Text("px").foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Сбросить")) {
                resize = .percent(100)
                keepAspect = true
                transform = ImageCropper.Transform()
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var cropControls: some View {
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
                transform = ImageCropper.Transform()
                columns = 1
                rows = 1
                rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
    }

    /// Shows the preview turned and mirrored; the frame starts over on the new picture.
    private func updateDisplay() {
        guard let sourceImage else { return }
        displayImage = (try? ImageCropper.apply(transform, to: sourceImage)) ?? sourceImage
        imageSize = transform.size(for: sourceSize)
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        applyAspect()
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
            sourceImage = image
            sourceSize = size
            updateDisplay()
            if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil {
                columns = 3
                rows = 2
                DispatchQueue.main.async { columnCuts[0] = 0.22 }
            }
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func run() {
        guard let first = images.first else { return }
        if mode == .size {
            let resize = resize, transform = transform
            let options = AppSettings.shared.conversionOptions
            ConversionService.shared.runEach(String(localized: "Изменение размера"), inputs: images) {
                try ImageCropper.resizeFile($0, to: resize, transform: transform, options: options)
            }
            close()
            return
        }
        let firstRect = rect
        let choice = aspectChoice
        let exact = CGSize(width: exactWidth, height: exactHeight)
        let outputSize: CGSize? = choice == .exact ? exact : nil
        let options = AppSettings.shared.conversionOptions
        let transform = transform
        let columnCuts = columnCuts, rowCuts = rowCuts
        ConversionService.shared.runEach(String(localized: "Обрезка"), inputs: images) { url in
            var cropRect = firstRect
            if url != first, choice != .free {
                let size = transform.size(for: try ImageCropper.uprightSize(url))
                let aspect: CGFloat = switch choice {
                case .original: size.width / size.height
                case .exact: exact.width / max(exact.height, 1)
                default: choice.fixedRatio ?? size.width / size.height
                }
                cropRect = ImageCropper.centeredRect(aspect: aspect, imageSize: size)
            }
            return try ImageCropper.cropFile(url, rect: cropRect, outputSize: outputSize, transform: transform,
                                             columnCuts: columnCuts, rowCuts: rowCuts, options: options)
        }
        close()
    }
}
