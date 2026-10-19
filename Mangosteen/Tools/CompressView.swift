import SwiftUI

/// Compress tool: preset, quality or target size, optional resize and format, with a live estimate
/// computed on the first image.
struct CompressView: View {
    let urls: [URL]
    let close: () -> Void

    private enum SizeUnit: String, CaseIterable, Identifiable {
        case kb = "КБ", mb = "МБ"
        var id: String { rawValue }
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
            ToolFooter(fileCount: images.count + pdfs.count, actionTitle: "Сжать",
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
            Picker("Способ", selection: $settings.mode) {
                ForEach(CompressionSettings.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch settings.mode {
            case .preset:
                Picker("Пресет", selection: $settings.preset) {
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
                LabeledContent("Качество") {
                    HStack {
                        Slider(value: $settings.quality, in: 0.05...1)
                        Text("\(Int((settings.quality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            case .targetSize:
                LabeledContent("Не больше") {
                    HStack {
                        TextField("", value: $targetValue, format: .number)
                            .frame(width: 80)
                        Picker("", selection: $targetUnit) {
                            ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                }
            }

            Picker("Длинная сторона", selection: $settings.maxPixelSize) {
                Text("Без изменений").tag(Int?.none)
                ForEach(Self.sizeLimits, id: \.self) { Text("\($0) px").tag(Optional($0)) }
            }
            .disabled(settings.mode == .preset && settings.preset.maxPixelSize != nil)

            Picker("Формат", selection: $settings.format) {
                Text("Как у оригинала").tag(FileFormat?.none)
                ForEach(CompressionSettings.selectableFormats) { Text($0.displayName).tag(Optional($0)) }
            }
            Toggle("Сохранять метаданные", isOn: $settings.preserveMetadata)

            if !pdfs.isEmpty {
                Text("В PDF изображения будут пережаты в JPEG экранного разрешения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if images.contains(where: { FileFormat.detect($0)?.isLossy == false }) && settings.format == nil {
                Text("PNG, TIFF и другие форматы без потерь будут сохранены как \(ImageCompression.defaultLossyFormat.displayName).")
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
        ConversionService.shared.runEach("Сжатие", inputs: images + pdfs) {
            try ImageCompression.compressFile($0, settings: settings)
        }
        close()
    }
}
