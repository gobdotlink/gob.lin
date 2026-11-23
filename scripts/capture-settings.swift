import AppKit
import GoblinCore
import GoblinMeetings
import SwiftUI

/// Production views with isolated synthetic data and no system services: Settings, History, the
/// popover, first run and every overlay phase, in light and dark.
@main
struct SettingsCapture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GoblinBrand.registerFonts()
        let suite = "app.goblin.settings-capture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DictionaryRepository(url: directory.appendingPathComponent("dictionary.json")).save([
            DictionaryEntry(spelling: "Dev review", aliases: ["day review"]),
            DictionaryEntry(spelling: "gob.lin", aliases: ["goblin"]),
            DictionaryEntry(spelling: "Postgres", aliases: ["post grass"]),
            DictionaryEntry(spelling: "Sol", aliases: ["soul", "sole"], context: ["GPT", "6.1"]),
        ])
        defaults.set(try JSONEncoder().encode(HistoryRetention(maximumUnstarredCount: 500, maximumAgeDays: 30)), forKey: "history.retention")
        defaults.set(OverlayPosition.top.rawValue, forKey: "overlayPosition")
        // Meetings on, so the popover and the menu-bar mark have something to show; nothing records.
        defaults.set(true, forKey: MeetingsController.enabledKey)
        try RewriteSettingsStore.save(RewriteSettings(enabled: false, baseURL: "https://provider.invalid/v1", model: "example-model", cleanup: .light), defaults: defaults)
        defaults.set(true, forKey: MeetingsController.enabledKey)
        defaults.set(true, forKey: MeetingsController.setupFinishedKey)
        defaults.set(["com.apple.FaceTime": "always"], forKey: MeetingsController.appPoliciesKey)
        defaults.set(["com.hnc.Discord"], forKey: MeetingsController.neverAskKey)
        defaults.set(true, forKey: MeetingsController.rememberVoicesKey)
        SystemAudioAccess.shared.override = .granted
        let sampleMeetings = try SampleMeetings.write(in: directory.appendingPathComponent("Meetings", isDirectory: true))
        // Notes were said yes to once, so the weekly sync has them; the design crit shows what writing them looks like.
        defaults.set(true, forKey: MeetingNotesModel.consentKey)
        let model = AppModel(dataDirectory: directory, defaults: defaults, servicesEnabled: false,
            diagnosticEnvironment: DiagnosticEnvironment(microphonePermission: .notRequested,
                accessibilityPermission: .denied, inputMonitoringPermission: .denied,
                microphoneNames: ["Preview microphone"], defaultMicrophoneName: "Preview microphone"))
        precondition(model.overlay.position == .top, "Saved overlay position must apply before Settings or Preview opens")
        model.meetings.notes.usePreview(tools: SampleMeetings.notesTools, models: SampleMeetings.notesModels)
        let emptyDirectory = directory.appendingPathComponent("empty", isDirectory: true)
        let empty = AppModel(dataDirectory: emptyDirectory, defaults: defaults, servicesEnabled: false)
        let lifecycle = GoblinApplicationDelegate()
        lifecycle.model = model
        app.delegate = lifecycle
        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots", isDirectory: true)
        var captureFailed = false
        let capture = Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try await seedHistory(model.history)
                precondition(model.dictionary.entries.count == 4 && model.dictionary.available)
                // Two fixes of one word, so the Dictionary page offers it with the context they share.
                for (heard, after) in [("rock", "review"), ("rock", "agent")] {
                    model.dictionary.offerCorrection(dictated: "ask the Claude 5 \(heard) \(after) for this",
                                                     edited: "ask the Claude 5 Rook \(after) for this",
                                                     scope: DictionaryScope(application: "com.t3tools.t3code", project: "gob.lin"))
                }
                var last: NSWindow?
                @MainActor func shoot(_ name: String, _ view: some View, size: NSSize, dark: Bool = false,
                                      settle: Duration = .milliseconds(700)) async throws {
                    // A fresh window per shot, so one view's toolbar never leaks into the next capture.
                    last?.orderOut(nil)
                    let window = CaptureWindow(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    last = window
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.title = "gob.lin — \(name)"
                    window.setContentSize(size)
                    window.contentView = NSHostingView(rootView: view.allowsHitTesting(false))
                    window.park()
                    window.orderBack(nil)
                    window.becomeMain()
                    window.becomeKey()
                    try await Task.sleep(for: settle)
                    // A toolbar resizes the window once it is shown.
                    window.park()
                    try snapshot(window, to: destination.appendingPathComponent("design-\(name).png"))
                    print("Captured \(name)")
                }
                let only = CommandLine.arguments.dropFirst(2).first { !$0.hasPrefix("--") }
                func wanted(_ group: String) -> Bool { only == nil || only == group }

                if wanted("settings") {
                    for page in SettingsSection.allCases where page != .meetings {
                        model.settingsSelection = page
                        if page == .diagnostics { model.diagnostics.report(.modelUnavailable) }
                        try await shoot("settings-\(page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1040, height: 1080))
                    }
                    // Every page in dark too: DESIGN.md asks for both appearances of whatever a change touches.
                    for page in SettingsSection.allCases where page != .history && page != .insights && page != .meetings {
                        model.settingsSelection = page
                        try await shoot("settings-\(page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-dark", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1040, height: 1080), dark: true)
                    }
                    empty.settingsSelection = .dictionary
                    try await shoot("settings-dictionary-empty-dark", SettingsView(model: empty, speechModels: empty.speechModels), size: NSSize(width: 1040, height: 1080), dark: true)
                    model.diagnostics.resolve(.model)
                    let provider = CleanupProviderSheet(settings: RewriteSettingsStore.load(defaults: defaults), defaults: defaults,
                                                        inspectCredentials: false, turnOn: false, onSave: { _ in }, onFailure: { _ in })
                    try await shoot("settings-cleanup-provider", provider, size: NSSize(width: 680, height: 520))
                    try await shoot("settings-cleanup-provider-dark", provider, size: NSSize(width: 680, height: 520), dark: true)
                    let sol = model.dictionary.entries.first { $0.spelling == "Sol" }!
                    for dark in [false, true] {
                        try await shoot("settings-dictionary-entry\(dark ? "-dark" : "")", DictionaryEntryEditor(entry: sol, model: model.dictionary).background(Color(nsColor: .windowBackgroundColor)),
                                        size: NSSize(width: 460, height: 740), dark: dark)
                    }
                }
                if wanted("icloud") {
                    // General's iCloud group with both switches, once for each History sync status.
                    model.settingsSelection = .general
                    model.dictionary.canSync = true
                    let statuses: [(String, HistorySyncStatus)] = [("syncing", .syncing), ("waiting", .waitingForAccount), ("full", .iCloudFull),
                                                                   ("update", .needsUpdate), ("purged", .purged), ("account", .differentAccount), ("off", .off)]
                    for (name, status) in statuses {
                        model.historySync.preview(status)
                        for dark in [false, true] {
                            try await shoot("settings-icloud-\(name)\(dark ? "-dark" : "")", SettingsView(model: model, speechModels: model.speechModels),
                                            size: NSSize(width: 1040, height: 1080), dark: dark)
                        }
                    }
                }
                if wanted("history") {
                    model.settingsSelection = .history
                    try await shoot("history", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720))
                    try await shoot("history-dark", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720), dark: true)
                    model.settingsSelection = .insights
                    try await shoot("history-insights", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 720))
                    model.settingsSelection = .history
                    empty.settingsSelection = .history
                    try await shoot("history-empty", SettingsView(model: empty), size: NSSize(width: 970, height: 620))
                    try await shoot("history-narrow", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 970, height: 620))
                    // The whole Insights page with this Mac alone, then with an iPhone's dictations too.
                    let devices = AppModel(dataDirectory: directory.appendingPathComponent("devices", isDirectory: true), defaults: defaults, servicesEnabled: false)
                    try await seedHistory(devices.history)
                    try await seedPhone(devices.history)
                    model.settingsSelection = .insights
                    devices.settingsSelection = .insights
                    for dark in [false, true] {
                        try await shoot("history-insights-full\(dark ? "-dark" : "")", SettingsView(model: model, speechModels: model.speechModels), size: NSSize(width: 1100, height: 1500), dark: dark)
                        try await shoot("history-insights-devices\(dark ? "-dark" : "")", SettingsView(model: devices, speechModels: devices.speechModels), size: NSSize(width: 1100, height: 1500), dark: dark)
                    }
                    model.settingsSelection = .history
                }
                if wanted("meetings") {
                    model.meetings.refreshList()
                    let meetingsSize = NSSize(width: 1180, height: 860)
                    for (name, id) in [("meetings", sampleMeetings.weekly), ("meetings-in-person", sampleMeetings.inPerson),
                                       ("meetings-stopped", sampleMeetings.stopped)] {
                        for dark in [false, true] where name == "meetings" || !dark {
                            model.settingsSelection = .meetings
                            model.meetings.focusedMeetingID = id
                            try await shoot(name + (dark ? "-dark" : ""), SettingsView(model: model, speechModels: model.speechModels),
                                            size: meetingsSize, dark: dark, settle: .milliseconds(1_200))
                        }
                    }
                    let store = model.meetings.library.store
                    for (name, id, voice) in [("meetings-who", sampleMeetings.weekly, "Speaker 3"),
                                              ("meetings-who-in-person", sampleMeetings.inPerson, "Speaker 2")] {
                        let detail = try await store.detail(id)
                        let lanes = MeetingTimeline.lanes(detail.turns, kind: detail.summary.kind)
                        let player = MeetingPlayer()
                        player.load(microphone: detail.microphoneAudio, system: detail.systemAudio)
                        let sheet = WhoIsThisSheet(meeting: detail.summary, lane: lanes.first { $0.name == voice }!, lanes: lanes, turns: detail.turns,
                                                   participants: detail.participants, voiceSuggestions: detail.voiceSuggestions[voice] ?? [],
                                                   remembersVoices: true, player: player, onName: { _ in }, onClose: {})
                            .background(Color(nsColor: .windowBackgroundColor))
                        for dark in [false, true] {
                            try await shoot(name + (dark ? "-dark" : ""), sheet, size: NSSize(width: 540, height: name == "meetings-who" ? 700 : 560), dark: dark)
                        }
                    }
                    // The notes on their own, and a meeting without them, as the page shows them below the transcript.
                    for (name, id) in [("meetings-notes", sampleMeetings.weekly), ("meetings-notes-offer", sampleMeetings.design)] {
                        let detail = try await store.detail(id)
                        let notes = try await store.notes(id)
                        let player = MeetingPlayer()
                        player.load(microphone: detail.microphoneAudio, system: detail.systemAudio)
                        if name == "meetings-notes-offer" { defaults.set(false, forKey: MeetingNotesModel.consentKey) }
                        let section = MeetingNotesSection(meeting: detail.summary, notes: notes, stale: false, names: detail.speakerNames,
                                                          model: model.meetings.notes, player: player, onChanged: {})
                            .padding(28).frame(width: 820, alignment: .topLeading).background(GoblinBrand.caseBackground)
                        for dark in [false, true] {
                            try await shoot(name + (dark ? "-dark" : ""), section, size: NSSize(width: 820, height: name == "meetings-notes" ? 880 : 200), dark: dark)
                        }
                        defaults.set(true, forKey: MeetingNotesModel.consentKey)
                    }
                    let mergeLine = MeetingChangeLine(message: "Merged Speaker 3 into Priya Shah.",
                                                      warning: SpeakerSuggestions.mergeWarning(unmatched: ["Sam Okafor"]),
                                                      missing: "Sam Okafor", onUndo: {})
                        .padding(20).frame(width: 760, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
                    for dark in [false, true] {
                        try await shoot("meetings-merge" + (dark ? "-dark" : ""), mergeLine, size: NSSize(width: 760, height: 100), dark: dark)
                    }
                    for dark in [false, true] {
                        SystemAudioAccess.shared.override = .unknown
                        try await shoot("meetings-setup" + (dark ? "-dark" : ""), MeetingsSetupSheet(meetings: model.meetings, notifications: .notDetermined) {},
                                        size: NSSize(width: 620, height: 640), dark: dark)
                        SystemAudioAccess.shared.override = .granted
                        try await shoot("meetings-setup-allowed" + (dark ? "-dark" : ""), MeetingsSetupSheet(meetings: model.meetings, notifications: .notDetermined) {},
                                        size: NSSize(width: 620, height: 640), dark: dark)
                    }
                    for dark in [false, true] {
                        model.settingsSelection = .meetingRecording
                        try await shoot("meeting-recording" + (dark ? "-dark" : ""), SettingsView(model: model, speechModels: model.speechModels),
                                        size: NSSize(width: 1040, height: 1180), dark: dark, settle: .milliseconds(1_000))
                        SystemAudioAccess.shared.override = .denied
                        try await shoot("meeting-recording-permission-off" + (dark ? "-dark" : ""), SettingsView(model: model, speechModels: model.speechModels),
                                        size: NSSize(width: 1040, height: 560), dark: dark)
                        SystemAudioAccess.shared.override = .granted
                        model.settingsSelection = .general
                        try await shoot("meetings-general" + (dark ? "-dark" : ""), SettingsView(model: model, speechModels: model.speechModels),
                                        size: NSSize(width: 1040, height: 1260), dark: dark)
                        empty.settingsSelection = .meetings
                        try await shoot("meetings-empty" + (dark ? "-dark" : ""), SettingsView(model: empty), size: NSSize(width: 1100, height: 720),
                                        dark: dark, settle: .milliseconds(1_000))
                    }
                }
                if wanted("popover") {
                    // Recent meetings join the popover once the list has loaded.
                    model.meetings.refreshList()
                    try await Task.sleep(for: .milliseconds(600))
                    model.meetings.previewUnopened(nil)
                    try await shoot("popover", popover(model), size: NSSize(width: 420, height: 900))
                    try await shoot("popover-dark", popover(model), size: NSSize(width: 420, height: 900), dark: true)
                    // A call just finished: the ready card, with a voice still to name.
                    model.meetings.previewUnopened(sampleMeetings.weekly)
                    try await shoot("popover-meeting-ready", popover(model), size: NSSize(width: 420, height: 1040))
                    try await shoot("popover-meeting-ready-dark", popover(model), size: NSSize(width: 420, height: 1040), dark: true)
                    model.meetings.previewUnopened(nil)
                    model.diagnostics.report(.requiredPermissionsMissing)
                    model.diagnostics.report(.rewriteConfiguration)
                    try await shoot("popover-attention-dark", popover(model), size: NSSize(width: 420, height: 720), dark: true)
                    model.diagnostics.resolve(.permissions)
                    model.diagnostics.resolve(.rewrite)
                }
                if wanted("onboarding") {
                    for step in OnboardingView.Step.allCases {
                        try await shoot("onboarding-\(step.rawValue + 1)", OnboardingView(model: model, startAt: step), size: NSSize(width: 660, height: 516))
                    }
                    // A long first take must not push the closing buttons out of the fixed-size window.
                    let long = (result: OverlayResult(application: nil, words: 100, seconds: 0.41),
                                text: Array(repeating: "The goblin types faster than I do, and it never stops to check.", count: 8).joined(separator: " "))
                    for step in [OnboardingView.Step.firstTake, .hired] {
                        try await shoot("onboarding-\(step.rawValue + 1)-long", OnboardingView(model: model, startAt: step, take: long), size: NSSize(width: 660, height: 516))
                    }
                    for step in OnboardingView.Step.allCases {
                        try await shoot("onboarding-\(step.rawValue + 1)-dark", OnboardingView(model: model, startAt: step), size: NSSize(width: 660, height: 516), dark: true)
                    }
                }
                if wanted("meetings") {
                    try await captureMeetings(model, to: destination) { name, view, size, dark in try await shoot(name, view, size: size, dark: dark) }
                }
                if wanted("overlay") {
                    for (name, overlay) in overlayPhases() {
                        try await shoot("overlay-\(name)", ZStack { Wallpaper(); DictationOverlay(model: overlay) },
                                        size: DictationOverlay.panelSize, dark: name.hasSuffix("dark"))
                    }
                }
            } catch { captureFailed = true; print("Capture failed: \(error)") }
            await model.shutdown()
            await empty.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            _ = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { app.terminate(nil) }
            }
        }
        // Run-loop delivery lets the real delegate's MainActor shutdown finish during terminateLater.
        let timeout = Timer(timeInterval: 180, repeats: false) { _ in
            MainActor.assumeIsolated {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
                exit(1)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        withExtendedLifetime((lifecycle, model, empty)) { app.run() }
        capture.cancel()
        timeout.invalidate()
        if captureFailed { exit(1) }
    }

    @MainActor private static func seedHistory(_ history: HistoryModel) async throws {
        let now = Date()
        let entries: [(String, String, String, String, Double, Double, Bool, String?)] = [
            ("Mail", "com.apple.mail", "um so can we push the design review to thursday like i want the overlay sorted before anyone sees it and uh and the menu still needs a pass on the copy",
             "Can we push the design review to Thursday? I want the overlay sorted before anyone sees it, and the menu still needs a pass on the copy.", 9, 60, true, nil),
            ("Slack", "com.tinyspeck.slackmacgap", "looks good to me ship it once notarisation passes", "Looks good to me. Ship it once notarisation passes.", 5, 600, false, nil),
            ("Xcode", "com.apple.dt.Xcode", "mirror the overlay when the caret sits in the bottom right corner", "Mirror the overlay when the caret sits in the bottom-right corner.", 6, 1500, false, nil),
            ("Messages", "com.apple.MobileSMS", "on my way grab me a flat white", "On my way. Grab me a flat white?", 3, 3600, true, nil),
            ("Terminal", "com.apple.Terminal", "fix the clipboard restore race when secure input is on", "fix the clipboard restore race when secure input is on", 4, 90_000, false,
             DiagnosticFailure.insertionTargetChanged.message),
            ("Safari", "com.apple.Safari", "best low profile mechanical keyboard", "best low profile mechanical keyboard", 2, 100_000, false, nil),
        ]
        for (name, bundle, raw, final, duration, age, starred, warning) in entries.reversed() {
            let entry = HistoryEntry(rawText: raw, finalText: final, tone: "formal", polished: raw != final,
                                     targetBundleIdentifier: bundle, targetApplicationName: name,
                                     createdAt: now.addingTimeInterval(-age), audioDuration: duration, model: "parakeet-tdt-v3",
                                     latencies: DictationTimings(captureMilliseconds: duration * 1000, asrMilliseconds: 142, rewriteMilliseconds: raw != final ? 386 : 0, insertionMilliseconds: 9),
                                     starred: starred, processingWarning: warning)
            guard await history.record(entry) else { throw CaptureError.seed }
        }
    }

    /// Dictations from an iPhone, whose keyboard can't name the app it types into.
    @MainActor private static func seedPhone(_ history: HistoryModel) async throws {
        guard let store = history.store else { throw CaptureError.seed }
        let phone = UUID().uuidString, now = Date()
        // A fixed name for this Mac, so the picture never shows the real computer's.
        try await store.saveDevice(id: store.deviceID, kind: HistoryDevice.mac, name: "MacBook Pro")
        try await store.saveDevice(id: phone, kind: HistoryDevice.iPhone, name: "iPhone")
        for (text, duration, age) in [("Running ten minutes late, start without me and I'll catch up on the notes.", 5.0, 900.0),
                                      ("Remind me to book the train for Friday morning.", 3, 5400),
                                      ("The overlay copy reads well on the phone too, ship it.", 0, 30_000)] {
            var entry = HistoryEntry(rawText: text, finalText: text, createdAt: now.addingTimeInterval(-age), audioDuration: duration)
            entry.device = phone
            guard await history.record(entry) else { throw CaptureError.seed }
        }
    }

    @MainActor private static func popover(_ model: AppModel) -> some View {
        ZStack(alignment: .top) {
            Wallpaper()
            MenuPopover(model: model)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .padding(.top, 24)
        }
    }

    /// The in-call surfaces from synthetic meetings: the popover module, the Sidekick, the pill and the menu-bar mark.
    @MainActor private static func captureMeetings(_ model: AppModel, to destination: URL,
                                                   shoot: @MainActor (String, AnyView, NSSize, Bool) async throws -> Void) async throws {
        let meetings = model.meetings
        let start = Date().addingTimeInterval(-(12 * 60 + 48))
        func line(_ t: Double, _ speaker: String, _ text: String) -> MeetingLine { MeetingLine(id: UUID(), speaker: speaker, start: t, text: text) }
        var call = MeetingsController.Recording(title: "Weekly sync", app: "Zoom", bundleID: "us.zoom.xos", startedAt: start)
        call.meetingID = "2026-11-16 140100 Weekly sync"
        call.microphoneLevel = -24
        call.systemLevel = -16
        // Cut the way the chunker cuts live speech: at short pauses, so mostly pieces of sentences.
        call.lines = [line(245, "You", "Then let's hold the next batch"),
                      line(248, "You", "until Thursday."),
                      line(370, "Them", "On pricing, I'd keep the free tier"),
                      line(373, "Them", "at three borrowed tools a month."),
                      line(412, "You", "Three feels right."),
                      line(414, "You", "We can raise it once lending is steady."),
                      line(580, "Them", "The offline mode still drops edits"),
                      line(583, "Them", "if you close the app too fast."),
                      line(615, "You", "Is that the same bug from the sync rewrite?"),
                      line(648, "Them", "Same family."),
                      line(650, "Them", "I'd rather fix it properly"),
                      line(653, "Them", "than patch it again."),
                      line(672, "You", "Yeah."),
                      line(690, "Them", "Can we write down which bugs block the launch"),
                      line(694, "Them", "and which don't?"),
                      line(750, "You", "Yes. I'll start the list"),
                      line(753, "You", "after this call.")]
        call.marks = [.init(id: UUID(), t: 372, label: "Pricing: free tier stays at three"), .init(id: UUID(), t: 760, label: "")]
        // With names live: voices I know by name, a new one as Speaker 3, and a last line whose voice isn't placed yet.
        var named = call
        named.namesLive = true
        named.lines = [line(648, "Priya Shah", "Export first. Is it still on for this sprint?"),
                       line(655, "You", "It's close. The CSV path works,"),
                       line(658, "You", "but the PDF one still drops page breaks."),
                       line(667, "Sam Okafor", "I'd ship CSV on its own and move PDF to next sprint."),
                       line(675, "Priya Shah", "Agreed."),
                       line(722, "Speaker 3", "I can pick up the page-break fix."),
                       line(725, "Speaker 3", "I'm next to Sam today, same laptop."),
                       line(740, "You", "Perfect, thanks."),
                       line(750, "Them", "Good. Then the release notes say CSV now.")]
        named.marks = [.init(id: UUID(), t: 700, label: "Ship CSV first")]
        var muted = call
        muted.muted = true
        muted.microphoneLevel = -100
        var ending = call
        ending.releasedSince = Date().addingTimeInterval(-13)
        ending.systemLevel = -100
        ending.microphoneLevel = -100
        var room = MeetingsController.Recording(title: "Conversation", app: "In person", bundleID: nil, startedAt: start)
        room.inPerson = true
        room.meetingID = "2026-11-16 140100 Conversation"
        room.microphoneLevel = -20
        room.lines = [line(402, "", "So the library said yes for the twelfth,"),
                      line(405, "", "and they'll let us in an hour early."),
                      line(409, "", "Is that the room with the projector?"),
                      line(414, "", "It is. I'll bring the adapter."),
                      line(470, "", "Then the twelfth it is."),
                      line(473, "", "Can someone put it on the calendar?")]
        var quietRoom = room
        quietRoom.microphoneLevel = -100
        let zoom = MeetingCandidate(app: AudioClientApp(bundleID: "us.zoom.xos", name: "Zoom", pid: nil, processes: [],
                                                        callApp: CallApp.matching(bundleID: "us.zoom.xos")),
                                    since: Date(), meetingTitle: "Weekly sync", isLikelyMeeting: true)

        let popovers: [(String, () -> Void)] = [
            ("recording", { meetings.preview(.recording(call)) }),
            ("muted", { meetings.preview(.recording(muted), sidekickVisible: false) }),
            ("ending", { meetings.preview(.recording(ending)) }),
            ("in-person", { meetings.preview(.recording(room)) }),
            ("in-person-quiet", { meetings.preview(.recording(quietRoom), quiet: true) }),
            ("processing", { meetings.preview(.processing(title: "Weekly sync", meetingID: "preview")) }),
            ("not-recording", { meetings.preview(.idle, unrecordedCall: zoom) }),
            ("system-audio-off", { meetings.preview(.idle, systemAudio: .denied) }),
        ]
        for (name, setUp) in popovers {
            setUp()
            for dark in [false, true] {
                try await shoot("popover-meeting-\(name)\(dark ? "-dark" : "")", AnyView(popover(model)), NSSize(width: 420, height: 760), dark)
            }
        }

        // The Sidekick in its own window, chrome and all: always dark, so one appearance.
        let sidekicks: [(String, () -> Void)] = [
            ("call", { meetings.preview(.recording(call)) }),
            ("names", { meetings.preview(.recording(named)) }),
            ("scrolled-back", { meetings.preview(.recording(call)) }),
            ("marking", { meetings.preview(.recording(call), markedAt: Date().addingTimeInterval(600)) }),
            ("muted", { meetings.preview(.recording(muted)) }),
            ("ending", { meetings.preview(.recording(ending)) }),
            ("system-audio-off", { meetings.preview(.recording(call), systemAudio: .denied) }),
            ("in-person", { meetings.preview(.recording(room)) }),
            ("in-person-quiet", { meetings.preview(.recording(quietRoom), quiet: true) }),
            ("expanded", { meetings.preview(.recording(call)) }),
            ("expanded-empty", { meetings.preview(.recording(call)) }),
            ("pill", { meetings.preview(.recording(call)) }),
            ("pill-left", { meetings.preview(.recording(call)) }),
        ]
        for (name, setUp) in sidekicks {
            setUp()
            let pill = name.hasPrefix("pill")
            let sidekick = SidekickModel(collapsed: pill, expanded: name.hasPrefix("expanded"))
            sidekick.onRight = name != "pill-left"
            for (microphone, system) in [(-30, -14), (-18, -40), (-26, -12), (-14, -30), (-22, -18)] as [(Float, Float)] {
                sidekick.push(microphone: name.contains("muted") || name.contains("ending") || name.contains("quiet") ? -100 : microphone,
                              system: name.contains("in-person") || name.contains("ending") ? -100 : system)
            }
            if name == "call" || name == "names" || name == "expanded" { sidekick.showsConsent = false }
            if name == "scrolled-back" { sidekick.previewScrolledBack = true }
            meetings.setTypedNotes(name == "expanded" ? """
                Pricing: free tier stays at three tools a month. Revisit once lending is steady.

                Offline edits still drop on a fast close. Sam wants a proper fix, not another patch.

                After the call: start the launch-blocker list.
                """ : "")
            if pill {
                for dark in [false, true] {
                    let view = ZStack { AppBackdrop(); SidekickPill(meetings: meetings, model: sidekick) }
                    try await shoot("sidekick-\(name)\(dark ? "-dark" : "")", AnyView(view), SidekickPill.windowSize, dark)
                }
                continue
            }
            let size = name.hasPrefix("expanded") ? SidekickController.expandedSize : SidekickController.compactSize
            let window = SidekickCaptureWindow(contentRect: NSRect(origin: .zero, size: size))
            // The real window is kept out of screen captures; this one has to be captured.
            window.sharingType = .readOnly
            window.contentView = NSHostingView(rootView: SidekickView(meetings: meetings, model: sidekick).allowsHitTesting(false))
            window.park()
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(700))
            window.park()
            try snapshot(window, to: destination.appendingPathComponent("design-sidekick-\(name).png"))
            window.orderOut(nil)
            print("Captured sidekick-\(name)")
        }
        meetings.setTypedNotes("")
        meetings.preview(.idle)

        // The menu-bar goblin at 4×: idle, recording a meeting, and dictating during one.
        for dark in [false, true] {
            let icons = HStack(spacing: 28) {
                ForEach(Array([(MascotState.idle, false), (.idle, true), (.recording, true), (.transcribing, true)].enumerated()), id: \.offset) { _, icon in
                    Image(nsImage: GoblinBrand.menuImage(icon.0, headset: icon.1)).resizable().interpolation(.none).frame(width: 88, height: 88)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            try await shoot("menu-bar-headset\(dark ? "-dark" : "")", AnyView(icons), NSSize(width: 520, height: 140), dark)
        }
    }

    @MainActor private static func overlayPhases() -> [(String, OverlayModel)] {
        func make(_ phase: OverlayPhase, committed: String = "", tentative: String = "", level: Double = 0.6,
                  configure: (OverlayModel) -> Void = { _ in }) -> OverlayModel {
            let model = OverlayModel()
            model.presented = true
            model.phase = .arming
            if phase != .arming { model.phase = .listening }
            model.committedText = committed
            model.tentativeText = tentative
            for value in [0.2, 0.5, 0.8, 0.45, level] { model.audioLevel = value }
            model.phase = phase
            model.audioSeconds = 7
            configure(model)
            return model
        }
        let words = "Cut the export redesign instead. Keep the onboarding, it's what people"
        let long = "so the build goes out tonight. Keep the onboarding, it's what people see first, and we'll move export to next week, because the copy pass on the menu still needs a day"
        return [
            ("arming", make(.arming)),
            ("listening", make(.listening, committed: words, tentative: " see first")),
            ("listening-long", make(.listening, committed: long, tentative: " or two")),
            ("listening-dark", make(.listening, committed: words, tentative: " see first")),
            ("handsfree", make(.listening, committed: "Second point: the overlay copy needs one more pass", tentative: " before anyone sees it") { $0.handsFree = true }),
            ("handsfree-keyed", make(.listening, committed: "Second point: the overlay copy needs one more pass") { $0.handsFree = true; $0.talkKey = .optionSpace }),
            ("transcribing", make(.transcribing, committed: words + " see first.")),
            ("polishing", make(.polishing, committed: "so um cut the export redesign instead keep the onboarding it's what people see first") { $0.cleanupLabel = "Light · Cerebras" }),
            ("inserted", make(.inserted(OverlayResult(application: "Team chat", words: 23, seconds: 0.59)))),
            ("milestone", make(.milestone(words: 10_000))),
            ("term-suggestion", make(.termSuggestion(TermSuggestion(spelling: "panacea", aliases: ["anasia"], projects: ["gob.lin"],
                                                                     reason: .correction(heard: "anasia"))))),
            ("term-suggestion-repeated", make(.termSuggestion(TermSuggestion(spelling: "Sol", aliases: ["soul", "sole"],
                                                                     reason: .correction(heard: "soul"), context: ["GPT", "6.1"], timesFixed: 5)))),
            ("term-added", make(.termAdded(TermSuggestion(spelling: "panacea", projects: ["gob.lin"], reason: .correction(heard: "anasia"))))),
            ("error-cleanup", make(.error(OverlayNotice(.rewriteTimeout)))),
            ("error-microphone", make(.error(OverlayNotice(.microphoneUnavailable)))),
            ("listening-new-microphone", make(.listening, committed: words, tentative: " see first") { $0.microphoneLine = "Using Lav Receiver" }),
            ("new-microphone", make(.newMicrophone(name: "Lav Receiver", uid: "preview-lav"))),
            ("error-secure", make(.error(OverlayNotice(.secureInputEnabled)))),
            ("mirrored", make(.listening, committed: "Sounds good, send it", tentative: " over") { $0.mirrored = true }),
            ("top", make(.listening, committed: "Top-right, under the menu bar") { $0.edge = .top }),
        ] + [false, true].flatMap { dark -> [(String, OverlayModel)] in
            let suffix = dark ? "-dark" : ""
            return [
                ("meeting-offer\(suffix)", make(.meetingOffer(MeetingOffer(app: "Zoom", bundleID: "us.zoom.xos", title: "Weekly sync")))),
                ("meeting-offer-system-audio-off\(suffix)", make(.meetingOffer(MeetingOffer(app: "Zoom", bundleID: "us.zoom.xos", title: "Weekly sync",
                                                                                          systemAudioOff: true)))),
                ("meeting-recording\(suffix)", make(.meetingRecording(title: "Weekly sync"))),
                ("meeting-ready\(suffix)", make(.meetingReady(MeetingReady(meetingID: "preview", title: "Weekly sync", detail: "42 min · 1 voice to name")))),
                ("meeting-slept\(suffix)", make(.meetingInterrupted(MeetingInterrupted(
                    sentence: "Recording stopped because the Mac went to sleep, so I kept the first 31 minutes.",
                    detail: "slept at 10:31", canRecordRest: true)))),
                ("meeting-quiet\(suffix)", make(.meetingQuiet(minutes: 10))),
            ]
        }
    }

    @MainActor private static func invalidateTree(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        for child in view.subviews { invalidateTree(child) }
    }

    @MainActor private static func snapshot(_ window: NSWindow, to file: URL) throws {
        if let view = window.contentView {
            invalidateTree(view)
            view.layoutSubtreeIfNeeded()
            view.display()
            window.displayIfNeeded()
        }
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        guard screenshot.terminationStatus != 0 else { return }
        // A locked or sleeping display can't be captured; render the view alone instead.
        // Window materials and chrome are missing from these.
        print("No window capture for \(file.lastPathComponent): drawn without materials or window chrome")
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.screenshot }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.screenshot }
        try png.write(to: file)
    }

    enum CaptureError: Error { case screenshot, seed }
}

/// Keeps the size it's given, so a whole page can be shot taller than the screen.
/// A window nobody sees and that never takes focus, so captures can run while the Mac is in use.
private final class CaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Drawn as the focused window, while the app in use keeps the real focus.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// The Sidekick's own window, parked like the others. It draws as it usually sits: not key, so the traffic lights rest.
private final class SidekickCaptureWindow: SidekickWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private extension NSWindow {
    /// The system only draws a window that touches a display, so one point of a corner does. Corners are rounded,
    /// so that point is clear.
    func park() {
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // The sharpest display, and above it: a toolbar grows the window upward.
        for screen in NSScreen.screens.sorted(by: { $0.backingScaleFactor > $1.backingScaleFactor }) {
            for x in [screen.frame.minX + 1 - frame.width, screen.frame.maxX - 1] {
                let spot = NSRect(origin: NSPoint(x: x, y: screen.frame.maxY - 1), size: frame.size)
                if NSScreen.screens.allSatisfy({ $0 == screen || !$0.frame.intersects(spot) }) { return setFrameOrigin(spot.origin) }
            }
        }
        // ponytail: displays above both top corners of every display leave no spot; the capture is then drawn without chrome.
        setFrameOrigin(NSPoint(x: -20_000, y: 0))
    }
}

/// A plain app window behind the Sidekick: light or dark, so the dark glass is seen over both.
private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            RoundedRectangle(cornerRadius: 12).fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .padding(.leading, 0).padding(.vertical, 8).padding(.trailing, 80)
        }
    }
}

/// A desktop-ish backdrop so translucent surfaces have something to sit on.
private struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.5, green: 0.6, blue: 0.56), Color(red: 0.3, green: 0.42, blue: 0.38)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(RadialGradient(colors: [Color(red: 0.78, green: 0.7, blue: 0.56).opacity(0.7), .clear],
                                    center: .topTrailing, startRadius: 0, endRadius: 420))
    }
}

/// Fictional meetings on disk, written the way a recording and its processing leave them, so the Meetings page,
/// its timeline and "Who's this?" render without a microphone or the speech models.
private enum SampleMeetings {
    struct IDs { var weekly: String; var inPerson: String; var stopped: String; var design: String }

    typealias Line = (speaker: String, minute: Double, text: String)

    static func write(in root: URL) throws -> IDs {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let weekly = try meeting(in: root, title: "Weekly sync", source: "Zoom", start: now.addingTimeInterval(-65 * 60), minutes: 42,
                                 participants: MeetingParticipants(all: ["Will", "Priya Shah", "Sam Okafor"], me: "Will"),
                                 names: ["Speaker 1": "Priya Shah", "Speaker 2": "Sam Okafor"],
                                 marks: [MeetingMark(t: 4 * 60 + 26, label: "Ship CSV first"), MeetingMark(t: 12 * 60 + 6),
                                         MeetingMark(t: 38 * 60 + 30, label: "Launch copy owner")],
                                 lines: [
            ("Speaker 1", 0.2, "Okay, I think everyone's here. Three things today: the export, the API timeline and the launch copy."),
            ("You", 0.5, "Quick heads-up, I'm recording this so I can write up notes. Shout if that's a problem."),
            ("Speaker 2", 0.62, "All good."),
            ("Speaker 1", 4.03, "Export first. Is it still on for this sprint?"),
            ("You", 4.15, "It's close. The CSV path works, but the PDF one still drops page breaks."),
            ("Speaker 2", 4.4, "I'd ship CSV on its own and move PDF to next sprint."),
            ("Speaker 3", 4.52, "I can pick up the page-break fix. I'm next to Sam today, same laptop."),
            ("Speaker 1", 7.3, "Good. Then the release notes say CSV now, PDF in two weeks, and nobody is surprised."),
            ("Speaker 2", 9.1, "I'll write the changelog entry and link the tracking issue so support can point people at it."),
            ("Speaker 1", 11.67, "Great, let's do that. Sam, how's the API timeline looking?"),
            ("Speaker 2", 11.8, "Fine, as long as we freeze the schema by Thursday."),
            ("You", 12.07, "Thursday works. I'll send the field list tonight."),
            ("Speaker 2", 15.4, "The one open question is pagination. Cursor or page numbers, I don't mind, but we pick one."),
            ("You", 16.2, "Cursor. Page numbers fall apart the moment someone deletes a row."),
            ("Speaker 3", 21.17, "Sorry, that was me, not Sam. Cursor gets my vote too, it matches the mobile client."),
            ("Speaker 1", 24.5, "Then it's settled. Let's not reopen it next week unless something breaks."),
            ("Speaker 2", 29.3, "Rate limits: we keep the current ones for the beta and look again after a month of real traffic."),
            ("You", 33.4, "Fine by me. I'd rather tune it from numbers than guess now."),
            ("Speaker 1", 38.35, "Last thing, launch copy. Who owns the first pass?"),
            ("Speaker 3", 38.45, "I'll take it. I wrote most of the onboarding strings anyway."),
            ("Speaker 1", 41.58, "Perfect. Let's check in on Thursday then."),
        ])
        try meeting(in: root, title: "Standup", source: "Zoom", start: now.addingTimeInterval(-14 * 60), minutes: 12,
                    participants: MeetingParticipants(all: ["Will", "Priya Shah"], me: "Will"), processed: false, lines: [])
        let design = try meeting(in: root, title: "Design crit", source: "Google Chrome", start: now.addingTimeInterval(-4 * 3_600), minutes: 25,
                    participants: MeetingParticipants(all: ["Will", "Ana Ruiz"], me: "Will"), lines: [
            ("Ana Ruiz", 0.25, "The empty state reads well, but the goblin's too big on small screens."),
            ("You", 0.5, "Fair. Let's look at it on a 13-inch screen before we decide."),
            ("Ana Ruiz", 9, "The list rows are right. I'd keep the two-line preview."),
            ("You", 18, "Agreed. I'll send the narrow captures after this."),
        ])
        let inPerson = try meeting(in: root, title: "Conversation", source: "Microphone", start: now.addingTimeInterval(-26 * 3_600), minutes: 18,
                                   kind: .inPerson, lines: [
            ("Speaker 1", 0.3, "Have you got five minutes about the offsite? I want to lock the venue this week."),
            ("Speaker 2", 0.7, "Sure. I liked the one by the river, as long as the train times work for everyone."),
            ("Speaker 1", 3.2, "They do, mostly. The early train gets in at nine, which is fine for a ten o'clock start."),
            ("Speaker 2", 6.8, "Then book it. I'll sort the agenda if you send me the headcount."),
            ("Speaker 1", 11.4, "Twenty-two so far. I'll chase the rest on Friday and send you the final number."),
            ("Speaker 2", 16.5, "Great. Lunch on site, or do we walk somewhere?"),
        ])
        let stopped = try meeting(in: root, title: "Roadmap review", source: "Zoom", start: now.addingTimeInterval(-28 * 3_600), minutes: 31,
                                  participants: MeetingParticipants(all: ["Will", "Jonas Berg", "Lena Park"], me: "Will"),
                                  names: ["Speaker 1": "Jonas Berg", "Speaker 2": "Lena Park"], stopReason: "sleep", lines: [
            ("Speaker 1", 0.4, "If we take meetings on this quarter, what slips?"),
            ("You", 1.1, "Probably the Windows port. It was always going to be the stretch goal."),
            ("Speaker 2", 6, "Then let's say so out loud in the update, so nobody plans around it."),
            ("Speaker 1", 22, "Agreed. Next up is the pricing page."),
        ])
        // Its audio went after a week; the transcript stays.
        let debrief = try meeting(in: root, title: "Hiring debrief", source: "Google Chrome", start: now.addingTimeInterval(-4 * 86_400), minutes: 33,
                                 participants: MeetingParticipants(all: ["Will", "Lena Park", "Jonas Berg"], me: "Will"),
                                 names: ["Speaker 1": "Lena Park", "Speaker 2": "Jonas Berg"], audio: false, lines: [
            ("Speaker 1", 0.3, "Strong on systems, quieter on product sense."),
            ("Speaker 2", 2, "I'd still move forward. The take-home was the best we've seen."),
            ("You", 4, "Same. Let's do the final round next week."),
        ])
        try writeNotes(in: root.appendingPathComponent(weekly, isDirectory: true))
        try seedPeople(root: root, weekly: weekly, crit: design, stopped: stopped, debrief: debrief, inPerson: inPerson)
        return IDs(weekly: weekly, inPerson: inPerson, stopped: stopped, design: design)
    }

    static let notesTools: [NotesTool: MeetingNotesModel.ToolState] = [
        .codex: .ready(NotesToolInstall(tool: .codex, executable: URL(fileURLWithPath: "/usr/local/bin/codex"), version: "0.169.0",
                                        signedIn: true, signIn: "ChatGPT")),
        .claudeCode: .signedOut(NotesToolInstall(tool: .claudeCode, executable: URL(fileURLWithPath: "/usr/local/bin/claude"), version: "2.1.323",
                                                 signedIn: false, signIn: nil)),
    ]

    static let notesModels: [NotesTool: [NotesModelOption]] = [
        .codex: [NotesModelOption(id: "gpt-6.2-sol", title: "GPT-6.2-Sol", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "low", isDefault: true),
                 NotesModelOption(id: "gpt-6.1-terra", title: "GPT-6.1 Terra", efforts: ["low", "medium", "high"], defaultEffort: "low"),
                 NotesModelOption(id: "gpt-6-luna", title: "GPT-6-Luna", efforts: ["low", "medium", "high"], defaultEffort: "medium")],
    ]

    /// Synthetic notes for the weekly sync: what a model would write from its lines above.
    static func writeNotes(in directory: URL) throws {
        let notes = MeetingNotes(
            title: "CSV export, API schema and launch copy",
            summary: "Export ships as CSV this sprint, with PDF two weeks later. The API schema freezes on Thursday with cursor pagination, and [S4] takes the first pass at the launch copy.",
            decisions: [MeetingNotes.Decision(text: "Ship CSV export on its own; PDF moves to next sprint.", status: .decided, at: 4 * 60 + 24),
                        MeetingNotes.Decision(text: "Use cursor pagination for the API.", status: .decided, at: 24 * 60 + 30),
                        MeetingNotes.Decision(text: "Revisit rate limits after a month of real traffic.", status: .open, at: 29 * 60 + 18)],
            actionItems: [MeetingNotes.ActionItem(task: "Write the changelog entry and link the tracking issue", owner: "S3", due: nil, at: 9 * 60 + 6),
                          MeetingNotes.ActionItem(task: "Send the field list", owner: "S1", due: "tonight", at: 12 * 60 + 4),
                          MeetingNotes.ActionItem(task: "Fix PDF page breaks", owner: "S4", due: "next sprint", at: 4 * 60 + 31),
                          MeetingNotes.ActionItem(task: "First pass at the launch copy", owner: "S4", due: nil, at: 38 * 60 + 27)],
            sections: [MeetingNotes.Section(heading: "Export", items: [
                           MeetingNotes.Item(text: "The CSV path works; PDF still drops page breaks.", at: 4 * 60 + 9),
                           MeetingNotes.Item(text: "Release notes will say CSV now and PDF in two weeks.", at: 7 * 60 + 18)]),
                       MeetingNotes.Section(heading: "API timeline", items: [
                           MeetingNotes.Item(text: "The timeline holds if the schema freezes by Thursday.", at: 11 * 60 + 48),
                           MeetingNotes.Item(text: "Cursor matches the mobile client; page numbers break when rows are deleted.", at: 16 * 60 + 12)])],
            marks: [MeetingNotes.MarkNote(t: 4 * 60 + 26, label: "Ship CSV first", note: "[S3] suggested shipping CSV alone and moving PDF to the next sprint."),
                    MeetingNotes.MarkNote(t: 12 * 60 + 6, label: nil, note: "You agreed to the Thursday freeze and to send the field list tonight.")],
            fixes: [MeetingNotes.SpellingFix(heard: "Post grass", meant: "Postgres", count: 2, kind: .applied),
                    MeetingNotes.SpellingFix(heard: "Okafur", meant: "Okafor", count: 1, kind: .suggested)],
            speakers: ["S1": "You", "S2": "Speaker 1", "S3": "Speaker 2", "S4": "Speaker 3"],
            written: MeetingNotes.Provenance(tool: .codex, model: "gpt-6.2-sol", effort: "medium", template: .auto, style: .concise,
                                             createdAt: Date(), seconds: 18, transcriptHash: MeetingNotesFile.sourceHash(directory),
                                             promptVersion: MeetingNotesPrompt.version))
        try MeetingNotesFile.write(notes, to: directory)
        try MeetingPostProcessor.render(directory: directory)
    }

    /// People known by voice, from synthetic voiceprints: who each named meeting taught, Sam named from his voice in the
    /// weekly sync, and its third voice sounding a little like Ana.
    static func seedPeople(root: URL, weekly: String, crit: String, stopped: String, debrief: String, inPerson: String) throws {
        func print(_ seed: Int) -> [Float] {
            Voiceprint.normalized((0..<VoiceprintModel.dimensions).map { Float(sin(Double($0 * (seed + 3)) * 0.37 + Double(seed))) })
        }
        func voice(_ label: String, _ seed: Int, track: MeetingTrack = .system, seconds: Double = 40) -> MeetingVoice {
            MeetingVoice(label: label, track: track, seconds: seconds, clipStart: 30, clipEnd: 42, embedding: print(seed))
        }
        let people = PeopleStore(meetingsRoot: root)
        let taught: [(String, [MeetingVoice], [String: String], Bool)] = [
            (debrief, [voice("Speaker 1", 2), voice("Speaker 2", 3), voice("You", 9, track: .microphone, seconds: 48)],
             ["Speaker 1": "Lena Park", "Speaker 2": "Jonas Berg"], false),
            (stopped, [voice("Speaker 1", 3), voice("Speaker 2", 2), voice("You", 9, track: .microphone, seconds: 31)],
             ["Speaker 1": "Jonas Berg", "Speaker 2": "Lena Park"], false),
            (crit, [voice("Ana Ruiz", 4, seconds: 64), voice("You", 9, track: .microphone, seconds: 52)], [:], false),
            (weekly, [voice("Speaker 1", 5, seconds: 95), voice("Speaker 2", 6, seconds: 71), voice("Speaker 3", 7, seconds: 22),
                      voice("You", 9, track: .microphone, seconds: 58)], ["Speaker 1": "Priya Shah", "Speaker 2": "Sam Okafor"], false),
        ]
        for (id, voices, names, inPerson) in taught {
            let directory = root.appendingPathComponent(id, isDirectory: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(MeetingSessionInfo.self,
                                                         from: Data(contentsOf: directory.appendingPathComponent(MeetingStorage.sessionFile)))
            var matches: [String: MeetingVoices.Match] = [:]
            if id == weekly {
                matches["Speaker 2"] = MeetingVoices.Match(personID: UUID(), name: "Sam Okafor", similarity: 0.86, named: true)
            }
            try MeetingVoices(voices: voices, matches: matches).write(directory)
            try people.learn(meetingID: id, title: session.title, startedAt: session.startedAt, inPerson: inPerson, voices: voices,
                             names: names, me: "Will")
        }
        // The weekly sync's third voice sounds a little like Ana, so Who's this? offers her first.
        let directory = root.appendingPathComponent(weekly, isDirectory: true)
        if var voices = MeetingVoices.read(directory), let ana = people.people().first(where: { $0.name == "Ana Ruiz" }) {
            voices.matches["Speaker 3"] = MeetingVoices.Match(personID: ana.id, name: ana.name, similarity: 0.72, named: false)
            try voices.write(directory)
        }
    }

    @discardableResult
    static func meeting(in root: URL, title: String, source: String, start: Date, minutes: Double, kind: MeetingKind = .call,
                        participants: MeetingParticipants = MeetingParticipants(), names: [String: String] = [:],
                        marks: [MeetingMark] = [], stopReason: String? = "call ended", processed: Bool = true, audio: Bool = true,
                        lines: [Line]) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let id = "\(formatter.string(from: start)) \(title)"
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var info = MeetingSessionInfo(title: title, source: source, target: kind == .inPerson ? "none" : "\(source) (1 process)", startedAt: start)
        info.kind = kind
        info.endedAt = start.addingTimeInterval(minutes * 60)
        info.stopReason = stopReason
        try encoder.encode(info).write(to: directory.appendingPathComponent(MeetingStorage.sessionFile))
        try encoder.encode(participants).write(to: directory.appendingPathComponent(MeetingStorage.participantsFile))
        try Data().write(to: directory.appendingPathComponent(MeetingStorage.segmentsFile))
        if audio { try writeWAV(to: directory.appendingPathComponent(MeetingStorage.audioFile(.microphone))) }
        if audio, kind == .call { try writeWAV(to: directory.appendingPathComponent(MeetingStorage.audioFile(.system))) }
        if !marks.isEmpty {
            let text = try marks.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try text.write(to: directory.appendingPathComponent(MeetingStorage.marksFile), atomically: true, encoding: .utf8)
        }
        guard processed else { return id }
        // Each line stands for a stretch of talk that runs until shortly before the next one, as a real call's do.
        let turns = lines.enumerated().map { index, line in
            let words = Double(line.text.split(separator: " ").count)
            let begin = line.minute * 60
            let next = index + 1 < lines.count ? lines[index + 1].minute * 60 : minutes * 60
            let end = min(max(begin + words * 0.38, next - 4), begin + 150)
            return TranscriptTurn(speaker: line.speaker, label: line.speaker,
                                  track: kind == .inPerson || line.speaker == "You" ? .microphone : .system,
                                  start: begin, end: max(end, begin + 1.5), text: line.text)
        }
        try encoder.encode(turns).write(to: directory.appendingPathComponent(MeetingStorage.attributedFile))
        try encoder.encode(names).write(to: directory.appendingPathComponent(MeetingStorage.speakersFile))
        try MeetingPostProcessor.render(directory: directory)
        return id
    }

    /// Two seconds of near-silence: enough for the page to treat the meeting as having audio.
    static func writeWAV(to url: URL) throws {
        let samples = 32_000
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
        for index in 0..<samples { append(Int16(truncatingIfNeeded: Int(sin(Double(index) * 0.05) * 40))) }
        try data.write(to: url)
    }
}
