import AppKit
import SwiftUI

/// Hosts a tool's SwiftUI view in its own window and keeps it alive until closed.
final class ToolWindow: NSObject, NSWindowDelegate {
    private static var openWindows: Set<ToolWindow> = []

    private var window: NSWindow?

    /// `content` receives a closure that closes the window.
    static func present<Content: View>(title: String, @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        let controller = ToolWindow()
        let view = content { [weak controller] in controller?.window?.close() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = controller
        // Size to the SwiftUI content before positioning; centring first lets the window grow off-screen.
        window.setContentSize(hosting.view.fittingSize)
        fitOnScreen(window)
        controller.window = window
        openWindows.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI may settle on its final size after the first layout pass.
        DispatchQueue.main.async { fitOnScreen(window) }
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
        Self.openWindows.remove(self)
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
