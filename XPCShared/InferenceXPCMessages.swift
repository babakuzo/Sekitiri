import Foundation

/// Versioned, Foundation-only messages shared by the app and its embedded
/// inference service. Large audio/transcript payloads stay on disk; XPC only
/// carries paths, parameters, progress, and artifact manifests.
public enum InferenceXPCSchema {
    public static let current = 1
    public static let serviceName = "local.sekitiri.InferenceService"
}

public enum InferenceJobKind: String, Codable, Sendable {
    case transcribe
    case diarize
    case summarize
    case warmUp
}

public struct InferenceJobRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let kind: InferenceJobKind
    public let sessionDirectory: String
    public let inputFiles: [String]
    public let stagingDirectory: String
    public let parameters: [String: String]

    public init(
        requestID: UUID = UUID(),
        kind: InferenceJobKind,
        sessionDirectory: URL,
        inputFiles: [URL],
        stagingDirectory: URL,
        parameters: [String: String] = [:]
    ) {
        self.schemaVersion = InferenceXPCSchema.current
        self.requestID = requestID
        self.kind = kind
        self.sessionDirectory = sessionDirectory.standardizedFileURL.path
        self.inputFiles = inputFiles.map { $0.standardizedFileURL.path }
        self.stagingDirectory = stagingDirectory.standardizedFileURL.path
        self.parameters = parameters
    }
}

public struct InferenceArtifact: Codable, Sendable, Equatable {
    public let role: String
    public let path: String
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String?

    public init(role: String, path: String, contentType: String, byteCount: Int64, sha256: String? = nil) {
        self.role = role
        self.path = path
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct InferenceJobResponse: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let artifacts: [InferenceArtifact]
    public let metadata: [String: String]

    public init(requestID: UUID, artifacts: [InferenceArtifact], metadata: [String: String] = [:]) {
        self.schemaVersion = InferenceXPCSchema.current
        self.requestID = requestID
        self.artifacts = artifacts
        self.metadata = metadata
    }
}

public enum InferenceJobPhase: String, Codable, Sendable {
    case queued
    case loadingModel
    case processing
    case saving
    case completed
    case cancelled
    case failed
}

public struct InferenceJobStatus: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let phase: InferenceJobPhase
    public let fractionCompleted: Double?
    public let message: String?

    public init(requestID: UUID, phase: InferenceJobPhase, fractionCompleted: Double? = nil, message: String? = nil) {
        self.schemaVersion = InferenceXPCSchema.current
        self.requestID = requestID
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
        self.message = message
    }
}

public struct InferenceWorkerHealth: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let processIdentifier: Int32
    public let activeJobs: Int
    public let serviceVersion: String

    public init(processIdentifier: Int32, activeJobs: Int, serviceVersion: String) {
        self.schemaVersion = InferenceXPCSchema.current
        self.processIdentifier = processIdentifier
        self.activeJobs = activeJobs
        self.serviceVersion = serviceVersion
    }
}

public enum InferenceWorkerFailureKind: String, Codable, Sendable {
    case unavailable
    case invalidRequest
    case unsupportedSchema
    case cancelled
    case timedOut
    case inferenceFailed
    case unsafePath
    case internalFailure
}

public struct InferenceWorkerFailure: Codable, Sendable, Error, Equatable {
    public let schemaVersion: Int
    public let kind: InferenceWorkerFailureKind
    public let message: String
    public let retryInProcess: Bool

    public init(kind: InferenceWorkerFailureKind, message: String, retryInProcess: Bool) {
        self.schemaVersion = InferenceXPCSchema.current
        self.kind = kind
        self.message = message
        self.retryInProcess = retryInProcess
    }
}

public enum InferenceXPCCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
