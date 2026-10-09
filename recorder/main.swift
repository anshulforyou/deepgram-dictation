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
// Stops cleanly on SIGINT or SIGTERM.

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

/// Records the default input device, converted to 16 kHz mono so the file format stays constant
/// even if the input device changes mid-recording. Only the input node is used: touching the
/// engine's output side makes it pair the mic with the speakers in an aggregate device, which
/// can deliver no input at all.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private(set) var firstSampleHostTime: Double?
    private var observer: NSObjectProtocol?

    func start(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try installTap()

        // Input device switched (e.g. AirPods connected): re-tap with the new device's format.
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
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw RecorderError("no microphone input available (is Microphone permission granted?)")
        }
        converter.downmix = true
        let format = self.format
        let ratio = format.sampleRate / inputFormat.sampleRate

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            guard let self, let file = self.file else { return }
            if self.firstSampleHostTime == nil {
                self.firstSampleHostTime = when.isHostTimeValid ? hostSeconds(when.hostTime) : nowHostSeconds()
            }
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
            if output.frameLength > 0 { try? file.write(from: output) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            if self.firstSampleHostTime == nil {
                self.firstSampleHostTime = hostSeconds(inputTime.pointee.mHostTime)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil) else {
                return
            }
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
            try mic.start(url: dir.appendingPathComponent("mic.m4a"))
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
        status.update([
            "state": "recording",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "warnings": warnings,
        ])
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        mic.stop()
        if captureSystem { system.stop() }
        let offset = { (t: Double?) -> Any in t.map { max(0, $0 - self.startHostTime) } ?? NSNull() }
        status.update([
            "state": "stopped",
            "endedAt": ISO8601DateFormatter().string(from: Date()),
            "duration": nowHostSeconds() - startHostTime,
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

// MARK: - Entry point

if CommandLine.arguments.contains("--mic-users") {
    printMicUsers()
    exit(0)
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
