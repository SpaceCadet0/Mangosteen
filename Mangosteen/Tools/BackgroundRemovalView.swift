import SwiftUI

/// Remove background tool: Vision finds the main subject; the background becomes transparent or a colour.
struct BackgroundRemovalView: View {
    let urls: [URL]
    let close: () -> Void

    private enum Fill: String, CaseIterable, Identifiable {
        case transparent, color
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transparent: String(localized: "Прозрачный")
            case .color: String(localized: "Цвет")
            }
        }
    }

    @State private var source: CGImage?
    @State private var cutout: CGImage?
    @State private var preview: NSImage?
    @State private var fill = Fill.transparent
    @State private var color = RGBAColor(red: 1, green: 1, blue: 1)
    @State private var cropToSubject = false
    @State private var message: String?

    private var images: [URL] {
        urls.filter { FileFormat.detect($0).map { $0.category == .image && $0 != .svg } ?? false }
    }

    private var options: BackgroundRemover.Options {
        BackgroundRemover.Options(fill: fill == .color ? color : nil, cropToSubject: cropToSubject)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .background(fill == .transparent ? AnyView(Checkerboard()) : AnyView(Color.clear))
                        .padding(12)
                } else if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView(String(localized: "Ищем объект…"))
                }
            }
            .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 480)

            HStack(spacing: 14) {
                Picker(String(localized: "Фон"), selection: $fill) {
                    ForEach(Fill.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                if fill == .color {
                    ColorPicker(String(localized: "Цвет"), selection: Binding(get: { color.cgColor }, set: { color = RGBAColor($0) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
                Toggle(String(localized: "Обрезать по объекту"), isOn: $cropToSubject)
                Spacer()
            }
            ToolFooter(fileCount: images.count, actionTitle: String(localized: "Убрать фон"),
                       actionDisabled: cutout == nil, cancel: close, action: run)
        }
        .padding(20)
        .task(id: cropToSubject) { await makeCutout() }
        .onChange(of: options) { _ in updatePreview() }
    }

    private func makeCutout() async {
        guard let first = images.first else {
            message = String(localized: "Нет изображений")
            return
        }
        cutout = nil
        preview = nil
        let crop = cropToSubject
        let loaded = source
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(CGImage, CGImage), Error> in
            Result {
                let image = try loaded ?? ImageConverter.load(first, maxPixelSize: 1400).image
                return (image, try BackgroundRemover.cutout(image, cropToSubject: crop))
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (image, subject)):
            source = image
            cutout = subject
            message = nil
            updatePreview()
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func updatePreview() {
        guard let cutout, let composed = try? BackgroundRemover.compose(cutout, fill: options.fill) else { return }
        preview = NSImage(cgImage: composed, size: .zero)
    }

    private func run() {
        let options = options
        let conversion = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach(String(localized: "Удаление фона"), inputs: images) {
            try BackgroundRemover.removeFile($0, options: options, conversion: conversion)
        }
        close()
    }
}

/// The grey-and-white squares that show transparency.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 10
            for row in 0..<Int(ceil(size.height / side)) {
                for column in 0..<Int(ceil(size.width / side)) {
                    let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? Color(white: 0.85) : Color(white: 0.7)))
                }
            }
        }
    }
}
