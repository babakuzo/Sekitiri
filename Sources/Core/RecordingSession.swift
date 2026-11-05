import AVFoundation
import Foundation

/// A stable snapshot of files whose encoders have finished. Open files are
/// never passed to the transcription worker. Files stay on disk until the
/// canonical transcript has been saved successfully.
struct CapturedAudioTrack: Sendable {
    let name: String
    let files: [URL]
    let offsetMs: Int
    let complete: Bool
}

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession: @unchecked Sendable {
    enum LifecycleError: Error {
        case startAlreadyInProgress
    }

    /// Combined, presentation-ready capture health. This deliberately models
    /// the two tracks independently: system audio can disappear while the
    /// microphone continues, and neither condition causes existing files to
    /// be discarded.
    enum CaptureHealth: Equatable {
        case idle
        case recording(microphone: MicRecorder.Health, systemAudio: SystemAudioRecorder.Health)
        case paused(microphone: MicRecorder.Health, systemAudio: SystemAudioRecorder.Health)
        case degraded(microphone: MicRecorder.Health, systemAudio: SystemAudioRecorder.Health, message: String)
    }

    /// Called on the main queue whenever either input route changes. Assign
    /// this from AppModel to publish a UI status without exposing recorders.
    var onCaptureHealthChange: ((CaptureHealth) -> Void)? {
        didSet { publishHealth() }
    }
    /// True when either captured track contains meaningful audio. This is a
    /// signal for safe auto-end detection only; raw samples never leave the
    /// recorder through this callback.
    var onAudioActivityChange: ((Bool) -> Void)?
    /// Microphone-only activity, reported about once per second on the main
    /// queue. Lets the UI warn when the mic itself has gone silent while
    /// other participants are still audible through system audio.
    var onMicActivityChange: ((Bool) -> Void)?
    /// Whether the microphone is delivering any signal at all, about once a
    /// second on the main queue.
    var onMicSignal: ((Bool) -> Void)?
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let captureSystemAudio: Bool
    private var systemAudioStarted = false
    private let meeting: MeetingContext?
    private var titleOverride: String?
    private var microphoneHealth: MicRecorder.Health = .idle
    private var systemAudioHealth: SystemAudioRecorder.Health = .idle
    private var isPaused = false
    private let lifecycleQueue = DispatchQueue(label: "local.sekitiri.recording-session", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    private var startToken: RecordingOperationToken?
    private var captureStopped = false
    private var sessionCaptureIssues: [String] = []

    var captureErrors: [String] {
        let sessionIssues = lifecycleLock.withLock { sessionCaptureIssues }
        return Array(Set(sessionIssues + mic.captureIssues + system.captureIssues)).sorted()
    }

    /// Segment timestamps and metadata share the session-start clock. A track
    /// that starts late retains its real delay instead of being shifted to zero.
    func closedAudioTracks() -> [CapturedAudioTrack] {
        let complete = lifecycleLock.withLock { captureStopped }
        var tracks = [CapturedAudioTrack(
            name: "mic", files: mic.closedSegmentURLs,
            offsetMs: Self.startOffsetMilliseconds(firstBufferAt: mic.firstBufferAt, startedAt: startedAt),
            complete: complete
        )]
        if captureSystemAudio {
            tracks.append(CapturedAudioTrack(
                name: "system", files: system.closedSegmentURLs,
                offsetMs: Self.startOffsetMilliseconds(firstBufferAt: system.firstBufferAt, startedAt: startedAt),
                complete: complete
            ))
        }
        return tracks
    }

    static func startOffsetMilliseconds(firstBufferAt: Date?, startedAt: Date) -> Int {
        guard let firstBufferAt else { return 0 }
        return max(0, Int((firstBufferAt.timeIntervalSince(startedAt) * 1_000).rounded()))
    }

    private func noteCaptureIssue(_ message: String) {
        lifecycleLock.withLock {
            if !sessionCaptureIssues.contains(message) { sessionCaptureIssues.append(message) }
        }
    }

    static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL, captureSystemAudio: Bool = true, meeting: MeetingContext? = nil, titleOverride: String? = nil) throws {
        self.captureSystemAudio = captureSystemAudio
        self.meeting = meeting
        self.titleOverride = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? titleOverride : nil
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        mic.onHealthChange = { [weak self] health in
            self?.microphoneHealth = health
            self?.publishHealth()
        }
        system.onHealthChange = { [weak self] health in
            self?.systemAudioHealth = health
            self?.publishHealth()
        }
        mic.onAudioActivity = { [weak self] active in
            self?.onMicActivityChange?(active)
            self?.publishAudioActivity(active)
        }
        system.onAudioActivity = { [weak self] active in
            self?.publishAudioActivity(active)
        }
        mic.onSignal = { [weak self] hasSignal in
            self?.onMicSignal?(hasSignal)
        }
    }

    /// Start the required microphone first, then attempt optional system
    /// audio. A missing permission or failed aggregate device must never cost
    /// the user the microphone recording that is already working.
    /// Cancellable, non-main-thread startup. Cancellation is cooperative at
    /// each Core Audio acquisition boundary and always rolls back the mic,
    /// process tap, aggregate device, and partial segments before returning.
    func start(inputDeviceID: String? = nil) async throws {
        let token = try makeStartToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lifecycleQueue.async { [self] in
                    do {
                        try performStart(inputDeviceID: inputDeviceID, token: token)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Compatibility entry point for existing callers. New UI code should use
    /// the async overload so Stop can cancel startup without blocking the main
    /// interface thread.
    @available(*, deprecated, message: "Use await start(inputDeviceID:) for cancellable startup")
    func start(inputDeviceID: String? = nil) throws {
        let token = try makeStartToken()
        try performStart(inputDeviceID: inputDeviceID, token: token)
    }

    /// May be called synchronously by a Stop button. It never waits for Core
    /// Audio; it only flips the cancellation token observed by startup.
    func cancelStart() {
        lifecycleLock.withLock { startToken?.cancel() }
    }

    func updateTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        titleOverride = trimmed.isEmpty ? nil : trimmed
    }

    /// Persist participant-authored context independently of the recording
    /// lifecycle. Errors deliberately propagate so the interface can keep the
    /// unsaved draft visible and explain how to recover instead of discarding it.
    func saveAdditionalNotes(_ notes: String) throws {
        try notes.write(to: additionalNotesURL, atomically: true, encoding: .utf8)
    }

    /// Returns the previously saved notes for this recording, or `nil` when no
    /// notes have been saved yet. This remains available after `stop()` because
    /// the recording folder is the durable source of truth for completed notes.
    func loadAdditionalNotes() throws -> String? {
        guard FileManager.default.fileExists(atPath: additionalNotesURL.path) else {
            return nil
        }
        return try String(contentsOf: additionalNotesURL, encoding: .utf8)
    }

    func pause() {
        mic.pause()
        if systemAudioStarted { system.pause() }
        isPaused = true
        writeActiveCheckpoint(state: "paused")
        publishHealth()
    }

    func resume() throws {
        try mic.resume()
        if systemAudioStarted {
            do {
                try system.resume()
            } catch {
                let message = "System audio could not resume. Microphone recording continues safely. \(error)"
                systemAudioHealth = .unavailable(message: message)
                noteCaptureIssue(message)
                publishHealth()
            }
        }
        isPaused = false
        writeActiveCheckpoint(state: "recording")
        publishHealth()
    }

    /// Refreshes a small local heartbeat while capture is active. The audio
    /// files remain the source of truth; this metadata only makes an interrupted
    /// session discoverable after a crash, sleep, or app replacement.
    func checkpoint() {
        writeActiveCheckpoint(state: isPaused ? "paused" : "recording")
    }

    /// Stop and finalise away from the caller's executor. The async overload is
    /// the production path: closing encoders, joining segments, validating
    /// files, and writing metadata all run on the lifecycle queue.
    func stop() async -> [String] {
        cancelStart()
        return await withCheckedContinuation { continuation in
            lifecycleQueue.async { [self] in
                continuation.resume(returning: performStop())
            }
        }
    }

    /// Compatibility entry point. It can block its caller and should be
    /// removed once App.swift has adopted `await session.stop()`.
    @available(*, deprecated, message: "Use await stop() so finalisation never blocks the UI")
    func stop() -> [String] {
        performStop()
    }

    private func performStop() -> [String] {
        // Encoder assembly can take time on long meetings. It is processing,
        // not recorded meeting duration.
        let ended = Date()
        mic.stop()
        if systemAudioStarted { system.stop() }
        lifecycleLock.withLock { captureStopped = true }
        isPaused = false
        publishHealth()
        var finalisationIssues: [String] = []
        do {
            try mic.finalizeSegments()
        } catch {
            finalisationIssues.append("mic.caf (could not assemble segments: \(error.localizedDescription))")
        }
        if systemAudioStarted {
            do {
                try system.finalizeSegments()
            } catch {
                finalisationIssues.append("system.caf (could not assemble segments: \(error.localizedDescription))")
            }
        }
        var invalidTracks = finalisationIssues + validateTracks()
        invalidTracks.append(contentsOf: captureErrors.map { "capture (\($0))" })

        let iso = ISO8601DateFormatter()

        let files = captureSystemAudio
            ? ["mic": "mic.caf", "system": "system.caf"]
            : ["mic": "mic.caf"]
        let tracks = closedAudioTracks()
        let offsets = Dictionary(uniqueKeysWithValues: tracks.map { ($0.name, $0.offsetMs) })
        let segmentFiles = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.name, $0.files.map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") })
        })
        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": files,
            "start_offset_ms": offsets,
            "segment_files": segmentFiles,
            "capture_errors": captureErrors,
            "invalid_tracks": invalidTracks,
        ]
        if let meeting {
            meta["calendar_event_id"] = meeting.eventID
            meta["title"] = meeting.title
            meta["attendees"] = meeting.attendees
            if let meetingURL = meeting.meetingURL {
                meta["meeting_url"] = meetingURL
            }
        }
        if let titleOverride { meta["title_override"] = titleOverride }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            try? FileManager.default.removeItem(at: activeCheckpointURL)
        } catch {
            // Preserve active.json so launch recovery can rebuild metadata.
            // Returning the issue keeps the completed UI from claiming that
            // finalisation succeeded silently.
            invalidTracks.append("meta.json (\(error.localizedDescription))")
        }
        return invalidTracks
    }

    private func makeStartToken() throws -> RecordingOperationToken {
        try lifecycleLock.withLock {
            if startToken != nil { throw LifecycleError.startAlreadyInProgress }
            let token = RecordingOperationToken()
            startToken = token
            return token
        }
    }

    private func performStart(inputDeviceID: String?, token: RecordingOperationToken) throws {
        defer {
            lifecycleLock.withLock {
                if startToken === token { startToken = nil }
            }
        }
        do {
            try token.checkCancellation()
            try mic.start(
                writingTo: dir.appendingPathComponent("mic.caf"),
                inputDeviceID: inputDeviceID,
                cancellationToken: token
            )
            try token.checkCancellation()
            if captureSystemAudio {
                do {
                    try system.start(
                        writingTo: dir.appendingPathComponent("system.caf"),
                        cancellationToken: token
                    )
                    try token.checkCancellation()
                    systemAudioStarted = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    systemAudioStarted = false
                    let message = "System audio is unavailable. Microphone recording continues safely. \(error)"
                    systemAudioHealth = .unavailable(message: message)
                    noteCaptureIssue(message)
                    publishHealth()
                }
            }
            try token.checkCancellation()
            writeActiveCheckpoint(state: "recording")
            publishHealth()
        } catch {
            system.cancelStart()
            mic.cancelStart()
            systemAudioStarted = false
            throw error
        }
    }

    /// Converts a session that was active when the process disappeared into a
    /// normal, recoverable completed session. This never deletes audio. CAF
    /// tracks that were not finalized may still fail validation later, but the
    /// user keeps the directory and can inspect or retry it.
    static func recoverInterruptedSessions(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var recovered: [URL] = []
        let iso = ISO8601DateFormatter()
        for dir in entries {
            let active = dir.appendingPathComponent("active.json")
            let meta = dir.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: active.path), !fm.fileExists(atPath: meta.path),
                  let data = try? Data(contentsOf: active),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let started = object["started"] as? String,
                  let files = object["files"] as? [String: String]
            else { continue }
            let ended = (object["heartbeat"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let startedDate = iso.date(from: started) ?? ended
            var recoveredMeta = object
            var invalidTracks = object["invalid_tracks"] as? [String] ?? []
            var captureErrors = object["capture_errors"] as? [String] ?? []
            captureErrors.append("Recording ended unexpectedly; the final audio segment may be incomplete.")
            for track in files.keys.sorted() {
                let destination = dir.appendingPathComponent("\(track).caf")
                guard !fm.fileExists(atPath: destination.path) else { continue }
                let discovered = SegmentedAudioWriter.discoveredSegments(in: dir, trackName: track)
                let segments = discovered.filter { segment in
                    guard let audio = try? AVAudioFile(forReading: segment) else { return false }
                    return audio.length > 0
                }
                if segments.count != discovered.count {
                    invalidTracks.append("\(track) (one or more interrupted segments could not be recovered)")
                }
                guard !segments.isEmpty else {
                    invalidTracks.append("\(track).caf (no recoverable audio)")
                    continue
                }
                do {
                    try SegmentedAudioWriter.finalize(segments: segments, to: destination, removeSegmentsOnSuccess: false)
                } catch {
                    invalidTracks.append("\(track) segments (\(error.localizedDescription))")
                }
            }
            for (track, file) in files {
                guard let audio = try? AVAudioFile(forReading: dir.appendingPathComponent(file)), audio.length > 0 else {
                    invalidTracks.append("\(track).caf (missing or empty recovered track)")
                    continue
                }
            }
            recoveredMeta["segment_files"] = Dictionary(uniqueKeysWithValues: files.keys.map { track in
                let segments = SegmentedAudioWriter.discoveredSegments(in: dir, trackName: track).filter {
                    guard let audio = try? AVAudioFile(forReading: $0) else { return false }
                    return audio.length > 0
                }
                return (track, segments.map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") })
            })
            recoveredMeta["capture_errors"] = Array(Set(captureErrors)).sorted()
            recoveredMeta["ended"] = iso.string(from: ended)
            recoveredMeta["duration_seconds"] = max(0, Int(ended.timeIntervalSince(startedDate)))
            recoveredMeta["files"] = files
            recoveredMeta["invalid_tracks"] = Array(Set(invalidTracks + captureErrors.map { "capture (\($0))" })).sorted()
            recoveredMeta["recovered_after_interruption"] = true
            if let recoveredData = try? JSONSerialization.data(withJSONObject: recoveredMeta, options: [.prettyPrinted, .sortedKeys]),
               (try? recoveredData.write(to: meta, options: .atomic)) != nil {
                try? fm.removeItem(at: active)
                recovered.append(dir)
            }
        }
        return recovered
    }

    private func validateTracks() -> [String] {
        let names = captureSystemAudio ? ["mic.caf", "system.caf"] : ["mic.caf"]
        return names.filter { name in
            let url = dir.appendingPathComponent(name)
            do { return try AVAudioFile(forReading: url).length == 0 } catch { return true }
        }
    }

    private var additionalNotesURL: URL {
        dir.appendingPathComponent("additional-notes.md")
    }

    private var activeCheckpointURL: URL {
        dir.appendingPathComponent("active.json")
    }

    private func writeActiveCheckpoint(state: String) {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "started": iso.string(from: startedAt),
            "heartbeat": iso.string(from: Date()),
            "state": state,
            "files": captureSystemAudio
                ? ["mic": "mic.caf", "system": "system.caf"]
                : ["mic": "mic.caf"],
            "start_offset_ms": Dictionary(uniqueKeysWithValues: closedAudioTracks().map { ($0.name, $0.offsetMs) }),
            "capture_errors": captureErrors,
            "invalid_tracks": captureErrors.map { "capture (\($0))" },
            "segment_files": [
                "mic": SegmentedAudioWriter.discoveredSegments(in: dir, trackName: "mic")
                    .map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") },
                "system": SegmentedAudioWriter.discoveredSegments(in: dir, trackName: "system")
                    .map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") },
            ],
        ]
        if let meeting {
            object["calendar_event_id"] = meeting.eventID
            object["title"] = meeting.title
            object["attendees"] = meeting.attendees
            if let meetingURL = meeting.meetingURL { object["meeting_url"] = meetingURL }
        }
        if let titleOverride { object["title_override"] = titleOverride }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: activeCheckpointURL, options: .atomic)
    }

    private func publishHealth() {
        let microphone = microphoneHealth
        let systemAudio = captureSystemAudio ? systemAudioHealth : .idle
        let state: CaptureHealth
        if case .unavailable(let message) = microphone {
            state = .degraded(microphone: microphone, systemAudio: systemAudio, message: message)
        } else if case .unavailable(let message) = systemAudio {
            state = .degraded(microphone: microphone, systemAudio: systemAudio, message: message)
        } else if case .idle = microphone {
            state = .idle
        } else if isPaused {
            state = .paused(microphone: microphone, systemAudio: systemAudio)
        } else {
            state = .recording(microphone: microphone, systemAudio: systemAudio)
        }
        DispatchQueue.main.async { [weak self] in self?.onCaptureHealthChange?(state) }
    }

    private func publishAudioActivity(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onAudioActivityChange?(active)
        }
    }
}

extension MicRecorder.Health {
    var label: String {
        switch self {
        case .idle: return "Microphone idle"
        case .recording(let deviceName): return "Mic connected: \(deviceName)"
        case .paused(let deviceName): return "Mic paused: \(deviceName)"
        case .unavailable(let message): return message
        }
    }
}

extension SystemAudioRecorder.Health {
    var label: String {
        switch self {
        case .idle: return "System audio off"
        case .recording: return "System audio connected"
        case .paused: return "System audio paused"
        case .unavailable(let message): return message
        }
    }
}
