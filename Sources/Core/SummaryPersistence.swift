import Foundation

enum SummaryDocumentStore {
    // Serializes short local file transactions only; model inference never holds
    // this lock. Recursive because migration/save reuse the same read helpers.
    private static let lock = NSRecursiveLock()
    static let canonicalFilename = "summary.json"
    static let legacyFilename = "summary.md"

    enum StoreError: LocalizedError {
        case unsupportedSchema(Int)
        case missingSummary
        case missingAction
        case sourceChanged

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This meeting uses summary schema version \(version), which this version of Sekitiri cannot open."
            case .missingSummary:
                return "No summary.json or summary.md was found for this meeting."
            case .missingAction:
                return "This action changed when the summary was updated. Reopen the meeting and try again."
            case .sourceChanged:
                return "The transcript or additional notes changed while the summary was being generated. Your previous summary is unchanged. Generate the summary again."
            }
        }
    }

    static func load(from meetingFolder: URL) throws -> CanonicalSummaryDocument? {
        lock.lock(); defer { lock.unlock() }
        let url = meetingFolder.appendingPathComponent(canonicalFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CanonicalSummaryDocument.self, from: Data(contentsOf: url))
        guard document.schemaVersion <= CanonicalSummaryDocument.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    static func loadOrMigrateIfPresent(from meetingFolder: URL, transcript: String) throws -> CanonicalSummaryDocument? {
        guard FileManager.default.fileExists(atPath: meetingFolder.appendingPathComponent(canonicalFilename).path)
            || FileManager.default.fileExists(atPath: meetingFolder.appendingPathComponent(legacyFilename).path) else { return nil }
        return try loadOrMigrate(from: meetingFolder, transcript: transcript)
    }

    /// Loads canonical JSON or performs a one-time, non-destructive migration
    /// from `summary.md`. The legacy file is intentionally left byte-for-byte
    /// unchanged so old app builds and exports continue to work.
    static func loadOrMigrate(
        from meetingFolder: URL,
        transcript: String,
        legacyModelID: String = "legacy-markdown",
        legacyTone: String = "Unknown",
        migratedAt: Date = Date()
    ) throws -> CanonicalSummaryDocument {
        lock.lock(); defer { lock.unlock() }
        if let existing = try load(from: meetingFolder) { return existing }
        let markdownURL = meetingFolder.appendingPathComponent(legacyFilename)
        guard FileManager.default.fileExists(atPath: markdownURL.path) else { throw StoreError.missingSummary }
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let document = CanonicalSummaryBuilder.build(
            markdown: markdown,
            transcript: transcript,
            modelID: legacyModelID,
            tone: legacyTone,
            generatedAt: migratedAt
        )
        try writeJSON(document, to: meetingFolder)
        return document
    }

    /// Persists canonical JSON atomically. When requested, `summary.md` is
    /// regenerated as a compatibility view after the JSON write succeeds.
    static func save(
        _ document: CanonicalSummaryDocument,
        to meetingFolder: URL,
        updateLegacyMarkdown: Bool = true,
        metadataPrefix: String? = nil
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
        try writeJSON(document, to: meetingFolder)
        if updateLegacyMarkdown {
            let legacyURL = meetingFolder.appendingPathComponent(legacyFilename)
            let existing = (try? String(contentsOf: legacyURL, encoding: .utf8)) ?? ""
            let markdown = (metadataPrefix ?? self.metadataPrefix(in: existing)) + CanonicalSummaryBuilder.markdown(from: document) + "\n"
            try markdown.write(
                to: meetingFolder.appendingPathComponent(legacyFilename),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Reloads the latest document before changing one action, so a view's old
    /// snapshot can never overwrite a regenerated summary or another edit.
    static func toggleAction(id: String, in meetingFolder: URL, transcript: String) throws -> CanonicalSummaryDocument {
        lock.lock(); defer { lock.unlock() }
        var document = try loadOrMigrate(from: meetingFolder, transcript: transcript)
        guard let index = document.actionItems.firstIndex(where: { $0.id == id }) else { throw StoreError.missingAction }
        document.actionItems[index].isCompleted.toggle()
        try save(document, to: meetingFolder)
        return document
    }

    /// Reconciliation and both compatibility writes share a transaction with
    /// action edits. A completion saved during inference is read at commit time.
    @discardableResult
    static func commitReplacement(
        _ draft: CanonicalSummaryDocument,
        to meetingFolder: URL,
        transcript: String,
        metadataPrefix: String,
        validateSource: (() throws -> Void)? = nil
    ) throws -> CanonicalSummaryDocument {
        lock.lock(); defer { lock.unlock() }
        try validateSource?()
        let previous = try loadOrMigrateIfPresent(from: meetingFolder, transcript: transcript)
        let document = replacement(document: draft, previous: previous)
        try save(document, to: meetingFolder, metadataPrefix: metadataPrefix)
        return document
    }

    static func verifySourceSnapshot(expected: String, current: String) throws {
        guard expected == current else { throw StoreError.sourceChanged }
    }

    /// Builds a replacement summary while carrying forward stable action IDs
    /// and completion state from the previous canonical document.
    static func replacement(document: CanonicalSummaryDocument, previous: CanonicalSummaryDocument?) -> CanonicalSummaryDocument {
        CanonicalSummaryBuilder.reconcile(document, previous: previous)
    }

    static func replacement(
        markdown: String,
        transcript: String,
        modelID: String,
        tone: String,
        generatedAt: Date = Date(),
        previous: CanonicalSummaryDocument?
    ) -> CanonicalSummaryDocument {
        CanonicalSummaryBuilder.build(
            markdown: markdown,
            transcript: transcript,
            modelID: modelID,
            tone: tone,
            generatedAt: generatedAt,
            previous: previous
        )
    }

    static func metadataPrefix(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard let section = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }) else { return "" }
        return lines[..<section].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
    }

    private static func writeJSON(_ document: CanonicalSummaryDocument, to meetingFolder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: meetingFolder.appendingPathComponent(canonicalFilename), options: .atomic)
    }
}
