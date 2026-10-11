// Pure decision logic for DeepgramRecorder, kept free of audio APIs so it can be unit tested
// (recorder/Tests). Compiled together with main.swift.

import Foundation

/// Detects a microphone that delivers only digital zeros: real microphones always have some
/// noise, so long runs of exact zeros mean the audio is being lost (blocked input, a broken
/// conversion, ...). Used to warn in the transcript instead of silently dropping the user's voice.
struct SilenceWatchdog {
    let threshold: Double          // seconds of continuous digital silence before reporting
    private(set) var silentSeconds = 0.0
    private(set) var heardAudio = false
    private(set) var tripped = false

    init(threshold: Double = 10) { self.threshold = threshold }

    /// Feeds one buffer; returns true exactly once, when the threshold is first crossed.
    mutating func feed(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Bool {
        let allZero = samples.allSatisfy { $0 == 0 }
        if !allZero {
            heardAudio = true
            silentSeconds = 0
            return false
        }
        silentSeconds += Double(samples.count) / sampleRate
        if !tripped && silentSeconds >= threshold {
            tripped = true
            return true
        }
        return false
    }
}

/// Tracks pauses in a meeting recording, so the reported duration covers only recorded time.
/// Times are host-clock seconds.
struct PauseClock {
    private(set) var pausedTotal = 0.0
    private(set) var pausedSince: Double?
    var isPaused: Bool { pausedSince != nil }

    /// Returns false if already paused.
    mutating func pause(at time: Double) -> Bool {
        guard pausedSince == nil else { return false }
        pausedSince = time
        return true
    }

    /// Returns false if not paused.
    mutating func resume(at time: Double) -> Bool {
        guard let since = pausedSince else { return false }
        pausedTotal += max(0, time - since)
        pausedSince = nil
        return true
    }

    /// Total paused time up to `time`, including a pause still in progress.
    func pausedSeconds(at time: Double) -> Double {
        pausedTotal + (pausedSince.map { max(0, time - $0) } ?? 0)
    }
}

/// Keeps a track in step with the clock. Audio sources sometimes skip time (the system audio
/// tap goes quiet for seconds at a time); appending regardless would shift everything after the
/// gap, and the mic and computer-audio tracks would drift apart. `framesToInsert` says how much
/// silence to write before a buffer so it lands at the right moment.
struct TrackClock {
    let sampleRate: Double
    let tolerance: Double            // seconds of lag ignored (clock jitter, small drift)
    private var anchor: Double?      // host time of the track's frame 0, adjusted after pauses
    private(set) var framesWritten: Int64 = 0

    init(sampleRate: Double, tolerance: Double = 0.25) {
        self.sampleRate = sampleRate
        self.tolerance = tolerance
    }

    /// After a pause: the next buffer continues the track without filling the paused time.
    mutating func reanchor() { anchor = nil }

    /// Call for every buffer, in order, with its host time and length; returns silence frames to
    /// write first.
    mutating func framesToInsert(at hostTime: Double, frames: Int) -> Int {
        var insert = 0
        if let anchor {
            let gap = Int64(((hostTime - anchor) * sampleRate).rounded()) - framesWritten
            if Double(gap) > tolerance * sampleRate { insert = Int(gap) }
        } else {
            anchor = hostTime - Double(framesWritten) / sampleRate
        }
        framesWritten += Int64(insert + frames)
        return insert
    }
}

/// A Bool shared between the main thread and audio threads.
final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum StreamCompletion {
    /// Whether Deepgram's final results cover all the audio sent (within `tolerance` seconds).
    /// Finalize can be answered before Deepgram has processed audio that arrived in a burst, so
    /// the reply alone doesn't mean the transcript is complete.
    static func isComplete(transcribedUntil: Double, audioSeconds: Double, tolerance: Double = 0.1) -> Bool {
        transcribedUntil >= audioSeconds - tolerance
    }
}

enum WAV {
    /// 44-byte header for 16-bit mono PCM.
    static func header(dataBytes: Int, sampleRate: Int = 16000) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        return header
    }
}

enum PCM {
    /// Converts Float32 samples to little-endian Int16 bytes, clamping to [-1, 1].
    static func int16Data(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            }
        }
        return data
    }

    /// Whether any sample is above the noise threshold (used to tell when a Bluetooth mic is live).
    static func hasSignal(_ samples: UnsafeBufferPointer<Float>, threshold: Float = 0.0005) -> Bool {
        samples.contains { abs($0) > threshold }
    }
}
