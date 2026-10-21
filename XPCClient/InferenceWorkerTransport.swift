import Foundation
import SekitiriInferenceXPCShared

public protocol InferenceWorkerTransport: Sendable {
    func perform(_ request: InferenceJobRequest) async throws -> InferenceJobResponse
    func status(for requestID: UUID) async throws -> InferenceJobStatus
    func cancel(_ requestID: UUID) async
    func health() async throws -> InferenceWorkerHealth
    func unloadModels() async throws
    func invalidate() async
}

public enum InferenceWorkerClientError: LocalizedError, Sendable {
    case unavailable(String)
    case invalidReply
    case timedOut
    case worker(InferenceWorkerFailure)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return "The local inference helper is unavailable: \(message)"
        case .invalidReply: return "The local inference helper returned an invalid response."
        case .timedOut: return "The local inference helper did not finish in time."
        case .worker(let failure): return failure.message
        }
    }

    public var permitsInProcessFallback: Bool {
        switch self {
        case .unavailable, .timedOut, .invalidReply: return true
        case .worker(let failure): return failure.retryInProcess
        }
    }
}

public actor InferenceWorkerClient {
    public typealias Fallback = @Sendable (InferenceJobRequest) async throws -> InferenceJobResponse

    private let transport: any InferenceWorkerTransport

    public init(transport: any InferenceWorkerTransport = NSXPCInferenceWorkerTransport()) {
        self.transport = transport
    }

    /// Runs out of process and falls back only for infrastructure failures.
    /// A model/prompt failure is returned to the UI instead of silently doing
    /// the expensive work twice in the main application.
    public func perform(
        _ request: InferenceJobRequest,
        timeout: Duration = .seconds(1_800),
        fallback: Fallback
    ) async throws -> InferenceJobResponse {
        do {
            return try await withThrowingTaskGroup(of: InferenceJobResponse.self) { group in
                group.addTask { try await self.transport.perform(request) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw InferenceWorkerClientError.timedOut
                }
                guard let first = try await group.next() else {
                    throw InferenceWorkerClientError.unavailable("No worker result was returned.")
                }
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            await transport.cancel(request.requestID)
            throw CancellationError()
        } catch let error as InferenceWorkerClientError where error.permitsInProcessFallback {
            await transport.cancel(request.requestID)
            return try await fallback(request)
        } catch {
            throw error
        }
    }

    public func status(for requestID: UUID) async throws -> InferenceJobStatus {
        try await transport.status(for: requestID)
    }

    public func health() async throws -> InferenceWorkerHealth {
        try await transport.health()
    }

    public func unloadModels() async throws {
        try await transport.unloadModels()
    }

    public func invalidate() async {
        await transport.invalidate()
    }
}
