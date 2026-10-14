import AudioToolbox
import AVFoundation
import Darwin
import Foundation

/// Precreated UI sounds use the system sound-effects route and its existing volume.
public final class FeedbackSounds: @unchecked Sendable {
    private let lock = NSLock()
    private var startID: SystemSoundID = 0
    private var stopID: SystemSoundID = 0
    private var session: UUID?
    private var started = false
    private var startAllowed = false
    private var protectionStart: UInt64 = 0
    private var protectedUntil: UInt64 = 0
    private var playGeneration = UUID()

    public init(directory: URL) {
        startID = Self.load(directory.appendingPathComponent("dictation-start.wav"))
        stopID = Self.load(directory.appendingPathComponent("dictation-stop.wav"))
    }

    deinit {
        if startID != 0 { AudioServicesDisposeSystemSoundID(startID) }
        if stopID != 0 { AudioServicesDisposeSystemSoundID(stopID) }
    }

    public func begin(sessionID: UUID) { lock.withLock { session = sessionID; started = false; startAllowed = true } }

    public func cancelStart(sessionID: UUID) { lock.withLock { if session == sessionID { startAllowed = false } } }

    func firstBuffer(sessionID: UUID) {
        lock.withLock {
            guard session == sessionID, startAllowed, !started else { return }
            started = true
            play(startID)
        }
    }

    public func end(sessionID: UUID, playStop: Bool) {
        lock.withLock {
            guard session == sessionID else { return }
            session = nil
            if started && playStop { play(stopID) }
        }
    }

    func protectsInput(at hostTime: UInt64, duration: UInt64) -> Bool {
        lock.withLock { hostTime <= protectedUntil && hostTime &+ duration >= protectionStart && protectionStart != 0 }
    }

    private func play(_ id: SystemSoundID) {
        guard id != 0 else { return }
        // Keep protection through playback completion, including device latency and acoustic decay.
        let now = mach_absolute_time()
        if now > protectedUntil { protectionStart = now }
        protectedUntil = UInt64.max
        let generation = UUID(); playGeneration = generation
        AudioServicesPlaySystemSoundWithCompletion(id) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.playGeneration == generation else { return }
                self.protectedUntil = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.25)
            }
        }
    }

    private static func load(_ url: URL) -> SystemSoundID {
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return 0 }
        var uiSound: UInt32 = 1
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout.size(ofValue: id)), &id,
                                 UInt32(MemoryLayout.size(ofValue: uiSound)), &uiSound)
        return id
    }
}

/// Gate only the two cue frequencies; retain the timing and speech overlapping a cue.
struct CaptureCueFilter {
    private var filters: [Notch]
    init(sampleRate: Double) {
        filters = [1320.0, 1760.0].flatMap { frequency in
            (0..<3).map { _ in Notch(frequency: frequency, sampleRate: sampleRate) }
        }
    }
    mutating func apply(_ samples: [Float], enabled: Bool) -> [Float] {
        var result = samples
        for i in samples.indices {
            var value = Double(samples[i])
            for j in filters.indices { value = filters[j].apply(value) }
            if enabled { result[i] = max(-1, min(1, Float(value))) }
        }
        return result
    }
    private struct Notch {
        let cosine: Double
        let radius = 0.985
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(frequency: Double, sampleRate: Double) { cosine = cos(2 * .pi * frequency / sampleRate) }
        mutating func apply(_ x: Double) -> Double {
            let y = radius * (x - 2 * cosine * x1 + x2) + 2 * radius * cosine * y1 - radius * radius * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
