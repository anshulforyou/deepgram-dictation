// Simulates a call app (Meet, Zoom, ...): holds the default mic in voice-processing mode for N
// seconds and reports how much of what it captured was digital silence.
//   callsim <seconds>   →  prints {"zeroFraction": 0.0-1.0, "seconds": N}
import AVFoundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let engine = AVAudioEngine()
try! engine.inputNode.setVoiceProcessingEnabled(true)
let format = engine.inputNode.outputFormat(forBus: 0)
var total = 0, zeros = 0
let lock = NSLock()
let skip = format.sampleRate * 2 // ignore start-up
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
    guard let data = buffer.floatChannelData else { return }
    lock.lock(); defer { lock.unlock() }
    for i in 0..<Int(buffer.frameLength) {
        total += 1
        if Double(total) > skip && data[0][i] == 0 { zeros += 1 }
    }
}
try! engine.start()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    engine.stop()
    let counted = max(1, Double(total) - skip)
    print("{\"zeroFraction\": \(Double(zeros) / counted), \"seconds\": \(seconds)}")
    exit(0)
}
dispatchMain()
