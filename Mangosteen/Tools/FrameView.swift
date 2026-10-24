import SwiftUI
import UniformTypeIdentifiers

/// Background tool: put a photo on a colour, gradient, image or blurred canvas with margin, corners and shadow.
struct FrameView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var settings = FrameSettings()
    @State private var photo: CGImage?
    @State private var backdrop: CGImage?
    @State private var rendered: NSImage?

    private var images: [URL] { urls.filter { FileFormat.detect($0)?.category == .image } }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    if let rendered {
                        Image(nsImage: rendered).resizable().scaledToFit().padding(10)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 460, idealWidth: 560, minHeight: 380, idealHeight: 480)
                controls
            }
            ToolFooter(fileCount: images.count, actionTitle: String(localized: "Сохранить"), actionDisabled: photo == nil,
                       cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
        .task(id: settings) { await renderPreview() }
    }

    private func color(_ keyPath: WritableKeyPath<FrameSettings, RGBAColor>) -> Binding<CGColor> {
        Binding(get: { settings[keyPath: keyPath].cgColor }, set: { settings[keyPath: keyPath] = RGBAColor($0) })
    }

    private var controls: some View {
        Form {
            Picker(String(localized: "Фон"), selection: $settings.background) {
                ForEach(FrameSettings.Background.allCases) { Text($0.title).tag($0) }
            }
            switch settings.background {
            case .color:
                ColorPicker(String(localized: "Цвет"), selection: color(\.color), supportsOpacity: false)
            case .gradient:
                ColorPicker(String(localized: "Начало"), selection: color(\.gradientStart), supportsOpacity: false)
                ColorPicker(String(localized: "Конец"), selection: color(\.gradientEnd), supportsOpacity: false)
                labeledSlider(String(localized: "Угол"), value: $settings.gradientAngle, range: 0...360, format: "%.0f°")
            case .image:
                LabeledContent(String(localized: "Изображение")) {
                    Button(settings.backgroundImage?.lastPathComponent ?? String(localized: "Выбрать…"), action: chooseBackground)
                }
                labeledSlider(String(localized: "Размытие"), value: $settings.blur, range: 0...1)
            case .blur:
                labeledSlider(String(localized: "Размытие"), value: $settings.blur, range: 0...1)
            }

            Picker(String(localized: "Пропорции"), selection: $settings.aspect) {
                ForEach(CanvasAspect.allCases) { aspect in
                    Text(aspect == .auto ? String(localized: "Как у фото") : aspect.title).tag(aspect)
                }
            }
            labeledSlider(String(localized: "Отступ"), value: $settings.padding, range: 0...0.4)
            // Half the shorter side rounds the photo fully: a square becomes a circle. The label reads 100% there.
            labeledSlider(String(localized: "Скругление"), value: $settings.cornerRadius, range: 0...0.5, shownMaximum: 0.5)
            labeledSlider(String(localized: "Тень"), value: $settings.shadow, range: 0...1)
        }
        .toolForm()
        .frame(width: 340)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               format: String? = nil, shownMaximum: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(format.map { String(format: $0, value.wrappedValue) }
                     ?? "\(Int((value.wrappedValue / shownMaximum * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backdrop = try? ImageConverter.load(url, maxPixelSize: 1600).image
        settings.backgroundImage = url
    }

    private func load() async {
        guard let first = images.first else { return }
        photo = await Task.detached(priority: .userInitiated) {
            try? ImageConverter.load(first, maxPixelSize: 1200).image
        }.value
        await renderPreview()
    }

    private func renderPreview() async {
        guard let photo else { return }
        let settings = settings
        let backdrop = backdrop
        let image = await Task.detached(priority: .userInitiated) {
            try? FrameComposer.compose(photo, settings: settings, backgroundImage: backdrop)
        }.value
        guard !Task.isCancelled, let image else { return }
        rendered = NSImage(cgImage: image, size: .zero)
    }

    private func run() {
        let settings = settings
        let options = AppSettings.shared.conversionOptions
        ConversionService.shared.runEach(String(localized: "Фон"), inputs: images) {
            try FrameComposer.composeFile($0, settings: settings, options: options)
        }
        close()
    }
}
