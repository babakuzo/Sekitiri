import Foundation
import Testing
@testable import SekitiriApp

@Suite("Meeting renaming, moments and action filtering")
struct MeetingEditingTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sekitiri-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(url: URL, source: URL? = nil) -> MeetingItem {
        MeetingItem(id: url.lastPathComponent, url: url, title: "Untitled meeting", engine: "", durationSeconds: nil,
                    date: nil, participants: [], sourceSession: source, status: .transcriptReady, excerpt: "", searchText: "")
    }

    private func meta(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
    }

    @Test("Rename writes title_override and keeps other metadata; empty restores")
    func renameRoundTrip() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original: [String: Any] = ["title": "Zoom call", "started": "2026-11-04T09:00:00Z"]
        try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("meta.json"))

        try MeetingLibrary.rename(item(url: folder), to: "  Team Weekly Huddle ")
        var saved = try meta(folder)
        #expect(saved["title_override"] as? String == "Team Weekly Huddle")
        #expect(saved["title"] as? String == "Zoom call")
        #expect(saved["started"] as? String == "2026-11-04T09:00:00Z")

        try MeetingLibrary.rename(item(url: folder), to: "")
        saved = try meta(folder)
        #expect(saved["title_override"] == nil)
    }

    @Test("Rename falls back to the capture folder's metadata")
    func renameUsesSourceSession() throws {
        let vault = try temporaryFolder()
        let capture = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: capture)
        }
        try JSONSerialization.data(withJSONObject: ["title": "Old"]).write(to: capture.appendingPathComponent("meta.json"))
        try MeetingLibrary.rename(item(url: vault, source: capture), to: "Planning")
        #expect(try meta(capture)["title_override"] as? String == "Planning")
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("meta.json").path))
    }

    @Test("Rename without any metadata file fails instead of creating one")
    func renameNeedsMetadata() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: MeetingLibrary.RenameError.self) {
            try MeetingLibrary.rename(item(url: folder), to: "Anything")
        }
    }

    @Test("Marked moments survive a save and load")
    func momentsRoundTrip() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let moments = [MarkedMoment(seconds: 750, label: "Decision on hiring order"),
                       MarkedMoment(seconds: 1361.5, label: "Budget review moved")]
        MarkedMoment.save(moments, in: folder)
        #expect(MarkedMoment.load(from: folder) == moments)
        #expect(MarkedMoment.load(from: nil).isEmpty)
        #expect(MarkedMoment.load(from: folder.appendingPathComponent("missing")).isEmpty)
    }

    @Test("Placeholder action text is recognised, real actions are not")
    func placeholderActions() {
        for text in ["None.", "none", " N/A ", "No action items.", ""] {
            #expect(OpenActionItem.isPlaceholder(text), "\(text)")
        }
        for text in ["None of the slides are ready; Ada fixes them", "Send the roadmap"] {
            #expect(!OpenActionItem.isPlaceholder(text), "\(text)")
        }
    }
}
