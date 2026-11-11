import SwiftUI

/// Pages per sheet: 2, 4, 6 or 9 PDF pages on each sheet, shown as a small layout sketch. Pages stay vector.
struct PDFSheetView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var perSheet = 4
    private var pdfs: [URL] { urls.filter { FileFormat.detect($0) == .pdf } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                Picker(String(localized: "Страниц на листе"), selection: $perSheet) {
                    ForEach([2, 4, 6, 9], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                sketch
            }
            Text(String(localized: "Страницы идут по порядку слева направо и сверху вниз. Текст остаётся текстом, линии — чёткими. Лист — размера первой страницы; для 2 и 6 он поворачивается горизонтально."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ToolFooter(fileCount: pdfs.count, actionTitle: String(localized: "Сохранить PDF"),
                       actionDisabled: pdfs.isEmpty, cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 520)
    }

    /// The sheet with its numbered cells.
    private var sketch: some View {
        let grid = PDFLayout.grid(perSheet: perSheet)
        let sheet = grid.landscape ? CGSize(width: 92, height: 66) : CGSize(width: 66, height: 92)
        return VStack(spacing: 3) {
            ForEach(0..<grid.rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<grid.columns, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(Text("\(row * grid.columns + column + 1)").font(.system(size: 9, weight: .semibold)))
                    }
                }
            }
        }
        .padding(5)
        .frame(width: sheet.width, height: sheet.height)
        .background(RoundedRectangle(cornerRadius: 3).fill(.background).shadow(radius: 1))
        .accessibilityHidden(true)
    }

    private func run() {
        let count = perSheet
        ConversionService.shared.runEach(String(localized: "Страниц на листе"), inputs: pdfs) {
            try PDFLayout.pagesPerSheet($0, perSheet: count)
        }
        close()
    }
}
