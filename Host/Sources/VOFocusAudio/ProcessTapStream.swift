import AVFoundation
import CoreAudio
import Foundation

/// Records what some processes play into a stereo 16-bit WAV file through a
/// Core Audio process tap. No microphone is involved: a tap only receives the audio
/// those processes send to the speakers.
///
/// Times in the file are times since `origin`: silence fills the stretch before the
/// first buffer and any gap while the tap is re-created for new processes.
@available(macOS 14.2, *)
final class ProcessTapStream: @unchecked Sendable {
    let url: URL
    private let origin: UInt64
    private let ioQueue = DispatchQueue(label: "dev.vofocus.audio-tap")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var silence: AVAudioPCMBuffer?
    private var lastHeard: UInt64 = 0

    // Only touched by the owner (SimulatorAudioRecorder, an actor).
    private(set) var processes: [AudioObjectID] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    /// `origin` is a host time in nanoseconds; time 0 in the file.
    init(url: URL, origin: UInt64) {
        self.url = url
        self.origin = origin
    }

    /// Taps these processes instead of the current ones. An empty list stops the tap
    /// (the file keeps growing with silence when a tap starts again).
    func retarget(_ newProcesses: [AudioObjectID]) throws {
        guard newProcesses != processes else { return }
        stopTap()
        processes = newProcesses
        guard !newProcesses.isEmpty else { return }

        let description = CATapDescription(stereoMixdownOfProcesses: newProcesses)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CoreAudioError("Creating the audio tap", status) }

        // A tap-only aggregate device never runs its IO proc: it needs a real device
        // as its clock.
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VOFocus VoiceOver audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        if let output = CoreAudioProperty.defaultOutputDeviceUID {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { stopTap(); throw CoreAudioError("Creating the aggregate device", status) }

        var streamDescription: AudioStreamBasicDescription = CoreAudioProperty.get(
            tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            stopTap()
            throw CoreAudioError("Reading the tap's format", -1)
        }
        try openFileIfNeeded(format: tapFormat)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue) { [weak self] _, input, inputTime, _, _ in
            self?.receive(input, at: inputTime.pointee, format: tapFormat)
        }
        guard status == noErr else { stopTap(); throw CoreAudioError("Starting the audio tap", status) }
        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else { stopTap(); throw CoreAudioError("Starting the audio tap", status) }
    }

    /// Seconds since the processes last played anything audible, or nil if never.
    var secondsSinceHeard: Double? {
        lock.withLock { lastHeard == 0 ? nil : Double(CoreAudioProperty.nowNanos &- lastHeard) / 1e9 }
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let stride = buffer.stride
        var peak: Float = 0
        for channel in 0..<(buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)) {
            let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength) * stride)
            for sample in samples { peak = max(peak, abs(sample)) }
        }
        return peak
    }

    /// Stops recording, pads the file with silence up to now and closes it.
    func finish() {
        stopTap()
        ioQueue.sync {}
        lock.withLock {
            padSilence(to: frame(atNanos: CoreAudioProperty.nowNanos))
            file = nil
        }
    }

    // MARK: - Private

    private func stopTap() {
        if aggregate != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func openFileIfNeeded(format tapFormat: AVAudioFormat) throws {
        try lock.withLock {
            if let format {
                guard format.sampleRate == tapFormat.sampleRate, format.channelCount == tapFormat.channelCount else {
                    throw CoreAudioError("The output device changed sample rate mid-recording; recording", -2)
                }
                return
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: tapFormat.isInterleaved)
            format = tapFormat
            silence = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 4096)
            if let silence {
                let list = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
                for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            }
        }
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        lock.withLock {
            if time.mFlags.contains(.hostTimeValid) {
                padSilence(to: frame(atNanos: AudioConvertHostTimeToNanos(time.mHostTime)))
            }
            if Self.peak(buffer) > 0.001 { lastHeard = CoreAudioProperty.nowNanos }
            do {
                try file?.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                file = nil
            }
        }
    }

    /// The file position for a host time. Call with `lock` held.
    private func frame(atNanos nanos: UInt64) -> AVAudioFramePosition {
        guard let format else { return 0 }
        let seconds = Double(Int64(bitPattern: nanos &- origin)) / 1e9
        return AVAudioFramePosition(max(0, seconds) * format.sampleRate)
    }

    /// Writes silence until the file reaches `target`, if it's more than 20 ms behind.
    /// Call with `lock` held.
    private func padSilence(to target: AVAudioFramePosition) {
        guard let file, let silence, let format, target - framesWritten > AVAudioFramePosition(format.sampleRate * 0.02)
        else { return }
        var missing = target - framesWritten
        while missing > 0 {
            silence.frameLength = AVAudioFrameCount(min(missing, AVAudioFramePosition(silence.frameCapacity)))
            guard (try? file.write(from: silence)) != nil else { return }
            framesWritten += AVAudioFramePosition(silence.frameLength)
            missing -= AVAudioFramePosition(silence.frameLength)
        }
    }
}
