import CoreAudio
import Foundation

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial; var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    return value
}
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
for id in ids {
    let pid: pid_t = prop(id, kAudioProcessPropertyPID, 0)
    let running: UInt32 = prop(id, kAudioProcessPropertyIsRunningOutput, 0)
    var path = [CChar](repeating: 0, count: 4096)
    proc_pidpath(pid, &path, 4096)
    print(id, pid, running == 1 ? "OUT" : "   ", String(cString: path))
}
