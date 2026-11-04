import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet-v3",
///         "diarization": true
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine. An explicit choice always wins. Otherwise Parakeet
    /// Ultra (more accurate than v3 at the same speed) is used on fresh
    /// installs; Macs that already hold v3 keep it until the user upgrades in
    /// Settings, so the next meeting never waits on a surprise download.
    static func transcriptionEngine() -> String {
        if let explicit = UserDefaults.standard.string(forKey: "localTranscriptionEngine")
            ?? transcription()?["engine"] as? String {
            return explicit
        }
        if ParakeetEngine.isCached(engine: "parakeet-ultra") || !ParakeetEngine.isCached(engine: "parakeet-v3") {
            return "parakeet-ultra"
        }
        return "parakeet-v3"
    }

    /// Language for the next recording. Parakeet identifies the language on
    /// its own and handles English/French switching; the only available hint
    /// filters by alphabet and measurably hurts mixed-language meetings
    /// (FluidAudio #840), so new recordings always use automatic detection.
    /// Sessions recorded earlier keep the language saved with them.
    static func transcriptionLanguage() -> String {
        "auto"
    }

    /// Terms the recognizer should favour: the user's glossary (one term per
    /// line or comma-separated) plus meeting attendees' names. Email addresses
    /// and terms under three characters are skipped; the list is capped to
    /// keep rescoring fast and precise.
    static func transcriptionVocabulary(attendees: [String] = []) -> [String] {
        let glossary = UserDefaults.standard.string(forKey: "transcriptionVocabulary") ?? ""
        var terms = glossary.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        for attendee in attendees where !attendee.contains("@") {
            terms.append(attendee)
            terms += attendee.split(separator: " ").map(String.init)
        }
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !$0.contains("@") && seen.insert($0.lowercased()).inserted }
            .prefix(200)
            .map { $0 }
    }

    /// Split the mixed system-audio track into stable speaker slots after
    /// recording. Sortformer labels voices as Speaker 0, Speaker 1, etc.; it
    /// deliberately does not guess real-world names.
    static func speakerDiarizationEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: "localSpeakerDiarization") as? Bool {
            return value
        }
        return transcription()?["diarization"] as? Bool ?? false
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    enum EchoCancellation: String, CaseIterable, Identifiable {
        case automatic = "auto"
        case on
        case off
        var id: String { rawValue }
    }

    /// The echo cancellation preference: Settings first, then the config
    /// file's `mic_voice_processing`, otherwise automatic.
    static func echoCancellation() -> EchoCancellation {
        if let raw = UserDefaults.standard.string(forKey: "echoCancellation"),
           let mode = EchoCancellation(rawValue: raw) { return mode }
        if let legacy = load()?["mic_voice_processing"] as? Bool { return legacy ? .on : .off }
        return .automatic
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Automatic mode enables it only when the output is not
    /// headphones; ducking of other audio is minimised in MicRecorder.
    static func micVoiceProcessing() -> Bool {
        switch echoCancellation() {
        case .on: return true
        case .off: return false
        case .automatic: return !AudioOutputRoute.isPrivateListening()
        }
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}

/// Transcription engines offered in Settings, most recommended first.
enum TranscriptionEngineOption: String, CaseIterable, Identifiable {
    case ultra = "parakeet-ultra"
    case v3 = "parakeet-v3"
    case englishOnly = "parakeet"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultra: return "Best accuracy (recommended)"
        case .v3: return "Standard"
        case .englishOnly: return "English only"
        }
    }

    var detail: String {
        switch self {
        case .ultra: return "25 languages, including mixed English and French. About 630 MB, downloaded once."
        case .v3: return "25 languages. The previous default model."
        case .englishOnly: return "English meetings only."
        }
    }
}
