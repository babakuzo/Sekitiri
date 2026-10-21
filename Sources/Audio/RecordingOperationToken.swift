import Foundation

/// Cooperative cancellation shared by the session and both Core Audio
/// recorders. Core Audio setup calls themselves are synchronous, but every
/// acquired resource is followed by a cancellation check and rollback. This
/// guarantees that a cancelled start can never finish as an active recording.
final class RecordingOperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}

