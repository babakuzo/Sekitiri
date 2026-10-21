import Foundation
import Testing
@testable import SekitiriInferenceXPCClient
@testable import SekitiriInferenceXPCShared

private actor FakeTransport: InferenceWorkerTransport {
    enum Mode { case success, unavailable, modelFailure }
    let mode: Mode
    private(set) var cancelled: [UUID] = []

    init(mode: Mode) { self.mode = mode }

    func perform(_ request: InferenceJobRequest) async throws -> InferenceJobResponse {
        switch mode {
        case .success: return .init(requestID: request.requestID, artifacts: [])
        case .unavailable: throw InferenceWorkerClientError.unavailable("test")
        case .modelFailure:
            throw InferenceWorkerClientError.worker(.init(kind: .inferenceFailed, message: "bad model", retryInProcess: false))
        }
    }

    func status(for requestID: UUID) async throws -> InferenceJobStatus { .init(requestID: requestID, phase: .processing) }
    func cancel(_ requestID: UUID) async { cancelled.append(requestID) }
    func health() async throws -> InferenceWorkerHealth { .init(processIdentifier: 1, activeJobs: 0, serviceVersion: "test") }
    func unloadModels() async throws {}
    func invalidate() async {}
}

private func request() -> InferenceJobRequest {
    let session = URL(fileURLWithPath: "/tmp/meeting")
    return .init(
        kind: .summarize,
        sessionDirectory: session,
        inputFiles: [session.appendingPathComponent("transcript.md")],
        stagingDirectory: session.appendingPathComponent(".inference-staging")
    )
}

@Test func messagesRoundTripWithoutLosingIdentity() throws {
    let original = request()
    let data = try InferenceXPCCodec.encode(original)
    #expect(try InferenceXPCCodec.decode(InferenceJobRequest.self, from: data) == original)
}

@Test func unavailableWorkerUsesInProcessFallback() async throws {
    let job = request()
    let client = InferenceWorkerClient(transport: FakeTransport(mode: .unavailable))
    let response = try await client.perform(job) { request in
        .init(requestID: request.requestID, artifacts: [], metadata: ["execution": "in-process"])
    }
    #expect(response.metadata["execution"] == "in-process")
}

@Test func modelFailureDoesNotRepeatInferenceInProcess() async {
    let job = request()
    let client = InferenceWorkerClient(transport: FakeTransport(mode: .modelFailure))
    var fallbackRan = false
    do {
        _ = try await client.perform(job) { request in
            fallbackRan = true
            return .init(requestID: request.requestID, artifacts: [])
        }
        Issue.record("Expected the worker failure to escape")
    } catch {
        #expect(fallbackRan == false)
    }
}
