import AVFoundation
import CoreAudio
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    /// A lightweight, UI-agnostic description of the input route. The
    /// callback is always delivered on the main queue so an AppModel can
    /// publish it directly without bridging Core Audio's realtime threads.
    enum Health: Equatable {
        case idle
        case recording(deviceName: String)
        case paused(deviceName: String)
        case unavailable(message: String)
    }

    var onHealthChange: ((Health) -> Void)?
    /// Low-bandwidth activity signal used by the meeting auto-end policy.
    /// It carries only a boolean and never exposes audio samples.
    var onAudioActivity: ((Bool) -> Void)?
    /// Whether the mic delivered any signal at all, reported with activity.
    /// A working microphone always has some noise floor; exact zeros mean
    /// macOS is withholding the input (permission) or it is muted.
    var onSignal: ((Bool) -> Void)?
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)
        case inputDeviceSelectionFailed(OSStatus)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            case .inputDeviceSelectionFailed(let status): return "couldn't select microphone (OSStatus \(status))"
            }
        }
    }

    private var engine = AVAudioEngine()
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

    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false
    private var lastActivityReportAt: Date?
    private var selectedDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var selectedDeviceName = "Microphone"
    private var health = Health.idle
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(
        writingTo url: URL,
        inputDeviceID: String? = nil,
        cancellationToken: RecordingOperationToken? = nil
    ) throws {
        guard !isRecording else { return }
        self.url = url
        do {
            try cancellationToken?.checkCancellation()
            try attach(
                voiceProcessing: Config.micVoiceProcessing(),
                inputDeviceID: inputDeviceID,
                cancellationToken: cancellationToken
            )
            try cancellationToken?.checkCancellation()
            isRecording = true
            report(.recording(deviceName: selectedDeviceName))
        } catch {
            rollbackStart()
            throw error
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Explicitly close the CAF writer so Core Audio finalizes its packet
        // table. Releasing AVAudioFile directly can leave an unopenable file.
        writer?.close()
        removeDeviceMonitoring()
        report(.idle)
    }

    func pause() {
        engine.pause()
        report(.paused(deviceName: selectedDeviceName))
    }

    func resume() throws {
        do {
            try engine.start()
            report(.recording(deviceName: selectedDeviceName))
        } catch {
            report(.unavailable(message: "Microphone could not resume. Audio already captured was preserved. \(error)"))
            throw error
        }
    }

    /// Builds the legacy single-file track after capture has stopped. This is
    /// intentionally separate from `stop()` so RecordingSession can run the
    /// comparatively expensive decode/re-encode work away from the UI thread.
    func finalizeSegments() throws {
        guard let url else { return }
        let segments = writer?.segmentURLs
            ?? SegmentedAudioWriter.discoveredSegments(in: url.deletingLastPathComponent(), trackName: "mic")
        try SegmentedAudioWriter.finalize(segments: segments, to: url, removeSegmentsOnSuccess: false)
    }

    /// Roll back a start that was cancelled before the session became active.
    /// No partial capture is promoted to a user-visible recording.
    func cancelStart() {
        rollbackStart()
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(
        voiceProcessing: Bool,
        inputDeviceID: String? = nil,
        cancellationToken: RecordingOperationToken? = nil
    ) throws {
        try cancellationToken?.checkCancellation()
        engine = AVAudioEngine()
        let input = engine.inputNode

        if let inputDeviceID, let device = AudioInputDevice.available().first(where: { $0.id == inputDeviceID }) {
            guard let audioUnit = input.audioUnit else { throw RecorderError.inputDeviceSelectionFailed(-1) }
            var selected = device.deviceID
            let status = AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RecorderError.inputDeviceSelectionFailed(status) }
            selectedDeviceID = device.deviceID
            selectedDeviceName = device.name
        } else {
            selectedDeviceID = defaultInputDeviceID()
            selectedDeviceName = AudioInputDevice.available().first(where: { $0.deviceID == selectedDeviceID })?.name ?? "Default microphone"
        }
        try cancellationToken?.checkCancellation()

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            writer = try SegmentedAudioWriter(
                sessionDirectory: url!.deletingLastPathComponent(),
                trackName: "mic",
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved,
                sampleRate: monoFormat.sampleRate
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        try cancellationToken?.checkCancellation()

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        try cancellationToken?.checkCancellation()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer?.discard()
            writer = nil
            throw RecorderError.engineStartFailed(error)
        }
        try cancellationToken?.checkCancellation()
        installDeviceMonitoring()

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.captureWriteFailed, buffer.frameLength > 0, let writer = self.writer else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.reportAudioActivity(from: buffer)

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try writer.write(from: buffer)
            } catch is CancellationError where !self.isRecording {
                // Stop can close a writer while the final tap callback waits
                // for its lock. This is a normal shutdown, not capture loss.
                return
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
                writer.close()
                self.captureWriteFailed = true
                self.report(.unavailable(message: "Microphone audio stopped saving. The system-audio track and everything already recorded were preserved."))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.captureWriteFailed, buffer.frameLength > 0, let writer = self.writer else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else {
                writer.close()
                self.captureWriteFailed = true
                self.report(.unavailable(message: "Microphone conversion ran out of memory. Audio already captured was preserved."))
                return
            }
            do {
                try converter.convert(to: mono, from: buffer)
                self.reportAudioActivity(from: mono)
                try writer.write(from: mono)
            } catch is CancellationError where !self.isRecording {
                // Stop can close a writer while the final tap callback waits
                // for its lock. This is a normal shutdown, not capture loss.
                return
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
                writer.close()
                self.captureWriteFailed = true
                self.report(.unavailable(message: "Microphone audio stopped saving. The system-audio track and everything already recorded were preserved."))
            }
        }
    }

    private func reportAudioActivity(from buffer: AVAudioPCMBuffer) {
        // This callback runs for every audio buffer. Throttle before scanning
        // samples so a 48 kHz route does not repeatedly perform work whose UI
        // result is emitted only once per second.
        let now = Date()
        guard lastActivityReportAt == nil || now.timeIntervalSince(lastActivityReportAt!) >= 1 else { return }
        guard buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0]
        else { return }
        let peak = Self.peak(of: channel, count: Int(buffer.frameLength))
        lastActivityReportAt = now
        let active = peak >= 0.008
        DispatchQueue.main.async { [weak self] in
            self?.onAudioActivity?(active)
            self?.onSignal?(peak > 0)
        }
    }

    static func peak(of samples: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writer?.discard()
        writer = nil
        firstBufferAt = nil
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            writer = nil
            report(.unavailable(message: "Microphone stopped delivering audio. Your recording has been kept."))
        }
    }

    private func rollbackStart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writer?.discard()
        writer = nil
        removeDeviceMonitoring()
        isRecording = false
        report(.idle)
    }

    private func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : kAudioObjectUnknown
    }

    private func installDeviceMonitoring() {
        removeDeviceMonitoring()
        guard selectedDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if !self.isDeviceAlive(self.selectedDeviceID) {
                self.report(.unavailable(message: "\(self.selectedDeviceName) disconnected. Audio captured so far has been preserved."))
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(selectedDeviceID, &address, DispatchQueue.main, listener)
        if status == noErr { deviceAliveListener = listener }
    }

    private func removeDeviceMonitoring() {
        guard selectedDeviceID != kAudioObjectUnknown, let deviceAliveListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(selectedDeviceID, &address, DispatchQueue.main, deviceAliveListener)
        self.deviceAliveListener = nil
    }

    private func isDeviceAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
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
