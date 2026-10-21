import Foundation

/// One segment of a wheel.
struct WheelItem {
    let id: String
    let title: String
    let symbolName: String
    let perform: ([URL]) -> Void
}

/// Builds the segments shown for a wheel and a set of dragged files.
enum WheelItemProvider {
    static func items(for kind: WheelKind, urls: [URL]) -> [WheelItem] {
        switch kind {
        case .convert: conversionItems(for: urls)
        case .tools: toolItems(for: urls)
        case .actions: actionItems
        }
    }

    private static func conversionItems(for urls: [URL]) -> [WheelItem] {
        FormatCatalog.targets(for: urls).map { format in
            WheelItem(id: "convert.\(format.rawValue)", title: format.displayName, symbolName: format.symbolName) { urls in
                ConversionService.shared.convert(urls, to: format)
            }
        }
    }

    private static func toolItems(for urls: [URL]) -> [WheelItem] {
        let formats = urls.compactMap(FileFormat.detect)
        var items: [WheelItem] = []
        if formats.contains(where: { $0.category.isMedia }) {
            items.append(WheelItem(id: "tool.trimMedia", title: String(localized: "Обрезать"), symbolName: "timeline.selection") { urls in
                ToolWindow.present(title: String(localized: "Обрезка"), files: urls) { TrimMediaView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.splitMedia", title: String(localized: "Разделить"), symbolName: "scissors") { urls in
                ToolWindow.present(title: String(localized: "Разделение"), files: urls) { SplitMediaView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }) {
            items.append(WheelItem(id: "tool.speed", title: String(localized: "Скорость"), symbolName: "gauge.with.dots.needle.67percent") { urls in
                ToolWindow.present(title: String(localized: "Скорость"), files: urls) { SpeedView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }) {
            items.append(WheelItem(id: "tool.normalize", title: String(localized: "Громкость"), symbolName: "speaker.wave.3") { urls in
                ToolWindow.present(title: String(localized: "Громкость"), files: urls) { NormalizeView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.bleep", title: String(localized: "Запикать"), symbolName: "waveform.badge.minus") { urls in
                ToolWindow.present(title: String(localized: "Запикать"), files: urls) { BleepView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .audio }) {
            items.append(WheelItem(id: "tool.channels", title: String(localized: "Каналы"), symbolName: "headphones") { urls in
                ToolWindow.present(title: String(localized: "Каналы"), files: urls) { ChannelsView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.visualizer", title: String(localized: "Визуализатор"), symbolName: "waveform.circle") { urls in
                ToolWindow.present(title: String(localized: "Визуализатор"), files: urls) { VisualizerView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .video }) {
            items.append(WheelItem(id: "tool.redactVideo", title: String(localized: "Скрыть"), symbolName: "eye.slash") { urls in
                ToolWindow.present(title: String(localized: "Скрыть на видео"), files: urls) { VideoRedactView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.cropVideo", title: String(localized: "Кадрировать"), symbolName: "crop") { urls in
                ToolWindow.present(title: String(localized: "Кадрирование видео"), files: urls) { VideoCropView(urls: urls, close: $0) }
            })
        }
        if formats.filter({ $0.category == .video }).count >= 2 {
            items.append(WheelItem(id: "tool.join", title: String(localized: "Склеить"), symbolName: "film.stack") { urls in
                ToolWindow.present(title: String(localized: "Склейка видео"), files: urls) { JoinView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }),
           !formats.contains(where: { $0.category == .image || $0 == .pdf }) {
            items.append(WheelItem(id: "tool.compressMedia", title: String(localized: "Сжать"), symbolName: "arrow.down.right.and.arrow.up.left") { urls in
                ToolWindow.present(title: String(localized: "Сжатие"), files: urls) { MediaCompressView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .video }) {
            items.append(WheelItem(id: "tool.frames", title: String(localized: "Кадры"), symbolName: "photo.on.rectangle") { urls in
                ToolWindow.present(title: String(localized: "Кадры из видео"), files: urls) { FramesView(urls: urls, close: $0) }
            })
        }
        let hasImages = formats.contains { $0.category == .image }
        if hasImages || formats.contains(.pdf) {
            items.append(WheelItem(id: "tool.compress", title: String(localized: "Сжать"), symbolName: "arrow.down.right.and.arrow.up.left") { urls in
                ToolWindow.present(title: String(localized: "Сжатие"), files: urls) { CompressView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            // Russian says «Обрезать» for both trimming media and cropping images; the other languages need two words.
            items.append(WheelItem(id: "tool.crop", title: String(localized: "Обрезать.изображение", defaultValue: "Обрезать"),
                                   symbolName: "crop") { urls in
                ToolWindow.present(title: String(localized: "Обрезка"), files: urls) { CropView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.edit", title: String(localized: "Редактор"), symbolName: "slider.horizontal.3") { urls in
                ToolWindow.present(title: String(localized: "Редактор фото"), files: urls) { PhotoEditView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.annotate", title: String(localized: "Пометки"), symbolName: "pencil.and.outline") { urls in
                ToolWindow.present(title: String(localized: "Пометки"), files: urls) { AnnotateView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.redact", title: String(localized: "Скрыть"), symbolName: "eye.slash") { urls in
                ToolWindow.present(title: String(localized: "Скрыть лица и текст"), files: urls) { RedactView(urls: urls, close: $0) }
            })
        }
        if formats.contains(.pdf) {
            // With media in the selection there is a "Split" for video too; say which one this is.
            let splitTitle = formats.contains(where: { $0.category.isMedia }) ? String(localized: "Разделить PDF") : String(localized: "Разделить")
            items.append(WheelItem(id: "tool.splitPDF", title: splitTitle, symbolName: "scissors") { urls in
                ToolWindow.present(title: String(localized: "Разделение PDF"), files: urls) { PDFSplitView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.organizePDF", title: String(localized: "Порядок страниц"), symbolName: "list.number") { urls in
                ToolWindow.present(title: String(localized: "Порядок страниц"), files: urls) { PDFOrganizeView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.frame", title: String(localized: "Фон"), symbolName: "photo.artframe") { urls in
                ToolWindow.present(title: String(localized: "Фон"), files: urls) { FrameView(urls: urls, close: $0) }
            })
        }
        if formats.filter({ $0.category == .image }).count >= 2 {
            items.append(WheelItem(id: "tool.collage", title: String(localized: "Коллаж"), symbolName: "square.grid.2x2") { urls in
                ToolWindow.present(title: String(localized: "Коллаж"), files: urls) { CollageView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .image && $0 != .svg }) {
            items.append(WheelItem(id: "tool.metadata", title: String(localized: "Метаданные"), symbolName: "info.circle") { urls in
                ToolWindow.present(title: String(localized: "Метаданные"), files: urls) { MetadataView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.createPDF", title: String(localized: "PDF из фото"), symbolName: "doc.badge.plus") { urls in
                ConversionService.shared.runBatch(String(localized: "Создание PDF"), inputs: urls) { [try PDFTools.createPDF(fromImages: $0)] }
            })
        }
        if formats.contains(where: { $0.category == .archive }) {
            items.append(WheelItem(id: "tool.extract", title: String(localized: "Распаковать"), symbolName: "archivebox") { urls in
                let archives = urls.filter { FileFormat.detect($0)?.category == .archive }
                ConversionService.shared.runEach(String(localized: "Распаковка"), inputs: archives) {
                    try ArchiveConverter.extractNextToArchive($0)
                }
            })
        }
        if formats.filter({ $0 == .pdf }).count >= 2 {
            items.append(WheelItem(id: "tool.mergePDF", title: String(localized: "Объединить"), symbolName: "doc.on.doc") { urls in
                ConversionService.shared.runBatch(String(localized: "Объединение PDF"), inputs: urls) { [try PDFTools.merge($0)] }
            })
        }
        return items
    }

    private static let actionItems: [WheelItem] = [
        WheelItem(id: "action.airdrop", title: "AirDrop", symbolName: "dot.radiowaves.left.and.right", perform: FileActions.airDrop),
        WheelItem(id: "action.float", title: "Float", symbolName: "tray.and.arrow.down", perform: FloatShelf.shared.add),
        WheelItem(id: "action.copy", title: String(localized: "Копировать"), symbolName: "doc.on.clipboard", perform: FileActions.copy),
        WheelItem(id: "action.move", title: String(localized: "Переместить"), symbolName: "folder", perform: FileActions.move),
        WheelItem(id: "action.copyPath", title: String(localized: "Путь"), symbolName: "link", perform: FileActions.copyPaths),
        WheelItem(id: "action.terminal", title: String(localized: "Терминал"), symbolName: "terminal", perform: FileActions.openTerminal),
    ]
}
