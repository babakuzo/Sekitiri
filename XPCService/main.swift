import Foundation

private struct UnavailableInferenceJobHandler: InferenceJobHandling {
    func run(
        request: InferenceJobRequest,
        progress: @Sendable @escaping (InferenceJobStatus) async -> Void
    ) async throws -> InferenceJobResponse {
        throw InferenceWorkerFailure(
            kind: .unavailable,
            message: "The out-of-process model adapter has not been linked into this build.",
            retryInProcess: true
        )
    }

    func unloadModels() async throws {}
}

let service = InferenceWorkerService(
    handler: UnavailableInferenceJobHandler(),
    serviceVersion: "1.0-boundary"
)
let delegate = InferenceWorkerListener(exportedObject: service)
withExtendedLifetime(delegate) {
    NSXPCListener.service().resume()
}
