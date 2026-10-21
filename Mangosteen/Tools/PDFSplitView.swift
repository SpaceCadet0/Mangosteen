import PDFKit
import SwiftUI

/// Split PDF tool: scissors after a page start a new document, a click on a page leaves it out.
/// Presets cut after every page, in half, or every N pages. Works on the first PDF of the selection.
struct PDFSplitView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var pageCount = 0
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var cuts: Set<Int> = []
    @State private var excluded: Set<Int> = []
    @State private var groupSize = 2
    @State private var loadError: String?

    private var pdf: URL? { urls.first { FileFormat.detect($0) == .pdf } }
    private var groups: [[Int]] { PDFSplitter.groups(pageCount: pageCount, cuts: cuts, excluded: excluded) }

    /// Which resulting document each kept page belongs to, for the alternating tint.
    private var documentOfPage: [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, pages) in groups.enumerated() {
            for page in pages { result[page] = index }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 12) {
            presets
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 12) {
                    ForEach(0..<pageCount, id: \.self) { page in
                        cell(page, document: documentOfPage[page])
                    }
                }
                .padding(12)
            }
            .frame(minWidth: 680, idealWidth: 780, minHeight: 380, idealHeight: 500)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            .overlay {
                if let loadError { Text(loadError).foregroundStyle(.secondary) }
            }
            summary
            ToolFooter(fileCount: pdf == nil ? 0 : 1, actionTitle: String(localized: "Разделить"),
                       actionDisabled: groups.isEmpty || (groups.count == 1 && excluded.isEmpty),
                       cancel: close, action: run)
        }
        .padding(20)
        .task { await load() }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Каждая страница")) { cuts = PDFSplitter.cuts(every: 1, pageCount: pageCount) }
            Button(String(localized: "Пополам")) { cuts = PDFSplitter.halfCut(pageCount: pageCount) }
            Divider().frame(height: 18)
            Stepper(value: $groupSize, in: 1...max(pageCount, 1)) {
                Text(String(localized: "По \(groupSize) стр.")).monospacedDigit()
            }
            Button(String(localized: "Применить")) { cuts = PDFSplitter.cuts(every: groupSize, pageCount: pageCount) }
            Spacer()
            Button(String(localized: "Сбросить")) {
                cuts = []
                excluded = []
            }
        }
        .disabled(pageCount < 1)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline) {
            let groups = groups
            Text(String(localized: "Документов: \(groups.count)"))
                .font(.callout.weight(.semibold))
            Text(groups.map { PDFSplitter.rangesText($0) }.joined(separator: "  ·  "))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(String(localized: "Ножницы — разрезать после страницы, клик по странице — убрать её."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cell(_ page: Int, document: Int?) -> some View {
        let isExcluded = excluded.contains(page)
        let isCut = cuts.contains(page)
        let isLast = page == pageCount - 1
        return HStack(spacing: 4) {
            VStack(spacing: 6) {
                ZStack {
                    if let thumbnail = thumbnails[page] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .shadow(radius: 1)
                            .opacity(isExcluded ? 0.3 : 1)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if isExcluded {
                        Image(systemName: "xmark")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
                Text(document.map { String(localized: "\(page + 1) · док. \($0 + 1)") } ?? String(localized: "\(page + 1) · убрана"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isExcluded ? .secondary : .primary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint(for: document)))
            .contentShape(Rectangle())
            .onTapGesture {
                if isExcluded { excluded.remove(page) } else { excluded.insert(page) }
            }

            // The cut after this page: a dashed line with scissors, or a faint scissors button to add one.
            Button {
                if isCut { cuts.remove(page) } else { cuts.insert(page) }
            } label: {
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(isCut ? Brand.color : Color.clear)
                        .frame(width: 2, height: 46)
                    Image(systemName: "scissors")
                        .foregroundStyle(isCut ? Brand.color : Color.secondary.opacity(0.6))
                    Rectangle()
                        .fill(isCut ? Brand.color : Color.clear)
                        .frame(width: 2, height: 46)
                }
                .frame(width: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCut ? String(localized: "Убрать разрез") : String(localized: "Разрезать после этой страницы"))
            .opacity(isLast ? 0 : 1)
            .disabled(isLast)
        }
    }

    private func tint(for document: Int?) -> Color {
        guard let document else { return .clear }
        return document % 2 == 0 ? Brand.color.opacity(0.22) : Color.secondary.opacity(0.15)
    }

    private func load() async {
        guard let pdf, let document = PDFDocument(url: pdf) else {
            loadError = String(localized: "Не удалось открыть PDF")
            return
        }
        if document.isLocked {
            loadError = String(localized: "PDF защищён паролем")
            return
        }
        pageCount = document.pageCount
        if ProcessInfo.processInfo.environment["MANGOSTEEN_DEMO"] != nil, pageCount > 3 {
            cuts = [1]
            excluded = [pageCount - 1]
        }
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            thumbnails[index] = page.thumbnail(of: NSSize(width: 220, height: 220), for: .cropBox)
            if index % 8 == 7 { await Task.yield() }
        }
    }

    private func run() {
        guard let pdf else { return }
        let cuts = cuts, excluded = excluded
        ConversionService.shared.runBatch(String(localized: "Разделение PDF"), inputs: [pdf]) { _ in
            [try PDFSplitter.split(pdf, cuts: cuts, excluded: excluded)]
        }
        close()
    }
}
