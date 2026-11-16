import Foundation
import Testing
@testable import GoblinMeetings

/// Tone bursts stand in for speech: the chunker only needs energy, and the scripted engine supplies words.
private func bursts(_ ranges: [ClosedRange<Double>], seconds: Double, frequency: Double) -> [Float] {
    (0..<Int(seconds * MeetingAudio.sampleRate)).map { index in
        let time = Double(index) / MeetingAudio.sampleRate
        return ranges.contains { $0.contains(time) } ? Float(sin(2 * .pi * frequency * time) * 0.3) : 0
    }
}

@Test func aSimulatedCallRunsThroughRecordingTranscriptionAndPostProcessing() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inputs = root.appendingPathComponent("inputs", isDirectory: true)
    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
    let systemURL = inputs.appendingPathComponent("system.wav"), microphoneURL = inputs.appendingPathComponent("microphone.wav")
    try Fixtures.writeWAV(bursts([0.5...1.7, 3.0...4.2], seconds: 7, frequency: 220), to: systemURL)
    try Fixtures.writeWAV(bursts([5.0...6.2], seconds: 7, frequency: 330), to: microphoneURL)

    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let directory = try await MeetingSimulator.run(system: systemURL, microphone: microphoneURL, echoGain: 0, engine: ScriptedEngine(),
                                                   title: "Simulation", root: meetings) { _ in }
    #expect(directory.deletingLastPathComponent().standardizedFileURL == meetings.standardizedFileURL)
    let segments = try MeetingPostProcessor.loadSegments(directory.appendingPathComponent(MeetingStorage.segmentsFile))
    #expect(segments.filter { $0.track == .system }.count == 2)
    #expect(segments.filter { $0.track == .microphone }.count == 1)
    for track in MeetingTrack.allCases {
        let samples = try WAVFile.readSamples(directory.appendingPathComponent(MeetingStorage.audioFile(track)))
        #expect(abs(samples.count - 7 * 16_000) < 1_600)
    }

    let store = MeetingStore(root: meetings, options: Fixtures.options(spans: [DiarizedSpan(speaker: 0, start: 0.4, end: 4.3)]))
    let turns = try await store.process(directory.lastPathComponent)
    // The two system bursts are under 1.5 s apart, so they join into one turn.
    #expect(turns.map(\.speaker) == ["Speaker 1", "You"])
    #expect(turns.map(\.words.count) == [4, 2])
    let summary = try #require(await store.list().first)
    #expect(summary.state == .ready)
    #expect(summary.source == "simulation")
    #expect(abs(summary.duration - 7) < 0.2)
}
