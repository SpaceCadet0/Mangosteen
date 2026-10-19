import AppKit

/// A small floating panel in the top-right corner that shows progress of running jobs.
/// It appears only when work takes longer than `showDelay`, so quick conversions stay silent.
final class ProgressHUD {
    static let shared = ProgressHUD()

    private struct Job {
        var title: String
        var total: Int
        var done = 0
        /// Progress of files still running, by index; -1 marks a finished file.
        var partial: [Int: Double] = [:]
        var cancel: (() -> Void)?
    }

    private let showDelay: TimeInterval = 0.5
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private let cancelButton = NSButton()
    private var jobs: [UUID: Job] = [:]
    private var pendingShow: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let background = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Остановить"))
        cancelButton.isBordered = false
        cancelButton.toolTip = String(localized: "Остановить")
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let stack = NSStackView(views: [titleLabel, indicator, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        background.addSubview(cancelButton)
        // The text column takes all the width left of the Stop button, so the bar spans the panel.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            cancelButton.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 18),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        panel.contentView = background
    }

    #if DEBUG
    var debugWindow: NSWindow { panel }
    #endif

    // All methods are called on the main thread.

    func begin(_ title: String, total: Int, cancel: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        jobs[id] = Job(title: title, total: max(total, 1), cancel: cancel)
        if !panel.isVisible, pendingShow == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingShow = nil
                self?.present()
            }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
        }
        refresh()
        return id
    }

    func update(_ id: UUID, item: Int, fraction: Double) {
        // A late progress update must not resurrect a finished file.
        guard jobs[id] != nil, jobs[id]?.partial[item] != -1 else { return }
        jobs[id]?.partial[item] = fraction
        refresh()
    }

    func step(_ id: UUID, item: Int? = nil) {
        guard jobs[id] != nil else { return }
        jobs[id]?.done += 1
        if let item { jobs[id]?.partial[item] = -1 }
        refresh()
    }

    func end(_ id: UUID) {
        jobs[id] = nil
        guard jobs.isEmpty else {
            refresh()
            return
        }
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
    }

    @objc private func cancelTapped() {
        for id in jobs.keys where jobs[id]?.cancel != nil {
            jobs[id]?.cancel?()
            jobs[id]?.title = String(localized: "Останавливаю…")
        }
        refresh()
    }

    private func present() {
        guard !jobs.isEmpty, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - panel.frame.height - 16))
        refresh()
        panel.orderFrontRegardless()
    }

    private func refresh() {
        let total = jobs.values.reduce(0) { $0 + $1.total }
        let done = jobs.values.reduce(0) { $0 + $1.done }
        let running = jobs.values.reduce(0.0) { sum, job in sum + job.partial.values.filter { $0 >= 0 }.reduce(0, +) }
        let fraction = total == 0 ? 0 : min((Double(done) + running) / Double(total), 1)
        titleLabel.stringValue = jobs.count == 1 ? (jobs.values.first?.title ?? "") : String(localized: "Задач: \(jobs.count)")
        detailLabel.stringValue = String(localized: "\(done) из \(total) · \(Int((fraction * 100).rounded()))%")
        indicator.doubleValue = fraction
        // Hidden, not removed, so the bar keeps its length.
        cancelButton.alphaValue = jobs.values.contains { $0.cancel != nil } ? 1 : 0
        cancelButton.isEnabled = cancelButton.alphaValue > 0
    }
}
