import Foundation
import SekitiriInferenceXPCShared

private final class SendableReply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<T, Error>
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

public actor NSXPCInferenceWorkerTransport: InferenceWorkerTransport {
    private var connection: NSXPCConnection?
    private var invalidationMessage: String?

    public init() {}

    public func perform(_ request: InferenceJobRequest) async throws -> InferenceJobResponse {
        let requestData = try InferenceXPCCodec.encode(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = SendableReply(continuation)
                do {
                    let proxy = try remoteProxy { error in
                        box.resume(throwing: InferenceWorkerClientError.unavailable(error.localizedDescription))
                    }
                    proxy.perform(requestData) { responseData, failureData in
                        Self.resume(box, responseData: responseData, failureData: failureData)
                    }
                } catch {
                    box.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(request.requestID) }
        }
    }

    public func status(for requestID: UUID) async throws -> InferenceJobStatus {
        try await withCheckedThrowingContinuation { continuation in
            let box = SendableReply(continuation)
            do {
                let proxy = try remoteProxy { error in
                    box.resume(throwing: InferenceWorkerClientError.unavailable(error.localizedDescription))
                }
                proxy.status(requestID.uuidString) { statusData, failureData in
                    Self.resume(box, responseData: statusData, failureData: failureData)
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    public func cancel(_ requestID: UUID) async {
        try? remoteProxy { _ in }.cancel(requestID.uuidString)
    }

    public func health() async throws -> InferenceWorkerHealth {
        try await withCheckedThrowingContinuation { continuation in
            let box = SendableReply(continuation)
            do {
                let proxy = try remoteProxy { error in
                    box.resume(throwing: InferenceWorkerClientError.unavailable(error.localizedDescription))
                }
                proxy.healthCheck { healthData, failureData in
                    Self.resume(box, responseData: healthData, failureData: failureData)
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    public func unloadModels() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = SendableReply<Void>(continuation)
            do {
                let proxy = try remoteProxy { error in
                    box.resume(throwing: InferenceWorkerClientError.unavailable(error.localizedDescription))
                }
                proxy.unloadModels { failureData in
                    if let failureData,
                       let failure = try? InferenceXPCCodec.decode(InferenceWorkerFailure.self, from: failureData) {
                        box.resume(throwing: InferenceWorkerClientError.worker(failure))
                    } else if failureData != nil {
                        box.resume(throwing: InferenceWorkerClientError.invalidReply)
                    } else {
                        box.resume(returning: ())
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    public func invalidate() async {
        connection?.invalidate()
        connection = nil
    }

    private func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> SekitiriInferenceXPCProtocol {
        let connection = try activeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { await self?.recordInvalidation(error.localizedDescription) }
            errorHandler(error)
        }) as? SekitiriInferenceXPCProtocol else {
            throw InferenceWorkerClientError.unavailable("Could not create the service proxy.")
        }
        return proxy
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let invalidationMessage {
            self.invalidationMessage = nil
            connection?.invalidate()
            connection = nil
            throw InferenceWorkerClientError.unavailable(invalidationMessage)
        }
        if let connection { return connection }
        let newConnection = NSXPCConnection(serviceName: InferenceXPCSchema.serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: SekitiriInferenceXPCProtocol.self)
        newConnection.interruptionHandler = { [weak self] in
            Task { await self?.recordInvalidation("The inference service was interrupted.") }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { await self?.recordInvalidation("The inference service connection was invalidated.") }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func recordInvalidation(_ message: String) {
        invalidationMessage = message
        connection = nil
    }

    private nonisolated static func resume<T: Decodable>(
        _ box: SendableReply<T>,
        responseData: Data?,
        failureData: Data?
    ) {
        if let failureData,
           let failure = try? InferenceXPCCodec.decode(InferenceWorkerFailure.self, from: failureData) {
            box.resume(throwing: InferenceWorkerClientError.worker(failure))
            return
        }
        guard failureData == nil,
              let responseData,
              let response = try? InferenceXPCCodec.decode(T.self, from: responseData) else {
            box.resume(throwing: InferenceWorkerClientError.invalidReply)
            return
        }
        box.resume(returning: response)
    }
}
