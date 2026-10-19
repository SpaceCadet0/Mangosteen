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
            items.append(WheelItem(id: "tool.trimMedia", title: "Обрезать", symbolName: "timeline.selection") { urls in
                ToolWindow.present(title: "Обрезка") { TrimMediaView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.splitMedia", title: "Разделить", symbolName: "scissors") { urls in
                ToolWindow.present(title: "Разделение") { SplitMediaView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }) {
            items.append(WheelItem(id: "tool.speed", title: "Скорость", symbolName: "gauge.with.dots.needle.67percent") { urls in
                ToolWindow.present(title: "Скорость") { SpeedView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }) {
            items.append(WheelItem(id: "tool.normalize", title: "Громкость", symbolName: "speaker.wave.3") { urls in
                ToolWindow.present(title: "Громкость") { NormalizeView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.bleep", title: "Запикать", symbolName: "waveform.badge.minus") { urls in
                ToolWindow.present(title: "Запикать") { BleepView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .audio }) {
            items.append(WheelItem(id: "tool.channels", title: "Каналы", symbolName: "headphones") { urls in
                ToolWindow.present(title: "Каналы") { ChannelsView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.visualizer", title: "Визуализатор", symbolName: "waveform.circle") { urls in
                ToolWindow.present(title: "Визуализатор") { VisualizerView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .video }) {
            items.append(WheelItem(id: "tool.cropVideo", title: "Кадрировать", symbolName: "crop") { urls in
                ToolWindow.present(title: "Кадрирование видео") { VideoCropView(urls: urls, close: $0) }
            })
        }
        if formats.filter({ $0.category == .video }).count >= 2 {
            items.append(WheelItem(id: "tool.join", title: "Склеить", symbolName: "film.stack") { urls in
                ToolWindow.present(title: "Склейка видео") { JoinView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category.isMedia }),
           !formats.contains(where: { $0.category == .image || $0 == .pdf }) {
            items.append(WheelItem(id: "tool.compressMedia", title: "Сжать", symbolName: "arrow.down.right.and.arrow.up.left") { urls in
                ToolWindow.present(title: "Сжатие") { MediaCompressView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .video }) {
            items.append(WheelItem(id: "tool.frames", title: "Кадры", symbolName: "photo.on.rectangle") { urls in
                ToolWindow.present(title: "Кадры из видео") { FramesView(urls: urls, close: $0) }
            })
        }
        let hasImages = formats.contains { $0.category == .image }
        if hasImages || formats.contains(.pdf) {
            items.append(WheelItem(id: "tool.compress", title: "Сжать", symbolName: "arrow.down.right.and.arrow.up.left") { urls in
                ToolWindow.present(title: "Сжатие") { CompressView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.crop", title: "Обрезать", symbolName: "crop") { urls in
                ToolWindow.present(title: "Обрезка") { CropView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.edit", title: "Редактор", symbolName: "slider.horizontal.3") { urls in
                ToolWindow.present(title: "Редактор фото") { PhotoEditView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.annotate", title: "Пометки", symbolName: "pencil.and.outline") { urls in
                ToolWindow.present(title: "Пометки") { AnnotateView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.redact", title: "Скрыть", symbolName: "eye.slash") { urls in
                ToolWindow.present(title: "Скрыть лица и текст") { RedactView(urls: urls, close: $0) }
            })
        }
        if formats.contains(.pdf) {
            items.append(WheelItem(id: "tool.organizePDF", title: "Страницы", symbolName: "doc.on.doc") { urls in
                ToolWindow.present(title: "Страницы PDF") { PDFOrganizeView(urls: urls, close: $0) }
            })
        }
        if hasImages {
            items.append(WheelItem(id: "tool.frame", title: "Фон", symbolName: "photo.artframe") { urls in
                ToolWindow.present(title: "Фон") { FrameView(urls: urls, close: $0) }
            })
        }
        if formats.filter({ $0.category == .image }).count >= 2 {
            items.append(WheelItem(id: "tool.collage", title: "Коллаж", symbolName: "square.grid.2x2") { urls in
                ToolWindow.present(title: "Коллаж") { CollageView(urls: urls, close: $0) }
            })
        }
        if formats.contains(where: { $0.category == .image && $0 != .svg }) {
            items.append(WheelItem(id: "tool.metadata", title: "Метаданные", symbolName: "info.circle") { urls in
                ToolWindow.present(title: "Метаданные") { MetadataView(urls: urls, close: $0) }
            })
            items.append(WheelItem(id: "tool.createPDF", title: "PDF из фото", symbolName: "doc.badge.plus") { urls in
                ConversionService.shared.runBatch("Создание PDF", inputs: urls) { [try PDFTools.createPDF(fromImages: $0)] }
            })
        }
        if formats.contains(where: { $0.category == .archive }) {
            items.append(WheelItem(id: "tool.extract", title: "Распаковать", symbolName: "archivebox") { urls in
                let archives = urls.filter { FileFormat.detect($0)?.category == .archive }
                ConversionService.shared.runEach("Распаковка", inputs: archives) {
                    try ArchiveConverter.extractNextToArchive($0)
                }
            })
        }
        if formats.filter({ $0 == .pdf }).count >= 2 {
            items.append(WheelItem(id: "tool.mergePDF", title: "Объединить", symbolName: "doc.on.doc") { urls in
                ConversionService.shared.runBatch("Объединение PDF", inputs: urls) { [try PDFTools.merge($0)] }
            })
        }
        return items
    }

    private static let actionItems: [WheelItem] = [
        WheelItem(id: "action.airdrop", title: "AirDrop", symbolName: "dot.radiowaves.left.and.right", perform: FileActions.airDrop),
        WheelItem(id: "action.float", title: "Float", symbolName: "tray.and.arrow.down", perform: FloatShelf.shared.add),
        WheelItem(id: "action.copy", title: "Копировать", symbolName: "doc.on.clipboard", perform: FileActions.copy),
        WheelItem(id: "action.move", title: "Переместить", symbolName: "folder", perform: FileActions.move),
        WheelItem(id: "action.copyPath", title: "Путь", symbolName: "link", perform: FileActions.copyPaths),
        WheelItem(id: "action.terminal", title: "Терминал", symbolName: "terminal", perform: FileActions.openTerminal),
    ]
}
