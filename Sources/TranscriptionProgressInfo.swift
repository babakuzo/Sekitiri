import Foundation

/// Presentation snapshot of the work that happens after Stop. The app model
/// derives the coarse stage from the transcription coordinator's status
/// today; `fractionCompleted` and `secondsRemaining` stay nil until the
/// coordinator reports them.
struct TranscriptionProgressInfo: Equatable {
    /// Session folder name (`RecordingSession.dir.lastPathComponent`).
    var session: String
    /// 0...1 when known; nil renders an indeterminate progress bar.
    var fractionCompleted: Double?
    /// Estimated time left when known.
    var secondsRemaining: TimeInterval?
    /// One of the `Stage` values below.
    var stage: String
}

extension TranscriptionProgressInfo {
    /// Stage names shared by the model and the processing UI.
    enum Stage {
        static let saved = "Saved"
        static let transcribing = "Transcribing"
        static let speakers = "Speakers"
        static let ready = "Ready"
        static let failed = "Failed"
    }

    var isReady: Bool { stage == Stage.ready }
    var isFailed: Bool { stage == Stage.failed }

    /// "about 3 min left", or nil when no estimate is available.
    var remainingText: String? {
        guard let secondsRemaining, secondsRemaining.isFinite, secondsRemaining > 0 else { return nil }
        if secondsRemaining < 60 { return "less than a minute left" }
        let minutes = Int((secondsRemaining / 60).rounded(.up))
        return "about \(minutes) min left"
    }
}
