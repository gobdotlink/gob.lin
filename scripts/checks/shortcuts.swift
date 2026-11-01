import CoreGraphics
import Foundation

// Event traces as macOS delivers them: modifier changes carry the shared flag, the key's side bit and the
// always-set non-coalesced bit. Function keys carry the Fn flag macOS adds itself.
private enum Event { case modifier(UInt16, Bool), down(UInt16, extra: UInt64 = 0, label: String = "", isRepeat: Bool = false), up(UInt16) }
private let fn = HotkeyShortcut.fnFlag

private func flags(_ held: Set<UInt16>) -> UInt64 {
    HotkeyShortcut.modifierKeys.filter { held.contains($0.code) }.reduce(UInt64(0x100)) { $0 | $1.flag | $1.side }
}

/// Plays a trace through the recorder, as the settings window sees it.
private func record(_ events: [Event]) -> HotkeyShortcut? {
    var capture = ShortcutCapture(), held: Set<UInt16> = []
    for event in events {
        switch event {
        case .modifier(let code, let down):
            if down { held.insert(code) } else { held.remove(code) }
            capture.modifierChanged(code: code, flags: flags(held))
        case .down(let code, let extra, let label, let isRepeat):
            capture.keyDown(code: code, flags: flags(held) | extra, label: label, isRepeat: isRepeat)
        case .up(let code):
            if let done = capture.keyUp(code: code) { return done }
        }
    }
    return capture.finished
}

/// Plays a trace through the shortcut matcher, as the event tap sees it.
private func tap(_ shortcut: HotkeyShortcut, _ events: [Event]) -> [String] {
    var held = false, inputs: [String] = [], down: Set<UInt16> = []
    for event in events {
        switch event {
        case .modifier(let code, let isDown):
            if isDown { down.insert(code) } else { down.remove(code) }
            guard shortcut.keyCode == nil else { continue }
            switch shortcut.modifierChange(code: code, flags: flags(down), held: held) {
            case .press: held = true; inputs.append("press")
            case .release: held = false; inputs.append("release")
            case .chord: inputs.append("chord")
            case nil: break
            }
        case .down(let code, let extra, _, let isRepeat):
            if shortcut.matchesKey(code, flags: flags(down) | extra), !held, !isRepeat { held = true; inputs.append("press") }
            else if shortcut.keyCode == nil, held { inputs.append("chord") }
        case .up(let code):
            if code == shortcut.keyCode, held { held = false; inputs.append("release") }
        }
    }
    return inputs
}

private func tapped(_ code: UInt16) -> [Event] { [.modifier(code, true), .modifier(code, false)] }

func checkShortcuts() {
    let control = CGEventFlags.maskControl.rawValue, option = CGEventFlags.maskAlternate.rawValue
    let command = CGEventFlags.maskCommand.rawValue, shift = CGEventFlags.maskShift.rawValue

    // Measured on an external keyboard. Mac mode: physical Right Ctrl sends Right Option.
    expect(record(tapped(61)) == .rightOption, "Mac-mode Right Ctrl records as the Right Option preset")
    // Windows mode: Right Ctrl is Right Control and stays distinct from Left Control.
    let rightControl = record(tapped(62))!
    expect(rightControl.modifiers == control && rightControl.sides == 0x2000 && rightControl.title == "Right Control", "Right Control keeps its side")
    expect(tap(rightControl, tapped(59)).isEmpty, "Left Control does not trigger a Right Control talk key")
    expect(tap(rightControl, tapped(62)) == ["press", "release"], "Right Control presses and releases")
    expect(tap(rightControl, [.modifier(62, true), .modifier(59, true), .modifier(59, false), .modifier(62, false)]) == ["press", "chord", "release"],
           "adding Left Control while holding Right Control is a chord")
    // Insert alone, in both modes. macOS adds the Fn flag to it.
    let insert = record([.down(114, extra: fn, label: "Insert"), .up(114)])!
    expect(insert.keyCode == 114 && insert.modifiers == 0 && insert.label == "Insert" && insert.isValid, "Insert alone records")
    expect(tap(insert, [.down(114, extra: fn), .up(114)]) == ["press", "release"], "Insert alone triggers")
    expect(tap(insert, [.modifier(56, true), .down(114, extra: fn), .up(114), .modifier(56, false)]).isEmpty, "Shift+Insert leaves Insert alone")
    // Right Ctrl + Insert: Right Option in Mac mode, Right Control in Windows mode.
    let optionInsert = record([.modifier(61, true), .down(114, extra: fn, label: "Insert"), .up(114), .modifier(61, false)])!
    expect(optionInsert.modifiers == option && optionInsert.label == "⌥Insert" && optionInsert.title == "Option + Insert", "Mac-mode Right Ctrl+Insert")
    let controlInsert = record([.modifier(62, true), .down(114, extra: fn, label: "Insert"), .up(114), .modifier(62, false)])!
    expect(controlInsert.modifiers == control && controlInsert.worksUnderSecureInput, "Windows-mode Right Ctrl+Insert")
    // Mac-mode mic key: a Globe tap, then Globe+Space. The macro records whole.
    let globeSpace = record([.modifier(63, true), .modifier(63, false), .modifier(63, true), .down(49, extra: fn, label: "Space"), .modifier(63, false), .up(49)])!
    expect(globeSpace.keyCode == 49 && globeSpace.modifiers == fn && !globeSpace.worksUnderSecureInput && globeSpace.caution != nil, "Mac-mode mic key records as Fn+Space")
    // Windows-mode mic key: Win+C arrives as Command+C. Allowed, with a warning.
    let commandC = record([.modifier(55, true), .down(8, label: "C"), .up(8), .modifier(55, false)])!
    expect(commandC.modifiers == command && commandC.caution != nil, "Windows-mode mic key records as Command+C with a warning")

    // Every modifier key alone keeps its side, and the other side never presses it.
    for key in HotkeyShortcut.modifierKeys {
        let shortcut = record(tapped(key.code))!
        expect(shortcut.isValid && shortcut.keyCode == nil, "\(key.name) records")
        expect(tap(shortcut, tapped(key.code)) == ["press", "release"], "\(key.name) triggers")
        for other in HotkeyShortcut.modifierKeys where other.code != key.code {
            expect(!tap(shortcut, tapped(other.code)).contains("press"), "\(other.name) does not trigger \(key.name)")
        }
    }
    expect(record(tapped(63)) == .fn, "Fn records as the Fn preset")
    // Every pair of modifier keys, released in either order, records as both keys.
    for first in HotkeyShortcut.modifierKeys {
        for second in HotkeyShortcut.modifierKeys where second.code != first.code {
            let pair = record([.modifier(first.code, true), .modifier(second.code, true), .modifier(first.code, false), .modifier(second.code, false)])
            let expected = HotkeyShortcut(modifierKeys: [first.code, second.code])
            expect(pair == expected && expected.isValid, "\(first.name) + \(second.name) records, released first-down first")
            expect(record([.modifier(first.code, true), .modifier(second.code, true), .modifier(second.code, false), .modifier(first.code, false)]) == expected,
                   "\(first.name) + \(second.name) records, released last-down first")
            expect(tap(expected, [.modifier(first.code, true), .modifier(second.code, true), .modifier(second.code, false), .modifier(first.code, false)]) == ["press", "release"],
                   "\(first.name) + \(second.name) presses once both are down and releases when either comes up")
            expect(!tap(expected, tapped(first.code)).contains("press"), "\(first.name) alone does not trigger \(first.name) + \(second.name)")
        }
    }

    // Plain keys, Esc and keys with Shift record as chosen; repeats never replace the key.
    let escape = record([.down(53, label: "Esc"), .up(53)])!
    expect(escape.keyCode == 53 && escape.modifiers == 0 && escape.caution != nil, "Esc records, with a note about cancelling")
    let letter = record([.down(0, label: "A"), .modifier(56, true), .down(0, extra: shift, label: "A", isRepeat: true), .up(0), .modifier(56, false)])!
    expect(letter.modifiers == 0 && letter.isValid && letter.caution != nil, "a plain letter records, with a typing warning")
    expect(record([.modifier(56, true), .down(0, label: "A"), .modifier(56, false), .up(0)])?.modifiers == shift, "modifiers count at key-down, not release")
    expect(record([.down(96, extra: fn, label: "F5"), .up(96)])?.modifiers == 0, "F5 drops the Fn flag macOS adds")
    expect(record([.modifier(56, true), .modifier(56, false)]) != nil && record([.modifier(56, true)]) == nil, "a modifier saves only after release")

    // Stored shortcuts from earlier builds keep working.
    let decoder = JSONDecoder()
    let legacyRight = try! decoder.decode(HotkeyShortcut.self, from: Data(#"{"modifiers":524288,"modifier":"rightOption","keyLabel":"Right Option"}"#.utf8))
    expect(legacyRight == .rightOption, "a stored Right Option stays Right Option")
    let legacyControl = try! decoder.decode(HotkeyShortcut.self, from: Data(#"{"modifiers":262144,"modifier":"control","keyLabel":"Control"}"#.utf8))
    expect(legacyControl.isValid && tap(legacyControl, tapped(59)) == ["press", "release"] && tap(legacyControl, tapped(62)) == ["press", "release"],
           "a stored generic Control still accepts either side")
    for shortcut in [HotkeyShortcut.fn, .rightOption, .optionSpace, rightControl, insert, globeSpace, HotkeyShortcut(modifierKeys: [59, 56])] {
        expect(try! decoder.decode(HotkeyShortcut.self, from: JSONEncoder().encode(shortcut)) == shortcut, "\(shortcut.title) round-trips")
    }

    // The tap's inputs drive hold and hands-free through the state machine.
    var state = HotkeyStateMachine()
    state.press(at: 20)
    expect(state.tick(at: 20.31) == [.beginRecording(.hold)], "holding Right Control starts push-to-talk")
    expect(state.release(at: 20.5) == [.finishRecording(queueForProcessing: false)], "letting go finishes")
    state.press(at: 21)
    expect(state.release(at: 21.1) == [.beginRecording(.handsFree)], "tapping Insert starts hands-free")
}
