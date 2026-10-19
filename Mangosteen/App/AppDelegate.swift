import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        NSApp.applicationIconImage = MangosteenArt.appIcon()
        NSApp.mainMenu = makeMainMenu()
        menuBar = MenuBarController(
            openFiles: { [weak self] kind in self?.chooseFiles(for: kind) },
            openSettings: { [weak self] in self?.showSettings() },
            openWelcome: { [weak self] in self?.showWelcome() }
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
        if ProcessInfo.processInfo.arguments.contains("--snapshot") { return }
        #endif
        if !UserDefaults.standard.bool(forKey: WelcomeView.shownKey) {
            showWelcome()
        }
    }

    @objc func showWelcome() {
        ToolWindow.present(title: "Как пользоваться Mangosteen") { WelcomeView(close: $0) }
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
        // "iconset": writes the app icon PNGs (and the menu bar icon preview) into the `output` folder.
        if itemID == "iconset" {
            func save(_ image: NSImage, pixels: Int, name: String) {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = NSSize(width: pixels, height: pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
            }
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for pixels in [16, 32, 64, 128, 256, 512, 1024] {
                save(MangosteenArt.appIcon(size: CGFloat(pixels)), pixels: pixels, name: "icon_\(pixels).png")
            }
            save(MangosteenArt.menuBarIcon(size: 18), pixels: 36, name: "menubar@2x.png")
            exit(0)
        }
        // "wheel.convert" / "wheel.tools" / "wheel.actions" show the wheel itself at the centre of the screen.
        if itemID.hasPrefix("wheel."), let kind = WheelKind(rawValue: String(itemID.dropFirst("wheel.".count))) {
            let center = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            wheel.show(kind: kind, urls: inputs, at: center)
            finishSnapshot(window: wheel.debugWindow)
            return
        }
        if itemID == "welcome" {
            showWelcome()
            finishSnapshot(window: nil)
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

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Настройки Mangosteen"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        AppPresence.settingsWindow = settingsWindow
        AppPresence.windowOpened()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppPresence.windowClosed()
    }

    /// Clicking the Dock icon brings back a hidden or minimised window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = AppPresence.windows.last(where: \.isMiniaturized) ?? AppPresence.windows.last {
            AppPresence.bringBack(window)
        }
        return false
    }

    /// Shown while Mangosteen acts as a regular app (any window open). The Edit menu also makes
    /// ⌘C/⌘V/⌘A work in text fields; the Window menu lists open windows.
    private func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let main = NSMenu()

        let app = NSMenu(title: "Mangosteen")
        app.addItem(item("О Mangosteen", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        let settings = item("Настройки…", #selector(showSettings), ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(item("Скрыть Mangosteen", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Выйти из Mangosteen", #selector(NSApplication.terminate(_:)), "q"))

        let edit = NSMenu(title: "Правка")
        edit.addItem(item("Отменить", Selector(("undo:")), "z"))
        edit.addItem(item("Повторить", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Вырезать", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Копировать", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Вставить", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Выделить всё", #selector(NSText.selectAll(_:)), "a"))

        let window = NSMenu(title: "Окно")
        window.addItem(item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Масштаб", #selector(NSWindow.performZoom(_:))))
        window.addItem(item("Закрыть", #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(.separator())
        window.addItem(item("Все окна на передний план", #selector(NSApplication.arrangeInFront(_:))))

        for submenu in [app, edit, window] {
            let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        NSApp.windowsMenu = window
        return main
    }
}
