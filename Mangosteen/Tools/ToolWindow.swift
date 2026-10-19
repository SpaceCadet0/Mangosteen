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
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = controller
        window.center()
        controller.window = window
        openWindows.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
