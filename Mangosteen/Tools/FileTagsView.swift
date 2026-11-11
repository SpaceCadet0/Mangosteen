import SwiftUI

/// Metadata of video, audio and PDF: the fields that kind of file has. With several files a field that differs
/// between them shows "different values" and is changed only if edited; an emptied field is cleared.
struct FileTagsView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var texts: [FileTags.Field: String] = [:]
    @State private var original: [FileTags.Field: String] = [:]
    @State private var mixed: Set<FileTags.Field> = []
    @State private var removeAll = false
    @State private var message: String?

    private var files: [URL] { urls.filter { FileFormat.detect($0).map(FileTags.supports) ?? false } }
    /// Fields every chosen file has.
    private var fields: [FileTags.Field] {
        let lists = files.compactMap(FileFormat.detect).map { Set(FileTags.fields(for: $0)) }
        guard let first = lists.first else { return [] }
        let common = lists.dropFirst().reduce(first) { $0.intersection($1) }
        return FileTags.Field.allCases.filter(common.contains)
    }

    private var changes: [FileTags.Field: String] {
        var result: [FileTags.Field: String] = [:]
        for field in fields {
            let text = texts[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if text != original[field, default: ""] { result[field] = text }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section {
                    ForEach(fields) { field in
                        TextField(field.title, text: binding(field),
                                  prompt: mixed.contains(field) ? Text(String(localized: "разные значения")) : nil)
                            .disabled(removeAll)
                    }
                }
                Section {
                    Toggle(String(localized: "Удалить все метаданные"), isOn: $removeAll)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: CGFloat(fields.count) * 34 + 110)
            Text(message ?? String(localized: "Сохраняется копия «(метаданные)». Видео и звук копируются без перекодирования, качество не меняется."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ToolFooter(fileCount: files.count, actionTitle: String(localized: "Сохранить"),
                       actionDisabled: files.isEmpty || (!removeAll && changes.isEmpty), cancel: close, action: run)
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private func binding(_ field: FileTags.Field) -> Binding<String> {
        Binding(get: { texts[field, default: ""] }, set: { texts[field] = $0 })
    }

    private func load() async {
        let files = files
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[[FileTags.Field: String]], Error> in
            Result { try files.map(FileTags.read) }
        }.value
        switch result {
        case .success(let all):
            var values: [FileTags.Field: String] = [:]
            var differing: Set<FileTags.Field> = []
            for field in FileTags.Field.allCases {
                let found = Set(all.map { $0[field, default: ""] })
                if found.count == 1 { values[field] = found.first } else { differing.insert(field) }
            }
            original = values
            texts = values
            mixed = differing
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func run() {
        let changes = changes, removeAll = removeAll
        ConversionService.shared.runEach(String(localized: "Метаданные"), inputs: files, maxConcurrent: 2) {
            try FileTags.write($0, changes: changes, removeAll: removeAll, progress: $1, cancellation: $2)
        }
        close()
    }
}
