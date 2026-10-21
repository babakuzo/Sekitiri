import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

/// Extractive source notes do not load or invoke a language model.
struct NativeSourceNotesEngine: NativeSummarizationEngine, Sendable {
    let name = "source-notes"

    func summarize(
        transcript: String,
        prompt: String,
        tone: String,
        progress: @MainActor @Sendable @escaping (SummaryProgress) -> Void
    ) async throws -> SummaryGenerationResult {
        let outcome = try await SourceSelectionSummary.run(
            transcript: transcript, modelID: name, tone: tone,
            maxCharacters: 4_000, sourceOnly: true, progress: progress
        ) { _, _, _ in
            throw MeetingNotesService.ServiceError.failed("Lightweight source notes cannot invoke a language model.")
        }
        return SummaryGenerationResult(
            text: CanonicalSummaryBuilder.markdown(from: outcome.document),
            modelID: outcome.document.modelID, inputTokens: 0,
            passCount: outcome.passCount, document: outcome.document
        )
    }
}

struct NativeAFMEngine: NativeSummarizationEngine {
    let name = "afm"

    func summarize(
        transcript: String,
        prompt: String,
        tone: String,
        progress: @MainActor @Sendable @escaping (SummaryProgress) -> Void
    ) async throws -> SummaryGenerationResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw MeetingNotesService.ServiceError.failed("Apple Intelligence requires macOS 26 or later.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw MeetingNotesService.ServiceError.failed("Apple Intelligence is unavailable on this Mac. Choose a downloaded Qwen model in Settings.")
        }
        let inputTokens = try await tokenCount(model: model, text: transcript)
        let outcome = try await SourceSelectionSummary.run(
            transcript: transcript, modelID: "com.apple.system-language-model.default", tone: tone,
            maxCharacters: 2_400, progress: progress
        ) { instructions, input, maxTokens in
            let request = "Extract records from these labeled transcript sources:\n\n" + input
            let count = try await tokenCount(model: model, text: instructions + "\n" + request)
            guard count + maxTokens + 250 <= model.contextSize else {
                throw MeetingNotesService.ServiceError.failed("This transcript passage exceeds Apple Intelligence's context window.")
            }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens)
            // Schema-constrained decoding enforces complete, correctly typed
            // JSON. Source IDs and quotations still pass normal validation.
            if instructions == StructuredSummaryPipeline.reconciliationInstructions {
                let response = try await session.respond(
                    to: request, generating: AFMSupersessionEnvelope.self,
                    includeSchemaInPrompt: false, options: options
                )
                return response.rawContent.jsonString
            }
            if instructions == SourceSelectionSummary.instructions {
                let response = try await session.respond(to: request, generating: AFMSourceSelection.self, includeSchemaInPrompt: false, options: options)
                return response.rawContent.jsonString
            }
            let response = try await session.respond(
                to: request, generating: AFMExtractionEnvelope.self,
                includeSchemaInPrompt: false, options: options
            )
            return response.rawContent.jsonString
        }
        return SummaryGenerationResult(
            text: CanonicalSummaryBuilder.markdown(from: outcome.document),
            modelID: outcome.document.modelID, inputTokens: max(1, inputTokens),
            passCount: outcome.passCount, document: outcome.document
        )
        #else
        throw MeetingNotesService.ServiceError.failed("Apple Intelligence requires macOS 26 or later.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func tokenCount(model: SystemLanguageModel, text: String) async throws -> Int {
        if #available(macOS 26.4, *) { return try await model.tokenCount(for: text) }
        return max(1, text.utf8.count / 3)
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct AFMSourceSelection {
    var decisions: [String]
    var actions: [String]
    var facts: [String]
    var proposals: [String]
    var unresolved: [String]
    var corrections: [String]
}

@available(macOS 26.0, *)
@Generable
private struct AFMExtractionEnvelope {
    @Guide(description: "Every distinct evidenced decision, commitment, fact, proposal, question, risk or explicit correction. Empty if no useful evidence.", .maximumCount(24))
    var records: [AFMExtractionRecord]
}

@available(macOS 26.0, *)
@Generable
private struct AFMExtractionRecord {
    @Guide(description: "One exact category. Suggestions are proposals; withdrawn commitments are corrections, not new actions.", .anyOf(["decision", "action", "fact", "proposal", "question", "risk", "correction"]))
    var type: String
    @Guide(description: "A concise complete statement preserving negation, uncertainty and language.")
    var text: String
    @Guide(description: "The exact S-number label of the single supporting source.")
    var source: String
    @Guide(description: "Verbatim supporting words copied from that source, at least eight characters.")
    var quote: String
    @Guide(description: "Only for actions: the explicitly stated assignee, or exact speaker label for their own volunteered commitment. Otherwise nil.")
    var owner: String?
    @Guide(description: "Only for actions: the exact deadline phrase copied from the quote. Otherwise nil.")
    var due: String?
}

@available(macOS 26.0, *)
@Generable
private struct AFMSupersessionEnvelope {
    @Guide(description: "Only explicitly superseded earlier record IDs paired with their later correction IDs. Empty if none.", .maximumCount(32))
    var superseded: [AFMSupersession]
}

@available(macOS 26.0, *)
@Generable
private struct AFMSupersession {
    @Guide(description: "Exact R-number ID from earlier records.")
    var record: String
    @Guide(description: "Exact R-number ID of the later correction cancelling or replacing the same record.")
    var by: String
}
#endif

struct NativeMLXEngine: NativeSummarizationEngine, Sendable {
    let model: LocalSummaryModel
    var name: String { model.engineID }

    init(model: LocalSummaryModel = .qwen2B) { self.model = model }

    func summarize(
        transcript: String,
        prompt: String,
        tone: String,
        progress: @MainActor @Sendable @escaping (SummaryProgress) -> Void
    ) async throws -> SummaryGenerationResult {
        #if canImport(MLXLLM)
        await progress(.loadingModel)
        return try await LocalSummaryRuntime.shared.withContainer(model: model) { container in
            try Task.checkCancellation()
            let inputTokens = await container.encode(transcript).count
            let outcome = try await SourceSelectionSummary.run(
                transcript: transcript, modelID: model.modelID, tone: tone,
                maxCharacters: 4_000, progress: progress
            ) { instructions, input, maxTokens in
                try await LocalGenerationDeadline.run {
                    try await generate(container: container, instructions: instructions, input: input, maxTokens: maxTokens)
                }
            }
            return SummaryGenerationResult(
                text: CanonicalSummaryBuilder.markdown(from: outcome.document),
                modelID: model.modelID, inputTokens: inputTokens,
                passCount: outcome.passCount, document: outcome.document
            )
        }
        #else
        throw MeetingNotesService.ServiceError.failed("MLX summary models are unavailable in this build.")
        #endif
    }

    #if canImport(MLXLLM)
    private func generate(
        container: ModelContainer,
        instructions: String,
        input: String,
        maxTokens: Int
    ) async throws -> String {
        let request = "Extract records from these labeled transcript sources:\n\n" + input
        let sourceTokens = await container.encode(instructions + "\n" + request).count
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: min(8_192, max(2_048, sourceTokens + maxTokens + 256)),
            kvBits: 8,
            temperature: 0,
            repetitionPenalty: 1.0,
            prefillStepSize: 512
        )
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        var response = ""
        do {
            for try await text in session.streamResponse(to: request) {
                try Task.checkCancellation()
                response += text
            }
        } catch {
            // The stream's producer is an unstructured task. Ending iteration
            // cancels it, but its GPU work may still own KV buffers. Wait for
            // the session lock before allowing the runtime lease to release.
            await session.synchronize()
            await session.clear()
            throw error
        }
        await session.synchronize()
        await session.clear()
        try Task.checkCancellation()
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
