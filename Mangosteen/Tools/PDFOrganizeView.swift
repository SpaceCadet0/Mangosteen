import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// PDF pages tool: drag to reorder, rotate, duplicate and delete pages. Several PDFs are organised as one.
struct PDFOrganizeView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var documents: [PDFDocument] = []
    @State private var names: [String] = []
    @State private var items: [PDFPageItem] = []
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var selection: Set<UUID> = []
    @State private var dragging: PDFPageItem?
    @State private var loadError: String?

    private var pdfs: [URL] { urls.filter { FileFormat.detect($0) == .pdf } }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        cell(item, position: position)
                            .onDrag {
                                dragging = item
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDelegate(target: item, items: $items, dragging: $dragging))
                    }
                }
                .padding(12)
            }
            .frame(minWidth: 640, idealWidth: 760, minHeight: 380, idealHeight: 520)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            .overlay {
                if let loadError { Text(loadError).foregroundStyle(.secondary) }
            }
            HStack {
                Text(String(localized: "Клик — выбрать, ⌘-клик — добавить к выбору, перетаскивание — порядок, ⌫ — удалить."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ToolFooter(fileCount: pdfs.count, actionTitle: String(localized: "Сохранить PDF"), actionDisabled: items.isEmpty,
                       cancel: close, action: run)
        }
        .padding(20)
        .onDeleteCommand(perform: deleteSelected)
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { rotate(-90) } label: { Label(String(localized: "Влево"), systemImage: "rotate.left") }
            Button { rotate(90) } label: { Label(String(localized: "Вправо"), systemImage: "rotate.right") }
            Button(action: duplicateSelected) { Label(String(localized: "Дублировать"), systemImage: "plus.square.on.square") }
            Button(action: deleteSelected) { Label(String(localized: "Удалить"), systemImage: "trash") }
            Spacer()
            Button(selection.count == items.count ? String(localized: "Снять выделение") : String(localized: "Выделить все")) {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
            Text(String(localized: "\(items.count) стр.")).monospacedDigit().foregroundStyle(.secondary)
        }
        .disabled(items.isEmpty)
    }

    private func cell(_ item: PDFPageItem, position: Int) -> some View {
        let isSelected = selection.contains(item.id)
        return VStack(spacing: 6) {
            ZStack {
                if let thumbnail = thumbnails["\(item.document)-\(item.page)"] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .shadow(radius: 1)
                        .rotationEffect(.degrees(Double(item.rotation)))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 120, height: 120)
            Text("\(position + 1)").font(.caption.monospacedDigit())
            if documents.count > 1 {
                Text(names[item.document]).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Brand.color.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Brand.color : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                selection = [item.id]
            }
        }
    }

    // MARK: Actions

    private func rotate(_ degrees: Int) {
        for index in items.indices where selection.contains(items[index].id) {
            items[index].rotation = ((items[index].rotation + degrees) % 360 + 360) % 360
        }
    }

    private func duplicateSelected() {
        var result: [PDFPageItem] = []
        var copies: Set<UUID> = []
        for item in items {
            result.append(item)
            if selection.contains(item.id) {
                let copy = PDFPageItem(document: item.document, page: item.page, rotation: item.rotation)
                result.append(copy)
                copies.insert(copy.id)
            }
        }
        items = result
        selection = copies
    }

    private func deleteSelected() {
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func load() async {
        let loaded = pdfs.compactMap { PDFDocument(url: $0) }
        guard !loaded.isEmpty, loaded.count == pdfs.count else {
            loadError = String(localized: "Не удалось открыть PDF")
            return
        }
        if loaded.contains(where: \.isLocked) {
            loadError = String(localized: "PDF защищён паролем")
            return
        }
        documents = loaded
        names = pdfs.map(\.lastPathComponent)
        items = PDFOrganizer.items(for: loaded)
        for (documentIndex, document) in loaded.enumerated() {
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                thumbnails["\(documentIndex)-\(pageIndex)"] = page.thumbnail(of: NSSize(width: 240, height: 240), for: .cropBox)
                if pageIndex % 8 == 7 { await Task.yield() }
            }
        }
    }

    private func run() {
        guard let first = pdfs.first else { return }
        let items = items
        let documents = documents
        ConversionService.shared.runBatch(String(localized: "Порядок страниц"), inputs: [first]) { _ in
            [try PDFOrganizer.save(items, from: documents, nextTo: first)]
        }
        close()
    }
}

/// Moves the dragged page to the position of the page it hovers over.
private struct ReorderDelegate: DropDelegate {
    let target: PDFPageItem
    @Binding var items: [PDFPageItem]
    @Binding var dragging: PDFPageItem?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id,
              let from = items.firstIndex(where: { $0.id == dragging.id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
