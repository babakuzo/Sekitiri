import FluidAudio
import Foundation

/// One local ASR model produces the authoritative transcript from closed files.
/// Windows are checkpointed during capture; Stop only finishes the remaining
/// audio. Original recordings remain recoverable until a complete commit exists.
actor TranscriptionCoordinator {
    struct LiveSegment: Identifiable, Sendable {
        let id: String
        let speaker: String
        let start: TimeInterval
        let text: String
        var end: TimeInterval = 0
        var isMicrophone = false
    }
    /// Work done for the meeting currently being finalised. `fraction` covers
    /// recognition of all tracks; the speaker stage follows when enabled.
    struct Progress: Sendable, Equatable {
        enum Stage: Sendable, Equatable { case transcribing, identifyingSpeakers }
        var stage: Stage
        var fraction: Double
        var secondsRemaining: TimeInterval?
    }
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case progress(session: String, Progress)
        case ready(session: String, issues: [String])
        case failed(session: String, message: String)
    }
    private struct Settings: Codable, Sendable {
        let engine: String
        let language: String
        /// Names and terms to favour for this meeting: the user's glossary
        /// plus calendar attendees. Absent in sessions recorded before.
        var vocabulary: [String]? = nil
        static func load(in directory: URL) throws -> Self {
            let url = directory.appendingPathComponent(TranscriptIntegrity.settingsFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            }
            let value = Self(engine: Config.transcriptionEngine(), language: Config.transcriptionLanguage(),
                             vocabulary: Config.transcriptionVocabulary(attendees: Self.attendees(in: directory)))
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            return value
        }

        private static func attendees(in directory: URL) -> [String] {
            let url = directory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return object["attendees"] as? [String] ?? []
        }
    }
    private var queue: [URL] = []
    private var draining = false
    private var activeDirectory: URL?
    private var drainTask: Task<Void, Never>?
    private var recordingActive = false
    private var engine: (any WindowedTranscriptionEngine)?
    private let engineFactory: @Sendable (String, String) -> any WindowedTranscriptionEngine
    private let runHooks: Bool
    private let transcriptionEnabled: @Sendable () -> Bool
    private let speakerEnrichmentEnabled: @Sendable () -> Bool
    private var engineSettings: Settings?
    private var diarizer: SortformerDiarizer?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var backgroundTask: Task<Void, Never>?
    private var backgroundGeneration = 0

    init(engineFactory: @escaping @Sendable (String, String) -> any WindowedTranscriptionEngine = { name, language in
        ParakeetEngine(version: ParakeetEngine.version(forEngine: name), languageCode: language)
    }, runHooks: Bool = true,
         transcriptionEnabled: @escaping @Sendable () -> Bool = { Config.transcriptionEnabled() },
         speakerEnrichmentEnabled: @escaping @Sendable () -> Bool = { Config.speakerDiarizationEnabled() }) {
        self.engineFactory = engineFactory
        self.runHooks = runHooks
        self.transcriptionEnabled = transcriptionEnabled
        self.speakerEnrichmentEnabled = speakerEnrichmentEnabled
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    func beginRecording() async {
        recordingActive = true
        let activeDrain = drainTask
        activeDrain?.cancel()
        await activeDrain?.value
        await stopLiveAndWait()
    }

    func endRecordingAndEnqueue(_ directory: URL) async {
        // Keep the same model warm for finalisation rather than loading twice.
        await stopLiveAndWait(releaseEngine: false)
        recordingActive = false
        enqueue(directory)
    }

    func endRecordingWithoutEnqueue() async {
        await stopLiveAndWait()
        recordingActive = false
        drainIfIdle()
    }

    func stopLiveAndWait(releaseEngine: Bool = true) async {
        backgroundGeneration += 1
        let task = backgroundTask
        backgroundTask = nil
        task?.cancel()
        await task?.value
        if releaseEngine && !draining { await releaseASR() }
    }

    func handleMemoryPressure() async {
        await stopLiveAndWait(releaseEngine: false)
        // A running final window owns the engine until its result is saved.
        if !draining { await releaseASR() }
        if !draining {
            diarizer?.cleanup()
            diarizer = nil
        }
    }

    func startBackgroundTranscription(
        session: RecordingSession,
        onUpdate: @escaping @Sendable ([LiveSegment]) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async {
        await stopLiveAndWait(releaseEngine: false)
        guard transcriptionEnabled(), recordingActive else {
            onStatus("Audio is being saved. Automatic transcription is off.")
            return
        }
        let generation = backgroundGeneration
        backgroundTask = Task { [weak self] in
            await self?.runBackground(session: session, generation: generation,
                                      onUpdate: onUpdate, onStatus: onStatus)
        }
    }

    private func runBackground(
        session: RecordingSession, generation: Int,
        onUpdate: @escaping @Sendable ([LiveSegment]) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async {
        do {
            let settings = try Settings.load(in: session.dir)
            onStatus("Recording safely. Transcript sections appear as audio is processed.")
            var failedTracks = Set<String>()
            var latest: [String: [LiveSegment]] = [:]
            var lastSources: [String: [URL]] = [:]
            var backlogged = Set<String>()
            while !Task.isCancelled, generation == backgroundGeneration {
                let tracks = session.closedAudioTracks()
                for track in tracks where !track.files.isEmpty && !failedTracks.contains(track.name) {
                    try Task.checkCancellation()
                    // Closed files are immutable. Avoid reopening every old
                    // audio header on each poll when nothing new was captured.
                    if lastSources[track.name] == track.files, !backlogged.contains(track.name) { continue }
                    lastSources[track.name] = track.files
                    do {
                        // Do not load weights before enough closed audio exists.
                        let duration = try AudioWindowReader.duration(of: track.files)
                        guard duration >= TranscriptionWindow.coreDuration + TranscriptionWindow.contextDuration else { continue }
                        let engine = try await preparedEngine(settings)
                        var checkpoint = try checkpoint(in: session.dir, track: track.name,
                                                        sources: track.files, settings: settings, engine: engine)
                        // One window per track each turn keeps both sides of a
                        // conversation moving, even after a temporary backlog.
                        if let plan = try await engine.planWindow(sourceURLs: track.files,
                                                                  after: checkpoint.completedThrough,
                                                                  available: checkpoint.duration, final: false) {
                            try await recognize(plan, sources: track.files, engine: engine,
                                                checkpoint: &checkpoint, directory: session.dir, track: track.name)
                            latest[track.name] = liveSegments(checkpoint.segments, track: track.name, offsetMs: track.offsetMs)
                            onUpdate(Self.withoutEcho(latest.values.flatMap { $0 }.sorted { $0.start < $1.start }))
                            onStatus("Recording · transcript sections saved locally")
                            if TranscriptionWindow.next(after: checkpoint.completedThrough,
                                                        available: checkpoint.duration, final: false) != nil {
                                backlogged.insert(track.name)
                            } else { backlogged.remove(track.name) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failedTracks.insert(track.name)
                        log(session.dir, "background transcription paused for \(track.name): \(error)")
                        onStatus("Recording continues. Unfinished transcription will be retried after Stop.")
                    }
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError { /* Durable windows resume after Stop. */ }
        catch {
            log(session.dir, "background transcription unavailable: \(error)")
            onStatus("Recording continues. Transcription will resume after Stop.")
        }
    }

    func enqueue(_ directory: URL) {
        guard transcriptionEnabled() else {
            runHook(for: directory)
            return
        }
        guard activeDirectory != directory else { return }
        if !queue.contains(directory) { queue.append(directory) }
        drainIfIdle()
    }

    func resumePending(root: URL) {
        guard transcriptionEnabled(),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path),
                  !TranscriptIntegrity.isComplete(at: directory),
                  hasRecoverableAudio(in: directory),
                  activeDirectory != directory,
                  !queue.contains(directory) else { continue }
            queue.append(directory)
        }
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !recordingActive, !draining, !queue.isEmpty else { return }
        draining = true
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let directory = queue.removeFirst()
            if Task.isCancelled || recordingActive {
                queue.insert(directory, at: 0)
                break
            }
            activeDirectory = directory
            publish(.transcribing(session: directory.lastPathComponent, queued: queue.count))
            do {
                let transcript = try await transcribe(directory)
                publish(.ready(session: directory.lastPathComponent, issues: transcript.validationIssues))
                if transcript.isComplete {
                    if runHooks { notifyUser(title: "Sekitiri — transcript ready", body: directory.lastPathComponent) }
                    if speakerEnrichmentEnabled(), !recordingActive {
                        try await enrichSpeakers(in: directory, transcript: transcript)
                    }
                    runHook(for: directory)
                } else {
                    log(directory, "transcription failed: incomplete recording — \(transcript.validationIssues.joined(separator: "; "))")
                    if runHooks { notifyUser(title: "Sekitiri — transcript needs attention", body: "Available speech was saved. Some audio could not be transcribed.") }
                }
            } catch is CancellationError {
                if !TranscriptIntegrity.isComplete(at: directory), !queue.contains(directory) {
                    queue.insert(directory, at: 0)
                }
                break
            } catch {
                log(directory, "transcription failed: \(error)")
                publish(.failed(session: directory.lastPathComponent, message: error.localizedDescription))
                if runHooks { notifyUser(title: "Sekitiri — transcription needs attention", body: error.localizedDescription) }
            }
            activeDirectory = nil
        }
        activeDirectory = nil
        await releaseASR()
        diarizer?.cleanup()
        diarizer = nil
        draining = false
        drainTask = nil
        publish(.idle)
        drainIfIdle()
    }

    private func transcribe(_ directory: URL) async throws -> Transcript {
        try Task.checkCancellation()
        let meta = try SessionMeta.read(from: directory)
        let settings = try Settings.load(in: directory)
        let engine = try await preparedEngine(settings)
        let engineName = engine.name
        let engineModel = engine.model
        var recognized: [(track: SessionMeta.Track, audio: URL, segments: [TranscriptSegment])] = []
        var outcomes: [Transcript.TrackOutcome] = []
        let sources = recordedSources(in: directory)
        var progress = ProgressTracker()
        for track in meta.tracks {
            let trackName = track.speaker == "me" ? "mic" : "system"
            let files = sources[trackName] ?? [directory.appendingPathComponent(track.file)]
            if let duration = try? AudioWindowReader.duration(of: files) {
                progress.totals[trackName] = duration
            }
        }
        for track in meta.tracks {
            try Task.checkCancellation()
            let audio = directory.appendingPathComponent(track.file)
            let trackName = track.speaker == "me" ? "mic" : "system"
            let files = sources[trackName] ?? [audio]
            guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                if let cached = savedSegments(in: directory, track: trackName, settings: settings, engine: engine) {
                    recognized.append((track: track, audio: audio, segments: cached))
                }
                outcomes.append(.init(file: track.file, status: .missing, segmentCount: 0, message: "Saved audio is missing."))
                continue
            }
            do {
                var checkpoint = try checkpoint(in: directory, track: trackName,
                                                sources: files, settings: settings, engine: engine)
                // Work already saved during the meeting or an earlier attempt counts.
                progress.record(track: trackName, completed: checkpoint.completedThrough, processedAudio: 0)
                while let plan = try await engine.planWindow(sourceURLs: files,
                                                             after: checkpoint.completedThrough,
                                                             available: checkpoint.duration, final: true) {
                    try Task.checkCancellation()
                    let audioDone = try await recognize(plan, sources: files, engine: engine,
                                                        checkpoint: &checkpoint, directory: directory, track: trackName)
                    progress.record(track: trackName, completed: checkpoint.completedThrough,
                                    processedAudio: audioDone)
                    publish(.progress(session: directory.lastPathComponent, progress.snapshot))
                }
                recognized.append((track: track, audio: audio, segments: checkpoint.segments))
                outcomes.append(.init(file: track.file, status: .complete, segmentCount: checkpoint.segments.count))
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Earlier committed windows remain readable and resumable. A
                // failed track never promotes the whole meeting to complete.
                if let partial = savedSegments(in: directory, track: trackName, settings: settings, engine: engine) {
                    recognized.append((track: track, audio: audio, segments: partial))
                }
                outcomes.append(.init(file: track.file, status: .failed,
                                      segmentCount: recognized.last(where: { $0.track.file == track.file })?.segments.count ?? 0,
                                      message: error.localizedDescription))
                log(directory, "track transcription failed for \(track.file): \(error)")
            }
        }
        await releaseASR()
        var merged: [Transcript.Segment] = []
        for item in recognized {
            try Task.checkCancellation()
            let offset = TimeInterval(item.track.offsetMs) / 1000
            func ms(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) + offset) * 1000) }
            // The transcript itself is never blocked on speaker models. Keep
            // accurate source-track labels; optional enrichment can run later.
            merged += item.segments.map { segment in
                Transcript.Segment(
                    speaker: item.track.speaker,
                    start_ms: ms(segment.start), end_ms: ms(max(segment.start, segment.end)), text: segment.text,
                    words: segment.words.map { words in
                        words.map { Transcript.Word(text: $0.text, start_ms: ms($0.start),
                                                    end_ms: ms(max($0.start, $0.end)), confidence: $0.confidence) }
                    })
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }
        let echo = EchoSuppression.split(merged)
        if !echo.suppressed.isEmpty {
            log(directory, "suppressed \(echo.suppressed.count) microphone segments repeating system audio")
        }
        let transcript = Transcript(engine: engineName, model: engineModel,
                                    created_at: ISO8601DateFormatter().string(from: Date()),
                                    segments: echo.kept, trackOutcomes: outcomes, issues: meta.issues,
                                    suppressedSegments: echo.suppressed)
        try transcript.write(to: directory)
        log(directory, "saved \(echo.kept.count) segments; complete=\(transcript.isComplete)")
        // Retain short source files while a retry could use their checkpoints.
        // The assembled mic/system files remain available for playback.
        if transcript.isComplete {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("segments"))
        }
        return transcript
    }

    private func savedSegments(in directory: URL, track: String, settings: Settings,
                               engine: any WindowedTranscriptionEngine) -> [TranscriptSegment]? {
        let url = TranscriptionCheckpoint.url(in: directory, track: track)
        return TranscriptionCheckpoint.recoverPartial(at: url, engine: engine.name,
                                                       model: engine.model, language: settings.language)?.segments
    }

    private func hasRecoverableAudio(in directory: URL) -> Bool {
        let fm = FileManager.default
        return ["mic", "system"].contains { name in
            fm.fileExists(atPath: directory.appendingPathComponent("\(name).caf").path)
                || !SegmentedAudioWriter.discoveredSegments(in: directory, trackName: name).isEmpty
        }
    }

    private func checkpoint(in directory: URL, track: String, sources: [URL], settings: Settings,
                            engine: any WindowedTranscriptionEngine) throws -> TranscriptionCheckpoint {
        try TranscriptionCheckpoint.open(at: TranscriptionCheckpoint.url(in: directory, track: track),
                                         sources: sources, engine: engine.name, model: engine.model,
                                         language: settings.language)
    }

    /// Recognize one planned window and commit it. Windows that voice
    /// activity detection found silent are committed without decoding.
    /// Returns the seconds of audio decoded (zero for a silent window), which
    /// is what the time estimate's speed is measured on.
    @discardableResult
    private func recognize(_ plan: WindowPlan, sources: [URL], engine: any WindowedTranscriptionEngine,
                           checkpoint: inout TranscriptionCheckpoint, directory: URL, track: String) async throws -> TimeInterval {
        let window = plan.window
        let started = ContinuousClock.now
        let segments = plan.hasSpeech
            ? try await engine.transcribeWindow(sourceURLs: sources, start: window.readStart,
                                                duration: window.readEnd - window.readStart,
                                                retaining: window.coreStart..<window.coreEnd)
            : []
        try Task.checkCancellation()
        try checkpoint.append(segments, for: window,
                              savingTo: TranscriptionCheckpoint.url(in: directory, track: track))
        let detail = plan.hasSpeech ? "saved" : "silent, skipped"
        log(directory, "\(track) \(String(format: "%.1f", window.coreStart))–\(String(format: "%.1f", window.coreEnd))s \(detail) in \(started.duration(to: .now))")
        return plan.hasSpeech ? window.coreEnd - window.coreStart : 0
    }

    private func liveSegments(_ segments: [TranscriptSegment], track: String, offsetMs: Int) -> [LiveSegment] {
        segments.enumerated().map { index, segment in
            LiveSegment(id: "\(track)-\(index)", speaker: track == "mic" ? "You" : "Other participants",
                        start: segment.start + Double(offsetMs) / 1000, text: segment.text,
                        end: segment.end + Double(offsetMs) / 1000, isMicrophone: track == "mic")
        }
    }

    /// Live text gets the same echo filter as the final transcript, so
    /// speaker playback does not appear twice while recording.
    static func withoutEcho(_ segments: [LiveSegment]) -> [LiveSegment] {
        let system = segments.filter { !$0.isMicrophone }.map {
            Transcript.Segment(speaker: "them", start_ms: Int($0.start * 1000), end_ms: Int($0.end * 1000), text: $0.text)
        }
        guard !system.isEmpty else { return segments }
        return segments.filter { segment in
            guard segment.isMicrophone else { return true }
            let mic = Transcript.Segment(speaker: "me", start_ms: Int(segment.start * 1000),
                                         end_ms: Int(segment.end * 1000), text: segment.text)
            return !EchoSuppression.isEcho(mic, system: system)
        }
    }

    private func recordedSources(in directory: URL) -> [String: [URL]] {
        let url = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["segment_files"] as? [String: [String]] else { return [:] }
        var result: [String: [URL]] = [:]
        for name in ["mic", "system"] {
            guard let files = paths[name], !files.isEmpty,
                  files.allSatisfy({ $0.hasPrefix("segments/\(name)/") && !$0.split(separator: "/").contains("..") }) else { continue }
            let urls = files.map { directory.appendingPathComponent($0) }
            // An old completed recording may have removed its segment cache.
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { result[name] = urls }
        }
        return result
    }

    private func preparedEngine(_ settings: Settings) async throws -> any WindowedTranscriptionEngine {
        if let engine, engineSettings?.engine == settings.engine,
           engineSettings?.language == settings.language {
            if let configurable = engine as? any VocabularyConfigurable {
                await configurable.setVocabulary(settings.vocabulary ?? [])
            }
            return engine
        }
        await releaseASR()
        let engine = engineFactory(settings.engine, settings.language)
        do {
            try await engine.prepare()
            try Task.checkCancellation()
        } catch {
            await engine.release()
            throw error
        }
        self.engine = engine
        engineSettings = settings
        if let configurable = engine as? any VocabularyConfigurable {
            await configurable.setVocabulary(settings.vocabulary ?? [])
        }
        return engine
    }

    private func releaseASR() async {
        if let engine { await engine.release() }
        engine = nil
        engineSettings = nil
    }

    private func preparedDiarizer() async throws -> SortformerDiarizer {
        if let diarizer { return diarizer }
        var config = SortformerConfig.balancedV2_1
        // The palettized set is substantially lighter and avoids memory
        // pressure when ASR and diarization are both loaded on an 8 GB Mac.
        if ProcessInfo.processInfo.physicalMemory <= 8 * 1_073_741_824 {
            config.precision = .palettized
        }
        let diarizer = SortformerDiarizer(config: config)
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
        return diarizer
    }

    private func enrichSpeakers(in directory: URL, transcript: Transcript) async throws {
        guard transcript.segments.contains(where: { $0.speaker == "them" }) else { return }
        let meta = try SessionMeta.read(from: directory)
        guard let track = meta.tracks.first(where: { $0.speaker == "them" }) else { return }
        publish(.progress(session: directory.lastPathComponent,
                          Progress(stage: .identifyingSpeakers, fraction: 1, secondsRemaining: nil)))
        let spans = await diarizationSpans(for: directory.appendingPathComponent(track.file), directory: directory)
        diarizer?.cleanup()
        diarizer = nil
        try Task.checkCancellation()
        guard !spans.isEmpty else { return }
        let offset = Double(track.offsetMs) / 1000
        let enriched = transcript.segments.flatMap { segment -> [Transcript.Segment] in
            guard segment.speaker == "them" else { return [segment] }
            return SpeakerAttribution.assign(segment, spans: spans, offset: offset, fallback: "them")
        }
        let result = Transcript(engine: transcript.engine, model: transcript.model,
                                created_at: transcript.created_at, segments: enriched,
                                trackOutcomes: transcript.trackOutcomes, issues: transcript.issues,
                                suppressedSegments: transcript.suppressedSegments)
        try result.write(to: directory)
    }

    private func diarizationSpans(for audio: URL, directory: URL) async -> [SpeakerSpan] {
        guard Config.speakerDiarizationEnabled() else { return [] }
        do {
            let diarizer = try await preparedDiarizer()
            let timeline = try diarizer.processComplete(audioFileURL: audio)
            return timeline.speakers.values.flatMap { speaker in
                (speaker.finalizedSegments + speaker.tentativeSegments).map {
                    SpeakerSpan(
                        speaker: "Speaker \(speaker.index + 1)",
                        start: TimeInterval($0.startTime),
                        end: TimeInterval($0.endTime)
                    )
                }
            }
        } catch {
            log(directory, "speaker diarization unavailable for \(audio.lastPathComponent): \(error)")
            return []
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard runHooks else { return }
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Recognition progress across a meeting's tracks, with a time estimate
    /// from the speed measured so far in this run.
    private struct ProgressTracker {
        var totals: [String: TimeInterval] = [:]
        var completed: [String: TimeInterval] = [:]
        let started = ContinuousClock.now
        var processed: TimeInterval = 0

        mutating func record(track: String, completed through: TimeInterval, processedAudio: TimeInterval) {
            completed[track] = through
            processed += processedAudio
        }

        var snapshot: Progress {
            let total = totals.values.reduce(0, +)
            let done = completed.reduce(0) { $0 + min($1.value, totals[$1.key] ?? $1.value) }
            let fraction = total > 0 ? min(1, done / total) : 0
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            var remaining: TimeInterval?
            if processed >= 20, seconds > 0 {
                remaining = max(0, total - done) / (processed / seconds)
            }
            return Progress(stage: .transcribing, fraction: fraction, secondsRemaining: remaining)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
