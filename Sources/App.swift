import AppKit
import Combine
import EventKit
import SwiftUI

struct RecordingSafetyPrompt: Identifiable {
    let id = UUID()
    let reason: String
    let detail: String
}

/// Presentation state of one capture track (microphone or system audio).
enum CaptureTrackState: Equatable {
    case off
    case recording
    case paused
    case degraded(String)

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }
}

/// How the single status line should be presented.
enum AppStatusTone: Equatable {
    case normal
    case recording
    case warning
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
    /// The one user-facing status line. Set through `setStatus(_:tone:)`.
    @Published private(set) var status = "Ready"
    @Published private(set) var statusTone: AppStatusTone = .normal
    @Published var liveSegments: [TranscriptionCoordinator.LiveSegment] = []
    @Published var liveTranscriptionStatus = ""
    @Published var detectedCallPrompt: MeetingContext?
    @Published var showingCompletedRecording = false
    @Published var draftMeetingTitle = ""
    @Published var recordingTitle = ""
    @Published var additionalNotes = ""
    @Published var additionalNotesSaveStatus = ""
    @Published var additionalNotesSaveError: String?
    @Published var recordingSafetyPrompt: RecordingSafetyPrompt?
    /// Set by the menu bar or other windows; ContentView consumes it.
    @Published var requestedMeetingID: String?
    @Published var requestedSection: String?
    /// Moments marked during the current (or just finished) recording.
    @Published private(set) var markedMoments: [MarkedMoment] = []
    /// A short confirmation at the bottom of the window, optionally undoable.
    @Published private(set) var toast: AppToast?
    private var toastUndo: (() -> Void)?
    private var toastDismissTask: Task<Void, Never>?
    private var queuedToasts: [String] = []
    /// Start of the current (or just-finished) recording.
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var microphoneTrack: CaptureTrackState = .off
    @Published private(set) var systemAudioTrack: CaptureTrackState = .off
    @Published private(set) var microphoneDeviceName: String?
    /// True while either track has reported sound within the last moment.
    @Published private(set) var isHearingAudio = false
    /// No sound reached either track for 30 seconds while recording.
    @Published private(set) var noSoundWarning = false
    /// The microphone alone has been silent for two minutes while other
    /// participants were still audible: likely the wrong or a muted input.
    @Published private(set) var micSilenceWarning = false
    /// The microphone is delivering exact digital silence, which a working
    /// mic never does: macOS is blocking it or it is muted.
    @Published private(set) var micSendingNothing = false
    /// When the stop-after-silence safety will stop the recording.
    @Published private(set) var silenceStopDeadline: Date?
    /// Post-recording processing: stage from coordinator status events,
    /// fraction and time estimate from its progress reports.
    @Published var transcriptionProgress: TranscriptionProgressInfo?
    @Published private(set) var lastCompletedSessionDirectory: URL?
    /// Bumped whenever meetings on disk change (transcript ready, deleted…).
    @Published private(set) var archiveRevision = 0
    /// A session whose summary should start when its meeting page opens.
    @Published var pendingSummarySession: URL?
    @Published private(set) var calendarAuthorization: EKAuthorizationStatus
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
    private var ticker: Timer?
    private let coordinator = TranscriptionCoordinator()
    private let calendarService: CalendarService
    private var calendarTimer: Timer?
    private var calendarAuthorizationObserver: AnyCancellable?
    /// Every start gets a token. A Stop pressed while setup is still in flight
    /// invalidates that token, so a delayed audio setup can never turn itself
    /// into a recording after the user has cancelled it.
    private var recordingStartGeneration = 0
    private var recordingMeeting: MeetingContext?
    private var lastAudioActivityAt: Date?
    private var lastMicActivityAt: Date?
    static let micSilenceWarningSeconds: TimeInterval = 120
    private var lastMicSignalAt: Date?
    private var micSendingNothingNotified = false
    nonisolated static let micNoSignalWarningSeconds: TimeInterval = 30
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

    static let noSoundWarningSeconds: TimeInterval = 30
    static let silenceStopWarningSeconds: TimeInterval = 60

    init() {
        let defaults = UserDefaults.standard
        // `autoRecord` is written on every launch below, so its absence marks
        // the very first launch of any Sekitiri build.
        let isFirstLaunch = defaults.object(forKey: "autoRecord") == nil
        if isFirstLaunch {
            // New installs opt in to browser-tab detection (NEW-USER-SETTINGS).
            // An existing stored choice is never overridden.
            if defaults.object(forKey: "browserCallDetection") == nil {
                defaults.set(false, forKey: "browserCallDetection")
            }
        } else if defaults.object(forKey: "hasCompletedOnboarding") == nil {
            // Existing installs were already set up; Settings can rerun setup.
            defaults.set(true, forKey: "hasCompletedOnboarding")
        }

        let savedSummaryModel = defaults.string(forKey: "summaryModel")
        let legacyModelIDs = ["qwen3-4b", "gemma3n-e2b"]
        let initialSummaryModel = ModelItem.initialSelection(savedID: savedSummaryModel)
        selectedModel = initialSummaryModel
        if let savedSummaryModel, legacyModelIDs.contains(savedSummaryModel) {
            defaults.set(initialSummaryModel.id, forKey: "summaryModel")
        }
        // Older builds exposed an auto-record preference. Never honour a value
        // left behind by those versions: calendar and browser signals may only
        // prompt the user, never begin capture without an explicit action.
        defaults.set(false, forKey: "autoRecord")
        calendarService = CalendarService()
        calendarAuthorization = calendarService.authorizationStatus
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
        calendarAuthorizationObserver = calendarService.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.calendarAuthorization = status }
            }
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
                    self.liveTranscriptionStatus = "Live transcript paused to protect your recording. Saved audio will be transcribed after the meeting."
                }
                self.refreshReadyStateAfterUnload()
            }
        }
        pressure.resume()
        memoryPressureSource = pressure
    }

    nonisolated static func recordingsRoot() -> URL {
        Config.resolveRoot(cliOverride: nil)
    }

    var isCalendarConnected: Bool { calendarAuthorization == .fullAccess }

    func toggleRecording() { recording || isStartingRecording ? stop() : startIfNotRecording() }

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
        if !isCalendarConnected { return "Calendar isn’t connected" }
        if let activeMeeting { return "In meeting: \(activeMeeting.title)" }
        if let upcomingMeeting {
            return "Next: \(upcomingMeeting.title) · \(Self.relative(upcomingMeeting.start))"
        }
        return "No upcoming meetings"
    }

    func setStatus(_ text: String, tone: AppStatusTone = .normal) {
        status = text
        statusTone = tone
    }

    func start(context: MeetingContext? = nil, customTitle: String? = nil) {
        guard !recording && !isStartingRecording && !isFinalizingRecording else { return }
        let devices = AudioInputDevice.available()
        guard !devices.isEmpty else {
            setStatus("No microphone is available. Connect or enable one, then try again.", tone: .warning)
            notifyUser(title: "Sekitiri — recording unavailable", body: "Connect or enable a microphone, then try again.")
            return
        }
        let requestedDeviceID = UserDefaults.standard.string(forKey: "inputDeviceID")
        let inputDeviceID = devices.contains(where: { $0.id == requestedDeviceID }) ? requestedDeviceID : AudioInputDevice.defaultID()
        let systemAudio = UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true
        let source = context ?? calendarService.activeMeeting ?? upcomingMeeting
        // The draft title is pre-filled from the calendar; only a title the
        // user actually changed becomes an override.
        let typedTitle = customTitle ?? (context == nil && draftMeetingTitle != source?.title ? draftMeetingTitle : nil)
        let requestedTitle = typedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meeting = source.map { MeetingContext(eventID: $0.eventID, title: requestedTitle.isEmpty ? $0.title : requestedTitle, start: $0.start, end: $0.end, attendees: $0.attendees, meetingURL: $0.meetingURL) }
            ?? (requestedTitle.isEmpty ? nil : MeetingContext(eventID: "manual-\(UUID().uuidString)", title: requestedTitle, start: Date(), end: Date().addingTimeInterval(3600), attendees: [], meetingURL: nil))

        isStartingRecording = true
        recordingStartGeneration &+= 1
        let startGeneration = recordingStartGeneration
        showingCompletedRecording = false
        transcriptionProgress = nil
        recordingTitle = meeting?.title ?? (requestedTitle.isEmpty ? "Untitled meeting" : requestedTitle)
        setStatus("Starting recorder…")
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
        recordingStartedAt = newSession.startedAt
        recordingMeeting = meeting
        recordingCallWasDetected = calendarService.detectedCall != nil
            || meeting?.eventID.hasPrefix("browser-") == true
            || meeting?.eventID.hasPrefix("teams-desktop-") == true
        safetyPromptKeys.removeAll()
        longRecordingReminderMinutes.removeAll()
        recordingSafetyPrompt = nil
        resetCaptureIndicators(activityAt: Date())
        isStartingRecording = false
        isPaused = false
        pausedDuration = 0
        pausedAt = nil
        markedMoments = []
        additionalNotes = ""
        additionalNotesSaveStatus = ""
        additionalNotesSaveError = nil
        draftMeetingTitle = ""
        setStatus("Recording", tone: .recording)
        liveSegments = []
        liveTranscriptionStatus = "Preparing local transcription…"
        liveTranscriptionSuspendedForResources = false
        newSession.onCaptureHealthChange = { [weak self] health in
            Task { @MainActor [weak self] in self?.captureHealthDidChange(health) }
        }
        newSession.onAudioActivityChange = { [weak self] active in
            Task { @MainActor [weak self] in self?.audioActivityDidChange(active) }
        }
        newSession.onMicActivityChange = { [weak self] active in
            Task { @MainActor [weak self] in
                guard let self, active, self.recording, !self.isPaused else { return }
                self.lastMicActivityAt = Date()
                if self.micSilenceWarning { self.micSilenceWarning = false }
            }
        }
        newSession.onMicSignal = { [weak self] hasSignal in
            Task { @MainActor [weak self] in
                guard let self, hasSignal, self.recording, !self.isPaused else { return }
                self.lastMicSignalAt = Date()
                if self.micSendingNothing { self.micSendingNothing = false }
            }
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
        setStatus("Recording couldn’t start: \(error.localizedDescription)", tone: .warning)
        Task { [coordinator] in await coordinator.endRecordingWithoutEnqueue() }
        notifyUser(title: "Sekitiri — recording failed", body: error.localizedDescription)
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
        setStatus("Saving recording…")
        elapsed = TranscriptDocument.clock(secs)
        ticker?.invalidate()
        ticker = nil
        _ = persistAdditionalNotes(using: session)
        Task { [weak self, coordinator] in
            // Stop closes encoders and joins files on the capture queue. The
            // interface remains responsive and background ASR sources survive.
            let invalidTracks = await session.stop()
            guard let self else { return }
            if invalidTracks.isEmpty {
                self.setStatus("Recording saved")
            } else {
                self.setStatus("Recording needs attention: \(invalidTracks.joined(separator: ", ")). Available audio was preserved.", tone: .warning)
                notifyUser(title: "Sekitiri — recording needs attention",
                           body: invalidTracks.joined(separator: ", "))
            }
            self.lastCompletedSessionDirectory = session.dir
            self.session = nil
            self.recording = false
            self.isPaused = false
            self.showingCompletedRecording = true
            self.recordingMeeting = nil
            self.resetCaptureIndicators(activityAt: nil)
            self.recordingCallWasDetected = false
            self.liveTranscriptionSuspendedForResources = false
            self.recordingSafetyPrompt = nil
            self.liveTranscriptionStatus = ""
            let transcribes = Config.transcriptionEnabled()
            self.isTranscribing = transcribes
            self.transcriptionProgress = transcribes
                ? TranscriptionProgressInfo(session: session.dir.lastPathComponent, fractionCompleted: nil,
                                            secondsRemaining: nil, stage: TranscriptionProgressInfo.Stage.saved)
                : nil
            self.archiveRevision &+= 1
            await LocalSummaryRuntime.shared.unload()
            await coordinator.endRecordingAndEnqueue(session.dir)
            self.isFinalizingRecording = false
        }
    }

    /// Used when quitting: stops capture and waits (bounded) until files are closed.
    func stopAndWaitForSave() async {
        if recording || isStartingRecording { stop() }
        let deadline = Date().addingTimeInterval(15)
        while (recording || isFinalizingRecording), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
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
        setStatus("Recording start cancelled")
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
        setStatus("Discarding recording…")
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
            self.resetCaptureIndicators(activityAt: nil)
            self.recordingStartedAt = nil
            self.lastCompletedSessionDirectory = nil
            self.liveSegments = []
            self.liveTranscriptionStatus = ""
            self.additionalNotes = ""
            self.additionalNotesSaveStatus = ""
            self.setStatus("Recording discarded")
            await coordinator.endRecordingWithoutEnqueue()
            self.isFinalizingRecording = false
        }
    }

    func deleteCompletedAudio() {
        guard let directory = lastCompletedSessionDirectory else { return }
        deleteAudio(session: directory)
    }

    /// Moves a meeting's original audio to the Trash. Its transcript, notes
    /// and action items stay; the toast's Undo puts the audio back.
    @discardableResult
    func deleteAudio(session directory: URL) -> Bool {
        guard !isTranscribing, TranscriptIntegrity.isComplete(at: directory) else {
            setStatus("Finish or retry transcription before deleting its source audio.", tone: .warning)
            return false
        }
        do {
            let trashed = try MeetingNotesService.trashAudio(for: directory)
            archiveRevision &+= 1
            showToast("Audio moved to the Trash. Transcript and notes are kept.") { [weak self] in
                do {
                    try MeetingNotesService.restore(trashed)
                    self?.archiveRevision &+= 1
                    self?.showToast("Audio restored")
                } catch {
                    self?.showToast("Couldn’t restore the audio. It’s still in the Trash.")
                }
            }
            return true
        } catch {
            setStatus("Couldn’t delete audio: \(error.localizedDescription)", tone: .warning)
            return false
        }
    }

    func deleteCompletedMeeting() {
        guard let directory = lastCompletedSessionDirectory else { return }
        guard deleteMeeting(session: directory) else { return }
        lastCompletedSessionDirectory = nil
        showingCompletedRecording = false
        transcriptionProgress = nil
        recordingTitle = ""
        additionalNotes = ""
        liveSegments = []
    }

    /// Deletes a meeting's capture folder and its vault copy. Returns false and
    /// explains why when deletion isn't safe right now.
    @discardableResult
    func deleteMeeting(session directory: URL) -> Bool {
        guard !isTranscribing else {
            setStatus("Wait for transcription to finish before deleting a meeting.", tone: .warning)
            return false
        }
        do {
            let trashed = try MeetingNotesService.trashMeeting(for: directory)
            if lastCompletedSessionDirectory?.standardizedFileURL == directory.standardizedFileURL {
                lastCompletedSessionDirectory = nil
                showingCompletedRecording = false
                transcriptionProgress = nil
            }
            archiveRevision &+= 1
            showToast("Meeting moved to the Trash") { [weak self] in
                do {
                    try MeetingNotesService.restore(trashed)
                    self?.archiveRevision &+= 1
                    self?.showToast("Meeting restored")
                } catch {
                    self?.showToast("Couldn’t restore the meeting. It’s still in the Trash.")
                }
            }
            return true
        } catch {
            setStatus("Couldn’t delete meeting: \(error.localizedDescription)", tone: .warning)
            return false
        }
    }

    // MARK: Marked moments

    /// Saves the current point in the recording, labelled with the newest
    /// live line so the moment is recognisable later.
    func markMoment() {
        guard recording, !isPaused, let session else { return }
        let seconds = elapsedDuration(for: session)
        let latest = liveSegments.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = latest.isEmpty ? "Marked moment" : String(latest.prefix(70)) + (latest.count > 70 ? "…" : "")
        markedMoments.append(MarkedMoment(seconds: seconds, label: label))
        MarkedMoment.save(markedMoments, in: session.dir)
        showToast("Moment marked at \(TranscriptDocument.clock(seconds))")
    }

    // MARK: Toasts

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        // A plain message waits its turn rather than taking away a pending Undo.
        if undo == nil, toastUndo != nil {
            queuedToasts.append(message)
            return
        }
        toastDismissTask?.cancel()
        toast = AppToast(message: message, canUndo: undo != nil)
        toastUndo = undo
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 3 : 7))
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
        toastUndo = nil
        if !queuedToasts.isEmpty { showToast(queuedToasts.removeFirst()) }
    }

    func undoToast() {
        let undo = toastUndo
        dismissToast()
        undo?()
    }

    /// Renames a saved meeting. An empty title restores the original name.
    @discardableResult
    func renameMeeting(_ item: MeetingItem, to title: String) -> Bool {
        do {
            try MeetingLibrary.rename(item, to: title)
            archiveRevision &+= 1
            return true
        } catch {
            return false
        }
    }

    func updateRecordingTitle(_ title: String) {
        recordingTitle = title
        session?.updateTitle(title)
        guard session == nil, let dir = lastCompletedSessionDirectory else { return }
        try? MeetingLibrary.setTitleOverride(title, in: dir.appendingPathComponent("meta.json"))
    }

    func updateAdditionalNotes(_ notes: String) {
        additionalNotes = notes
        _ = persistAdditionalNotes()
    }

    func retryAdditionalNotesSave() {
        _ = persistAdditionalNotes()
    }

    func retryTranscription(for sessionDirectory: URL) {
        setStatus("Retrying transcription…")
        if sessionDirectory.standardizedFileURL == lastCompletedSessionDirectory?.standardizedFileURL {
            transcriptionProgress = TranscriptionProgressInfo(
                session: sessionDirectory.lastPathComponent, fractionCompleted: nil,
                secondsRemaining: nil, stage: TranscriptionProgressInfo.Stage.saved
            )
        }
        Task { [coordinator] in await coordinator.enqueue(sessionDirectory) }
    }

    /// Asks for audio or video files and imports them.
    func chooseAudioToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.message = "Choose recordings to transcribe. The originals aren’t changed."
        panel.allowedContentTypes = AudioImport.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importAudio(from: panel.urls)
    }

    /// Imports existing recordings as meetings, transcribes them like any
    /// other, and opens the first one. Transcription waits while recording.
    func importAudio(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        showToast(urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…")
        Task {
            var imported: [URL] = []
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    imported.append(try await AudioImport.importFile(url, into: Self.recordingsRoot()))
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            for directory in imported {
                await coordinator.enqueue(directory)
            }
            archiveRevision &+= 1
            if let first = imported.first {
                requestedMeetingID = first.lastPathComponent
            }
            if let failure = failures.first {
                setStatus(failures.count == 1 ? failure : "\(failures.count) files couldn’t be imported. \(failure)", tone: .warning)
            }
            if !imported.isEmpty {
                showToast(recording
                    ? "Imported. Transcription starts when this recording ends."
                    : imported.count == 1 ? "Imported. Transcribing now." : "Imported \(imported.count) files. Transcribing now.")
            }
        }
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
                // Paused time is never counted as silence.
                lastAudioActivityAt = Date()
                lastMicActivityAt = Date()
                lastMicSignalAt = Date()
                setStatus("Recording", tone: .recording)
                if !liveTranscriptionSuspendedForResources {
                    startLiveTranscription(for: session)
                }
            } else {
                session.pause()
                pausedAt = Date()
                isPaused = true
                isHearingAudio = false
                noSoundWarning = false
                silenceStopDeadline = nil
                setStatus("Paused")
                liveTranscriptionStatus = "Live transcript paused"
                Task { [coordinator] in await coordinator.stopLiveAndWait() }
            }
        } catch {
            setStatus("Couldn’t resume recording: \(error.localizedDescription)", tone: .warning)
        }
    }

    /// Keeps recording after the stop-after-silence warning.
    func keepRecordingThroughSilence() {
        lastAudioActivityAt = Date()
        silenceStopDeadline = nil
        noSoundWarning = false
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
            return "Apple Intelligence isn’t available on this Mac. Choose Quick extract or Qwen 3.5."
        }
        guard selectedModel.requiresDownload else { return nil }
        switch localSummaryModelState {
        case .ready: return nil
        case .notDownloaded: return "Qwen 3.5 isn’t downloaded yet."
        case .downloading: return "Qwen 3.5 is still downloading."
        case .loading: return "Qwen 3.5 is loading for another summary."
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
            setStatus("Finish the recording before downloading a local model")
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
            archiveRevision &+= 1
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

    /// Clears every capture warning. Silence is measured from `activityAt`:
    /// now when a recording starts, nil once it has ended.
    private func resetCaptureIndicators(activityAt: Date?) {
        lastAudioActivityAt = activityAt
        lastMicActivityAt = activityAt
        lastMicSignalAt = activityAt
        micSendingNothingNotified = false
        isHearingAudio = false
        noSoundWarning = false
        micSilenceWarning = false
        micSendingNothing = false
        silenceStopDeadline = nil
        microphoneTrack = .off
        systemAudioTrack = .off
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
            return false
        }
    }

    private func tick() {
        guard let session else { return }
        let now = Date()
        elapsed = TranscriptDocument.clock(elapsedDuration(for: session, at: now))
        session.checkpoint()
        protectRecordingFromThermalPressureIfNeeded()
        if isHearingAudio, let last = lastAudioActivityAt, now.timeIntervalSince(last) > 2 {
            isHearingAudio = false
        }
        evaluateSilence(now: now)
        evaluateRecordingSafety(now: now)
    }

    private func protectRecordingFromThermalPressureIfNeeded() {
        guard recording, !liveTranscriptionSuspendedForResources else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            liveTranscriptionSuspendedForResources = true
            liveTranscriptionStatus = "Live transcript paused because this Mac is under heavy load. Recording continues safely."
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
                    // Transcript progress stays with the transcript; it never
                    // replaces the recording status line.
                    self?.liveTranscriptionStatus = message
                }
            })
        }
    }

    private func captureHealthDidChange(_ health: RecordingSession.CaptureHealth) {
        switch health {
        case .idle:
            microphoneTrack = .off
            systemAudioTrack = .off
        case .recording(let microphone, let systemAudio),
             .paused(let microphone, let systemAudio):
            applyTrackHealth(microphone: microphone, systemAudio: systemAudio)
        case .degraded(let microphone, let systemAudio, let message):
            applyTrackHealth(microphone: microphone, systemAudio: systemAudio)
            notifyUser(title: "Sekitiri — capture connection changed", body: message)
        }
    }

    private func applyTrackHealth(microphone: MicRecorder.Health, systemAudio: SystemAudioRecorder.Health) {
        switch microphone {
        case .idle: microphoneTrack = .off
        case .recording(let name): microphoneTrack = .recording; microphoneDeviceName = name
        case .paused(let name): microphoneTrack = .paused; microphoneDeviceName = name
        case .unavailable(let message): microphoneTrack = .degraded(message)
        }
        switch systemAudio {
        case .idle: systemAudioTrack = .off
        case .recording: systemAudioTrack = .recording
        case .paused: systemAudioTrack = .paused
        case .unavailable(let message): systemAudioTrack = .degraded(message)
        }
    }

    private func audioActivityDidChange(_ active: Bool) {
        guard active, recording, !isPaused else { return }
        lastAudioActivityAt = Date()
        if !isHearingAudio { isHearingAudio = true }
        if noSoundWarning { noSoundWarning = false }
        if silenceStopDeadline != nil { silenceStopDeadline = nil }
    }

    private func syncCalendarState() {
        calendarService.refresh()
        activeMeeting = calendarService.activeMeeting
        upcomingMeeting = calendarService.upcomingMeeting
        todaySchedule = calendarService.todaySchedule
        if !recording, !isStartingRecording, draftMeetingTitle.isEmpty {
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

    /// Exact digital silence for this long means the mic is blocked or muted,
    /// not just quiet.
    nonisolated static func micIsSendingNothing(since lastSignal: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSignal) >= micNoSignalWarningSeconds
    }

    /// Stop-after-silence: warns after 30 s without sound, warns again one
    /// minute before the configured silence limit, then stops and saves.
    private func evaluateSilence(now: Date) {
        guard recording, !isPaused, let session else { return }
        let reference = lastAudioActivityAt ?? session.startedAt
        let silence = now.timeIntervalSince(reference)
        let quiet = silence >= Self.noSoundWarningSeconds
        if noSoundWarning != quiet { noSoundWarning = quiet }
        let micSilence = now.timeIntervalSince(lastMicActivityAt ?? session.startedAt)
        let micQuiet = !quiet && micSilence >= Self.micSilenceWarningSeconds
        if micSilenceWarning != micQuiet { micSilenceWarning = micQuiet }
        let noSignal = Self.micIsSendingNothing(since: lastMicSignalAt ?? session.startedAt, now: now)
        if micSendingNothing != noSignal { micSendingNothing = noSignal }
        if noSignal, !micSendingNothingNotified {
            // Once per recording: the meeting app is usually in front.
            micSendingNothingNotified = true
            notifyUser(title: "Sekitiri — your microphone isn’t recording",
                       body: "It has sent no sound at all for 30 seconds. Check that Sekitiri is allowed to use the microphone and that it isn’t muted.")
        }

        let minutes = UserDefaults.standard.integer(forKey: "recordingSafetyTimeoutMinutes")
        guard minutes > 0 else {
            if silenceStopDeadline != nil { silenceStopDeadline = nil }
            return
        }
        let limit = TimeInterval(minutes * 60)
        if silence >= limit {
            silenceStopDeadline = nil
            notifyUser(title: "Sekitiri — recording stopped",
                       body: "No sound for \(minutes) minutes, so Sekitiri stopped and saved the recording.")
            stop()
        } else if silence >= limit - Self.silenceStopWarningSeconds {
            if silenceStopDeadline == nil {
                silenceStopDeadline = reference.addingTimeInterval(limit)
                notifyUser(title: "Sekitiri — no sound detected",
                           body: "Recording stops in about a minute unless sound resumes. Open Sekitiri to keep recording.")
            }
        } else if silenceStopDeadline != nil {
            silenceStopDeadline = nil
        }
    }

    private func evaluateRecordingSafety(now: Date) {
        guard recording, !isPaused, recordingSafetyPrompt == nil, let session else { return }
        let duration = elapsedDuration(for: session, at: now)
        let reminderMarks = [(60, "You’ve been recording for an hour."), (90, "You’ve been recording for 90 minutes.")]
        for (minutes, message) in reminderMarks where duration >= TimeInterval(minutes * 60) {
            guard longRecordingReminderMinutes.insert(minutes).inserted else { continue }
            setStatus("Recording · \(message)", tone: .recording)
            notifyUser(title: "Sekitiri — recording still active", body: message + " Sekitiri keeps recording until you stop it.")
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
        setStatus("Recording · stop manually when the meeting is over", tone: .recording)
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
        typealias Stage = TranscriptionProgressInfo.Stage
        switch state {
        case .idle:
            isTranscribing = false
            if transcriptionProgress?.stage == Stage.speakers {
                transcriptionProgress?.stage = Stage.ready
                transcriptionProgress?.fractionCompleted = 1
                transcriptionProgress?.secondsRemaining = nil
            }
            archiveRevision &+= 1
        case .transcribing(let name, let queued):
            isTranscribing = true
            if !recording, !isStartingRecording {
                setStatus(queued > 0 ? "Transcribing · \(queued) more queued" : "Transcribing")
            }
            if transcriptionProgress?.session == name {
                transcriptionProgress?.stage = Stage.transcribing
            } else if name == lastCompletedSessionDirectory?.lastPathComponent {
                transcriptionProgress = TranscriptionProgressInfo(session: name, fractionCompleted: nil,
                                                                  secondsRemaining: nil, stage: Stage.transcribing)
            }
        case .progress(let name, let progress):
            isTranscribing = true
            if transcriptionProgress?.session != name, name == lastCompletedSessionDirectory?.lastPathComponent {
                transcriptionProgress = TranscriptionProgressInfo(session: name, fractionCompleted: nil,
                                                                  secondsRemaining: nil, stage: Stage.transcribing)
            }
            guard transcriptionProgress?.session == name else { break }
            transcriptionProgress?.fractionCompleted = progress.fraction
            transcriptionProgress?.secondsRemaining = progress.secondsRemaining
            if progress.stage == .identifyingSpeakers { transcriptionProgress?.stage = Stage.speakers }
        case .ready(let name, let issues):
            // The final job may still be enriching speaker labels; .idle
            // releases the shared resource permit.
            if issues.isEmpty {
                if !recording, !isStartingRecording { setStatus("Transcript ready") }
                if transcriptionProgress?.session == name {
                    transcriptionProgress?.stage = Config.speakerDiarizationEnabled() ? Stage.speakers : Stage.ready
                    transcriptionProgress?.fractionCompleted = 1
                    transcriptionProgress?.secondsRemaining = nil
                }
            } else {
                if !recording, !isStartingRecording {
                    setStatus("Transcript incomplete — some audio couldn’t be transcribed. The recording is preserved.", tone: .warning)
                }
                if transcriptionProgress?.session == name { transcriptionProgress?.stage = Stage.failed }
            }
            archiveRevision &+= 1
        case .failed(let name, let message):
            isTranscribing = false
            if !recording, !isStartingRecording {
                setStatus("Transcription needs attention: \(message)", tone: .warning)
            }
            if transcriptionProgress?.session == name { transcriptionProgress?.stage = Stage.failed }
            archiveRevision &+= 1
        }
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
        Window("Sekitiri", id: MainWindow.id) {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    MainWindow.show()
                    NotificationCenter.default.post(name: .sekitiriShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            RecordingCommands(model: appDelegate.model)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appDelegate.model)
                .tint(SekitiriColor.terracotta)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reopens the single main window from AppKit code (menu bar, Dock).
@MainActor
enum MainWindow {
    static let id = "main"
    /// Captured from the window's environment the first time it appears.
    static var openAction: OpenWindowAction?

    static func show() {
        NSApp.activate()
        if let openAction {
            openAction(id: id)
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct RecordingCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Recording") {
            Button(model.recording ? "Stop Recording" : model.isStartingRecording ? "Cancel Recording Start" : "Start Recording") {
                model.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isFinalizingRecording)

            Button(model.isPaused ? "Resume Recording" : "Pause Recording") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.recording || model.isFinalizingRecording)

            Button("Mark Moment") { model.markMoment() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.recording || model.isPaused)
        }
        CommandGroup(after: .newItem) {
            Button("Import Audio…") { model.chooseAudioToImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

// MARK: - App delegate (menu bar, control server)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var controlServer: RecordingControlServer?
    private var globalStopMonitor: Any?
    private var localStopMonitor: Any?
    private var miniRecorder: MiniRecorderController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Sekitiri is also the meeting detector. Closing the window should
        // leave the menu-bar process alive so reminders and browser checks
        // continue without requiring a second helper app.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recording || model.isStartingRecording || model.isFinalizingRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = "Sekitiri will stop and save this recording first. Transcription continues the next time you open Sekitiri."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Recording")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor [model] in
            await model.stopAndWaitForSave()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DevSnapshot.runIfRequested(model: model)

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

        miniRecorder = MiniRecorderController(model: model)
    }
}
