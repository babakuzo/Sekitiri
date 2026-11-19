import AVFoundation
import ApplicationServices
import Foundation
import Network

/// Problems worth catching while they can still be fixed: before a recording
/// starts, or early enough during one. Disk space, the speech model when the
/// Mac is offline, whether macOS lets Sekitiri hear computer audio, and the
/// permission the ⌥⌘R stop shortcut needs in other apps.
enum RecordingPreflight {
    struct Snapshot: Equatable {
        var freeBytes: Int64?
        var speechModelReady: Bool
        var online: Bool
        var computerAudioConfirmed: Bool
        var stopShortcutEverywhere: Bool
    }

    static func snapshot() async -> Snapshot {
        let online = await isOnline()
        return await Task.detached(priority: .utility) {
            Snapshot(
                freeBytes: freeSpace(),
                speechModelReady: ParakeetEngine.isCached(engine: Config.transcriptionEngine()),
                online: online,
                computerAudioConfirmed: computerAudioConfirmed,
                stopShortcutEverywhere: stopShortcutWorksEverywhere
            )
        }.value
    }

    // MARK: Disk space

    /// Both tracks are AAC. A meeting uses roughly half this, so estimates
    /// err towards warning early.
    static let bytesPerRecordingHour: Int64 = 120_000_000
    static let lowSpaceBeforeRecording: Int64 = 2_000_000_000
    static let lowSpaceWhileRecording: Int64 = 1_000_000_000

    /// Free space on the volume that holds recordings, or nil if unreadable.
    static func freeSpace(at root: URL = AppModel.recordingsRoot()) -> Int64? {
        var url = root
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func recordingTimeLeft(freeBytes: Int64) -> TimeInterval {
        Double(max(0, freeBytes)) / Double(bytesPerRecordingHour) * 3600
    }

    /// "about 40 minutes", "about 6 hours": coarse on purpose.
    static func describe(_ time: TimeInterval) -> String {
        let minutes = Int(time / 60)
        if minutes < 2 { return "less than a minute" }
        if minutes < 60 {
            let rounded = minutes < 10 ? minutes : minutes / 5 * 5
            return "about \(rounded) minutes"
        }
        let hours = Int((time / 3600).rounded())
        return hours == 1 ? "about an hour" : "about \(hours) hours"
    }

    // MARK: Network

    /// One reading of the current network path.
    static func isOnline() async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        let monitor = NWPathMonitor()
        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    // MARK: Computer audio

    /// macOS gives no way to ask whether Screen & System Audio Recording is
    /// allowed: a tap without permission just records silence. So Sekitiri
    /// remembers whether it has ever heard computer audio, from a recording
    /// or from `testComputerAudio()`.
    private static let computerAudioKey = "computerAudioConfirmed"

    static var computerAudioConfirmed: Bool {
        UserDefaults.standard.bool(forKey: computerAudioKey)
    }

    static func setComputerAudioConfirmed(_ confirmed: Bool) {
        UserDefaults.standard.set(confirmed, forKey: computerAudioKey)
    }

    /// Plays a short system sound from another process and listens for it
    /// with the same tap a recording uses. The first run is also what makes
    /// macOS ask for permission. Nothing is kept.
    static func testComputerAudio() async -> Bool {
        let heard = await Task.detached(priority: .userInitiated) { listenForTestSound() }.value
        if heard { setComputerAudioConfirmed(true) }
        return heard
    }

    /// Blocks for about two seconds; run it off the main thread.
    private static func listenForTestSound() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sekitiri-audio-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return false }
        let recorder = SystemAudioRecorder()
        do { try recorder.start(writingTo: directory.appendingPathComponent("system.caf")) } catch { return false }
        Thread.sleep(forTimeInterval: 0.3)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        if (try? player.run()) != nil { player.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.3)
        recorder.stop()
        return peakLevel(under: directory) >= 0.008
    }

    /// Loudest sample in any CAF file below `directory`.
    static func peakLevel(under directory: URL) -> Float {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var peak: Float = 0
        for case let url as URL in files where url.pathExtension == "caf" {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(min(file.length, 48_000 * 30))),
                  (try? file.read(into: buffer)) != nil,
                  let channels = buffer.floatChannelData else { continue }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
            }
        }
        return peak
    }

    // MARK: Stop shortcut

    /// macOS only passes key presses in other apps to Sekitiri's ⌥⌘R monitor
    /// once it is trusted under Privacy & Security › Accessibility.
    static var stopShortcutWorksEverywhere: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which leads to the Accessibility list.
    static func askForStopShortcutPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// A recording the app found unfinished at launch and saved.
struct RecoveredRecording: Identifiable, Equatable {
    let id: String
    let title: String
    let minutes: Int

    init(id: String, title: String, minutes: Int) {
        self.id = id
        self.title = title
        self.minutes = minutes
    }

    init(directory: URL) {
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let named = [meta["title_override"], meta["title"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        self.init(id: directory.lastPathComponent,
                  title: named ?? "Untitled meeting",
                  minutes: ((meta["duration_seconds"] as? Int) ?? 0) / 60)
    }

    var savedLength: String {
        switch minutes {
        case 0: return "less than a minute"
        case 1: return "1 minute"
        default: return "\(minutes) minutes"
        }
    }

    /// The launch dialog's wording for one or several recordings.
    static func message(for recordings: [RecoveredRecording]) -> String {
        guard let first = recordings.first else { return "" }
        if recordings.count == 1 {
            return "Sekitiri closed while “\(first.title)” was recording. Everything up to that point (\(first.savedLength)) was saved and is being transcribed now."
        }
        let names = recordings.map { "“\($0.title)” (\($0.savedLength))" }
        let list = names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Sekitiri closed during recording. \(list) were saved and are being transcribed now."
    }
}
