@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation
import VOFocusKit

/// Records a connected iPhone's audio output over USB, the way QuickTime's iPhone
/// recording does (CoreMediaIO screen-capture devices). It's the phone's own output,
/// not a microphone, but it is everything the phone plays: notifications and other
/// apps too, which is why VOFocus suggests Do Not Disturb. The phone's speaker is
/// silent while recording.
///
/// macOS files an iPhone's capture stream under camera permission, as it does for
/// QuickTime, and asks once for the app running VOFocus; the Mac's camera isn't used.
/// Microphone permission isn't needed (tested: with camera allowed and microphone
/// denied, the phone's audio comes through; with only microphone access it doesn't).
public actor DeviceAudioRecorder: VoiceOverAudioRecorder {
    private let device: String
    private let url: URL
    private let started = Date()
    private let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    private var session: AVCaptureSession?
    private var writer: SampleWriter?
    private var notes: [String] = []

    /// `device` is the device's name or UDID. The recording is `<directory>/<name>.wav`.
    public init(device: String, directory: URL, name: String) {
        self.device = device
        url = directory.appending(path: "\(name).wav")
    }

    /// What to tell someone before recording a device.
    public static let notice = """
        Recording everything the iPhone plays over USB (not its microphone): turn on Do Not \
        Disturb on the phone so notifications and other apps aren't recorded. The phone's \
        speaker is silent while recording.
        """

    /// Asks macOS for camera access once (the only permission recording a device needs),
    /// so a run can stop before starting instead of failing at every scenario.
    public static func requestAccess() async throws {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw SimulatorAudioError("""
                macOS didn't allow camera access, which it requires to record an iPhone's audio \
                over USB (the Mac's camera isn't used). Allow it in System Settings > Privacy & \
                Security > Camera for the app running VOFocus (such as Terminal), then run again.
                """)
        }
    }

    public func start() async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Self.requestAccess()
        let capture = try await Self.captureDevice(matching: device)
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: capture)
        guard session.canAddInput(input) else { throw SimulatorAudioError("Can't record \(capture.localizedName).") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        let writer = SampleWriter(url: url, origin: origin)
        output.setSampleBufferDelegate(writer, queue: writer.queue)
        guard session.canAddOutput(output) else { throw SimulatorAudioError("Can't record audio from \(capture.localizedName).") }
        session.addOutput(output)
        session.startRunning()
        self.session = session
        self.writer = writer
        // The capture takes a moment to start delivering audio (silent or not); wait,
        // so whatever happens next is recorded.
        let deadline = Date().addingTimeInterval(5)
        while !writer.receiving && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if !writer.receiving { notes.append("The iPhone's audio took over 5 s to start; the beginning may be missing.") }
    }

    public func waitUntilQuiet(quiet: Double, limit: Double) async {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if writer?.secondsSinceHeard.map({ $0 >= quiet }) ?? true { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        notes.append("The iPhone was still playing audio \(Int(limit)) s after the last step; the recording stops there.")
    }

    public func stop() -> AudioRecording {
        session?.stopRunning()
        session = nil
        let file = writer?.finish()
        if let error = writer?.error { notes.append(error) }
        writer = nil
        return AudioRecording(started: started, stopped: Date(), folder: url.deletingLastPathComponent(),
                              speech: file, sounds: file, notes: notes)
    }

    /// Finds the iPhone among the capture devices, by name; a UDID is looked up first.
    static func captureDevice(matching device: String) async throws -> AVCaptureDevice {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
        let name = try await deviceName(device) ?? device
        // iPhones appear a moment after that, while the main run loop runs.
        for _ in 0..<40 {
            let devices = await MainActor.run {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                return AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
            }
            if let match = devices.first(where: { $0.localizedName == name })
                ?? (devices.count == 1 ? devices.first : nil) {
                return match
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SimulatorAudioError("""
            "\(name)" didn't appear as a USB capture device. Is it connected by cable, unlocked and trusted?
            """)
    }

    /// The device's name, when `device` is a UDID.
    static func deviceName(_ device: String) async throws -> String? {
        guard device.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil else { return nil }
        let json = FileManager.default.temporaryDirectory.appending(path: "vofocus-device-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        _ = try await Shell.run(["xcrun", "devicectl", "device", "info", "details", "--device", device,
                                 "--json-output", json.path])
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let properties = result["deviceProperties"] as? [String: Any] else { return nil }
        return properties["name"] as? String
    }

    /// The device's iOS version ("27.2"), for choosing the matching sound files.
    public static func iOSVersion(_ device: String) async -> String? {
        let json = FileManager.default.temporaryDirectory.appending(path: "vofocus-device-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        _ = try? await Shell.run(["xcrun", "devicectl", "device", "info", "details", "--device", device,
                                  "--json-output", json.path])
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let properties = result["deviceProperties"] as? [String: Any] else { return nil }
        return properties["osVersionNumber"] as? String
    }
}

/// Writes captured sample buffers to a WAV file, padding gaps with silence so file
/// time matches wall time since `origin`.
private final class SampleWriter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.vofocus.device-audio")
    private let url: URL
    private let origin: Double
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var lastHeard: Double?
    private(set) var error: String?

    init(url: URL, origin: Double) {
        self.url = url
        self.origin = origin
    }

    /// Whether any audio (even silence) has arrived.
    var receiving: Bool { lock.withLock { file != nil || framesWritten > 0 } }

    var secondsSinceHeard: Double? {
        lock.withLock { lastHeard.map { CMClockGetTime(CMClockGetHostTimeClock()).seconds - $0 } }
    }

    func finish() -> URL? {
        queue.sync {}
        return lock.withLock {
            let written = file != nil
            file = nil
            return written ? url : nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        lock.withLock {
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                }
                guard let file else { return }
                // Silence for any gap before this buffer.
                let target = AVAudioFramePosition(max(0, sampleBuffer.presentationTimeStamp.seconds - origin) * format.sampleRate)
                if target - framesWritten > AVAudioFramePosition(format.sampleRate * 0.02),
                   let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(target - framesWritten)) {
                    silence.frameLength = silence.frameCapacity
                    for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                        memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize))
                    }
                    try file.write(from: silence)
                    framesWritten += AVAudioFramePosition(silence.frameLength)
                }
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(frames)
                if Self.isAudible(buffer) { lastHeard = CMClockGetTime(CMClockGetHostTimeClock()).seconds }
            } catch {
                self.error = "Writing the recording failed: \(error)"
                file = nil
            }
        }
    }

    private static func isAudible(_ buffer: AVAudioPCMBuffer) -> Bool {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            if buffer.format.commonFormat == .pcmFormatInt16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<Int(audioBuffer.mDataByteSize) / 2 where abs(Int32(samples[index])) > 33 { return true }
            } else if buffer.format.commonFormat == .pcmFormatFloat32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(audioBuffer.mDataByteSize) / 4 where abs(samples[index]) > 0.001 { return true }
            }
        }
        return false
    }
}
