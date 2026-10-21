import Foundation
import SekitiriInferenceXPCShared

public protocol InferenceJobHandling: Sendable {
    func run(
        request: InferenceJobRequest,
        progress: @Sendable @escaping (InferenceJobStatus) async -> Void
    ) async throws -> InferenceJobResponse
    func unloadModels() async throws
}

private final class XPCReplyBox: @unchecked Sendable {
    let reply: (Data?, Data?) -> Void
    init(_ reply: @escaping (Data?, Data?) -> Void) { self.reply = reply }
}

private actor InferenceJobRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var statuses: [UUID: InferenceJobStatus] = [:]

    func start(
        request: InferenceJobRequest,
        handler: any InferenceJobHandling,
        reply: XPCReplyBox
    ) {
        guard tasks[request.requestID] == nil else {
            Self.fail(reply, .init(kind: .invalidRequest, message: "This request is already running.", retryInProcess: false))
            return
        }
        statuses[request.requestID] = .init(requestID: request.requestID, phase: .queued)
        tasks[request.requestID] = Task {
            do {
                let response = try await handler.run(request: request) { status in
                    await self.update(status)
                }
                try Task.checkCancellation()
                await update(.init(requestID: request.requestID, phase: .completed, fractionCompleted: 1))
                reply.reply(try InferenceXPCCodec.encode(response), nil)
            } catch is CancellationError {
                await update(.init(requestID: request.requestID, phase: .cancelled))
                Self.fail(reply, .init(kind: .cancelled, message: "Inference was cancelled.", retryInProcess: false))
            } catch let failure as InferenceWorkerFailure {
                await update(.init(requestID: request.requestID, phase: .failed, message: failure.message))
                Self.fail(reply, failure)
            } catch {
                await update(.init(requestID: request.requestID, phase: .failed, message: error.localizedDescription))
                Self.fail(reply, .init(kind: .inferenceFailed, message: error.localizedDescription, retryInProcess: false))
            }
            await finish(request.requestID)
        }
    }

    func status(_ requestID: UUID) -> InferenceJobStatus? { statuses[requestID] }
    func activeCount() -> Int { tasks.count }

    func cancel(_ requestID: UUID) {
        tasks[requestID]?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    private func update(_ status: InferenceJobStatus) {
        statuses[status.requestID] = status
    }

    private func finish(_ requestID: UUID) {
        tasks[requestID] = nil
        if statuses.count > 64 {
            let active = Set(tasks.keys)
            statuses = statuses.filter { active.contains($0.key) }
        }
    }

    private nonisolated static func fail(_ box: XPCReplyBox, _ failure: InferenceWorkerFailure) {
        box.reply(nil, try? InferenceXPCCodec.encode(failure))
    }
}

/// Exported XPC object. Model ownership belongs exclusively to the injected
/// handler, allowing the service process to release all inference memory when
/// it exits while the recording/UI process remains alive.
public final class InferenceWorkerService: NSObject, SekitiriInferenceXPCProtocol {
    private let handler: any InferenceJobHandling
    private let registry = InferenceJobRegistry()
    private let serviceVersion: String

    public init(handler: any InferenceJobHandling, serviceVersion: String) {
        self.handler = handler
        self.serviceVersion = serviceVersion
        super.init()
    }

    public func perform(_ requestData: Data, withReply reply: @escaping (Data?, Data?) -> Void) {
        let box = XPCReplyBox(reply)
        do {
            let request = try InferenceXPCCodec.decode(InferenceJobRequest.self, from: requestData)
            guard request.schemaVersion == InferenceXPCSchema.current else {
                return Self.fail(box, .init(kind: .unsupportedSchema, message: "Unsupported inference message version.", retryInProcess: true))
            }
            try Self.validatePaths(in: request)
            Task { await registry.start(request: request, handler: handler, reply: box) }
        } catch let failure as InferenceWorkerFailure {
            Self.fail(box, failure)
        } catch {
            Self.fail(box, .init(kind: .invalidRequest, message: "The inference request could not be decoded.", retryInProcess: false))
        }
    }

    public func status(_ requestID: String, withReply reply: @escaping (Data?, Data?) -> Void) {
        let box = XPCReplyBox(reply)
        guard let id = UUID(uuidString: requestID) else {
            return Self.fail(box, .init(kind: .invalidRequest, message: "Invalid request identifier.", retryInProcess: false))
        }
        Task {
            guard let status = await registry.status(id) else {
                return Self.fail(box, .init(kind: .invalidRequest, message: "Unknown inference request.", retryInProcess: false))
            }
            box.reply(try? InferenceXPCCodec.encode(status), nil)
        }
    }

    public func cancel(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        Task { await registry.cancel(id) }
    }

    public func healthCheck(withReply reply: @escaping (Data?, Data?) -> Void) {
        let box = XPCReplyBox(reply)
        Task {
            let health = InferenceWorkerHealth(
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                activeJobs: await registry.activeCount(),
                serviceVersion: serviceVersion
            )
            box.reply(try? InferenceXPCCodec.encode(health), nil)
        }
    }

    public func unloadModels(withReply reply: @escaping (Data?) -> Void) {
        let replyBox = XPCReplyBox { _, failure in reply(failure) }
        Task {
            await registry.cancelAll()
            do {
                try await handler.unloadModels()
                replyBox.reply(nil, nil)
            } catch {
                Self.fail(replyBox, .init(kind: .internalFailure, message: error.localizedDescription, retryInProcess: true))
            }
        }
    }

    private static func validatePaths(in request: InferenceJobRequest) throws {
        let session = URL(fileURLWithPath: request.sessionDirectory).standardizedFileURL
        let staging = URL(fileURLWithPath: request.stagingDirectory).standardizedFileURL
        guard session.isFileURL, staging.isFileURL,
              staging.path.hasPrefix(session.path + "/") else {
            throw InferenceWorkerFailure(kind: .unsafePath, message: "The staging folder must be inside the meeting folder.", retryInProcess: false)
        }
        for path in request.inputFiles {
            let input = URL(fileURLWithPath: path).standardizedFileURL
            guard input.path.hasPrefix(session.path + "/") else {
                throw InferenceWorkerFailure(kind: .unsafePath, message: "An inference input is outside the meeting folder.", retryInProcess: false)
            }
        }
    }

    private static func fail(_ box: XPCReplyBox, _ failure: InferenceWorkerFailure) {
        box.reply(nil, try? InferenceXPCCodec.encode(failure))
    }
}
