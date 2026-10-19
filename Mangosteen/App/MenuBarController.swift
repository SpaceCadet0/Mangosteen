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
        let float = NSMenuItem(title: "Показать или скрыть Float", action: #selector(floatSelected), keyEquivalent: "")
        float.target = self
        menu.addItem(float)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(settingsSelected), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти из Mangosteen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var windowItems: [NSMenuItem] = []

    /// Open windows, listed at the top of the menu so a hidden or minimised one can be brought back.
    private func refreshWindowItems(in menu: NSMenu) {
        windowItems.forEach(menu.removeItem)
        windowItems.removeAll()
        let windows = AppPresence.windows
        guard !windows.isEmpty else { return }
        var items = [NSMenuItem(title: "Открытые окна", action: nil, keyEquivalent: "")]
        items[0].isEnabled = false
        for window in windows {
            let title = window.subtitle.isEmpty ? window.title : "\(window.title) — \(window.subtitle)"
            let item = NSMenuItem(title: title + (window.isMiniaturized ? " (свёрнуто)" : ""),
                                  action: #selector(windowSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window
            item.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            items.append(item)
        }
        items.append(.separator())
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: offset)
        }
        windowItems = items
    }

    @objc private func windowSelected(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        AppPresence.bringBack(window)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshWindowItems(in: menu)
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

    @objc private func floatSelected() {
        FloatShelf.shared.toggle()
    }

    @objc private func settingsSelected() {
        openSettings()
    }
}
