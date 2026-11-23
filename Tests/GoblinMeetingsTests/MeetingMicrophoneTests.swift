import GoblinCore
import GoblinEngines
import Testing
@testable import GoblinMeetings

private let usb = AudioInputDevice(id: 10, uid: "usb-1", name: "Lav Receiver", model: "LavRX:1234", kind: .usb)
private let airPods = AudioInputDevice(id: 20, uid: "airpods:input", name: "AirPods", kind: .bluetooth)
private let builtIn = AudioInputDevice(id: 30, uid: "builtin", name: "MacBook Pro Microphone", kind: .builtIn)
private let lidShut = AudioInputDevice(id: 30, uid: "builtin", name: "MacBook Pro Microphone", kind: .builtIn, silencedByLid: true)

private func choose(_ preference: MeetingMicrophonePreference = .sameAsCall, connected: [AudioInputDevice] = [usb, airPods, builtIn],
                    call: [UInt32] = [], current: MeetingMicrophone? = nil, ranked: AudioInputDevice? = airPods) -> MeetingMicrophone? {
    MeetingMicrophone.choose(preference: preference, connected: connected, callDevices: call, current: current) { ranked }
}

/// The call's mic, not the default: opening a headset's mic under a call that uses another one switches the headset to
/// its call profile and stops the call's sound.
@Test func meetingMicFollowsTheCallAppsMicOverTheRanking() {
    #expect(choose(call: [usb.id]) == MeetingMicrophone(device: usb, reason: .call))
    // While the call app is between mics, the one it had stays open rather than falling back to the ranking.
    #expect(choose(current: MeetingMicrophone(device: usb, reason: .call)) == MeetingMicrophone(device: usb, reason: .call))
    // In person there's no call: dictation's ranking.
    #expect(choose() == MeetingMicrophone(device: airPods, reason: .ranking))
}

@Test func pickedMeetingMicWinsWhileItCanHear() {
    let entry = MicrophoneRanking.Entry(uid: "usb-old-port", name: "Lav Receiver", model: "LavRX:1234", kind: .usb)
    // Matched by product and name after moving to another USB port.
    #expect(choose(.device(entry), call: [airPods.id]) == MeetingMicrophone(device: usb, reason: .picked))
    // Unplugged: the call's mic instead.
    #expect(choose(.device(entry), connected: [airPods, builtIn], call: [airPods.id]) == MeetingMicrophone(device: airPods, reason: .call))
}

@Test func lidSilencedMicIsNeverChosen() {
    let picked = MicrophoneRanking.Entry(uid: builtIn.uid, name: builtIn.name, kind: .builtIn)
    #expect(choose(.device(picked), connected: [usb, lidShut], call: [usb.id]) == MeetingMicrophone(device: usb, reason: .call))
    #expect(choose(connected: [usb, lidShut], call: [lidShut.id], ranked: usb) == MeetingMicrophone(device: usb, reason: .ranking))
    #expect(choose(connected: [lidShut], current: MeetingMicrophone(device: builtIn, reason: .call), ranked: nil) == nil)
}
