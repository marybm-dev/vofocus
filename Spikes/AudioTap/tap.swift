// Spike: record the audio output of Simulator processes with a Core Audio process
// tap (macOS 14.2+). No microphone. Usage:
//   tap <seconds> <out.caf> [all|service|runtime] [--mute]
//   runtime = processes under a simruntime RuntimeRoot (default)
//   service = CoreSimulator's SimAudioProcessorService
import AVFoundation
import CoreAudio
import Foundation

func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial; var size = UInt32(MemoryLayout<T>.size)
    withUnsafeMutablePointer(to: &value) { _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    return value
}

func processObjects() -> [(id: AudioObjectID, pid: pid_t, path: String)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.map { id in
        let pid: pid_t = get(id, kAudioProcessPropertyPID, 0)
        var buf = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &buf, 4096)
        return (id, pid, String(cString: buf))
    }
}

let args = CommandLine.arguments
let seconds = Double(args[1])!
let outURL = URL(filePath: args[2])
let mode = args.count > 3 ? args[3] : "runtime"
let mute = args.contains("--mute")

let chosen = processObjects().filter {
    switch mode {
    case "service": $0.path.contains("SimAudioProcessorService")
    case let name where name.hasPrefix("name:"): ($0.path as NSString).lastPathComponent == name.dropFirst(5)
    case "all": $0.path.contains("/RuntimeRoot/") || $0.path.contains("SimAudioProcessorService")
    default: $0.path.contains("/RuntimeRoot/")
    }
}
for p in chosen { FileHandle.standardError.write("tapping \(p.pid) \((p.path as NSString).lastPathComponent)\n".data(using: .utf8)!) }

let desc = CATapDescription(stereoMixdownOfProcesses: chosen.map(\.id))
desc.uuid = UUID()
desc.isPrivate = true
desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
var tap = AudioObjectID(kAudioObjectUnknown)
var err = AudioHardwareCreateProcessTap(desc, &tap)
guard err == noErr else { fatalError("create tap: \(err)") }

// The aggregate device needs a clock: the default output device.
let outputDevice: AudioObjectID = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, 0)
let outputUID: CFString = get(outputDevice, kAudioDevicePropertyDeviceUID, "" as CFString)
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceNameKey: "VOFocus audio tap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
]
var agg = AudioObjectID(kAudioObjectUnknown)
err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
guard err == noErr else { fatalError("create aggregate: \(err)") }

var asbd: AudioStreamBasicDescription = get(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
let format = AVAudioFormat(streamDescription: &asbd)!
FileHandle.standardError.write("format \(format)\n".data(using: .utf8)!)
let file = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

var peak: Float = 0
var callbacks = 0
var writeError: Error?
var proc: AudioDeviceIOProcID?
let queue = DispatchQueue(label: "tap")
err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, input, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
    if let ch = buffer.floatChannelData {
        for c in 0..<Int(format.channelCount) { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[c][i])) } }
    }
    callbacks += 1
    do { try file.write(from: buffer) } catch { writeError = error }
}
guard err == noErr else { fatalError("ioproc: \(err)") }
FileHandle.standardError.write("starting \(Date())\n".data(using: .utf8)!)
err = AudioDeviceStart(agg, proc)
FileHandle.standardError.write("started \(Date())\n".data(using: .utf8)!)
guard err == noErr else { fatalError("start: \(err)") }
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(agg, proc)
AudioDeviceDestroyIOProcID(agg, proc!)
AudioHardwareDestroyAggregateDevice(agg)
AudioHardwareDestroyProcessTap(tap)
queue.sync {}
if let writeError { print("write error: \(writeError)") }
print("callbacks=\(callbacks) wrote \(outURL.path) frames=\(file.length) peak=\(peak)")
