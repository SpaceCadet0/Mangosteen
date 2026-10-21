import AppKit
import SwiftUI

/// The status-bar icon and its menu.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openFiles: (WheelKind) -> Void
    private let openSettings: () -> Void
    private let openWelcome: () -> Void
    private let openAbout: () -> Void
    private let headerItem = NSMenuItem()
    private let header = NSHostingView(rootView: MenuHeader(hint: ""))
    private var wheelItems: [WheelKind: NSMenuItem] = [:]
    private let historyItem = NSMenuItem()

    init(openFiles: @escaping (WheelKind) -> Void, openSettings: @escaping () -> Void, openWelcome: @escaping () -> Void,
         openAbout: @escaping () -> Void) {
        self.openFiles = openFiles
        self.openSettings = openSettings
        self.openWelcome = openWelcome
        self.openAbout = openAbout
        super.init()

        statusItem.button?.image = MangosteenArt.menuBarIcon()
        statusItem.button?.image?.accessibilityDescription = "Mangosteen"

        let menu = NSMenu()
        menu.delegate = self
        header.frame = NSRect(x: 0, y: 0, width: 290, height: 56)
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())
        for kind in WheelKind.allCases {
            let item = makeItem("\(kind.title)…", symbol: Self.symbol(for: kind), action: #selector(openFilesSelected(_:)))
            item.representedObject = kind.rawValue
            wheelItems[kind] = item
            menu.addItem(item)
        }
        menu.addItem(makeItem(String(localized: "Показать или скрыть Float"), symbol: "tray.and.arrow.down", action: #selector(floatSelected)))
        historyItem.title = String(localized: "Недавние результаты")
        historyItem.image = Self.icon("clock.arrow.circlepath")
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(String(localized: "Как пользоваться…"), symbol: "questionmark.circle", action: #selector(welcomeSelected)))
        menu.addItem(makeItem(String(localized: "О Mangosteen…"), symbol: "info.circle", action: #selector(aboutSelected)))
        menu.addItem(makeItem(String(localized: "Настройки…"), symbol: "gearshape", action: #selector(settingsSelected), key: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Выйти из Mangosteen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.icon("power")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private static func symbol(for kind: WheelKind) -> String {
        switch kind {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "wrench.and.screwdriver"
        case .actions: "bolt"
        }
    }

    private static func icon(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    private func makeItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = Self.icon(symbol)
        return item
    }


    #if DEBUG
    /// Snapshot mode: opens the menu under the status item (the call returns when the menu closes).
    func debugOpenMenu() {
        guard let button = statusItem.button, let menu = statusItem.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
    #endif

    private var windowItems: [NSMenuItem] = []

    /// Open windows, listed at the top of the menu so a hidden or minimised one can be brought back.
    private func refreshWindowItems(in menu: NSMenu) {
        windowItems.forEach(menu.removeItem)
        windowItems.removeAll()
        let windows = AppPresence.windows
        guard !windows.isEmpty else { return }
        var items = [NSMenuItem(title: String(localized: "Открытые окна"), action: nil, keyEquivalent: "")]
        items[0].isEnabled = false
        for window in windows {
            let title = window.subtitle.isEmpty ? window.title : "\(window.title) — \(window.subtitle)"
            let item = NSMenuItem(title: title + (window.isMiniaturized ? String(localized: " (свёрнуто)") : ""),
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

    // MARK: History

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Recent results, newest first: each with Show in Finder, Open and Delete result.
    private func refreshHistory() {
        guard let submenu = historyItem.submenu else { return }
        submenu.removeAllItems()
        let entries = OperationHistory.shared.current()
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "Пока пусто"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for entry in entries.prefix(10) {
            let first = entry.outputs[0].lastPathComponent
            let more = entry.outputs.count > 1 ? String(localized: " и ещё \(entry.outputs.count - 1)") : ""
            let item = NSMenuItem(title: "\(first)\(more)", action: nil, keyEquivalent: "")
            item.image = NSWorkspace.shared.icon(forFile: entry.outputs[0].path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.toolTip = "\(entry.title) · \(Self.timeFormatter.string(from: entry.date))"
            let actions = NSMenu()
            let header = NSMenuItem(title: "\(entry.title) · \(Self.timeFormatter.string(from: entry.date))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            actions.addItem(header)
            actions.addItem(.separator())
            for (title, symbol, selector) in [
                (String(localized: "Показать в Finder"), "folder", #selector(revealResult(_:))),
                (String(localized: "Открыть"), "arrow.up.forward.app", #selector(openResult(_:))),
            ] {
                let action = makeItem(title, symbol: symbol, action: selector)
                action.representedObject = entry.id
                actions.addItem(action)
            }
            actions.addItem(.separator())
            let delete = makeItem(String(localized: "Удалить результат"), symbol: "trash", action: #selector(deleteResult(_:)))
            delete.representedObject = entry.id
            actions.addItem(delete)
            item.submenu = actions
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(makeItem(String(localized: "Очистить историю"), symbol: "xmark.circle", action: #selector(clearHistory)))
    }

    private func entry(for sender: NSMenuItem) -> OperationHistory.Entry? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return OperationHistory.shared.entries.first { $0.id == id }
    }

    @objc private func revealResult(_ sender: NSMenuItem) {
        guard let entry = entry(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(entry.outputs)
    }

    @objc private func openResult(_ sender: NSMenuItem) {
        entry(for: sender)?.outputs.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func deleteResult(_ sender: NSMenuItem) {
        guard let entry = entry(for: sender) else { return }
        OperationHistory.shared.deleteResults(of: entry.id)
    }

    @objc private func clearHistory() {
        OperationHistory.shared.clear()
    }

    @objc private func windowSelected(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        AppPresence.bringBack(window)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshWindowItems(in: menu)
        refreshHistory()
        let settings = AppSettings.shared
        let modifiers: [WheelKind: ModifierChoice] = [
            .convert: settings.convertModifier, .tools: settings.toolsModifier, .actions: settings.actionsModifier,
        ]
        let keys = WheelKind.allCases.compactMap { modifiers[$0] }
            .filter { $0 != .none }
            .map(\.symbol)
            .joined(separator: " ")
        header.rootView = MenuHeader(hint: String(localized: "Тащите файл и нажмите \(keys)"))
        // The wheel's key sits at the right edge as a badge, where shortcuts are shown.
        for (kind, item) in wheelItems {
            let modifier = modifiers[kind] ?? .none
            item.badge = modifier == .none ? nil : NSMenuItemBadge(string: modifier.symbol)
        }
    }

    @objc private func openFilesSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = WheelKind(rawValue: raw) else { return }
        openFiles(kind)
    }

    @objc private func floatSelected() {
        FloatShelf.shared.toggle()
    }

    @objc private func welcomeSelected() {
        openWelcome()
    }

    @objc private func aboutSelected() {
        openAbout()
    }

    @objc private func settingsSelected() {
        openSettings()
    }
}

/// The top of the menu: the app's icon, name and how to open a wheel.
private struct MenuHeader: View {
    let hint: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: MangosteenArt.appIcon(size: 64))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Mangosteen").font(.system(size: 13, weight: .semibold))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
    }
}
