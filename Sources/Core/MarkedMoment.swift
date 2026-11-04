import Foundation

/// A point the user marked while recording, stored as moments.json in the
/// capture folder next to the audio.
struct MarkedMoment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Seconds into the recording, excluding pauses.
    var seconds: TimeInterval
    var label: String

    static let filename = "moments.json"

    static func save(_ moments: [MarkedMoment], in directory: URL) {
        guard let data = try? JSONEncoder().encode(moments) else { return }
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    static func load(from directory: URL?) -> [MarkedMoment] {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else { return [] }
        return (try? JSONDecoder().decode([MarkedMoment].self, from: data)) ?? []
    }
}

struct AppToast: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}
