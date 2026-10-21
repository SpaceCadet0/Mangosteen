import AppKit

/// The last finished operations and the files they produced, kept across launches. The menu bar menu lists them
/// with Show in Finder, Open and Delete result (which moves the files to the Trash, so it can be undone there).
final class OperationHistory {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let title: String
        let date: Date
        var outputs: [URL]
    }

    static let shared = OperationHistory()
    static let limit = 20

    private let defaults: UserDefaults
    private let key = "operationHistory"
    private(set) var entries: [Entry] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func record(_ title: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        entries.insert(Entry(id: UUID(), title: title, date: Date(), outputs: outputs), at: 0)
        entries = Array(entries.prefix(Self.limit))
        save()
    }

    /// Entries whose files still exist (missing files are dropped, entries with none left disappear).
    func current() -> [Entry] {
        let fileManager = FileManager.default
        let pruned = entries.compactMap { entry -> Entry? in
            var entry = entry
            entry.outputs = entry.outputs.filter { fileManager.fileExists(atPath: $0.path) }
            return entry.outputs.isEmpty ? nil : entry
        }
        if pruned.map(\.outputs) != entries.map(\.outputs) {
            entries = pruned
            save()
        }
        return entries
    }

    /// Moves the entry's files to the Trash and forgets the entry.
    func deleteResults(of id: UUID, completion: ((Error?) -> Void)? = nil) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.recycle(entry.outputs) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.entries.removeAll { $0.id == id }
                self?.save()
                completion?(error)
            }
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
