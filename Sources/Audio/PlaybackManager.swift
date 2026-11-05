import AVFoundation
import Combine
import Foundation

/// Coordinates playback of the independent microphone and system-audio tracks
/// without doing file decoding on the SwiftUI/main actor.
@MainActor
final class PlaybackManager: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var message: String?
    @Published private(set) var notice: String?

    private let engine = PlaybackEngine()
    private var activePaths: [String] = []

    init() {
        engine.onPrepared = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.prepared(result)
            }
        }
        engine.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.progressed(progress)
            }
        }
        engine.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.finished()
            }
        }
    }

    deinit {
        engine.shutdown()
    }

    var hasLoadedTrack: Bool { !activePaths.isEmpty && duration > 0 }

    func toggle(trackURLs: [URL]) {
        if isPreparing { return }
        if isPlaying {
            pause()
        } else if isPaused && !activePaths.isEmpty {
            resume()
        } else {
            start(trackURLs: trackURLs)
        }
    }

    func start(trackURLs: [URL]) {
        guard !isPreparing else { return }
        stop(resetMessage: false)
        isPreparing = true
        message = nil
        notice = nil
        activePaths = trackURLs.map(\.path)
        engine.prepare(trackURLs: trackURLs)
    }

    func pause() {
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        isPaused = true
    }

    func resume() {
        guard isPaused, hasLoadedTrack else { return }
        engine.play()
        isPaused = false
        isPlaying = true
    }

    func stop(resetMessage: Bool = true) {
        engine.stop()
        isPlaying = false
        isPaused = false
        isPreparing = false
        currentTime = 0
        duration = 0
        activePaths = []
        notice = nil
        if resetMessage { message = nil }
    }

    func seek(to value: TimeInterval) {
        guard hasLoadedTrack else { return }
        let clamped = min(max(0, value), duration)
        currentTime = clamped
        engine.seek(to: clamped)
    }

    func timeLabel(_ value: TimeInterval) -> String {
        TranscriptDocument.clock(value)
    }

    private func prepared(_ result: PlaybackPreparationResult) {
        isPreparing = false
        let duration = result.duration
        let playablePaths = result.playablePaths
        let skippedNames = result.skippedNames
        guard duration > 0, !playablePaths.isEmpty else {
            activePaths = []
            self.duration = 0
            message = skippedNames.first ?? "This recording has no playable audio track. The saved files are still available."
            return
        }
        activePaths = playablePaths
        self.duration = duration
        currentTime = 0
        message = nil
        notice = skippedNames.isEmpty ? nil : "Playing the available track. Couldn’t open \(skippedNames.joined(separator: ", "))."
        engine.play()
        isPlaying = true
        isPaused = false
    }

    private func progressed(_ progress: PlaybackProgress) {
        guard !isPaused else { return }
        currentTime = min(max(0, progress.currentTime), duration)
        isPlaying = progress.isPlaying
    }

    private func finished() {
        currentTime = duration
        isPlaying = false
        isPaused = false
    }
}

private struct PlaybackPreparationResult: Sendable {
    let duration: TimeInterval
    let playablePaths: [String]
    let skippedNames: [String]

}

private struct PlaybackProgress: Sendable {
    let currentTime: TimeInterval
    let isPlaying: Bool
}

/// AVAudioPlayer instances are isolated to a serial queue. This keeps opening,
/// decoding, seeking, and polling away from SwiftUI rendering and input.
private final class PlaybackEngine: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onPrepared: ((PlaybackPreparationResult) -> Void)?
    var onProgress: ((PlaybackProgress) -> Void)?
    var onFinished: (() -> Void)?

    private let queue = DispatchQueue(label: "com.sekitiri.playback", qos: .userInitiated)
    private var players: [AVAudioPlayer] = []
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var shuttingDown = false

    func prepare(trackURLs: [URL]) {
        let requested = trackURLs
        let requestGeneration = UUID()
        queue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.generation = requestGeneration
            self.stopLocked()

            var players: [AVAudioPlayer] = []
            var playablePaths: [String] = []
            var skippedNames: [String] = []
            var longestDuration: TimeInterval = 0

            for url in requested {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    guard player.duration > 0 else {
                        skippedNames.append(url.lastPathComponent)
                        continue
                    }
                    player.delegate = self
                    player.prepareToPlay()
                    players.append(player)
                    playablePaths.append(url.path)
                    longestDuration = max(longestDuration, player.duration)
                } catch {
                    skippedNames.append(url.lastPathComponent)
                }
            }

            guard !players.isEmpty else {
                let details = skippedNames.isEmpty
                    ? "No audio tracks were found for this meeting."
                    : "The saved audio tracks couldn’t be opened: \(skippedNames.joined(separator: ", "))."
                self.emitPrepared(PlaybackPreparationResult(duration: 0, playablePaths: [], skippedNames: [details]))
                return
            }

            self.players = players
            self.emitPrepared(PlaybackPreparationResult(
                duration: longestDuration,
                playablePaths: playablePaths,
                skippedNames: skippedNames
            ))
        }
    }

    func play() {
        queue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            guard !self.players.isEmpty else { return }
            self.players.forEach { _ = $0.play() }
            self.startTimerLocked()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.players.forEach { $0.pause() }
            self.stopTimerLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = UUID()
            self.stopLocked()
        }
    }

    func seek(to time: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.players.forEach { $0.currentTime = min(max(0, time), $0.duration) }
        }
    }

    func shutdown() {
        queue.sync {
            shuttingDown = true
            stopLocked()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            guard self.players.allSatisfy({ !$0.isPlaying }) else { return }
            self.stopTimerLocked()
            self.emitFinished()
        }
    }

    private func startTimerLocked() {
        stopTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let player = self.players.first else { return }
            self.emitProgress(PlaybackProgress(currentTime: player.currentTime, isPlaying: player.isPlaying))
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimerLocked() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func stopLocked() {
        stopTimerLocked()
        players.forEach { $0.stop() }
        players = []
    }

    private func emitPrepared(_ result: PlaybackPreparationResult) {
        DispatchQueue.main.async { [weak self] in self?.onPrepared?(result) }
    }

    private func emitProgress(_ progress: PlaybackProgress) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(progress) }
    }

    private func emitFinished() {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }
}
