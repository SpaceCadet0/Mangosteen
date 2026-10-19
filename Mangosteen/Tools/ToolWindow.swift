import AppKit
import SwiftUI

/// Hosts a tool's SwiftUI view in its own window and keeps it alive until closed.
final class ToolWindow: NSObject, NSWindowDelegate {
    private static var openWindows: [ToolWindow] = []

    private var window: NSWindow?

    /// Open tool windows, oldest first (minimised ones included).
    static var windows: [NSWindow] { openWindows.compactMap(\.window) }

    /// `content` receives a closure that closes the window. `files` name the window so several are
    /// easy to tell apart in the Window menu and the status menu.
    static func present<Content: View>(title: String, files: [URL] = [],
                                       @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        let controller = ToolWindow()
        let view = content { [weak controller] in controller?.window?.close() }
        let hosting = NSHostingController(rootView: view.tint(Brand.color))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.subtitle = subtitle(for: files)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = controller
        // Size to the SwiftUI content before positioning; centring first lets the window grow off-screen.
        window.setContentSize(hosting.view.fittingSize)
        fitOnScreen(window)
        controller.window = window
        openWindows.append(controller)
        AppPresence.windowOpened()
        window.makeKeyAndOrderFront(nil)
        // SwiftUI may settle on its final size after the first layout pass.
        DispatchQueue.main.async { fitOnScreen(window) }
    }

    private static func subtitle(for files: [URL]) -> String {
        guard let first = files.first else { return "" }
        return files.count > 1 ? "\(first.lastPathComponent) и ещё \(files.count - 1)" : first.lastPathComponent
    }

    /// Shrinks the window to the visible area of the screen under the cursor and centres it there.
    private static func fitOnScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width - 40)
        frame.size.height = min(frame.height, visible.height - 40)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        Self.openWindows.removeAll { $0 === self }
        AppPresence.windowClosed()
    }
}

/// Mangosteen normally lives only in the menu bar. While any of its windows is open it becomes a regular
/// app — Dock icon, ⌘Tab, ⌘` and the Window menu — so a window that went behind others or was minimised
/// can always be brought back. It returns to the menu bar when the last window closes.
enum AppPresence {
    /// The settings window, tracked alongside tool windows.
    static weak var settingsWindow: NSWindow?

    static func windowOpened() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        // Decide after the closing window is gone.
        DispatchQueue.main.async {
            let settingsOpen = settingsWindow.map { $0.isVisible || $0.isMiniaturized } ?? false
            if ToolWindow.windows.isEmpty, !settingsOpen, NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Every window the user can return to.
    static var windows: [NSWindow] {
        ToolWindow.windows + [settingsWindow].compactMap { $0 }.filter { $0.isVisible || $0.isMiniaturized }
    }

    static func bringBack(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Bottom bar shared by tool windows: file count, Cancel and the main action.
struct ToolFooter: View {
    let fileCount: Int
    let actionTitle: String
    var actionDisabled = false
    let cancel: () -> Void
    let action: () -> Void

    var body: some View {
        HStack {
            Text(WheelView.filesLabel(fileCount))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Отмена", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(actionDisabled)
        }
    }
}
