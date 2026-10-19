import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dragMonitor = DragMonitor.shared
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
        #if DEBUG
        runSnapshotIfRequested()
        #endif
    }

    #if DEBUG
    /// `Mangosteen --snapshot <item id> <output.png> <file>…` opens a wheel item's window on the files and
    /// saves a picture of it, so tool layouts can be checked without clicking through the UI.
    private func runSnapshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 3 else { return }
        let itemID = arguments[flag + 1]
        let output = URL(fileURLWithPath: arguments[flag + 2])
        let inputs = arguments[(flag + 3)...].map { URL(fileURLWithPath: $0) }
        // "wheel.convert" / "wheel.tools" / "wheel.actions" show the wheel itself at the centre of the screen.
        if itemID.hasPrefix("wheel."), let kind = WheelKind(rawValue: String(itemID.dropFirst("wheel.".count))) {
            let center = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            wheel.show(kind: kind, urls: inputs, at: center)
            finishSnapshot(window: wheel.debugWindow)
            return
        }
        let kind: WheelKind = itemID.hasPrefix("action.") ? .actions : itemID.hasPrefix("convert.") ? .convert : .tools
        guard let item = WheelItemProvider.items(for: kind, urls: inputs).first(where: { $0.id == itemID }) else {
            print("snapshot: no item \(itemID)")
            exit(2)
        }
        item.perform(inputs)
        // Conversions have no window of their own; capture the progress panel instead.
        finishSnapshot(window: kind == .convert ? ProgressHUD.shared.debugWindow : nil)
        _ = output
    }

    /// Prints the window id after 3 s and stays open 4 s more so `screencapture -l <id>` can grab it.
    private func finishSnapshot(window fixed: NSWindow?) {
        let delay = Double(ProcessInfo.processInfo.environment["MANGOSTEEN_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = fixed ?? NSApp.windows.first(where: { $0.isVisible && $0.contentViewController != nil }),
                  window.isVisible else {
                print("snapshot: no window")
                exit(3)
            }
            print("snapshot: window \(window.frame), screen \(window.screen?.visibleFrame ?? .zero), id \(window.windowNumber)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
        }
    }
    #endif

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
