// DeepgramRecorder: records the microphone and (optionally) all computer audio to separate
// AAC files for meeting transcription. It runs as its own app bundle so macOS asks for
// Microphone and System Audio Recording permission on its behalf.
//
//   DeepgramRecorder --out <session dir> [--system]
//   DeepgramRecorder --mic-users     (prints apps currently using the microphone, as JSON)
//
// Writes into the session dir:
//   mic.m4a, system.m4a  audio tracks
//   status.json          {"state": "starting"|"recording"|"stopped"|"error", ...}
//   recorder.pid
// Stops cleanly on SIGINT or SIGTERM. SIGUSR1 pauses and SIGUSR2 resumes: while paused nothing is
// written to either track, so both stay aligned and paused time isn't sent to Deepgram.

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Helpers

struct RecorderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw RecorderError("\(what) failed (OSStatus \(status))") }
}

func hostSeconds(_ hostTime: UInt64) -> Double {
    Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
}

func nowHostSeconds() -> Double { hostSeconds(AudioGetCurrentHostTime()) }

/// Writes `frames` of silence to `file`, in chunks.
func writeSilence(_ frames: Int, format: AVAudioFormat, to file: AVAudioFile) {
    var remaining = frames
    while remaining > 0 {
        let count = AVAudioFrameCount(min(remaining, 48000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buffer.frameLength = count
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        try? file.write(from: buffer)
        remaining -= Int(count)
    }
}

final class StatusWriter {
    let url: URL
    var fields: [String: Any] = [:]
    let lock = NSLock()

    init(dir: URL) { url = dir.appendingPathComponent("status.json") }

    func update(_ changes: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        fields.merge(changes) { _, new in new }
        fields["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Microphone

/// Captures the default input device as 16 kHz mono Float32 buffers. Re-taps when the input device changes mid-capture (e.g. AirPods connecting). Only
/// the input node is used: touching the engine's output side makes it pair the mic with the
/// speakers in an aggregate device, which can deliver no input at all.
///
/// Never enable voice processing here: when a call app holds the same mic in that mode, it
/// knocks out the call app's audio.
final class MicCapture {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let onBuffer: (AVAudioPCMBuffer, AVAudioTime) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        try installTap()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            do {
                self.engine.inputNode.removeTap(onBus: 0)
                try self.installTap()
                try self.engine.start()
            } catch {
                FileHandle.standardError.write("mic restart failed: \(error)\n".data(using: .utf8)!)
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func installTap() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let format = Self.format
        // Multi-channel inputs (the MacBook mic array reports 3 channels, AirPods 9, whenever a call
        // app uses voice processing) must not go through AVAudioConverter's downmix: it outputs
        // pure zeros for them. Take the first channel instead; the channels carry the same voice.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let monoInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoInput, to: format) else {
            throw RecorderError("no microphone input available (is Microphone permission granted?)")
        }
        let ratio = format.sampleRate / inputFormat.sampleRate
        let onBuffer = self.onBuffer

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { input, when in
            guard let channels = input.floatChannelData,
                  let buffer = AVAudioPCMBuffer(pcmFormat: monoInput, frameCapacity: input.frameLength) else { return }
            buffer.frameLength = input.frameLength
            buffer.floatChannelData![0].update(from: channels[0], count: Int(input.frameLength))
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if output.frameLength > 0 { onBuffer(output, when) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Records the microphone to a 16 kHz mono AAC file. `onBlocked` is called (once, on an audio
/// thread) if the mic delivers only digital silence for a while, i.e. another app blocks it.
final class MicRecorder {
    private var capture: MicCapture?
    private var file: AVAudioFile?
    private var watchdog = SilenceWatchdog()
    private(set) var firstSampleHostTime: Double?
    let paused = AtomicFlag()
    private var clock = TrackClock(sampleRate: MicCapture.format.sampleRate)
    private var wasPaused = false

    func start(url: URL, onBlocked: @escaping () -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        let capture = MicCapture { [weak self] buffer, when in
            guard let self else { return }
            if self.paused.isSet { self.wasPaused = true; return }
            if self.wasPaused { self.clock.reanchor(); self.wasPaused = false }
            let time = when.isHostTimeValid ? hostSeconds(when.hostTime) : nowHostSeconds()
            if self.firstSampleHostTime == nil { self.firstSampleHostTime = time }
            let gap = self.clock.framesToInsert(at: time, frames: Int(buffer.frameLength))
            if gap > 0 { writeSilence(gap, format: buffer.format, to: file) }
            try? file.write(from: buffer)
            if let data = buffer.floatChannelData,
               self.watchdog.feed(samples: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)),
                                  sampleRate: buffer.format.sampleRate) {
                onBlocked()
            }
        }
        self.capture = capture
        try capture.start()
    }

    func stop() {
        capture?.stop()
        capture = nil
        file = nil // closing the AVAudioFile finalises the .m4a
    }
}

// MARK: - System audio (Core Audio process tap, macOS 14.2+)

final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private(set) var firstSampleHostTime: Double?
    let paused = AtomicFlag()
    private var clock: TrackClock?
    private var wasPaused = false
    private let queue = DispatchQueue(label: "system-audio", qos: .userInitiated)

    func start(url: URL) throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.name = "DeepgramRecorder"
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "creating system audio tap")

        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeepgramRecorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "creating aggregate device")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "reading tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError("unsupported tap format")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: tapFormat.sampleRate,
            AVNumberOfChannelsKey: tapFormat.channelCount,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: tapFormat.commonFormat, interleaved: tapFormat.isInterleaved)
        self.file = file
        clock = TrackClock(sampleRate: tapFormat.sampleRate)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            if self.paused.isSet { self.wasPaused = true; return }
            if self.wasPaused { self.clock?.reanchor(); self.wasPaused = false }
            let time = inputTime.pointee.mHostTime != 0 ? hostSeconds(inputTime.pointee.mHostTime) : nowHostSeconds()
            if self.firstSampleHostTime == nil { self.firstSampleHostTime = time }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil) else {
                return
            }
            let gap = self.clock?.framesToInsert(at: time, frames: Int(buffer.frameLength)) ?? 0
            if gap > 0 { writeSilence(gap, format: tapFormat, to: file) }
            try? file.write(from: buffer)
        }, "creating IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "starting system audio capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync {} // let any in-flight write finish before closing the file
        file = nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "reading default output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "reading output device UID")
        guard let uid else { throw RecorderError("output device has no UID") }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Session

final class Session {
    let dir: URL
    let captureSystem: Bool
    let status: StatusWriter
    let mic = MicRecorder()
    let system = SystemAudioRecorder()
    var startHostTime = 0.0
    var pauses = PauseClock()
    var warnings: [String] = []
    var signalSources: [DispatchSourceSignal] = []
    var stopped = false

    init(dir: URL, captureSystem: Bool) {
        self.dir = dir
        self.captureSystem = captureSystem
        status = StatusWriter(dir: dir)
    }

    func run() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: dir.appendingPathComponent("recorder.pid"), atomically: true, encoding: .utf8)
        status.update(["state": "starting", "pid": Int(getpid()), "captureSystem": captureSystem])
        installSignalHandlers()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            status.update(["state": "waiting-permission"])
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    granted ? self.begin() : self.fail("Microphone permission denied")
                }
            }
        default:
            fail("Microphone permission denied. Enable DeepgramRecorder in System Settings → Privacy & Security → Microphone.")
        }
    }

    private func begin() {
        startHostTime = nowHostSeconds()
        do {
            try mic.start(url: dir.appendingPathComponent("mic.m4a")) { [weak self] in
                DispatchQueue.main.async { self?.micBlocked() }
            }
        } catch {
            return fail("Microphone: \(error)")
        }
        var warnings: [String] = []
        if captureSystem {
            do {
                try system.start(url: dir.appendingPathComponent("system.m4a"))
            } catch {
                warnings.append("Computer audio not captured: \(error)")
            }
        }
        self.warnings = warnings
        status.update([
            "state": "recording",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "startedAtEpoch": Date().timeIntervalSince1970,
            "paused": false,
            "warnings": warnings,
        ])
    }

    private func micBlocked() {
        warnings.append("Your microphone delivered no sound (another app, such as the call, was blocking it), "
            + "so your own voice may be missing.")
        status.update(["warnings": warnings])
    }

    private func installSignalHandlers() {
        let handlers: [(Int32, (Session) -> Void)] = [
            (SIGINT, { $0.stop() }), (SIGTERM, { $0.stop() }),
            (SIGUSR1, { $0.setPaused(true) }), (SIGUSR2, { $0.setPaused(false) }),
        ]
        for (sig, handler) in handlers {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in if let self { handler(self) } }
            source.resume()
            signalSources.append(source)
        }
    }

    private func setPaused(_ paused: Bool) {
        guard !stopped else { return }
        let now = nowHostSeconds()
        guard paused ? pauses.pause(at: now) : pauses.resume(at: now) else { return }
        mic.paused.isSet = paused
        system.paused.isSet = paused
        status.update(["paused": paused, "pausedSeconds": pauses.pausedSeconds(at: now)])
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let stopTime = nowHostSeconds()
        mic.stop()
        if captureSystem { system.stop() }
        let offset = { (t: Double?) -> Any in t.map { max(0, $0 - self.startHostTime) } ?? NSNull() }
        status.update([
            "state": "stopped",
            "endedAt": ISO8601DateFormatter().string(from: Date()),
            "duration": stopTime - startHostTime - pauses.pausedSeconds(at: stopTime),
            "paused": false,
            "pausedSeconds": pauses.pausedSeconds(at: stopTime),
            "micOffset": offset(mic.firstSampleHostTime),
            "systemOffset": offset(system.firstSampleHostTime),
        ])
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("recorder.pid"))
        exit(0)
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        status.update(["state": "error", "error": message])
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("recorder.pid"))
        exit(1)
    }
}

// MARK: - Microphone users (for meeting detection)

/// Prints a JSON array of processes currently capturing audio input, e.g.
/// [{"pid": 123, "bundleID": "us.zoom.xos"}]. Needs no permissions (macOS 14.2+).
func printMicUsers() {
    func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        }
    }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    var users: [[String: Any]] = []
    if AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr {
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr {
            for process in processes {
                var running: UInt32 = 0
                guard readProperty(process, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
                var pid: pid_t = 0
                _ = readProperty(process, kAudioProcessPropertyPID, &pid)
                var bundleID: Unmanaged<CFString>?
                var entry: [String: Any] = ["pid": Int(pid)]
                if readProperty(process, kAudioProcessPropertyBundleID, &bundleID), let bundleID {
                    entry["bundleID"] = bundleID.takeRetainedValue() as String
                }
                users.append(entry)
            }
        }
    }
    let data = (try? JSONSerialization.data(withJSONObject: users)) ?? Data("[]".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - Streaming dictation

/// Streams the microphone to Deepgram's live API while the user speaks, so the transcript is
/// ready almost as soon as they stop. Run directly (not via `open`) so it shares Hammerspoon's
/// microphone permission.
///
///   DeepgramRecorder --stream --url <wss://...> [--save <file.wav>]
///   (API key in the DEEPGRAM_API_KEY environment variable)
///
/// Prints {"event": "listening"} once the mic delivers real audio (Bluetooth mics such as AirPods
/// are silent for a second or two while they switch on).
/// SIGINT: stop recording, flush, and print {"transcript": "..."} (or {"error": ..., "audio": ...}).
/// SIGTERM: cancel immediately and print nothing.
final class StreamSession {
    private let url: URL
    private let apiKey: String
    private let saveURL: URL?
    private let queue = DispatchQueue(label: "stream")
    private var capture: MicCapture?
    private var announcedListening = false
    private var socket: URLSessionWebSocketTask?
    private var saveHandle: FileHandle?
    private var savedBytes = 0
    private var finals: [String] = []
    private var transcribedUntil = 0.0   // end time (s) of the latest final result
    private var audioSeconds: Double?    // total audio sent, known once recording stops
    private var socketError: String?
    private var stopping = false
    private var finished = false
    private var signalSources: [DispatchSourceSignal] = []

    init(url: URL, apiKey: String, saveURL: URL?) {
        self.url = url
        self.apiKey = apiKey
        self.saveURL = saveURL
    }

    func start() {
        installSignalHandlers()
        if let saveURL {
            FileManager.default.createFile(atPath: saveURL.path, contents: WAV.header(dataBytes: 0))
            saveHandle = try? FileHandle(forWritingTo: saveURL)
            saveHandle?.seekToEndOfFile()
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receive()

        let capture = MicCapture { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            let pcm = PCM.int16Data(samples)
            let loud = PCM.hasSignal(samples)
            self.queue.async {
                if loud && !self.announcedListening {
                    self.announcedListening = true
                    self.emit(["event": "listening"])
                }
                self.sendAudio(pcm)
            }
        }
        do {
            try capture.start()
            self.capture = capture
        } catch {
            output(["error": "\(error)"])
        }
    }

    private func sendAudio(_ data: Data) {
        saveHandle?.write(data)
        savedBytes += data.count
        socket?.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { if self.socketError == nil { self.socketError = error.localizedDescription } }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async {
                    if self.socketError == nil { self.socketError = error.localizedDescription }
                    if self.stopping { self.finish() }
                }
            case .success(let message):
                if case .string(let text) = message { self.queue.async { self.handle(text) } }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if ProcessInfo.processInfo.environment["DEEPGRAM_STREAM_DEBUG"] != nil {
            let alt = ((json["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first
            FileHandle.standardError.write(Data(String(format: "%.3f %@ final=%@ fin=%@ start=%@ dur=%@ %@\n",
                Date().timeIntervalSince1970, "\(json["type"] ?? "")", "\(json["is_final"] ?? "")",
                "\(json["from_finalize"] ?? "")", "\(json["start"] ?? "")", "\(json["duration"] ?? "")",
                "\(alt?["transcript"] ?? "")").utf8))
        }
        // Deepgram sends Metadata last, after flushing every result, when we close the stream.
        if json["type"] as? String == "Metadata", stopping { return finish() }
        guard json["type"] as? String == "Results" else { return }
        let channel = json["channel"] as? [String: Any]
        let alternatives = channel?["alternatives"] as? [[String: Any]]
        guard json["is_final"] as? Bool == true else { return }
        if let transcript = alternatives?.first?["transcript"] as? String, !transcript.isEmpty {
            finals.append(transcript)
        }
        if let start = json["start"] as? Double, let duration = json["duration"] as? Double {
            transcribedUntil = max(transcribedUntil, start + duration)
        }
        // Done once results cover all the audio we sent (Finalize can answer before Deepgram has
        // processed audio that arrived in a burst, so its reply alone isn't enough).
        if let audioSeconds, StreamCompletion.isComplete(transcribedUntil: transcribedUntil, audioSeconds: audioSeconds) {
            finish()
        }
    }

    /// The recorder has exited and all audio has been sent: ask Deepgram for the remaining results.
    private func audioEnded() {
        guard stopping, !finished else { return }
        if socketError != nil { return finish() }
        let seconds = Double(savedBytes) / 32000
        audioSeconds = seconds
        if StreamCompletion.isComplete(transcribedUntil: transcribedUntil, audioSeconds: seconds) { return finish() }
        socket?.send(.string(#"{"type":"Finalize"}"#)) { _ in }
        // Backup: CloseStream makes Deepgram flush everything, send Metadata and close.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.finished else { return }
            self.socket?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        }
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish() } // last resort
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let saveHandle {
            saveHandle.seek(toFileOffset: 0)
            saveHandle.write(WAV.header(dataBytes: savedBytes))
            try? saveHandle.close()
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        if let socketError, finals.isEmpty {
            output(["error": socketError, "audio": saveURL?.path ?? NSNull()])
        } else {
            output(["transcript": finals.joined(separator: " ")])
        }
    }

    private func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    private func output(_ object: [String: Any]) {
        emit(object)
        exit(0)
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGTERM { exit(0) }
                self.stopping = true
                // Buffers already captured are queued ahead of this, so all audio is sent first.
                self.capture?.stop()
                self.queue.async { self.audioEnded() }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

func runStreamMode() -> Never {
    var args = CommandLine.arguments.dropFirst()
    var url: URL?, save: URL?
    while let arg = args.popFirst() {
        switch arg {
        case "--url": url = args.popFirst().flatMap(URL.init(string:))
        case "--save": save = args.popFirst().map { URL(fileURLWithPath: $0) }
        default: break
        }
    }
    let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    guard let url, !key.isEmpty else {
        FileHandle.standardError.write(Data("usage: DeepgramRecorder --stream --url WSS_URL [--save FILE]\n".utf8))
        exit(2)
    }
    let session = StreamSession(url: url, apiKey: key, saveURL: save)
    session.start()
    dispatchMain()
}

// MARK: - Entry point

if CommandLine.arguments.contains("--mic-users") {
    printMicUsers()
    exit(0)
}
if CommandLine.arguments.contains("--stream") {
    runStreamMode()
}

func parseArguments() -> (URL, Bool)? {
    var args = CommandLine.arguments.dropFirst()
    var out: URL?
    var system = false
    while let arg = args.popFirst() {
        switch arg {
        case "--out": if let path = args.popFirst() { out = URL(fileURLWithPath: path) }
        case "--system": system = true
        default: break // ignore extra arguments LaunchServices may add
        }
    }
    return out.map { ($0, system) }
}

guard let (dir, captureSystem) = parseArguments() else {
    FileHandle.standardError.write("usage: DeepgramRecorder --out <dir> [--system]\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let session = Session(dir: dir, captureSystem: captureSystem)
DispatchQueue.main.async { session.run() }
app.run()
