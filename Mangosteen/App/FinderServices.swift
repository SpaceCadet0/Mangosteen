import AppKit

/// Finder Quick Actions: right-click files → Services → "Mangosteen: Convert… / Tools… / Actions…" opens that wheel
/// at the pointer for the selected files. The services are declared in App/Info.plist.
final class FinderServices: NSObject {
    private let open: (WheelKind, [URL]) -> Void

    init(open: @escaping (WheelKind, [URL]) -> Void) {
        self.open = open
    }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(.convert, pasteboard)
    }

    @objc func toolsFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(.tools, pasteboard)
    }

    @objc func actionsFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(.actions, pasteboard)
    }

    private func handle(_ kind: WheelKind, _ pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { [open] in open(kind, urls) }
    }
}
