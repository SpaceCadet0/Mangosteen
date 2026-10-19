import SwiftUI

/// Metadata tool: edit common fields or strip data, with a searchable view of everything in the first file.
struct MetadataView: View {
    let urls: [URL]
    let close: () -> Void

    @State private var entries: [MetadataEditor.Entry] = []
    @State private var search = ""
    @State private var removeAll = false
    @State private var removeLocation = false
    @State private var texts: [MetadataField: String] = [:]
    @State private var originalTexts: [MetadataField: String] = [:]
    @State private var changeDate = false
    @State private var date = Date()
    @State private var changeLocation = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var hasLocation = false

    private var images: [URL] {
        urls.filter { FileFormat.detect($0).map { $0.category == .image && $0 != .svg } ?? false }
    }

    private var coordinates: (Double, Double)? {
        func parse(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let latitude = parse(latitudeText), let longitude = parse(longitudeText),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return nil
        }
        return (latitude, longitude)
    }

    private var changes: MetadataChanges {
        var changes = MetadataChanges()
        changes.removeAll = removeAll
        guard !removeAll else { return changes }
        changes.removeLocation = removeLocation
        for field in MetadataField.allCases where texts[field, default: ""] != originalTexts[field, default: ""] {
            changes.text[field] = texts[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if changeDate { changes.dateTaken = date }
        if changeLocation, !removeLocation, let (latitude, longitude) = coordinates {
            changes.latitude = latitude
            changes.longitude = longitude
        }
        return changes
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                editor
                inspector
            }
            ToolFooter(fileCount: images.count, actionTitle: "Сохранить копию",
                       actionDisabled: images.isEmpty || changes.isEmpty || (changeLocation && coordinates == nil && !removeLocation),
                       cancel: close, action: run)
        }
        .padding(20)
        .task { load() }
    }

    private var editor: some View {
        Form {
            Section {
                Toggle("Удалить все метаданные", isOn: $removeAll)
                Toggle("Удалить геопозицию", isOn: $removeLocation)
                    .disabled(removeAll || !hasLocation && !changeLocation)
            } footer: {
                if images.count > 1 {
                    Text("Изменения применятся ко всем \(WheelView.filesLabel(images.count)). Справа показаны данные первого.")
                }
            }

            Section("Поля") {
                ForEach(MetadataField.allCases) { field in
                    TextField(field.title, text: Binding(
                        get: { texts[field, default: ""] },
                        set: { texts[field] = $0 }
                    ))
                }
            }
            .disabled(removeAll)

            Section("Дата съёмки") {
                Toggle("Изменить дату", isOn: $changeDate)
                if changeDate {
                    DatePicker("Дата", selection: $date)
                }
            }
            .disabled(removeAll)

            Section("Геопозиция") {
                Toggle("Задать координаты", isOn: $changeLocation)
                if changeLocation {
                    TextField("Широта (−90…90)", text: $latitudeText)
                    TextField("Долгота (−180…180)", text: $longitudeText)
                    if coordinates == nil {
                        Text("Введите координаты в градусах, например 55.7558 и 37.6173")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(removeAll || removeLocation)
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
    }

    private var inspector: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) || $0.group.lowercased().contains(query)
        }
        let groups = Dictionary(grouping: filtered, by: \.group).sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск по полям", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(groups, id: \.key) { group, items in
                    Section(group) {
                        ForEach(items) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.key).foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.value)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    Text(entries.isEmpty ? "Метаданных нет" : "Ничего не найдено").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 400, height: 520)
    }

    private func load() {
        guard let first = images.first else { return }
        let properties = MetadataEditor.properties(of: first)
        entries = MetadataEditor.entries(of: properties)
        for field in MetadataField.allCases {
            originalTexts[field] = MetadataEditor.text(field, in: properties)
        }
        texts = originalTexts
        if let taken = MetadataEditor.dateTaken(in: properties) {
            date = taken
        }
        if let location = MetadataEditor.location(in: properties) {
            hasLocation = true
            latitudeText = String(format: "%.6f", location.latitude)
            longitudeText = String(format: "%.6f", location.longitude)
        }
    }

    private func run() {
        let changes = changes
        ConversionService.shared.runEach("Метаданные", inputs: images) {
            try MetadataEditor.apply(changes, to: $0)
        }
        close()
    }
}
