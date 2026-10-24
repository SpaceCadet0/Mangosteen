import SwiftUI

/// Compress tool: preset, quality or target size, optional resize and format, with a live estimate
/// computed on the first image.
struct CompressView: View {
    let urls: [URL]
    let close: () -> Void

    private enum SizeUnit: String, CaseIterable, Identifiable {
        case kb, mb
        var id: String { rawValue }
        var title: String { self == .kb ? String(localized: "КБ") : String(localized: "МБ") }
        var bytes: Double { self == .kb ? 1_000 : 1_000_000 }
    }

    @State private var settings: CompressionSettings = {
        var settings = CompressionSettings()
        settings.preserveMetadata = AppSettings.shared.preserveMetadata
        return settings
    }()
    @State private var targetValue = 1.0
    @State private var targetUnit = SizeUnit.mb
    @State private var preview: NSImage?
    @State private var estimate = ""
    @State private var isEstimating = false

    private static let sizeLimits = [4096, 3840, 2560, 1920, 1600, 1280, 1024, 800]
    /// Picker tag for «Своё…»; the number itself goes in a field below.
    private static let customSide = -1
    @State private var customLongSide = false

    private var longSideChoice: Binding<Int?> {
        Binding(get: { customLongSide ? Self.customSide : settings.maxPixelSize }, set: { choice in
            customLongSide = choice == Self.customSide
            settings.maxPixelSize = customLongSide ? (settings.maxPixelSize ?? 1600) : choice
        })
    }

    private var customSideValue: Binding<Int> {
        Binding(get: { settings.maxPixelSize ?? 1600 },
                set: { settings.maxPixelSize = min(max($0, 16), ImageCropper.Resize.maxSide) })
    }

    private var images: [URL] { urls.filter { FileFormat.detect($0)?.category == .image } }
    private var pdfs: [URL] { urls.filter { FileFormat.detect($0) == .pdf } }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                if let first = images.first {
                    previewPane(first)
                }
                controls
            }
            ToolFooter(fileCount: images.count + pdfs.count, actionTitle: String(localized: "Сжать"),
                       actionDisabled: images.isEmpty && pdfs.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .task(id: settings) { await updateEstimate() }
        .onChange(of: targetValue) { _ in updateTargetBytes() }
        .onChange(of: targetUnit) { _ in updateTargetBytes() }
    }

    private func previewPane(_ first: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
                if isEstimating {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 340, height: 260)
            Text(first.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(estimate)
                .font(.callout.monospacedDigit())
        }
        .frame(width: 340)
    }

    private var controls: some View {
        Form {
            Picker(String(localized: "Способ"), selection: $settings.mode) {
                ForEach(CompressionSettings.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch settings.mode {
            case .preset:
                Picker(String(localized: "Пресет"), selection: $settings.preset) {
                    ForEach(CompressionSettings.Preset.allCases) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
            case .quality:
                LabeledContent(String(localized: "Качество")) {
                    HStack {
                        Slider(value: $settings.quality, in: 0.05...1)
                        Text("\(Int((settings.quality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            case .targetSize:
                LabeledContent(String(localized: "Не больше")) {
                    HStack {
                        TextField("", value: $targetValue, format: .number)
                            .frame(width: 80)
                        Picker("", selection: $targetUnit) {
                            ForEach(SizeUnit.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                }
            }

            Picker(String(localized: "Длинная сторона"), selection: longSideChoice) {
                Text(String(localized: "Без изменений")).tag(Int?.none)
                ForEach(Self.sizeLimits, id: \.self) { Text("\($0) px").tag(Optional($0)) }
                Text(String(localized: "Своё…")).tag(Optional(Self.customSide))
            }
            .disabled(settings.mode == .preset && settings.preset.maxPixelSize != nil)
            if customLongSide {
                LabeledContent(String(localized: "Своя длинная сторона")) {
                    HStack {
                        TextField("", value: customSideValue, format: .number.grouping(.never))
                            .frame(width: 80)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                .disabled(settings.mode == .preset && settings.preset.maxPixelSize != nil)
            }

            Picker(String(localized: "Формат"), selection: $settings.format) {
                Text(String(localized: "Как у оригинала")).tag(FileFormat?.none)
                ForEach(CompressionSettings.selectableFormats) { Text($0.displayName).tag(Optional($0)) }
            }
            Toggle(String(localized: "Сохранять метаданные"), isOn: $settings.preserveMetadata)

            if !pdfs.isEmpty {
                Text(String(localized: "В PDF изображения будут пережаты в JPEG экранного разрешения."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if images.contains(where: { FileFormat.detect($0)?.isLossy == false }) && settings.format == nil {
                Text(String(localized: "PNG, TIFF и другие форматы без потерь будут сохранены как \(ImageCompression.defaultLossyFormat.displayName)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }

    private func updateTargetBytes() {
        settings.targetBytes = Int64(max(targetValue, 0.001) * targetUnit.bytes)
    }

    private func updateEstimate() async {
        guard let first = images.first else { return }
        // Debounce slider drags.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        isEstimating = true
        let settings = settings
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ImageCompression.compress(first, settings: settings) }
        }.value
        guard !Task.isCancelled else { return }
        isEstimating = false
        switch result {
        case .success(let (data, format)):
            preview = NSImage(data: data)
            let original = ImageCompression.fileSize(first)
            let formatter = ByteCountFormatter()
            let change = original > 0 ? Int((Double(data.count) / Double(original) - 1) * 100) : 0
            let sign = change > 0 ? "+" : "−"
            estimate = "\(formatter.string(fromByteCount: original)) → \(formatter.string(fromByteCount: Int64(data.count))) "
                + "\(format.displayName) (\(sign)\(abs(change))%)"
        case .failure(let error):
            estimate = error.localizedDescription
        }
    }

    private func run() {
        let settings = settings
        ConversionService.shared.runEach(String(localized: "Сжатие"), inputs: images + pdfs) {
            try ImageCompression.compressFile($0, settings: settings)
        }
        close()
    }
}
