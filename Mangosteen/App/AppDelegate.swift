import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dragMonitor = DragMonitor()
    private let wheel = WheelController()
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(
            openFiles: { [weak self] kind in self?.chooseFiles(for: kind) },
            openSettings: { [weak self] in self?.showSettings() }
        )

        dragMonitor.onModifierTap = { [weak self] flags, urls in
            guard let kind = AppSettings.shared.wheelKind(for: flags) else { return }
            self?.wheel.show(kind: kind, urls: urls)
        }
        dragMonitor.onDragEnded = { [weak self] in
            self?.wheel.dragEnded()
        }
        dragMonitor.start()
    }

    /// Fallback without dragging: pick files, then open the wheel at the cursor and click a segment.
    private func chooseFiles(for kind: WheelKind) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = kind == .actions
        panel.canChooseFiles = true
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        DispatchQueue.main.async { [weak self] in
            self?.wheel.show(kind: kind, urls: urls)
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Настройки Mangosteen"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
