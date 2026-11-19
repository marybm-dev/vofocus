// Spike: record a connected iPhone's audio output over USB, the way QuickTime's
// "New Movie Recording > iPhone" does (CoreMediaIO screen capture devices). This is
// the phone's own output (VoiceOver's speech and sounds), not any microphone.
//   device <seconds> <out.caf> [device name substring]
import AVFoundation
import CoreMediaIO
import Foundation

func say(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

// Make iOS devices show up as capture devices.
var address = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var allow: UInt32 = 1
let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &allow)
say("allow screen capture devices: \(status)")

let args = CommandLine.arguments
let seconds = Double(args[1])!
let outURL = URL(filePath: args[2])
let nameFilter = args.count > 3 ? args[3] : ""

func findDevice() -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
    for device in discovery.devices { say("found: \(device.localizedName) [\(device.uniqueID)] \(device.modelID)") }
    return discovery.devices.first { nameFilter.isEmpty || $0.localizedName.localizedCaseInsensitiveContains(nameFilter) || $0.uniqueID.localizedCaseInsensitiveContains(nameFilter) }
}

// The device appears a moment after enabling.
var device: AVCaptureDevice?
for _ in 0..<40 {
    device = findDevice()
    if device != nil { break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
}
guard let device else { say("no iOS device found"); exit(1) }
// macOS files an iPhone's screen-capture stream under camera (and microphone)
// permission, as it does for QuickTime. Neither of this Mac's own is used.
for media in [AVMediaType.video, .audio] where AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
    var answered = false
    AVCaptureDevice.requestAccess(for: media) { granted in say("\(media.rawValue) access: \(granted)"); answered = true }
    while !answered { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
}
say("camera authorization: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue), audio: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

final class Writer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var file: AVAudioFile?
    var buffers = 0
    var peak: Float = 0
    let url: URL
    init(url: URL) { self.url = url }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = sampleBuffer.formatDescription,
              let asbd = description.audioStreamBasicDescription else { return }
        var streamDescription = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        if file == nil {
            say("audio format: \(format)")
            file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)
        }
        if let channels = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) { for i in 0..<Int(frames) { peak = max(peak, abs(channels[c][i])) } }
        } else if let channels = buffer.int16ChannelData {
            for c in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
                for i in 0..<Int(frames) * (format.isInterleaved ? Int(format.channelCount) : 1) {
                    peak = max(peak, abs(Float(channels[c][i]) / 32768))
                }
            }
        }
        try? file?.write(from: buffer)
        buffers += 1
    }
}

let session = AVCaptureSession()
do {
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { say("can't add input"); exit(1) }
    session.addInput(input)
} catch {
    say("input failed: \(error)")
    exit(1)
}
let output = AVCaptureAudioDataOutput()
let writer = Writer(url: outURL)
let queue = DispatchQueue(label: "audio")
output.setSampleBufferDelegate(writer, queue: queue)
guard session.canAddOutput(output) else { say("can't add audio output"); exit(1) }
session.addOutput(output)
session.startRunning()
say("recording \(device.localizedName) for \(seconds) s")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
session.stopRunning()
queue.sync {}
print("buffers=\(writer.buffers) peak=\(writer.peak) file=\(outURL.path)")
