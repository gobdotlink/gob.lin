import Foundation

/// Capture may overlap a previous transcription; only processing is queued.
public struct HotkeyStateMachine: Sendable {
    public enum Recording: Equatable, Sendable { case hold, handsFree }
    public enum Action: Equatable, Sendable {
        case beginRecording(Recording)
        case finishRecording(queueForProcessing: Bool)
        case cancelRecording
    }
    public private(set) var recording: Recording?
    public private(set) var processingCount = 0
    private var pressedAt: TimeInterval?
    private var chorded = false
    private var lastRelease = -Double.infinity
    public init() {}

    public mutating func press(at time: TimeInterval) {
        guard pressedAt == nil, time - lastRelease >= 0.08 else { return }
        pressedAt = time
        chorded = false
    }

    public mutating func tick(at time: TimeInterval) -> [Action] {
        guard let pressedAt, !chorded, recording == nil, time - pressedAt >= 0.3 else { return [] }
        recording = .hold
        return [.beginRecording(.hold)]
    }

    public mutating func release(at time: TimeInterval) -> [Action] {
        guard let pressedAt else { return [] }
        self.pressedAt = nil
        lastRelease = time
        guard !chorded else { chorded = false; return [] }
        if recording != nil { return finish() }
        // If the run loop was busy at the threshold, preserve the hold's start/stop.
        if time - pressedAt >= 0.3 {
            recording = .hold
            return [.beginRecording(.hold)] + finish()
        }
        recording = .handsFree
        return [.beginRecording(.handsFree)]
    }

    public mutating func chord() -> [Action] {
        guard pressedAt != nil else { return [] }
        chorded = true
        if recording == .hold { recording = nil; return [.cancelRecording] }
        return []
    }

    public mutating func cancel() -> [Action] {
        pressedAt = nil
        chorded = false
        guard recording != nil else { return [] }
        recording = nil
        return [.cancelRecording]
    }

    public mutating func processingCompleted() {
        processingCount = max(0, processingCount - 1)
    }

    private mutating func finish() -> [Action] {
        recording = nil
        let queued = processingCount > 0
        processingCount += 1
        return [.finishRecording(queueForProcessing: queued)]
    }
}
