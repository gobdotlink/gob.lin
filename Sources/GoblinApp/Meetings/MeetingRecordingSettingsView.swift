import AppKit
import GoblinMeetings
import SwiftUI
import UserNotifications

/// The switch for Meetings, wherever it appears (General and Meeting Recording). Turning it on the first
/// time runs the setup sheet; after that it flips straight away.
struct MeetingsSwitch: View {
    @ObservedObject var meetings: MeetingsController
    @Binding var showingSetup: Bool

    var body: some View {
        Toggle(isOn: Binding(get: { meetings.enabled }, set: { on in
            if on, !meetings.setupFinished { showingSetup = true } else { meetings.setEnabled(on) }
        })) {
            Text("Record meetings")
            Text("Asks before recording a call, and transcribes it on this Mac.").rowDetail()
            Text("Turning it on asks for System Audio Recording and Notifications. Meetings then shows up in the sidebar under History. Nothing loads while it's off.")
        }
    }
}

/// The Meetings group on General: the switch, and once it's on, a way to its settings page.
struct MeetingsGeneralSection: View {
    let model: AppModel
    @ObservedObject private var meetings: MeetingsController
    @State private var showingSetup = false

    init(model: AppModel) {
        self.model = model
        _meetings = ObservedObject(wrappedValue: model.meetings)
    }

    var body: some View {
        Section {
            MeetingsSwitch(meetings: meetings, showingSetup: $showingSetup)
            if meetings.enabled {
                StatusRow(.ready, Text("On. Meetings sits under History.")) {
                    Button("Meeting Recording…") { model.settingsSelection = .meetingRecording }
                }
            } else if let failure = meetings.voiceCleanupFailure {
                // Meeting Recording is hidden while Meetings is off, so voiceprints left behind are reported here.
                StatusRow(.problem, Text("I couldn't delete every voiceprint. \(failure)")) {
                    Button("Try Again") { Task { await meetings.forgetVoices() } }
                }
            }
        } header: { CapsHeader("Meetings") }
        .sheet(isPresented: $showingSetup) { MeetingsSetupSheet(meetings: meetings) { showingSetup = false } }
    }
}

/// Settings → Meeting Recording: the switch, what happens when a call starts, and what's kept.
struct MeetingRecordingSettingsView: View {
    @ObservedObject var meetings: MeetingsController
    /// Shows the People page.
    var openPeople: () -> Void = {}
    @ObservedObject private var systemAudio = SystemAudioAccess.shared
    @State private var showingSetup = false
    @State private var confirmingForget = false
    @State private var audioBytes: Int?
    @State private var count = 0

    var body: some View {
        Section {
            MeetingsSwitch(meetings: meetings, showingSetup: $showingSetup)
            statusRow
        }
        .sheet(isPresented: $showingSetup) { MeetingsSetupSheet(meetings: meetings) { showingSetup = false } }
        Section {
            ForEach(MeetingsController.callAppRows) { row in
                LabeledContent {
                    Picker(row.name, selection: Binding(get: { meetings.policy(for: row) }, set: { meetings.setPolicy($0, for: row) })) {
                        ForEach(MeetingsController.CallPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                } label: {
                    HStack(spacing: 8) {
                        AppIcon(bundleIdentifier: row.iconBundleID, size: 18)
                        Text(row.name)
                    }
                    if let detail = row.detail { Text(detail).rowDetail() }
                }
            }
            Toggle(isOn: Binding(get: { meetings.showSidekick }, set: { meetings.showSidekick = $0 })) {
                Text("Show Sidekick")
                Text("Live captions in a small panel while a call records.").rowDetail()
                Text("It stays out of the overlay's corner.")
            }
        } header: { CapsHeader("When a call starts") } footer: {
            Text("Ask puts a question in the corner when the app picks up your mic. Always records without asking. Never stays quiet for that app.")
        }
        .disabled(!meetings.enabled)
        Section {
            LabeledContent {
                EmptyView()
            } label: {
                Text("Record a conversation")
                Text("For people in the room with you: Record Conversation in the menu bar uses only your mic.").rowDetail()
                Text("I split the voices afterwards and call them Speaker 1, Speaker 2 and so on, until you name them.")
            }
        } header: { CapsHeader("In the room") }
        .disabled(!meetings.enabled)
        Section {
            Toggle(isOn: Binding(get: { meetings.rememberVoices }, set: { on in
                if on { meetings.setRememberVoices(true) } else { confirmingForget = true }
            })) {
                Text("Remember voices")
                Text("Keeps voiceprints on this Mac so I can name people next time.").rowDetail()
                Text("I make a voiceprint of each voice you name, in calls and in the room, and name that person when I hear them again. Close calls are offered in Who's this? instead. Voiceprints never leave this Mac, and turning this off forgets them all.")
            }
            // On the row, not the section: a section's modifiers reach its small-caps header too.
            // Only turning voices on and off waits for Meetings; deleting what's left never does.
            .disabled(!meetings.enabled)
            .confirmationDialog("Forget every voice?", isPresented: $confirmingForget) {
                Button("Turn Off and Forget", role: .destructive) { meetings.setRememberVoices(false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("I'll delete the voiceprints of everyone in People. Names already given in meetings stay.")
            }
            if meetings.rememberVoices, let failure = meetings.voiceLearningFailure, !meetings.learningVoices {
                StatusRow(.problem, Text("I couldn't learn from every meeting. \(failure)")) {
                    Button("Try Again") { meetings.learnFromRecordedMeetings() }
                }
                .disabled(!meetings.enabled)
            } else if meetings.rememberVoices {
                StatusRow(meetings.learningVoices ? .waiting : .ready, Text(speakersLine)) {
                    Button("People…", action: openPeople)
                }
                .disabled(!meetings.enabled)
            } else if let failure = meetings.voiceCleanupFailure {
                StatusRow(.problem, Text("I couldn't delete every voiceprint. \(failure)")) {
                    Button("Try Again") { Task { await meetings.forgetVoices() } }
                }
            }
        } header: { CapsHeader("Speakers") }
        MeetingNotesSettingsSection(model: meetings.notes)
            .disabled(!meetings.enabled)
        Section {
            LabeledContent {
                Text("1 week").foregroundStyle(.secondary)
            } label: {
                Text("Keep audio")
                Text("Transcripts, names and marks stay after the audio goes.").rowDetail()
                Text("Starred meetings keep their audio.")
            }
            LabeledContent {
                Button("Choose…") {}.disabled(true)
            } label: {
                Text("Export folder")
                Text("Coming later: one Markdown file per meeting.").rowDetail()
            }
            StatusRow(.ready, Text(storageLine)) {
                Button("Show in Finder") {
                    let root = meetings.library.store.root
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(root)
                }
            }
        } header: { CapsHeader("Storage") }
        .task(id: meetings.meetings) {
            let store = meetings.library.store
            count = await store.list().count
            audioBytes = await store.audioBytes()
        }
        .onAppear {
            systemAudio.refresh()
            Task { await meetings.refreshNotificationStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemAudio.refresh()
            Task { await meetings.refreshNotificationStatus() }
        }
    }

    private var speakersLine: String {
        if meetings.learningVoices { return "Learning voices from the meetings you've already named…" }
        let others = meetings.people.filter { !$0.isMe }.count
        switch others {
        case 0: return "I don't know anyone's voice yet. Name a voice in a meeting and I'll remember it."
        case 1: return "I know 1 person by voice."
        default: return "I know \(others) people by voice."
        }
    }

    private var storageLine: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(audioBytes ?? 0), countStyle: .file)
        switch count {
        case 0: return "No meetings yet."
        case 1: return "1 meeting uses \(size) of audio."
        default: return "\(count) meetings use \(size) of audio."
        }
    }

    @ViewBuilder private var statusRow: some View {
        if !meetings.enabled {
            StatusRow(.off, Text("Off. Nothing loads until you turn it on."))
        } else if systemAudio.status == .denied {
            StatusRow(.waiting, Text("**System Audio Recording is off,** so I can only hear your side.")) {
                Button("Open System Settings") { systemAudio.openSettings() }
            }
        } else if meetings.notificationStatus == .denied {
            StatusRow(.waiting, Text("Notifications are off, so I can only ask in the corner.")) {
                Button("Open Notifications") { meetings.openNotificationSettings() }
            }
        } else {
            switch meetings.phase {
            case .recording(let recording): StatusRow(.ready, Text("Recording \(recording.title)."))
            case .processing(let title, _):
                StatusRow(.waiting, Text(meetings.processingDownloads ? meetings.processingLine : "Sorting out who said what in \(title)…"))
            case .failed(let message): StatusRow(.problem, Text(message))
            default:
                StatusRow(.ready, Text("Ready. I'll ask when a call starts.")) {
                    if let last = meetings.meetings.first {
                        Text("Last: \(last.title), \(last.startedAt.formatted(.relative(presentation: .named)))").lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Turning Meetings on, once: the permissions it needs, in first run's setup plate, and the consent note.
struct MeetingsSetupSheet: View {
    @ObservedObject var meetings: MeetingsController
    @ObservedObject private var notes: MeetingNotesModel
    @ObservedObject private var systemAudio = SystemAudioAccess.shared
    let close: () -> Void
    /// On unless switched off here: turning Meetings on with them on is the person's yes to both.
    @State private var writeNotes = true
    @State private var rememberVoices = true
    /// Set by previews and captures; otherwise the controller's reading.
    private let previewNotifications: UNAuthorizationStatus?
    @State private var waitingForSystemAudio = false

    /// Previews and captures pass the states they want to show.
    init(meetings: MeetingsController, notifications: UNAuthorizationStatus? = nil, close: @escaping () -> Void) {
        self.meetings = meetings
        _notes = ObservedObject(wrappedValue: meetings.notes)
        self.close = close
        previewNotifications = notifications
    }

    private var notifications: UNAuthorizationStatus? { previewNotifications ?? meetings.notificationStatus }

    private enum Item { case systemAudio, notifications }

    private var current: Item? {
        if systemAudio.status != .granted { return .systemAudio }
        if notifications != .authorized { return .notifications }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Two permissions, two choices.").font(.cardTitle)
            Text("macOS asks for each permission. I listen while I ask, and keep a call only if you say yes.")
                .font(.row).foregroundStyle(.secondary).padding(.top, 4)
            Plate(padding: 4) {
                VStack(spacing: 0) {
                    row(.systemAudio, symbol: "speaker.wave.2", title: Text("System Audio Recording"),
                        detail: "Lets me hear the other side of the call.",
                        light: systemAudio.status == .granted ? .ready : waitingForSystemAudio ? .waiting : .off,
                        waiting: waitingForSystemAudio && systemAudio.status != .granted) {
                        if systemAudio.status == .granted { allowed } else {
                            action(waitingForSystemAudio ? "Open Again" : systemAudio.status == .denied ? "Open System Settings" : "Allow…",
                                   current: current == .systemAudio) {
                                waitingForSystemAudio = true
                                Task { await systemAudio.request() }
                            }
                        }
                    }
                    rule(after: .systemAudio)
                    row(.notifications, symbol: "bell", title: Text("Notifications"),
                        detail: "Tells you when a recording is ready, or stops while you're away.",
                        light: notifications == .authorized ? .ready : .off) {
                        if notifications == .authorized { allowed }
                        else if notifications == .denied {
                            action("Open Settings", current: current == .notifications) {
                                Task { await meetings.allowNotifications() }
                            }
                        } else {
                            action("Allow", current: current == .notifications) {
                                Task { await meetings.allowNotifications() }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                PeekingGoblin(sprite: .shut, scale: 2).alignmentGuide(.top) { $0[.bottom] }.padding(.trailing, 24)
            }
            .padding(.top, 150)
            CapsHeader("After each call").padding(.leading, 14).padding(.top, 16).padding(.bottom, 4)
            Plate(padding: 4) {
                VStack(spacing: 0) {
                    Toggle(isOn: $writeNotes) {
                        Text("Write notes after each call")
                        // Shown, not behind the ⓘ: it says where the transcript goes, which is what this yes is for.
                        Text(notesLine).rowDetail()
                    }
                    .toggleStyle(PlateToggleStyle())
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    Hairline().padding(.horizontal, 10)
                    Toggle(isOn: $rememberVoices) {
                        Text("Remember voices")
                        Text("Keeps voiceprints of each call's voices and your own on this Mac, to name people next time.").rowDetail()
                    }
                    .toggleStyle(PlateToggleStyle())
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            Plate {
                Label {
                    Text("**Tell people before I record them.** In some places everyone on a call has to agree, and that part is up to you.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.2").foregroundStyle(.secondary)
                }
                .font(.status)
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                Text("Lights flip on as you allow each one.").font(.status).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Turn On") {
                    meetings.setupFinished = true
                    // Leaving notes on here is the yes to sending transcripts to the notes model.
                    notes.afterEachCall = writeNotes
                    if writeNotes { notes.consented = true }
                    meetings.setEnabled(true)
                    if rememberVoices { meetings.setRememberVoices(true) }
                    close()
                }
                .prominent().keyboardShortcut(.defaultAction)
                // Without System Audio Recording I'd only hear one side; if TCC can't be read, don't block.
                .disabled(systemAudio.status != .granted && systemAudio.checkable)
            }
            .closingActions()
            .padding(.top, 22)
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 24)
        .frame(width: 620)
        .caseBackground()
        .task {
            await meetings.refreshNotificationStatus()
            systemAudio.refresh()
            if notes.tools.isEmpty, !notes.scanning { notes.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemAudio.refresh()
            if systemAudio.status == .granted { waitingForSystemAudio = false }
            Task { await meetings.refreshNotificationStatus() }
        }
    }

    /// What the notes switch means: the model and who gets the transcript, or that a tool still needs setting up.
    private var notesLine: String {
        if let settings = notes.settings {
            return "With \(notes.describe(settings)), which sends the transcript to \(settings.tool.company)."
        }
        if notes.scanning { return "Looking for Codex or Claude Code on this Mac. They send the transcript to OpenAI or Anthropic." }
        return "Needs Codex or Claude Code, which send the transcript to OpenAI or Anthropic."
    }

    private var allowed: some View {
        Label("Allowed", systemImage: "checkmark").font(.status.weight(.medium)).foregroundStyle(GoblinBrand.mossText)
    }

    @ViewBuilder private func action(_ title: String, current: Bool, perform: @escaping () -> Void) -> some View {
        if current { Button(title, action: perform).prominent() } else { Button(title, action: perform).buttonStyle(.bordered) }
    }

    @ViewBuilder private func rule(after item: Item) -> some View {
        // Beside the tinted current row the rule would run into its corner.
        if current != item, current != .notifications {
            Hairline().padding(.leading, 110).padding(.trailing, 12)
        }
    }

    private func row<Trailing: View>(_ item: Item, symbol: String, title: Text, detail: String, light: LightState, waiting: Bool = false,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 5) {
                StatusLight(state: light)
                Text(light == .ready ? "ON" : light == .waiting ? "WAIT" : "OFF")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            }
            .frame(width: 40)
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                title.font(.row.weight(.semibold))
                Text(detail).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if waiting {
                    Text("Waiting for System Settings. Flip gob.lin on, then come back. I'll notice.")
                        .font(.status).foregroundStyle(GoblinBrand.candle).padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing() }
        }
        .padding(.vertical, 11).padding(.leading, 8).padding(.trailing, 12)
        .background(current == item ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
