// Unit tests for recorder/Logic.swift. A tiny runner instead of XCTest, which the Command Line
// Tools don't always ship. Run with `make test-swift` (or recorder/test.sh).

import Foundation

var failures = 0
var passes = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

func withSamples<R>(_ values: [Float], _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
    values.withUnsafeBufferPointer(body)
}

// MARK: PauseClock

test("pause clock adds up completed pauses") {
    var clock = PauseClock()
    expect(clock.pause(at: 10), "first pause")
    expect(clock.isPaused, "paused")
    expect(clock.resume(at: 15), "resume")
    expect(clock.pause(at: 20) && clock.resume(at: 22), "second pause")
    expect(!clock.isPaused && clock.pausedSeconds(at: 100) == 7, "7 s paused in total")
}

test("pause clock counts a pause still in progress") {
    var clock = PauseClock()
    _ = clock.pause(at: 10)
    expect(clock.pausedSeconds(at: 13) == 3, "3 s so far")
    expect(clock.pausedSeconds(at: 9) == 0, "never negative")
}

test("pause clock ignores repeated pause and resume") {
    var clock = PauseClock()
    expect(!clock.resume(at: 5), "resume while running is ignored")
    _ = clock.pause(at: 10)
    expect(!clock.pause(at: 12), "second pause is ignored")
    _ = clock.resume(at: 14)
    expect(clock.pausedSeconds(at: 20) == 4, "measured from the first pause")
}

test("atomic flag stores its value") {
    let flag = AtomicFlag()
    expect(!flag.isSet, "starts unset")
    flag.isSet = true
    expect(flag.isSet, "set")
}

// MARK: SilenceWatchdog

test("watchdog trips once after the threshold of digital silence") {
    var dog = SilenceWatchdog(threshold: 1.0)
    let zeros = [Float](repeating: 0, count: 8000) // 0.5 s at 16 kHz
    expect(withSamples(zeros) { dog.feed(samples: $0, sampleRate: 16000) } == false, "0.5 s: not yet")
    expect(withSamples(zeros) { dog.feed(samples: $0, sampleRate: 16000) } == true, "1.0 s: trips")
    expect(withSamples(zeros) { dog.feed(samples: $0, sampleRate: 16000) } == false, "trips only once")
    expect(dog.tripped && !dog.heardAudio, "state after tripping")
}

test("watchdog resets on real audio, including quiet noise") {
    var dog = SilenceWatchdog(threshold: 1.0)
    let zeros = [Float](repeating: 0, count: 12000)
    let noise: [Float] = (0..<1600).map { _ in Float.random(in: -0.0002...0.0002) }
    _ = withSamples(zeros) { dog.feed(samples: $0, sampleRate: 16000) }
    _ = withSamples(noise) { dog.feed(samples: $0, sampleRate: 16000) }
    expect(dog.silentSeconds == 0 && dog.heardAudio, "noise resets the clock")
    expect(withSamples(zeros) { dog.feed(samples: $0, sampleRate: 16000) } == false, "0.75 s after reset: no trip")
}

// MARK: StreamCompletion

test("stream is complete only when results cover all audio") {
    expect(StreamCompletion.isComplete(transcribedUntil: 4.79, audioSeconds: 4.79006), "exact coverage")
    expect(!StreamCompletion.isComplete(transcribedUntil: 4.40, audioSeconds: 4.79), "finalize before the last word")
    expect(!StreamCompletion.isComplete(transcribedUntil: 3.98, audioSeconds: 4.79), "missing tail segment")
    expect(StreamCompletion.isComplete(transcribedUntil: 4.70, audioSeconds: 4.79), "within tolerance")
}

// MARK: WAV / PCM

test("WAV header describes 16 kHz mono 16-bit PCM") {
    let h = WAV.header(dataBytes: 32000)
    expect(h.count == 44, "44 bytes")
    expect(String(decoding: h[0..<4], as: UTF8.self) == "RIFF", "RIFF tag")
    func u32(_ at: Int) -> UInt32 { h[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    func u16(_ at: Int) -> UInt16 { UInt16(h[at]) | UInt16(h[at + 1]) << 8 }
    expect(u32(4) == 36 + 32000, "RIFF size")
    expect(u16(22) == 1 && u32(24) == 16000 && u32(28) == 32000 && u16(34) == 16, "fmt chunk")
    expect(u32(40) == 32000, "data size")
}

test("PCM conversion clamps and encodes little-endian Int16") {
    let data = withSamples([0, 1, -1, 2, 0.5]) { PCM.int16Data($0) }
    let values = stride(from: 0, to: data.count, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
    expect(values == [0, 32767, -32767, 32767, 16383], "got \(values)")
}

test("signal detection ignores digital silence and dither") {
    expect(!withSamples([0, 0, 0]) { PCM.hasSignal($0) }, "silence")
    expect(!withSamples([0.0001, -0.0002]) { PCM.hasSignal($0) }, "below threshold")
    expect(withSamples([0, 0.01, 0]) { PCM.hasSignal($0) }, "speech-level sample")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
