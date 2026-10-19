import AppKit

/// The status-bar icon and its menu.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openFiles: (WheelKind) -> Void
    private let openSettings: () -> Void
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(openFiles: @escaping (WheelKind) -> Void, openSettings: @escaping () -> Void) {
        self.openFiles = openFiles
        self.openSettings = openSettings
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                           accessibilityDescription: "Mangosteen")

        let menu = NSMenu()
        menu.delegate = self
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())
        for kind in WheelKind.allCases {
            let item = NSMenuItem(title: "\(kind.title)…", action: #selector(openFilesSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(settingsSelected), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти из Mangosteen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let settings = AppSettings.shared
        let keys = [settings.convertModifier, settings.toolsModifier, settings.actionsModifier]
            .filter { $0 != .none }
            .map(\.symbol)
            .joined(separator: " ")
        hintItem.title = "Тащите файл и нажмите \(keys)"
    }

    @objc private func openFilesSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WheelKind(rawValue: raw) else { return }
        openFiles(kind)
    }

    @objc private func settingsSelected() {
        openSettings()
    }
}
