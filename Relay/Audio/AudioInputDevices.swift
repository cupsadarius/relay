import CoreAudio
import Foundation

/// The dictation microphone the user picked. `name` is kept so a missing device can still be
/// labeled after a restart, when CoreAudio no longer knows it.
struct SelectedMicrophone: Codable, Equatable, Sendable {
    let uid: String
    let name: String
}

struct AudioInputDevice: Equatable, Sendable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum MicrophoneSelection {
    /// `device == nil` means "use the system default input".
    struct Resolution: Equatable {
        let device: AudioInputDevice?
        let missing: SelectedMicrophone?
    }

    static func resolve(_ choice: SelectedMicrophone?, connected: [AudioInputDevice]) -> Resolution {
        guard let choice else { return Resolution(device: nil, missing: nil) }
        if let device = connected.first(where: { $0.uid == choice.uid }) {
            return Resolution(device: device, missing: nil)
        }
        return Resolution(device: nil, missing: choice)
    }
}

enum AudioInputDevices {
    /// The connected devices that have input streams, in CoreAudio order.
    static func connected() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id),
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                let name = stringProperty(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
