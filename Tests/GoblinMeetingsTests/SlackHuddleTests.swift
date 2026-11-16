import Foundation
import Testing
@testable import GoblinMeetings

// Window titles are made up. Slack's main window: "<conversation> - <workspace> - Slack".

private func window(_ subrole: String, _ title: String, role: String = "AXWindow") -> CallWindow {
    CallWindow(role: role, subrole: subrole, title: title)
}

private let slack = CallApp.matching(bundleID: "com.tinyspeck.slackmacgap")!
private let main = window("AXStandardWindow", "design-team - Acme - Slack")

// MARK: Which windows are read

@Test func slacksMainAndConversationWindowsAreNeverRead() {
    #expect(!slack.scope.reads(main))
    #expect(!slack.scope.reads(window("AXStandardWindow", "Alex Kim - Acme - Slack")))
    // A channel with "huddle" in its name is still a conversation window.
    #expect(!slack.scope.reads(window("AXStandardWindow", "huddle-notes - Acme - Slack")))
    #expect(!slack.scope.reads(window("AXStandardWindow", "team-huddle - Acme - Slack")))
    #expect(!slack.scope.reads(window("AXStandardWindow", "Huddlestone - Acme - Slack")))
    // Unsure: a plain window that doesn't say huddle, a dialog, a sheet, something without a subrole.
    #expect(!slack.scope.reads(window("AXStandardWindow", "Slack")))
    #expect(!slack.scope.reads(window("AXStandardWindow", "")))
    #expect(!slack.scope.reads(window("AXDialog", "Huddle")))
    #expect(!slack.scope.reads(window("", "Huddle")))
    #expect(!slack.scope.reads(window("AXStandardWindow", "Huddle", role: "AXSheet")))
}

@Test func slacksHuddleAndMiniWindowsAreRead() {
    #expect(slack.scope.reads(window("AXStandardWindow", "Huddle")))
    #expect(slack.scope.reads(window("AXStandardWindow", "Slack | Huddle with Alex Kim")))
    #expect(slack.scope.reads(window("AXStandardWindow", "Huddle: design-team - Acme - Slack")))
    #expect(slack.scope.reads(window("AXStandardWindow", "Huddle - Acme - Slack")))
    // The mini window floats over everything; Slack floats nothing else.
    #expect(slack.scope.reads(window("AXFloatingWindow", "")))
    #expect(slack.scope.reads(window("AXSystemFloatingWindow", "Slack")))
}

@Test func otherAppsKeepTheirScopes() {
    let zoom = CallApp.matching(bundleID: "us.zoom.xos")!
    #expect(zoom.scope == .wholeApp)
    #expect(zoom.scope.reads(window("AXStandardWindow", "Zoom Workplace")))
    #expect(zoom.scope.readsWholeWindow)
    #expect(!zoom.scope.skips(role: "AXToolbar", insidePage: true))

    let chrome = CallApp.matching(bundleID: "com.google.Chrome")!
    #expect(chrome.scope == .meetingPages)
    #expect(chrome.scope.reads(window("AXStandardWindow", "Meet – abc-defg-hij - Google Chrome")))
    #expect(!chrome.scope.reads(window("AXStandardWindow", "Inbox - Gmail - Google Chrome")))
    #expect(!chrome.scope.readsWholeWindow)
    #expect(chrome.scope.skips(role: "AXTabGroup", insidePage: false))
    #expect(chrome.scope.skips(role: "AXToolbar", insidePage: false))
    #expect(!chrome.scope.skips(role: "AXToolbar", insidePage: true))

    // Chat apps with no known phrases aren't read at all, even in a window titled like a meeting.
    for bundle in ["com.microsoft.teams2", "com.apple.FaceTime", "Cisco-Systems.Spark", "com.hnc.Discord"] {
        let app = CallApp.matching(bundleID: bundle)!
        #expect(app.scope == .nothing, "\(bundle)")
        #expect(!app.scope.reads(window("AXStandardWindow", "Weekly sync | Microsoft Teams")), "\(bundle)")
        #expect(!app.readsCallState, "\(bundle)")
    }
    #expect(!slack.readsCallState)
    #expect(zoom.readsCallState && chrome.readsCallState)

    // Helium's audio comes from its helper process, which counts as Helium and is read like Chrome.
    let helium = CallApp.matching(bundleID: "net.imput.helium.helper")!
    #expect(helium.name == "Helium" && helium.kind == .browser && helium.scope == .meetingPages && helium.readsCallState)
}

@Test func aBrowserPageIsReadOnlyAtAMeetingProvidersAddress() {
    for address in ["https://meet.google.com/abc-defg-hij", "https://app.zoom.us/wc/123/join", "https://us02web.zoom.us/j/1",
                    "https://teams.microsoft.com/v2/", "https://app.slack.com/huddle/T1/C1"] {
        #expect(AccessibilityScope.isMeetingPage(URL(string: address)), "\(address)")
    }
    // A page titled like a meeting elsewhere, a look-alike host, or no address at all isn't read.
    for address in ["https://example.com/Meet - standup", "https://meet.google.com.example.com/x", "https://notzoom.us/j/1",
                    "http://meet.google.com/abc-defg-hij", "file:///tmp/meet.html"] {
        #expect(!AccessibilityScope.isMeetingPage(URL(string: address)), "\(address)")
    }
    #expect(!AccessibilityScope.isMeetingPage(nil))
}

@Test func aHuddleWindowSkipsListsAndTextEntryWithinASmallBudget() {
    #expect(slack.scope.readsWholeWindow)
    #expect(slack.scope.budget <= 500)
    #expect(slack.scope.needsManualAccessibility)
    for role in ["AXList", "AXTable", "AXOutline", "AXTextArea", "AXTextField", "AXComboBox"] {
        #expect(slack.scope.skips(role: role, insidePage: true), "\(role)")
    }
    #expect(!slack.scope.skips(role: "AXButton", insidePage: true))
    #expect(!slack.scope.skips(role: "AXGroup", insidePage: true))
}

// MARK: The debug log's window shapes

@Test func windowShapesKeepNoConversationText() {
    #expect(CallWindow.titleShape("design-team - Acme - Slack") == "<x> - <x> - Slack")
    #expect(CallWindow.titleShape("Slack | Huddle with Alex Kim") == "Slack | <x huddle>")
    #expect(CallWindow.titleShape("Huddle: design-team - Acme - Slack") == "Huddle: <x> - <x> - Slack")
    #expect(CallWindow.titleShape("") == "")
    #expect(main.shape == "AXWindow/AXStandardWindow \"<x> - <x> - Slack\" (26)")
    #expect(window("AXFloatingWindow", "").shape == "AXWindow/AXFloatingWindow \"\" (0)")
    #expect(!main.shape.contains("design") && !main.shape.contains("Acme"))
}

// MARK: Clips and the mic test

@Test func slackWaitsTwentySecondsUnlessItsHuddleWindowShows() {
    #expect(slack.minimumMicTime == 20)
    // A clip or the settings mic test: the main window only.
    #expect(!slack.isLikelyMeeting(heldFor: 2, windows: [main]))
    #expect(!slack.isLikelyMeeting(heldFor: 19.5, windows: [main]))
    #expect(slack.isLikelyMeeting(heldFor: 20, windows: [main]))
    // The huddle window, or the mini window, skips the wait.
    #expect(slack.isLikelyMeeting(heldFor: 0.5, windows: [main, window("AXStandardWindow", "Huddle")]))
    #expect(slack.isLikelyMeeting(heldFor: 0.5, windows: [main, window("AXFloatingWindow", "")]))
    // No Accessibility permission: no windows, so the wait decides.
    #expect(!slack.isLikelyMeeting(heldFor: 5, windows: []))

    for bundle in ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "Cisco-Systems.Spark", "com.hnc.Discord",
                   "com.google.Chrome", "com.apple.Safari"] {
        let app = CallApp.matching(bundleID: bundle)!
        #expect(app.minimumMicTime == 2, "\(bundle)")
        #expect(!app.isLikelyMeeting(heldFor: 1.9, windows: []), "\(bundle)")
        #expect(app.isLikelyMeeting(heldFor: 2, windows: []), "\(bundle)")
        // Only Slack has a call-window rule; another app's floating window doesn't skip its wait.
        #expect(!app.isLikelyMeeting(heldFor: 1, windows: [window("AXFloatingWindow", "Huddle")]), "\(bundle)")
    }
}

@Test func aSlackCandidateTooShortIsSkippedThenOffered() {
    var gate = MeetingOfferGate()
    let app = AudioClientApp(bundleID: slack.bundleIDs[0], name: "Slack", pid: 1, processes: [], callApp: slack)
    let since = Date(timeIntervalSince1970: 0)
    let clip = MeetingCandidate(app: app, since: since, meetingTitle: "Slack",
                                isLikelyMeeting: slack.isLikelyMeeting(heldFor: 8, windows: [main]))
    let early = gate.update(candidates: [clip], busy: nil) { _ in .ask }
    #expect(early.decision == .none)
    #expect(early.skipped == [.init(bundleID: slack.bundleIDs[0], reason: .tooShort)])
    let huddle = MeetingCandidate(app: app, since: since, meetingTitle: "Slack",
                                  isLikelyMeeting: slack.isLikelyMeeting(heldFor: 20, windows: [main]))
    #expect(gate.update(candidates: [huddle], busy: nil) { _ in .ask }.decision == .offer(huddle))
}

// MARK: Titles

@Test func slackMeetingTitlesComeFromTheHuddleWindowOnly() {
    // Without a huddle window the app's name, never a conversation from the main window.
    #expect(slack.meetingTitle([main]) == "Slack")
    #expect(slack.meetingTitle([window("AXStandardWindow", "huddle-notes - Acme - Slack")]) == "Slack")
    #expect(slack.meetingTitle([]) == "Slack")
    // A huddle window: its own title when it says more than "Huddle", else "Slack huddle".
    #expect(slack.meetingTitle([main, window("AXStandardWindow", "Huddle")]) == "Slack huddle")
    #expect(slack.meetingTitle([main, window("AXFloatingWindow", "")]) == "Slack huddle")
    #expect(slack.meetingTitle([main, window("AXFloatingWindow", "design-team - Acme - Slack")]) == "Slack huddle")
    #expect(slack.meetingTitle([main, window("AXStandardWindow", "Slack | Huddle with Alex Kim")]) == "Huddle with Alex Kim")
    #expect(slack.meetingTitle([main, window("AXStandardWindow", "Huddle: design-team - Acme - Slack")]) == "Huddle: design-team")
    // The mini window first, the huddle window's title still wins.
    #expect(slack.meetingTitle([window("AXFloatingWindow", ""), window("AXStandardWindow", "Huddle with Alex Kim")])
        == "Huddle with Alex Kim")
    #expect(MeetingDetector.cleanTitle("Slack huddle") == "Slack huddle")

    // Other native apps as before: a window titled like a meeting, else the app's name.
    let teams = CallApp.matching(bundleID: "com.microsoft.teams2")!
    #expect(teams.meetingTitle([window("AXStandardWindow", "Weekly sync | Microsoft Teams")]) == "Weekly sync | Microsoft Teams")
    #expect(teams.meetingTitle([window("AXStandardWindow", "Activity")]) == "Microsoft Teams")
}

// MARK: Mute unknown

@Test func withoutSlackPhrasesMuteStaysUnknownAndNothingIsDropped() {
    // What a huddle window might show; none of it is a phrase gob.lin knows, so mute and sharing stay unknown.
    let lines = ["3 AXButton: Mute", "3 AXButton: Turn off camera", "4 AXButton: Share screen", "2 AXStaticText: Alex Kim"]
    #expect(AccessibilityProbe.muteState(lines) == nil)
    #expect(!AccessibilityProbe.sharingState(lines))
    // No mute changes: no mic line is left out, live or in the final transcript.
    let timeline = MuteTimeline()
    #expect(!timeline.silences(TranscriptSegment(track: .microphone, start: 10, end: 14, text: "words", words: [],
                                                 decodeMilliseconds: 0)))
    #expect(timeline.spans(end: 600).isEmpty)
    #expect(MeetingPostProcessor.mutedSpans("", end: 600).isEmpty)
    #expect(MeetingPostProcessor.mutedSpans(URL(fileURLWithPath: "/nonexistent/mute.jsonl"), end: 600).isEmpty)
}
