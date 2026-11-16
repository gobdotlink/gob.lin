import Foundation
import Testing
@testable import GoblinMeetings

@Test func marksRoundTripInTimeOrderWithLabelsOptional() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(MeetingMarks.read(from: directory).isEmpty)
    try MeetingMarks.write([MeetingMark(t: 372.456, label: "Pricing: free tier stays at three"), MeetingMark(t: 12.3, label: "  ")],
                           to: directory)
    let text = try String(contentsOf: directory.appendingPathComponent(MeetingStorage.marksFile), encoding: .utf8)
    // One mark per line, as the review reads them: a blank label is no label.
    #expect(text == "{\"t\":12.3}\n{\"label\":\"Pricing: free tier stays at three\",\"t\":372.46}\n")
    #expect(MeetingMarks.read(from: directory) == [MeetingMark(t: 12.3), MeetingMark(t: 372.46, label: "Pricing: free tier stays at three")])
    // Labelling later rewrites the line instead of adding one.
    try MeetingMarks.write([MeetingMark(t: 12.3, label: "Intro"), MeetingMark(t: 372.46, label: "Pricing: free tier stays at three")], to: directory)
    #expect(MeetingMarks.read(from: directory).map(\.label) == ["Intro", "Pricing: free tier stays at three"])
}

@Test func aTornMarksLineIsSkipped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{\"t\":4}\n{\"t\":9,\"lab".utf8).write(to: directory.appendingPathComponent(MeetingStorage.marksFile))
    #expect(MeetingMarks.read(from: directory) == [MeetingMark(t: 4)])
}

@Test func onlyYourOwnScreenShareHidesTheSidekick() {
    #expect(AccessibilityProbe.sharingState(["3 AXButton: Stop Share", "2 AXWindow: zoom share toolbar window"]))
    #expect(AccessibilityProbe.sharingState(["4 AXStaticText: You are screen sharing"]))
    #expect(AccessibilityProbe.sharingState(["7 AXStaticText: You are presenting", "8 AXButton: Stop presenting"]))
    #expect(!AccessibilityProbe.sharingState(["6 AXButton: Share Screen", "6 AXButton: Mute my audio"]))
    #expect(!AccessibilityProbe.sharingState(["9 AXButton: Present now", "7 AXStaticText: Alex Kim is presenting"]))
}
