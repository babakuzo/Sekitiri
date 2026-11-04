import CoreAudio
import Foundation

/// Inspects the current output route so echo cancellation can be enabled only
/// when meeting audio is coming out of speakers that the microphone can hear.
enum AudioOutputRoute {
    /// Best-effort guess that playback is private to the listener (headphones,
    /// headsets, earbuds). Bluetooth outputs are assumed to be personal audio;
    /// a Bluetooth speaker is the main miss, and transcript-level echo
    /// suppression still covers it.
    static func isPrivateListening() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let name = deviceName(device)?.lowercased() ?? ""
        let personalWords = ["headphone", "headset", "airpods", "earbud", "earphone", "buds", "beats"]
        if personalWords.contains(where: name.contains) { return true }
        switch transportType(device) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output reports 'hdpn' when wired headphones are plugged in.
            return dataSource(device) == fourCharCode("hdpn")
        default:
            return false
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        uint32Property(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func dataSource(_ device: AudioDeviceID) -> UInt32? {
        uint32Property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func fourCharCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// The Core Audio process object for this app, so the system-audio tap can
/// exclude Sekitiri's own playback (reviewing an earlier meeting, alerts).
enum OwnAudioProcess {
    static func objectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
