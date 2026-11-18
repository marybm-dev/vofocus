// Spike: find VoiceOver's sounds in a recording by matching it against the sound
// files in the Simulator runtime (normalized cross-correlation).
//   earcons <recording> <VoiceOverTouch.app/Sounds> [threshold]
import Accelerate
import AVFoundation
import Foundation

let rate = 11025.0
let window = 0.3  // seconds of each sound to match

func load(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let capacity = AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
    var done = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return input
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

let args = CommandLine.arguments
let signal = try load(URL(filePath: args[1]))
let threshold = Float(args.count > 3 ? args[3] : "0.8")!
// Running energy, for normalizing each window of the recording.
var cumulative = [Double](repeating: 0, count: signal.count + 1)
for i in 0..<signal.count { cumulative[i + 1] = cumulative[i] + Double(signal[i] * signal[i]) }

struct Hit { var time: Double; var name: String; var score: Float }
var hits: [Hit] = []
let soundsDir = URL(filePath: args[2])
let names = try FileManager.default.contentsOfDirectory(atPath: soundsDir.path)
    .filter { $0.hasSuffix(".aiff") && !$0.contains("-mono") }.sorted()
for name in names {
    var reference = try load(soundsDir.appending(path: name))
    // Trim leading silence, keep the first `window` seconds.
    if let start = reference.firstIndex(where: { abs($0) > 0.01 }) { reference.removeFirst(start) }
    reference = Array(reference.prefix(Int(window * rate)))
    let n = reference.count
    guard n > 64, signal.count > n else { continue }
    let refNorm = sqrt(vDSP.sumOfSquares(reference))
    guard refNorm > 0 else { continue }
    let count = signal.count - n + 1
    var corr = [Float](repeating: 0, count: count)
    vDSP_conv(signal, 1, reference, 1, &corr, 1, vDSP_Length(count), vDSP_Length(n))
    var best: (index: Int, score: Float)? = nil
    func flush() {
        if let b = best { hits.append(Hit(time: Double(b.index) / rate, name: String(name.dropLast(5)), score: b.score)) }
        best = nil
    }
    for i in 0..<count {
        let energy = cumulative[i + n] - cumulative[i]
        guard energy > 1e-6 else { continue }
        let score = corr[i] / (refNorm * Float(sqrt(energy)))
        if score >= threshold {
            if let b = best, i - b.index > Int(0.2 * rate) { flush() }
            if best == nil || score > best!.score { best = (i, score) }
        }
    }
    flush()
}
// Where several sounds match the same moment, keep the best.
hits.sort { $0.time < $1.time }
var kept: [Hit] = []
for hit in hits {
    if let last = kept.last, abs(last.time - hit.time) < 0.1 {
        if hit.score > last.score { kept[kept.count - 1] = hit }
    } else { kept.append(hit) }
}
for hit in kept { print(String(format: "%7.2f  %@  (%.2f)", hit.time, hit.name, hit.score)) }
