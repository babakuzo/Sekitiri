import AVFoundation
import CoreAudio
import Foundation

/// Records all system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes every
/// process's output to stereo and hands us buffers through a private aggregate
/// device. First use triggers the one-time "System Audio Recording" TCC prompt
/// and lights the purple recording indicator while active.
final class SystemAudioRecorder: @unchecked Sendable {
    /// System audio is optional: a failure here must never discard the mic
    /// recording. Consumers can present this state independently from mic
    /// health and offer the user the relevant macOS privacy recovery step.
    enum Health: Equatable {
        case idle
        case recording
        case paused
        case unavailable(message: String)
    }

    var onHealthChange: ((Health) -> Void)?
    /// Low-bandwidth activity signal used by safe auto-end detection. No
    /// samples are emitted through this callback.
    var onAudioActivity: ((Bool) -> Void)?
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    // Background ASR snapshots this reference while capture may replace it
    // during startup fallback. Retain it under a lock before reading its files.
    private let writerLock = NSLock()
    private var audioWriter: SegmentedAudioWriter?
    private var writer: SegmentedAudioWriter? {
        get { writerLock.withLock { audioWriter } }
        set { writerLock.withLock { audioWriter = newValue } }
    }
    private let issueLock = NSLock()
    private var savedCaptureIssues: [String] = []
    private var captureWriteFailed = false
    var captureIssues: [String] { issueLock.withLock { savedCaptureIssues } }
    var closedSegmentURLs: [URL] { writer?.closedSegmentURLs ?? [] }

    private var destinationURL: URL?
    private let queue = DispatchQueue(label: "com.digimata.quill.system-tap")
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    private var health = Health.idle
    private var lastActivityReportAt: Date?
    private var aggregateAliveListener: AudioObjectPropertyListenerBlock?

    /// Start capturing system audio, encoding AAC into `url` (use a .caf
    /// extension — CAF needs no finalization pass, so a crash mid-meeting
    /// loses nothing already written).
    func start(
        writingTo url: URL,
        cancellationToken: RecordingOperationToken? = nil
    ) throws {
        guard !isRecording else { return }
        destinationURL = url
        try cancellationToken?.checkCancellation()

        // Record everything the meeting plays, but not Sekitiri's own audio.
        let ownProcess = OwnAudioProcess.objectID().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
        description.name = "quill system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            try cancellationToken?.checkCancellation()
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            try cancellationToken?.checkCancellation()
            writer = try makeWriter(url: url, format: format)
            try installIOProc(format: format)
            try cancellationToken?.checkCancellation()
        } catch {
            cleanup(discardSegments: true)
            throw error
        }

        isRecording = true
        lastActivityReportAt = nil
        installAggregateMonitoring()
        report(.recording)
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanup(discardSegments: false)
        report(.idle)
    }

    func pause() {
        guard isRecording, let procID, aggregateID != kAudioObjectUnknown else { return }
        AudioDeviceStop(aggregateID, procID)
        report(.paused)
    }

    func resume() throws {
        guard isRecording, let procID, aggregateID != kAudioObjectUnknown else { return }
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
        report(.recording)
    }

    func finalizeSegments() throws {
        guard let destinationURL else { return }
        let segments = writer?.segmentURLs
            ?? SegmentedAudioWriter.discoveredSegments(
                in: destinationURL.deletingLastPathComponent(),
                trackName: "system"
            )
        try SegmentedAudioWriter.finalize(segments: segments, to: destinationURL, removeSegmentsOnSuccess: false)
    }

    func cancelStart() {
        isRecording = false
        cleanup(discardSegments: true)
        report(.idle)
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "quill-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeWriter(url: URL, format: AVAudioFormat) throws -> SegmentedAudioWriter {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            return try SegmentedAudioWriter(
                sessionDirectory: url.deletingLastPathComponent(),
                trackName: "system",
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved,
                sampleRate: format.sampleRate
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, !self.captureWriteFailed, let writer = self.writer else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else {
                writer.close()
                self.captureWriteFailed = true
                self.report(.unavailable(message: "System audio could not be decoded. Audio already captured was preserved."))
                return
            }
            guard buffer.frameLength > 0 else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.reportAudioActivity(from: buffer)
            do {
                try writer.write(from: buffer)
            } catch is CancellationError where !self.isRecording {
                return
            } catch {
                FileHandle.standardError.write(Data("system track write failed: \(error)\n".utf8))
                writer.close()
                self.captureWriteFailed = true
                self.report(.unavailable(message: "System audio capture stopped. Your microphone recording has been preserved."))
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    private func cleanup(discardSegments: Bool) {
        removeAggregateMonitoring()
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Close the compressed CAF writer before releasing it so the header
        // contains the final packet table and duration.
        if discardSegments {
            writer?.discard()
            writer = nil
        } else {
            writer?.close()
        }
        lastActivityReportAt = nil
    }

    private func reportAudioActivity(from buffer: AVAudioPCMBuffer) {
        // System taps can deliver many buffers per second. Check the reporting
        // interval before walking every channel so meeting apps keep priority.
        let now = Date()
        guard lastActivityReportAt == nil || now.timeIntervalSince(lastActivityReportAt!) >= 1 else { return }
        guard buffer.frameLength > 0 else { return }
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let channel = channels[channelIndex]
                for frameIndex in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channel[frameIndex]))
                }
            }
        } else {
            // A non-float tap buffer with frames is still evidence that the
            // system output route is active; the file writer handles the data.
            peak = 1
        }
        lastActivityReportAt = now
        let active = peak >= 0.008
        DispatchQueue.main.async { [weak self] in
            self?.onAudioActivity?(active)
        }
    }

    private func installAggregateMonitoring() {
        removeAggregateMonitoring()
        guard aggregateID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let device = aggregateID
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if Self.isInterruption(recording: self.isRecording, listening: device,
                                   current: self.aggregateID, alive: self.isAggregateAlive()) {
                self.report(.unavailable(message: "System audio connection was interrupted. Your microphone recording has been preserved."))
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(aggregateID, &address, DispatchQueue.main, listener)
        if status == noErr { aggregateAliveListener = listener }
    }

    /// Stop destroys the aggregate device, and a callback already queued on
    /// main can still run afterwards, when the device reads as gone. Only the
    /// device that is still capturing going away counts as an interruption;
    /// otherwise every recording would end flagged and its notes blocked.
    static func isInterruption(recording: Bool, listening: AudioObjectID, current: AudioObjectID, alive: Bool) -> Bool {
        recording && current != kAudioObjectUnknown && listening == current && !alive
    }

    private func removeAggregateMonitoring() {
        guard aggregateID != kAudioObjectUnknown, let aggregateAliveListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(aggregateID, &address, DispatchQueue.main, aggregateAliveListener)
        self.aggregateAliveListener = nil
    }

    private func isAggregateAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private func report(_ next: Health) {
        if case .unavailable(let message) = next {
            // A device going away after Stop (teardown, a late queued callback)
            // is not a capture problem and must never flag the recording.
            guard isRecording else { return }
            issueLock.withLock {
                if !savedCaptureIssues.contains(message) { savedCaptureIssues.append(message) }
            }
        }
        health = next
        DispatchQueue.main.async { [weak self] in self?.onHealthChange?(next) }
    }
}
