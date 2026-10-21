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

    /// Configured final-pass engine. `parakeet-v3` is the multilingual default;
    /// `parakeet` remains available as the English-focused v2 fallback.
    static func transcriptionEngine() -> String {
        UserDefaults.standard.string(forKey: "localTranscriptionEngine")
            ?? transcription()?["engine"] as? String
            ?? "parakeet-v3"
    }

    /// Language mode for the next recording. Auto keeps the full multilingual
    /// model and lets it identify the spoken language; explicit regional codes
    /// constrain recognition; Auto and Multilingual keep code-switching available.
    static func transcriptionLanguage() -> String {
        UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
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

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
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

enum TranscriptionLanguageOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case multilingual = "multilingual"
    case english = "en-US"
    case french = "fr-FR"
    case spanish = "es-ES"
    case german = "de-DE"
    case italian = "it-IT"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .multilingual: return "Multilingual"
        case .english: return "English"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Detect the spoken language automatically"
        case .multilingual: return "Keep supported languages available, including mixed English and French"
        default: return "Use the selected language for local recognition; choose Multilingual for mixed-language meetings"
        }
    }
}
