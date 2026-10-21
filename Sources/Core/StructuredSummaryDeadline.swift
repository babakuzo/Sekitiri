import Foundation

/// A deadline cancels the generation task and joins its cleanup. It never
/// returns while the losing inference task still owns GPU buffers.
enum LocalGenerationDeadline {
    struct Exceeded: LocalizedError, Sendable {
        var errorDescription: String? {
            "The local model took too long to respond. Your transcript and previous notes are safe. Try another local model."
        }
    }

    static func run<Value: Sendable>(
        timeout: Duration = .seconds(120),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                try Task.checkCancellation()
                throw Exceeded()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
