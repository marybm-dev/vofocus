import CoreAudio
import Foundation

/// Small wrappers for Core Audio's property API.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = address(selector)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    /// Core Audio's object for a process, or nil if it hasn't used audio yet.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static var defaultOutputDeviceUID: String? {
        let device: AudioObjectID = get(AudioObjectID(kAudioObjectSystemObject),
                                        kAudioHardwarePropertyDefaultSystemOutputDevice, default: 0)
        return device == 0 ? nil : string(device, kAudioDevicePropertyDeviceUID)
    }

    static var nowNanos: UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
}

struct CoreAudioError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, _ status: OSStatus) {
        description = "\(what) failed (\(status))"
    }
}
