import Foundation

/// Shared between a running job and the UI that can stop it. Thread-safe.
final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let toRun: [() -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            defer { handlers.removeAll() }
            return handlers
        }
        toRun.forEach { $0() }
    }

    /// Runs `handler` on cancellation, or immediately if already cancelled.
    func onCancel(_ handler: @escaping () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            handlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
