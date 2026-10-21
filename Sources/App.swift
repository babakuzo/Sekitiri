import AppKit
import SwiftUI

struct RecordingSafetyPrompt: Identifiable {
    let id = UUID()
    let reason: String
    let detail: String
}

// ============================================================================
// Sekitiri — ONE self-contained app. Record (mic + system), transcribe
// on-device, view the transcript live in a native window, and summarize.
// All recording/transcription runs IN-PROCESS (no spawned quill, no icon).
// ============================================================================

// MARK: - Shared model (observed by SwiftUI)

@MainActor
final class AppModel: ObservableObject {
    @Published var recording = false
    @Published var isStartingRecording = false
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isSummarizing = false
    @Published var isPaused = false
    @Published var elapsed = "0:00"
    @Published var latestTranscript = "No transcript yet."
    @Published var status = "Ready"
    @Published var liveSegments: [TranscriptionCoordinator.LiveSegment] = []
    @Published var liveTranscriptionStatus = ""
    @Published var detectedCallPrompt: MeetingContext?
    @Published var showingCompletedRecording = false
    @Published var draftMeetingTitle = ""
    @Published var recordingTitle = ""
    @Published var additionalNotes = ""
    @Published var additionalNotesSaveStatus = ""
    @Published var additionalNotesSaveError: String?
    @Published var captureHealthStatus = "Checking microphone and system audio…"
    @Published var recordingSafetyPrompt: RecordingSafetyPrompt?
    @Published var recordingSafetyStatus = ""
    @Published private(set) var activeMeeting: MeetingContext?
    @Published private(set) var upcomingMeeting: MeetingContext?
    @Published private(set) var todaySchedule: [MeetingContext] = []
    /// All summary choices are local. Qwen is downloaded explicitly, unloaded
    /// immediately on an 8 GB Mac, and retained only briefly on larger Macs.
    @Published var selectedModel: ModelItem {
        didSet {
            UserDefaults.standard.set(selectedModel.id, forKey: "summaryModel")
            if selectedModel.id != oldValue.id {
                Task { await self.refreshLocalSummaryModelState() }
            }
        }
    }
    @Published private(set) var localSummaryModelState: LocalSummaryModelState = .notDownloaded

    private var session: RecordingSession?
    private var lastCompletedSessionDirectory: URL?
    private var ticker: Timer?
    private let coordinator = TranscriptionCoordinator()
    private var transcriptPollTimer: Timer?
    private var lastTranscriptPath: String?
    var hasSavedTranscript: Bool { lastTranscriptPath != nil }
    private let calendarService: CalendarService
    private var calendarTimer: Timer?
    /// Every start gets a token. A Stop pressed while setup is still in flight
    /// invalidates that token, so a delayed audio setup can never turn itself
    /// into a recording after the user has cancelled it.
    private var recordingStartGeneration = 0
    private var recordingMeeting: MeetingContext?
    private var lastAudioActivityAt: Date?
    private var hasAudioActivity = false
    private var remindedMeetingIDs = Set<String>()
    private var promptedCallIDs = Set<String>()
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var safetyPromptKeys = Set<String>()
    private var longRecordingReminderMinutes = Set<Int>()
    private var recordingCallWasDetected = false
    private var summaryDownloadTask: Task<Void, Never>?
    private var activeSummaryTask: Task<Void, Error>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var liveTranscriptionSuspendedForResources = false

    init() {
        let savedSummaryModel = UserDefaults.standard.string(forKey: "summaryModel")
        let legacyModelIDs = ["qwen3-4b", "gemma3n-e2b"]
        let initialSummaryModel = ModelItem.initialSelection(savedID: savedSummaryModel)
        selectedModel = initialSummaryModel
        if let savedSummaryModel, legacyModelIDs.contains(savedSummaryModel) {
            UserDefaults.standard.set(initialSummaryModel.id, forKey: "summaryModel")
        }
        // Older builds exposed an auto-record preference. Never honour a value
        // left behind by those versions: calendar and browser signals may only
        // prompt the user, never begin capture without an explicit action.
        UserDefaults.standard.set(false, forKey: "autoRecord")
        calendarService = CalendarService()
        let root = AppModel.recordingsRoot()
        let recovered = RecordingSession.recoverInterruptedSessions(in: root)
        if !recovered.isEmpty {
            notifyUser(
                title: "Sekitiri — recording recovered",
                body: "An interrupted recording was preserved on this Mac and queued for transcription."
            )
        }
        Task {
            await refreshLocalSummaryModelState()
            await coordinator.setStatusHandler { [weak self] status in
                Task { @MainActor [weak self] in self?.transcriptionStatus(status) }
            }
            await coordinator.resumePending(root: root)
        }
        startTranscriptPolling()
        syncCalendarState()
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCalendarState() }
        }
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeSummaryTask?.cancel()
                if let summary = self.activeSummaryTask { _ = await summary.result }
                await LocalSummaryRuntime.shared.unload()
                await self.coordinator.handleMemoryPressure()
                if self.recording {
                    self.liveTranscriptionSuspendedForResources = true
                    self.liveTranscriptionStatus = "Background transcription paused to protect your recording. Saved audio will be processed after the meeting."
                    self.status = "● Recording · live transcript paused to protect recording"
                }
                self.refreshReadyStateAfterUnload()
            }
        }
        pressure.resume()
        memoryPressureSource = pressure
    }

    static func recordingsRoot() -> URL {
        Config.resolveRoot(cliOverride: nil)
    }

    func toggleRecording() { recording ? stop() : start() }

    func startIfNotRecording() {
        guard !recording && !isStartingRecording else { return }
        start()
    }

    func requestCalendarAccess() { calendarService.requestAccess() }

    func startDetectedCallRecording() {
        guard let call = detectedCallPrompt else { return }
        detectedCallPrompt = nil
        start(context: call)
    }

    func dismissDetectedCallPrompt() {
        detectedCallPrompt = nil
    }

    var calendarStatusText: String {
        if !calendarService.isAuthorized { return "Calendar access is not connected" }
        if let activeMeeting { return "In meeting: \(activeMeeting.title)" }
        if let upcomingMeeting {
            return "Next: \(upcomingMeeting.title) · \(Self.relative(upcomingMeeting.start))"
        }
        return "No upcoming meetings detected"
    }

    func start(context: MeetingContext? = nil, customTitle: String? = nil) {
        guard !recording && !isStartingRecording && !isFinalizingRecording else { return }
        let devices = AudioInputDevice.available()
        guard !devices.isEmpty else {
            status = "⚠ No microphone input is available"
            notifyUser(title: "Sekitiri — recording unavailable", body: "Connect or enable a microphone, then try again.")
            return
        }
        let requestedDeviceID = UserDefaults.standard.string(forKey: "inputDeviceID")
        let inputDeviceID = devices.contains(where: { $0.id == requestedDeviceID }) ? requestedDeviceID : AudioInputDevice.defaultID()
        let systemAudio = UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true
        let source = context ?? calendarService.activeMeeting ?? upcomingMeeting
        let requestedTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meeting = source.map { MeetingContext(eventID: $0.eventID, title: requestedTitle.isEmpty ? $0.title : requestedTitle, start: $0.start, end: $0.end, attendees: $0.attendees, meetingURL: $0.meetingURL) }
            ?? (requestedTitle.isEmpty ? nil : MeetingContext(eventID: "manual-\(UUID().uuidString)", title: requestedTitle, start: Date(), end: Date().addingTimeInterval(3600), attendees: [], meetingURL: nil))

        isStartingRecording = true
        recordingStartGeneration &+= 1
        let startGeneration = recordingStartGeneration
        showingCompletedRecording = false
        recordingTitle = meeting?.title ?? (requestedTitle.isEmpty ? "Untitled meeting" : requestedTitle)
        status = "Starting recorder…"
        let recordingsRoot = AppModel.recordingsRoot()
        Task { [weak self] in
            if let summary = self?.activeSummaryTask {
                summary.cancel()
                _ = await summary.result
            }
            await LocalSummaryRuntime.shared.unload()
            await self?.coordinator.beginRecording()
            guard let self,
                  self.isStartingRecording,
                  self.recordingStartGeneration == startGeneration else {
                await self?.coordinator.endRecordingWithoutEnqueue()
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                var newSession: RecordingSession?
                do {
                    newSession = try RecordingSession(root: recordingsRoot, captureSystemAudio: systemAudio, meeting: meeting, titleOverride: requestedTitle.isEmpty ? nil : requestedTitle)
                    try await newSession?.start(inputDeviceID: inputDeviceID)
                    if let newSession {
                        await self?.recordingDidStart(newSession, meeting: meeting, generation: startGeneration)
                    }
                } catch {
                    _ = await newSession?.stop()
                    await self?.recordingDidFail(error, generation: startGeneration, sessionDirectory: newSession?.dir)
                }
            }
        }
    }

    private func recordingDidStart(_ newSession: RecordingSession, meeting: MeetingContext?, generation: Int) async {
        guard isStartingRecording, generation == recordingStartGeneration else {
            _ = await newSession.stop()
            try? FileManager.default.removeItem(at: newSession.dir)
            Task { [coordinator] in await coordinator.endRecordingWithoutEnqueue() }
            return
        }
        newSession.updateTitle(recordingTitle)
        session = newSession
        recording = true
        recordingMeeting = meeting
        recordingCallWasDetected = calendarService.detectedCall != nil
            || meeting?.eventID.hasPrefix("browser-") == true
            || meeting?.eventID.hasPrefix("teams-desktop-") == true
        safetyPromptKeys.removeAll()
        longRecordingReminderMinutes.removeAll()
        recordingSafetyPrompt = nil
        recordingSafetyStatus = ""
        lastAudioActivityAt = Date()
        hasAudioActivity = false
        isStartingRecording = false
        isPaused = false
        pausedDuration = 0
        pausedAt = nil
        additionalNotes = ""
        additionalNotesSaveStatus = ""
        additionalNotesSaveError = nil
        status = meeting.map { "● Recording · \($0.title)" } ?? "● Recording"
        latestTranscript = "Recording… transcript will appear here."
        liveSegments = []
        liveTranscriptionStatus = "Preparing local transcription…"
        liveTranscriptionSuspendedForResources = false
        lastTranscriptPath = nil
        newSession.onCaptureHealthChange = { [weak self] health in
            Task { @MainActor [weak self] in self?.captureHealthDidChange(health) }
        }
        newSession.onAudioActivityChange = { [weak self] active in
            Task { @MainActor [weak self] in self?.audioActivityDidChange(active) }
        }
        startLiveTranscription(for: newSession)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func recordingDidFail(_ error: Error, generation: Int, sessionDirectory: URL?) {
        guard generation == recordingStartGeneration else {
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            return
        }
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        isStartingRecording = false
        status = "⚠ Recording failed: \(error)"
        Task { [coordinator] in await coordinator.endRecordingWithoutEnqueue() }
        notifyUser(title: "Sekitiri — recording failed", body: "\(error)")
    }

    func stop() {
        guard !isStartingRecording else {
            cancelStartingRecording()
            return
        }
        guard !isFinalizingRecording, let session else { return }
        let stoppedAt = Date()
        let secs = elapsedDuration(for: session, at: stoppedAt)
        isFinalizingRecording = true
        status = "Finishing recording…"
        elapsed = Self.format(secs)
        ticker?.invalidate()
        ticker = nil
        _ = persistAdditionalNotes(using: session)
        Task { [weak self, coordinator] in
            // Stop closes encoders and joins files on the capture queue. The
            // interface remains responsive and background ASR sources survive.
            let invalidTracks = await session.stop()
            guard let self else { return }
            self.status = invalidTracks.isEmpty
                ? "Recording saved — finishing transcript…"
                : "⚠ Recording needs attention: \(invalidTracks.joined(separator: ", ")). Available audio was preserved."
            if !invalidTracks.isEmpty {
                notifyUser(title: "Sekitiri — recording needs attention",
                           body: invalidTracks.joined(separator: ", "))
            }
            self.lastCompletedSessionDirectory = session.dir
            self.session = nil
            self.recording = false
            self.isPaused = false
            self.showingCompletedRecording = true
            self.recordingMeeting = nil
            self.lastAudioActivityAt = nil
            self.hasAudioActivity = false
            self.recordingCallWasDetected = false
            self.liveTranscriptionSuspendedForResources = false
            self.recordingSafetyPrompt = nil
            self.recordingSafetyStatus = ""
            self.liveTranscriptionStatus = "Finishing saved transcript sections…"
            self.isTranscribing = Config.transcriptionEnabled()
            await LocalSummaryRuntime.shared.unload()
            await coordinator.endRecordingAndEnqueue(session.dir)
            self.isFinalizingRecording = false
        }
    }

    /// Cancels setup before capture has begun. The detached setup task sees the
    /// changed generation and deletes its temporary session when it returns.
    private func cancelStartingRecording() {
        guard isStartingRecording else { return }
        recordingStartGeneration &+= 1
        isStartingRecording = false
        isPaused = false
        recordingTitle = ""
        elapsed = "0:00"
        liveSegments = []
        liveTranscriptionStatus = ""
        status = "Recording start cancelled"
        Task { [coordinator] in await coordinator.endRecordingWithoutEnqueue() }
    }

    /// User-confirmed deletion for a capture that is still active. This never
    /// queues transcription or creates a meeting in the notes vault.
    func discardCurrentCapture() {
        guard !isFinalizingRecording else { return }
        if isStartingRecording {
            cancelStartingRecording()
            return
        }
        guard let session else { return }
        isFinalizingRecording = true
        ticker?.invalidate()
        ticker = nil
        status = "Discarding recording…"
        Task { [weak self, coordinator] in
            await coordinator.stopLiveAndWait()
            _ = await session.stop()
            // Never remove files while inference can still append a checkpoint.
            try? FileManager.default.removeItem(at: session.dir)
            guard let self else { return }
            self.session = nil
            self.recording = false
            self.isPaused = false
            self.showingCompletedRecording = false
            self.recordingMeeting = nil
            self.lastAudioActivityAt = nil
            self.hasAudioActivity = false
            self.lastCompletedSessionDirectory = nil
            self.liveSegments = []
            self.liveTranscriptionStatus = ""
            self.additionalNotes = ""
            self.additionalNotesSaveStatus = ""
            self.status = "Recording discarded"
            await coordinator.endRecordingWithoutEnqueue()
            self.isFinalizingRecording = false
        }
    }

    func deleteCompletedAudio() {
        guard let directory = lastCompletedSessionDirectory else { return }
        guard !isTranscribing, TranscriptIntegrity.isComplete(at: directory) else {
            status = "Finish or retry transcription before deleting its source audio."
            return
        }
        do {
            try MeetingNotesService.deleteAudio(for: directory)
            status = "Audio deleted — transcript and notes are kept"
        } catch {
            status = "⚠ Couldn’t delete audio: \(error.localizedDescription)"
        }
    }

    func deleteCompletedMeeting() {
        guard !isTranscribing else {
            status = "Wait for transcription to finish before deleting the meeting."
            return
        }
        guard let directory = lastCompletedSessionDirectory else { return }
        do {
            try MeetingNotesService.deleteMeeting(for: directory)
            lastCompletedSessionDirectory = nil
            showingCompletedRecording = false
            recordingTitle = ""
            additionalNotes = ""
            liveSegments = []
            latestTranscript = "No transcript yet."
            status = "Meeting deleted"
        } catch {
            status = "⚠ Couldn’t delete meeting: \(error.localizedDescription)"
        }
    }

    func updateRecordingTitle(_ title: String) {
        recordingTitle = title
        session?.updateTitle(title)
        guard session == nil, let dir = lastCompletedSessionDirectory else { return }
        let metaURL = dir.appendingPathComponent("meta.json")
        guard var meta = (try? Data(contentsOf: metaURL))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { meta.removeValue(forKey: "title_override") }
        else { meta["title_override"] = trimmed }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    func updateAdditionalNotes(_ notes: String) {
        additionalNotes = notes
        _ = persistAdditionalNotes()
    }

    func retryAdditionalNotesSave() {
        _ = persistAdditionalNotes()
    }

    func retryTranscription(for sessionDirectory: URL) {
        status = "Retrying transcription…"
        Task { [coordinator] in await coordinator.enqueue(sessionDirectory) }
    }

    func revealRecording(at directory: URL) {
        let files = ["mic.caf", "system.caf"].map { directory.appendingPathComponent($0) }
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(existing.isEmpty ? [directory] : existing)
    }

    func togglePause() {
        guard !isFinalizingRecording, let session, recording else { return }
        do {
            if isPaused {
                try session.resume()
                if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
                self.pausedAt = nil
                isPaused = false
                status = "● Recording resumed"
                if !liveTranscriptionSuspendedForResources {
                    startLiveTranscription(for: session)
                }
            } else {
                session.pause()
                pausedAt = Date()
                isPaused = true
                status = "Recording paused"
                liveTranscriptionStatus = "Live transcription paused"
                Task { [coordinator] in await coordinator.stopLiveAndWait() }
            }
        } catch {
            status = "⚠ Couldn’t resume recording: \(error)"
        }
    }

    func dismissCompletedRecording() {
        guard persistAdditionalNotes() else { return }
        showingCompletedRecording = false
        draftMeetingTitle = upcomingMeeting?.title ?? ""
    }

    /// Engine spec string for the meeting-notes summarizer.
    func engineSpec() -> String {
        selectedModel.engineSpec
    }

    var summaryModelActionMessage: String? {
        if isSummarizing { return "A summary is already running. Wait for it to finish or cancel it first." }
        if isTranscribing {
            return "Wait for transcription to finish before generating a summary."
        }
        if recording || isStartingRecording {
            return "Finish the recording before generating a summary. Sekitiri keeps all available resources focused on preserving the call."
        }
        if selectedModel.id == ModelItem.appleIntelligence.id,
           !LocalSummaryRuntime.appleFoundationModelAvailable {
            return "Apple Intelligence is unavailable on this Mac. Choose Qwen3.5 and download it in Settings."
        }
        guard selectedModel.requiresDownload else { return nil }
        switch localSummaryModelState {
        case .ready: return nil
        case .notDownloaded: return "Download Qwen3.5 in Settings before summarising."
        case .downloading: return "Qwen3.5 is still downloading."
        case .loading: return "Qwen3.5 is loading for another summary."
        case .failed(let message): return message
        }
    }

    func refreshLocalSummaryModelState() async {
        guard !localSummaryModelState.isBusy else { return }
        guard let selection = selectedModel.localModel else {
            localSummaryModelState = .ready
            return
        }
        let downloaded = await LocalSummaryRuntime.shared.isDownloaded(model: selection)
        guard selectedModel.localModel == selection || !selectedModel.requiresDownload else { return }
        localSummaryModelState = downloaded ? .ready : .notDownloaded
    }

    func downloadLocalSummaryModel() {
        guard summaryDownloadTask == nil else { return }
        guard !recording, !isStartingRecording else {
            status = "Finish the recording before downloading a local model"
            return
        }
        guard let selection = selectedModel.localModel else { return }
        localSummaryModelState = .downloading(0)
        summaryDownloadTask = Task { [weak self] in
            do {
                try await LocalSummaryRuntime.shared.download(model: selection) { [weak self] progress in
                    if self?.selectedModel.localModel == selection {
                        self?.localSummaryModelState = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { throw CancellationError() }
                if self?.selectedModel.localModel == selection { self?.localSummaryModelState = .ready }
            } catch is CancellationError {
                let downloaded = await LocalSummaryRuntime.shared.isDownloaded(model: selection)
                if self?.selectedModel.localModel == selection { self?.localSummaryModelState = downloaded ? .ready : .notDownloaded }
            } catch {
                if self?.selectedModel.localModel == selection { self?.localSummaryModelState = .failed(error.localizedDescription) }
            }
            self?.summaryDownloadTask = nil
            if self?.selectedModel.localModel != selection { self?.localSummaryModelState = .notDownloaded }
            await self?.refreshLocalSummaryModelState()
        }
    }

    func cancelLocalSummaryModelDownload() {
        summaryDownloadTask?.cancel()
    }

    func removeLocalSummaryModel() async {
        summaryDownloadTask?.cancel()
        summaryDownloadTask = nil
        do {
            try await LocalSummaryRuntime.shared.removeDownload(model: selectedModel.localModel ?? .qwen2B)
            localSummaryModelState = .notDownloaded
        } catch {
            localSummaryModelState = .failed(error.localizedDescription)
        }
    }

    func summarizeMeeting(
        session: URL,
        tone: String,
        prompt: String,
        progress: @MainActor @Sendable @escaping (SummaryProgress) -> Void
    ) async throws {
        if let message = summaryModelActionMessage {
            throw MeetingNotesService.ServiceError.failed(message)
        }
        let selection = selectedModel
        let usesQwen = selection.requiresDownload
        isSummarizing = true
        if usesQwen { localSummaryModelState = .loading }
        let task = Task {
            try await MeetingNotesService.summarize(
                session: session, engine: selection.engineSpec, tone: tone,
                prompt: prompt, progress: progress
            )
        }
        activeSummaryTask = task
        defer {
            activeSummaryTask = nil
            isSummarizing = false
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            if usesQwen { localSummaryModelState = .ready }
            if selectedModel.id != selection.id {
                localSummaryModelState = .notDownloaded
                await refreshLocalSummaryModelState()
            }
        } catch {
            // A malformed summary or a cancelled generation does not damage a
            // downloaded model. Keep Regenerate available for another attempt;
            // the caller displays the generation error separately.
            localSummaryModelState = .notDownloaded
            await refreshLocalSummaryModelState()
            throw error
        }
    }

    // MARK: Private

    private func refreshReadyStateAfterUnload() {
        if localSummaryModelState == .loading { localSummaryModelState = .ready }
    }

    /// Writes both active and completed-recording notes to their durable session
    /// folder. The editor's in-memory text is intentionally never cleared on a
    /// failure, and leaving the completed screen is blocked until it is saved.
    @discardableResult
    private func persistAdditionalNotes(using activeSession: RecordingSession? = nil) -> Bool {
        do {
            if let activeSession = activeSession ?? session {
                try activeSession.saveAdditionalNotes(additionalNotes)
            } else if let directory = lastCompletedSessionDirectory {
                try additionalNotes.write(
                    to: directory.appendingPathComponent("additional-notes.md"),
                    atomically: true,
                    encoding: .utf8
                )
            } else {
                return true
            }
            additionalNotesSaveStatus = "Saved automatically"
            additionalNotesSaveError = nil
            return true
        } catch {
            additionalNotesSaveStatus = ""
            additionalNotesSaveError = "Couldn’t save your additional notes. They are still in this editor—please retry before leaving."
            status = "⚠ Additional notes could not be saved"
            return false
        }
    }

    private func tick() {
        guard let session else { return }
        elapsed = Self.format(elapsedDuration(for: session))
        session.checkpoint()
        protectRecordingFromThermalPressureIfNeeded()
        evaluateRecordingSafety(now: Date())
        pollLatestTranscript()
    }

    private func protectRecordingFromThermalPressureIfNeeded() {
        guard recording, !liveTranscriptionSuspendedForResources else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            liveTranscriptionSuspendedForResources = true
            liveTranscriptionStatus = "Background transcription paused because this Mac is under heavy load. Recording continues safely."
            status = "● Recording · live transcript paused under heavy load"
            Task { [coordinator] in await coordinator.stopLiveAndWait() }
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
    }

    /// Elapsed capture time excludes every completed pause and the current pause,
    /// if one is in progress. Keeping this calculation shared ensures the frozen
    /// display while paused matches the final duration shown after Stop.
    private func elapsedDuration(for session: RecordingSession, at date: Date = Date()) -> TimeInterval {
        let activePauseDuration = pausedAt.map { date.timeIntervalSince($0) } ?? 0
        return max(0, date.timeIntervalSince(session.startedAt) - pausedDuration - activePauseDuration)
    }

    private func startLiveTranscription(for session: RecordingSession) {
        guard !liveTranscriptionSuspendedForResources else { return }
        liveTranscriptionStatus = "Preparing local transcription…"
        Task { [coordinator] in
            await coordinator.startBackgroundTranscription(session: session, onUpdate: { [weak self] segments in
                Task { @MainActor [weak self] in
                    guard self?.session?.dir == session.dir else { return }
                    self?.liveSegments = segments
                }
            }, onStatus: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard self?.session?.dir == session.dir else { return }
                    self?.liveTranscriptionStatus = message
                    if !(self?.isPaused ?? false) { self?.status = message }
                }
            })
        }
    }

    private func captureHealthDidChange(_ health: RecordingSession.CaptureHealth) {
        switch health {
        case .idle:
            captureHealthStatus = "Capture stopped"
        case .recording(let microphone, let systemAudio):
            captureHealthStatus = "\(microphone.label) · \(systemAudio.label)"
        case .paused(let microphone, let systemAudio):
            captureHealthStatus = "Paused · \(microphone.label) · \(systemAudio.label)"
        case .degraded(_, _, let message):
            captureHealthStatus = message
            notifyUser(title: "Sekitiri — capture connection changed", body: message)
        }
    }

    private func audioActivityDidChange(_ active: Bool) {
        guard active, recording, !isPaused else { return }
        hasAudioActivity = true
        lastAudioActivityAt = Date()
    }

    private func syncCalendarState() {
        calendarService.refresh()
        activeMeeting = calendarService.activeMeeting
        upcomingMeeting = calendarService.upcomingMeeting
        todaySchedule = calendarService.todaySchedule
        if !recording, draftMeetingTitle.isEmpty {
            draftMeetingTitle = activeMeeting?.title ?? upcomingMeeting?.title ?? ""
        }
        // Allow a later re-entry to the same browser call to prompt again,
        // while keeping the stable ID debounced during one continuous call.
        if calendarService.detectedCall == nil {
            promptedCallIDs.removeAll()
        }
        sendMeetingReminderIfNeeded(for: upcomingMeeting)
        promptForDetectedCallIfNeeded()
        evaluateRecordingSafety(now: Date())

    }

    private func evaluateRecordingSafety(now: Date) {
        guard recording, !isPaused, recordingSafetyPrompt == nil else { return }
        let duration = elapsedDuration(for: session!, at: now)
        let reminderMarks = [(60, "You have been recording for one hour."), (90, "You have been recording for 90 minutes.")]
        for (minutes, message) in reminderMarks where duration >= TimeInterval(minutes * 60) {
            guard longRecordingReminderMinutes.insert(minutes).inserted else { continue }
            recordingSafetyStatus = message + " Sekitiri will keep recording until you stop it."
            notifyUser(title: "Sekitiri — recording still active", body: recordingSafetyStatus)
        }

        if let timeout = UserDefaults.standard.object(forKey: "recordingSafetyTimeoutMinutes") as? Int,
           timeout > 0, duration >= TimeInterval(timeout * 60),
           safetyPromptKeys.insert("timeout-\(timeout)").inserted {
            notifyUser(title: "Sekitiri — safety timeout reached", body: "The configured recording safety timeout has stopped this recording.")
            stop()
            return
        }

        if let meeting = recordingMeeting, meeting.end <= now,
           safetyPromptKeys.insert("calendar-end-\(meeting.eventID)").inserted {
            recordingSafetyPrompt = RecordingSafetyPrompt(
                reason: "Calendar event ended",
                detail: "\(meeting.title) has reached its scheduled end. The recording is still running."
            )
            return
        }

        if recordingCallWasDetected,
           calendarService.detectedCall == nil,
           safetyPromptKeys.insert("call-ended").inserted {
            recordingSafetyPrompt = RecordingSafetyPrompt(
                reason: "Call no longer detected",
                detail: "Sekitiri can no longer see the browser or Teams call that was detected when recording started."
            )
        }
    }

    func keepRecordingAfterSafetyPrompt() {
        recordingSafetyPrompt = nil
        recordingSafetyStatus = "Still recording — stop manually when the meeting is over."
    }

    private func sendMeetingReminderIfNeeded(for meeting: MeetingContext?) {
        guard UserDefaults.standard.object(forKey: "meetingReminders") as? Bool ?? true,
              let meeting else { return }
        let seconds = meeting.start.timeIntervalSinceNow
        guard seconds > 0, seconds <= 300, remindedMeetingIDs.insert(meeting.eventID).inserted else { return }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        notifyUser(
            title: "Sekitiri — \(meeting.title) in \(minutes)m",
            body: "Ready to record? Remember to get consent before starting."
        )
    }

    private func promptForDetectedCallIfNeeded() {
        guard let call = calendarService.detectedCall, !recording,
              promptedCallIDs.insert(call.eventID).inserted else { return }
        notifyUser(
            title: "Sekitiri — \(call.title) detected",
            body: call.isCalendarBacked
                ? "Your calendar meeting appears to be active. Open Sekitiri to start a local recording."
                : "A possible call is open. Open Sekitiri to confirm and start recording."
        )
        detectedCallPrompt = call
    }

    private func transcriptionStatus(_ state: TranscriptionCoordinator.Status) {
        switch state {
        case .idle:
            isTranscribing = false
        case .transcribing(let name, let queued):
            isTranscribing = true
            status = "Finishing transcript for \(name)\(queued > 0 ? " · \(queued) queued" : "")…"
        case .ready(let name, let issues):
            // The final job may still be releasing its model or enriching
            // speaker labels; .idle releases the shared resource permit.
            status = issues.isEmpty ? "Transcript ready · \(name)"
                : "⚠ Transcript incomplete: \(issues.joined(separator: "; "))"
            liveTranscriptionStatus = issues.isEmpty ? "Transcript saved" : "Some audio needs attention"
            pollLatestTranscript()
        case .failed(let name, let message):
            isTranscribing = false
            status = "⚠ Transcription needs attention: \(name) — \(message)"
            liveTranscriptionStatus = "Your recording and completed sections were preserved for retry."
        }
    }

    private func startTranscriptPolling() {
        transcriptPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLatestTranscript() }
        }
    }

    private func pollLatestTranscript() {
        guard !recording else { return }
        let root = AppModel.recordingsRoot()
        guard let latest = newestRecording(in: root) else { return }
        let diarized = latest.appendingPathComponent("transcript.diarized.md")
        let plain = latest.appendingPathComponent("transcript.md")
        // New pipeline writes canonical plain text. Legacy diarization is only
        // preferred for a recording that has never used the new format.
        let modern = FileManager.default.fileExists(atPath: latest.appendingPathComponent("transcription-settings.json").path)
        let path = !modern && FileManager.default.fileExists(atPath: diarized.path) ? diarized : plain
        if let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty {
            latestTranscript = text
            lastTranscriptPath = path.path
            liveSegments = []
        }
    }

    private func newestRecording(in root: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func relative(_ date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSinceNow / 60))
        return mins == 0 ? "starting now" : "in \(mins)m"
    }
}

// MARK: - App entry

@main
struct SekitiriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 960, height: 680)
    }
}

// MARK: - App delegate (menu bar, control server)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var controlServer: RecordingControlServer?
    private var recordingMenuItem: NSMenuItem?
    private var globalStopMonitor: Any?
    private var localStopMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Sekitiri is also the meeting detector. Closing the window should
        // leave the menu-bar process alive so reminders and browser checks
        // continue without requiring a second helper app.
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        controlServer = try? RecordingControlServer { [weak self] action in
            Task { @MainActor in
                switch action {
                case "stop":  self?.model.stop()
                default: break
                }
            }
        }
        controlServer?.start()

        // ⌥⌘R is a native emergency stop. It never starts recording and does
        // not inspect keystrokes other than this exact registered combination.
        let handleStopShortcut: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 15, flags.contains([.command, .option]) else { return }
            Task { @MainActor [weak self] in self?.model.stop() }
        }
        globalStopMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleStopShortcut)
        localStopMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 15, flags.contains([.command, .option]) else { return event }
            handleStopShortcut(event)
            return nil
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "waveform.circle",
                                accessibilityDescription: "Sekitiri")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let rec = NSMenuItem(title: "● Start Recording",
                             action: #selector(toggleRecording), keyEquivalent: "")
        rec.target = self
        menu.addItem(rec)
        recordingMenuItem = rec
        menu.addItem(NSMenuItem.separator())
        let open = NSMenuItem(title: "Open Sekitiri",
                              action: #selector(openWindow), keyEquivalent: "w")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Sekitiri",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc func toggleRecording() {
        if model.isStartingRecording { model.stop() }
        else { model.toggleRecording() }
    }
    @objc func openWindow() { NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { NSApp.terminate(nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        recordingMenuItem?.title = model.recording
            ? "■ Stop Recording"
            : model.isStartingRecording ? "■ Cancel Recording Start" : "● Start Recording"
    }
}
