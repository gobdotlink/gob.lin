import Testing
@testable import GoblinCore

/// Each press that can start a take prepares it, and each preparation ends in exactly one take or one abandon, so
/// the microphone opened at key-down always has an owner that closes it.
@Test func pressPreparesAndEveryPreparationEndsOnce() {
    var tap = HotkeyStateMachine()
    #expect(tap.press(at: 1) == [.prepareRecording])
    #expect(tap.release(at: 1.1) == [.beginRecording(.handsFree)])
    #expect(tap.press(at: 2).isEmpty, "the press that ends a hands-free take prepares nothing")
    #expect(tap.release(at: 2.1) == [.finishRecording(queueForProcessing: false)])

    var hold = HotkeyStateMachine()
    #expect(hold.press(at: 1) == [.prepareRecording])
    #expect(hold.tick(at: 1.2).isEmpty)
    #expect(hold.tick(at: 1.31) == [.beginRecording(.hold)])
    #expect(hold.cancel() == [.cancelRecording], "a take that began is cancelled, not abandoned")
    #expect(hold.release(at: 1.5).isEmpty)

    var chord = HotkeyStateMachine()
    #expect(chord.press(at: 1) == [.prepareRecording])
    #expect(chord.chord() == [.abandonPreparation])
    #expect(chord.chord().isEmpty, "abandoned once")
    #expect(chord.tick(at: 1.4).isEmpty && chord.release(at: 1.5).isEmpty)
}

@Test func pressesThatCannotStartATakePrepareNothing() {
    var state = HotkeyStateMachine()
    #expect(state.press(at: 1) == [.prepareRecording])
    #expect(state.press(at: 1.05).isEmpty, "a repeat press")
    #expect(state.release(at: 1.1) == [.beginRecording(.handsFree)])
    #expect(state.press(at: 1.15).isEmpty, "inside the 80 ms debounce, while recording")
    #expect(state.release(at: 1.16).isEmpty)
    #expect(state.press(at: 1.5).isEmpty, "the press that ends the take")
    #expect(state.release(at: 1.6) == [.finishRecording(queueForProcessing: false)])
    #expect(state.press(at: 1.65).isEmpty, "inside the debounce after a release")
    #expect(state.release(at: 1.7).isEmpty)
}

@Test func cancellingAPendingPressAbandonsIt() {
    var state = HotkeyStateMachine()
    #expect(state.cancel().isEmpty, "nothing pressed, nothing to abandon")
    #expect(state.press(at: 1) == [.prepareRecording])
    #expect(state.cancel() == [.abandonPreparation], "Escape, suspension or the recorder before the threshold")
    #expect(state.cancel().isEmpty)
    #expect(state.tick(at: 1.4).isEmpty, "a queued threshold tick can't begin an abandoned press")
    #expect(state.press(at: 2) == [.prepareRecording])
    #expect(state.release(at: 2.4) == [.beginRecording(.hold), .finishRecording(queueForProcessing: false)],
            "a release after a missed threshold still begins, without abandoning")
}
