import AppKit

/// Actions that work on any file or folder (the Control wheel).
enum FileActions {
    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Puts the files themselves on the clipboard, ready to paste in Finder.
    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// One absolute path per line.
    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Переместить")
        panel.message = String(localized: "Куда переместить: \(WheelView.filesLabel(urls.count))")
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var moved: [URL] = []
        var failures: [(URL, Error)] = []
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
            let target = OutputNaming.uniqueURL(in: destination, baseName: OutputNaming.baseName(of: url),
                                                pathExtension: url.pathExtension)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                moved.append(target)
            } catch {
                failures.append((url, error))
            }
        }
        Feedback.finished(String(localized: "Перемещение"), outputs: moved, failures: failures)
    }

    /// Opens each folder (or a file's containing folder) in the chosen terminal app.
    static func openTerminal(_ urls: [URL]) {
        var folders: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let folder = isDirectory ? url : url.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: AppSettings.shared.terminalApp.bundleIdentifier)
            ?? workspace.urlForApplication(withBundleIdentifier: TerminalChoice.terminal.bundleIdentifier) else {
            NSSound.beep()
            return
        }
        workspace.open(folders, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                DispatchQueue.main.async { Feedback.showError(String(localized: "Терминал"), error) }
            }
        }
    }
}
