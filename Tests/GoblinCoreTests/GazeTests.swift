import Foundation
import Testing
@testable import GoblinCore

@Test func gazeFollowsThePointerWithoutFlickering() {
    #expect(Gaze.toward(dx: 10, dy: 10, from: .ahead) == .ahead)
    #expect(Gaze.toward(dx: 100, dy: 0, from: .ahead) == .e)
    #expect(Gaze.toward(dx: 0, dy: 100, from: .ahead) == .s)
    #expect(Gaze.toward(dx: -70, dy: 70, from: .ahead) == .sw)
    #expect(Gaze.toward(dx: 70, dy: -70, from: .ahead) == .ne)
    #expect(Gaze.toward(dx: -100, dy: 1, from: .ahead) == .w)
    #expect(Gaze.toward(dx: -100, dy: -1, from: .ahead) == .w)
    // 25° below east is past the sector edge at 22.5°, but the eyes hold until about 29°.
    let edge = 25 * Double.pi / 180
    #expect(Gaze.toward(dx: 100 * cos(edge), dy: 100 * sin(edge), from: .ahead) == .se)
    #expect(Gaze.toward(dx: 100 * cos(edge), dy: 100 * sin(edge), from: .e) == .e)
    #expect(Gaze.toward(dx: 100 * cos(edge), dy: 100 * sin(edge), from: .s) == .se)
    // The face's rim: 40 points away keeps whichever look the eyes already have.
    #expect(Gaze.toward(dx: 0, dy: 40, from: .ahead) == .ahead)
    #expect(Gaze.toward(dx: 0, dy: 40, from: .s) == .s)
}
