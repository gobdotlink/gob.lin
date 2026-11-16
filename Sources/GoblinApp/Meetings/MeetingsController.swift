import AppKit
import Combine
import Foundation
import GoblinEngines
import GoblinMeetings
import os
import UserNotifications

/// Meeting recording, without any UI: the Labs switch, the "Record this call?" offer, one recording at a time with
/// its live transcript, auto-stop, and processing afterwards. Views observe `phase` and `meetings` and call the actions.
@MainActor
final class MeetingsController: ObservableObject {
    struct Recording: Equatable {
        /// The live transcript left some speech for after the call.
        enum Captions: Equatable {
            /// It fell behind, or failed for a while and has recovered: some of it is transcribed after the call.
            case behind
            /// The speech model can't run right now; everything is transcribed after the call.
            case failing
        }

        var title: String
        /// The call app's name, or "In person".
        var app: String
        var bundleID: String?
        var startedAt: Date
        var microphoneLevel: Float = -100
        var systemLevel: Float = -100
        /// The newest live lines, oldest first.
        var lines: [MeetingLine] = []
        /// Chunks waiting for the speech model.
        var backlog = 0
        /// The call app's own mute state, when its window shows one.
        var muted: Bool?
        /// When the call app let go of the mic; recording stops 60 s later once the call is quiet.
        var releasedSince: Date?
        /// The meeting's folder name, its ID in `MeetingStore`.
        var meetingID = ""
        /// Moments marked so far, in time order.
        var marks: [LiveMark] = []
        /// The call app shows that this person is sharing their screen, so the Sidekick hides.
        var sharing = false
        /// A gob.lin dictation is running; its words stay out of the meeting.
        var dictating = false
        /// Keep Recording was chosen after the call app let go of the mic: no auto-stop until it takes it back.
        var keepRecording = false
        /// A conversation in the room, recorded from the mic alone: no call app, no You/Them, no mute state.
        var inPerson = false
        /// The mic stopped and hasn't come back; it's tried again every few seconds.
        var microphoneLost = false
        /// The call's sound stopped arriving after the output device changed; the tap is tried again every few seconds.
        var systemAudioLost = false
        /// Nil while the live transcript keeps up.
        var captions: Captions?

        /// Seconds of auto-stop countdown left, while the call app has let go of the mic.
        func autoStopRemaining(at date: Date = Date()) -> TimeInterval? {
            guard let releasedSince, !keepRecording else { return nil }
            return max(0, MeetingsController.releaseTimeout - date.timeIntervalSince(releasedSince))
        }
    }

    /// A moment marked during the call. `label` is empty until someone labels it.
    struct LiveMark: Identifiable, Equatable {
        let id: UUID
        let t: Double
        var label: String
    }

    /// Ask, Always or Never, per call app. Settings › Meeting Recording edits it; the default is Ask.
    typealias AppPolicy = MeetingCallPolicy

    /// A recording cut short, said once when someone is back at the Mac.
    struct Interruption: Equatable, Identifiable {
        enum Reason: Equatable { case sleep, lidClosed }
        let id = UUID()
        let reason: Reason
        let title: String
        let meetingID: String
        /// How much audio was kept.
        let kept: TimeInterval
        let at: Date
        let app: String
        let bundleID: String?
        /// The call app still holds the mic, so the rest can be recorded as part two.
        var callContinues = false
    }

    /// The overlay's one-line chip once processing is done: "Weekly sync is ready".
    struct ReadyNotice: Equatable, Identifiable {
        var id: String { meetingID }
        let meetingID: String
        let title: String
        let duration: TimeInterval
        /// Voices still called "Speaker N".
        let voicesToName: Int
    }

    enum Phase: Equatable {
        /// The Labs switch is off: no detector, no model, nothing loaded.
        case off
        case idle
        /// A call app has held the mic for 2 s.
        case offered(MeetingCandidate)
        case recording(Recording)
        /// Recording stopped; the transcript is being finished and speakers sorted out.
        case processing(title: String, meetingID: String)
        case finished(meetingID: String)
        case failed(String)

        /// For the log: the phase without titles or text.
        var name: String {
            switch self {
            case .off: "off"
            case .idle: "idle"
            case .offered(let candidate): "offered \(candidate.id)"
            case .recording(let recording): recording.inPerson ? "recording in person" : "recording \(recording.bundleID ?? "a call")"
            case .processing: "processing"
            case .finished: "finished"
            case .failed: "failed"
            }
        }
    }

    static let enabledKey = "meetings.enabled"
    /// Legacy list of apps not to ask about; read once into `appPoliciesKey` as Never.
    static let neverAskKey = "meetings.neverAskBundles"
    /// `[bundleID: "ask" | "always" | "never"]`. Apps not listed are Ask.
    static let appPoliciesKey = "meetings.appPolicies"
    /// Bool, default true: show the Sidekick while recording.
    static let showSidekickKey = "meetings.showSidekick"
    /// Bool, default false: the elapsed time beside the menu-bar goblin while recording.
    static let menuBarTimeKey = "meetings.menuBarTime"
    /// How long after the call app lets go of the mic recording stops, once the call audio is quiet too.
    nonisolated static let releaseTimeout: TimeInterval = 60
    static let quietLevel: Float = -50
    /// Live lines kept for the Sidekick's scroll-back; Copy All reads every line.
    static let liveLineLimit = 1_000

    @Published private(set) var phase: Phase = .off {
        didSet {
            // Levels and live lines change the recording many times a second; only a change of kind is logged.
            if phase.name != oldValue.name { logger.info("phase: \(oldValue.name, privacy: .public) → \(self.phase.name, privacy: .public)") }
            if MeetingOfferGate.blockerCleared(from: Self.offerBlocker(oldValue, starting: starting), to: offerBlocker) {
                scheduleOfferCheck()
            }
        }
    }
    @Published private(set) var meetings: [MeetingSummary] = []
    @Published private(set) var notificationStatus: UNAuthorizationStatus?
    /// Apps whose calls aren't offered any more.
    @Published private(set) var neverAsk: [String]
    /// Ask, Always or Never by bundle ID; apps not listed are Ask.
    @Published private(set) var appPolicies: [String: AppPolicy]
    /// A call app on the mic that isn't being recorded: the offer, or after Not Now, while the call lasts.
    @Published private(set) var unrecordedCall: MeetingCandidate?
    /// Whether the Sidekick shows for the current recording: Show Sidekick, until hidden or shown from the popover.
    @Published private(set) var sidekickVisible = true
    /// A recording that sleep or the lid cut short, until it has been said.
    @Published private(set) var interruption: Interruption?
    /// The finished meeting to announce, until the overlay has shown it.
    @Published private(set) var readyNotice: ReadyNotice?
    /// System Audio Recording, checked when Meetings turns on, at each recording, and when gob.lin comes forward.
    @Published private(set) var systemAudioPermission: SystemAudioPermission = .unknown
    /// When the newest mark was dropped, so the Sidekick's goblin can write it down.
    @Published private(set) var markedAt: Date?
    /// An in-person conversation's mic has been quiet this long, so the overlay asks whether to stop. Nil otherwise.
    @Published private(set) var quietQuestion: Date?
    /// A call whose offer should show again in the overlay, such as after the offer's notification was clicked.
    let offerRecalled = PassthroughSubject<MeetingCandidate, Never>()
    /// Runs as Stop begins, while the recording can still take a label: the Sidekick saves the one being typed.
    var willStop: () -> Void = {}
    /// The meeting the Meetings page should select when it next shows, such as after Open on the ready chip.
    @Published var focusedMeetingID: String?
    /// How far the speaker model's one-time download has got (0...1) while processing waits on it; nil otherwise.
    @Published private(set) var speakerModelDownload: Double?
    /// How far the meeting's own speech model has downloaded (0...1), the first time a meeting needs it because
    /// dictation uses another model; nil otherwise.
    @Published private(set) var speechModelDownload: Double?

    /// What processing is doing, for the popover, settings and the meeting's page.
    var processingLine: String { MeetingCopy.processing(download: speakerModelDownload, speechModel: speechModelDownload) }

    /// Whether processing is downloading a model rather than sorting out voices.
    var processingDownloads: Bool { speakerModelDownload != nil || speechModelDownload != nil }

    let library: MeetingLibrary
    let defaults: UserDefaults
    private let servicesEnabled: Bool
    private let gate: SpeechPriorityGate
    private let speechModels: SpeechModelService
    private let notifications = MeetingNotifications()
    private let logger = Logger(subsystem: "app.goblin.dictation", category: "meetings")
    private var detector: MeetingDetector?
    private var engine: MeetingSpeechEngine?
    private var session: MeetingSession?
    private var probe: AccessibilityProbe?
    private var timer: Timer?
    private var starting = false {
        didSet {
            if MeetingOfferGate.blockerCleared(from: Self.offerBlocker(phase, starting: oldValue), to: offerBlocker) {
                scheduleOfferCheck()
            }
        }
    }
    /// Bumped when Meetings is turned off or the app quits: a start still waiting on capture then throws its session
    /// away instead of recording.
    private var startGeneration = 0
    private var startTask: Task<Void, Never>?
    /// An offer check is queued for after the current change, so the phase setter is never re-entered.
    private var offerCheckQueued = false
    private var stopping: Task<Void, Never>?
    private var offerGate = MeetingOfferGate()
    /// The last offer decision logged, so a detector that changes every second doesn't repeat it.
    private var lastOfferLog = ""
    /// Each mic line on screen and its midpoint, so a mute read late can still take it back.
    private var microphoneMidpoints: [UUID: Double] = [:]
    /// Mute changes already applied to the live lines.
    private var appliedMute = MuteTimeline()
    /// Dictation takes running now: key-down, and key-up once their capture closed.
    private var takes: [UUID: (began: Date, captureEnded: Date?)] = [:]
    /// Takes whose span already went into a meeting that closed while they ran.
    private var takesRecorded: Set<UUID> = []
    /// The spans of this recording's finished takes, in seconds from its start, kept out of the live lines.
    private var dictatedSpans: [ClosedRange<Double>] = []
    private var reportAtStart = SpeechPriorityGate.Report()
    /// The longest a dictation was behind a chunk of this meeting.
    private var meetingMaximumWait = 0.0
    private var shuttingDown = false
    private var systemSoundAt = Date()
    private var lidWasClosed = false
    private var processing: Task<Void, Never>?
    /// The processing run (or launch repair) working right now, so quitting can stop it; the meeting stays pending
    /// and the next launch runs it again.
    private var processingWork: Task<String?, Never>?
    private var leftovers: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Every live line of the current recording, for Copy All and Copy New.
    private var transcriptLines: [MeetingLine] = []
    /// The lines Copy New or Copy All has already copied.
    private var copiedLines: Set<UUID> = []
    private var microphoneSoundAt = Date()
    private var pendingInterruption: Interruption?
    private var interruptionDelivery: Task<Void, Never>?
    private var pendingMarkWrite: Task<Void, Never>?
    private var notificationWatch: Task<Void, Never>?
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    /// In-person: ask whether to stop after this much silence on the mic.
    nonisolated static let conversationQuietTimeout: TimeInterval = 10 * 60
    /// The consent reminder, said wherever a recording is offered or started.
    nonisolated static let consentLine = MeetingCopy.consent

    init(defaults: UserDefaults, servicesEnabled: Bool, speechModels: SpeechModelService, gate: SpeechPriorityGate,
         root: URL = MeetingStorage.root) {
        self.defaults = defaults
        self.servicesEnabled = servicesEnabled
        self.speechModels = speechModels
        self.gate = gate
        let relay = DownloadRelay()
        let speechDownload: @Sendable (Double?) -> Void = relay.sendSpeech
        library = MeetingLibrary(root: root, modelDownload: relay.send, transcribeLater: { [gate, speechModels] chunks, options in
            // Its own engine for the job: dictation's when that's Parakeet, else a Parakeet loaded and unloaded here.
            let engine = MeetingSpeechEngine(gate: gate, dictationEngine: { try await speechModels.backgroundEngine() },
                                             onDownload: speechDownload)
            do {
                let segments = try await MeetingTranscriber.transcribeAll(chunks, engine: engine, options: options)
                await engine.unload()
                return segments
            } catch {
                await engine.unload()
                throw error
            }
        })
        MeetingDetector.removeLog(unless: defaults.bool(forKey: MeetingStorage.debugLogKey))
        var policies = (defaults.dictionary(forKey: Self.appPoliciesKey) as? [String: String] ?? [:])
            .compactMapValues(AppPolicy.init(rawValue:))
        for bundle in defaults.stringArray(forKey: Self.neverAskKey) ?? [] where policies[bundle] == nil { policies[bundle] = .never }
        appPolicies = policies
        neverAsk = policies.filter { $0.value == .never }.map(\.key).sorted()
        gate.observeWaits { [weak self] milliseconds in
            Task { @MainActor in self?.dictationWaited(milliseconds) }
        }
        notifications.onResponse = { [weak self] response in self?.respond(response) }
        relay.target = self
        if enabled {
            activate()
            refreshList()
        }
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The hidden `meetingsDebugAccessibilityLog` default: keep the raw call-window and detection logs for test captures.
    private var debugLogging: Bool { defaults.bool(forKey: MeetingStorage.debugLogKey) }

    var isRecording: Bool { if case .recording = phase { true } else { false } }

    /// The recording in progress, if any.
    var recording: Recording? { if case .recording(let recording) = phase { recording } else { nil } }

    /// Settings › Meeting Recording › Show Sidekick.
    var showSidekick: Bool {
        get { defaults.object(forKey: Self.showSidekickKey) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.showSidekickKey) }
    }

    /// Settings › Meeting Recording › the elapsed time in the menu bar.
    var showsMenuBarTime: Bool { defaults.bool(forKey: Self.menuBarTimeKey) }

    /// False while a recording runs, starts or is still closing.
    var canStart: Bool { enabled && servicesEnabled && !isRecording && !starting && stopping == nil }

    /// While Meetings is on and a meeting records, or a call app holds the mic, dictation must leave the call's sound
    /// alone. With Meetings off it's always false, so dictation pauses and mutes exactly as it does without Labs. It
    /// reads the detector's last poll, never the audio process list itself.
    var callInProgress: Bool {
        guard enabled else { return false }
        if isRecording || starting { return true }
        return (detector?.apps ?? []).contains { $0.callApp != nil && $0.isUsingMicrophone }
    }

    /// The call to record when Start is chosen without one: the one offered, else any call app on the mic.
    var detectedCandidate: MeetingCandidate? {
        if case .offered(let candidate) = phase { return candidate }
        return detector?.candidates.first(where: \.isLikelyMeeting)
    }

    // MARK: Labs switch

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        refreshSystemAudioPermission()
        defaults.set(on, forKey: Self.enabledKey)
        objectWillChange.send()
        if on {
            logger.info("meetings turned on")
            activate()
            Task {
                if NotificationAccess.step(for: await notifications.authorizationStatus()) == .request {
                    let granted = await notifications.requestAuthorization()
                    logger.info("notifications requested when turning on: \(granted ? "allowed" : "not allowed", privacy: .public)")
                }
                await refreshNotificationStatus()
            }
        } else {
            logger.info("meetings turned off")
            Task { await deactivate() }
        }
    }

    private func activate() {
        guard servicesEnabled, detector == nil else {
            if !servicesEnabled, phase == .off { phase = .idle }
            return
        }
        phase = .idle
        notifications.register()
        let detector = MeetingDetector(debugLog: debugLogging)
        detector.onChange = { [weak self] in self?.detectorChanged() }
        self.detector = detector
        detector.start()
        let center = NSWorkspace.shared.notificationCenter
        observe(center, center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interruptionDelivery?.cancel()
                self?.stop(reason: "sleep")
            }
        })
        observe(center, center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleInterruption(after: 3) }
        })
        observe(NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemAudioPermission()
                Task { await self?.refreshNotificationStatus() }
            }
        })
        observe(DistributedNotificationCenter.default(), DistributedNotificationCenter.default().addObserver(forName: Self.screenUnlocked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.pendingInterruption != nil { self?.scheduleInterruption(after: 1) } }
        })
        refreshSystemAudioPermission()
        Task { await refreshNotificationStatus() }
        processLeftovers()
    }

    private func deactivate() async {
        startGeneration += 1
        if isRecording { stop(reason: "turned off") }
        await stopping?.value
        detector?.stop()
        detector = nil
        removeObservers()
        if case .offered(let candidate) = phase { notifications.withdraw(bundleID: candidate.id) }
        unrecordedCall = nil
        pendingInterruption = nil
        interruption = nil
        await engine?.unload()
        engine = nil
        // Turned back on while this was closing: `activate` found the old detector and left it, so start again now.
        if enabled { activate() } else { phase = .off }
    }

    // MARK: Actions

    /// Records the candidate's call app. `title` names a recording that
    /// continues one cut short, such as "Roadmap review, part 2".
    func start(_ candidate: MeetingCandidate, title: String? = nil) {
        guard canStart else { return }
        starting = true
        if case .offered(let offered) = phase { notifications.withdraw(bundleID: offered.id) }
        // A call recorded and then stopped by hand isn't offered again until its app lets go of the mic. Only this
        // call: another app on the mic is asked about once the recording ends.
        offerGate.hold(candidate)
        logger.info("starting: \(candidate.id, privacy: .public)")
        let generation = startGeneration
        startTask = Task { await begin(.call(candidate), title: title, generation: generation) }
    }

    /// Records the room from the mic alone: people talking around the laptop, with no call. No detection, no
    /// Accessibility probe and no auto-stop; after 10 quiet minutes the overlay asks whether to stop.
    func startConversation() {
        guard canStart else { return }
        starting = true
        if case .offered(let offered) = phase { notifications.withdraw(bundleID: offered.id) }
        logger.info("starting: in person")
        let generation = startGeneration
        startTask = Task { await begin(.inPerson, title: nil, generation: generation) }
    }

    func stop() { stop(reason: "stopped") }

    /// After the call app let go of the mic: carry on until it's stopped by hand or the app takes the mic back.
    func keepRecording() {
        guard case .recording(var recording) = phase, recording.releasedSince != nil else { return }
        recording.keepRecording = true
        session?.note("keep recording after the call app let go of the mic")
        phase = .recording(recording)
    }

    /// Keep Going, after the quiet question: ask again after another 10 quiet minutes.
    func keepGoing() {
        guard quietQuestion != nil else { return }
        quietQuestion = nil
        microphoneSoundAt = Date()
        session?.note("keep going after a quiet stretch")
    }

    /// Not now. `neverForThisApp` stops offering this app's calls until it's reset in Settings. The popover keeps a
    /// Record row while the call lasts.
    func dismissOffer(neverForThisApp: Bool = false) {
        guard case .offered(let candidate) = phase else { return }
        notifications.withdraw(bundleID: candidate.id)
        logger.info("offer declined: \(candidate.id, privacy: .public)\(neverForThisApp ? ", never for this app" : "", privacy: .public)")
        if neverForThisApp { setPolicy(.never, for: candidate.id) }
        phase = .idle
        unrecordedCall = neverForThisApp ? nil : candidate
    }

    func resetNeverAsk() {
        for bundle in neverAsk { appPolicies[bundle] = nil }
        savePolicies()
        defaults.removeObject(forKey: Self.neverAskKey)
    }

    func policy(for bundleID: String) -> AppPolicy { appPolicies[bundleID] ?? .ask }

    func setPolicy(_ policy: AppPolicy, for bundleID: String) {
        if self.policy(for: bundleID) != policy { logger.info("policy for \(bundleID, privacy: .public): \(policy.rawValue, privacy: .public)") }
        appPolicies[bundleID] = policy == .ask ? nil : policy
        savePolicies()
        guard policy == .never else { return }
        // Never means quiet now too: an offer already up for this app goes, with its notification and Record row.
        if case .offered(let candidate) = phase, candidate.id == bundleID {
            notifications.withdraw(bundleID: bundleID)
            phase = .idle
        }
        if unrecordedCall?.id == bundleID { unrecordedCall = nil }
    }

    private func savePolicies() {
        defaults.set(appPolicies.mapValues(\.rawValue), forKey: Self.appPoliciesKey)
        neverAsk = appPolicies.filter { $0.value == .never }.map(\.key).sorted()
    }

    /// Clears a finished or failed notice.
    func acknowledge() {
        switch phase {
        case .finished, .failed: phase = enabled ? .idle : .off
        default: break
        }
    }

    /// Asks the Meetings page to select this meeting.
    func show(meetingID: String) { focusedMeetingID = meetingID }

    /// The overlay has shown the ready chip.
    func acknowledgeReady() { readyNotice = nil }

    /// The overlay has said the interruption (or it was dismissed).
    func acknowledgeInterruption() { interruption = nil }

    /// Record the rest of a call that sleep or the lid cut short, as part two.
    func recordRest() {
        guard let interruption else { return }
        self.interruption = nil
        let candidate = interruption.bundleID.flatMap { bundle in detector?.candidates.first { $0.id == bundle } }
        guard let candidate else { return }
        start(candidate, title: "\(interruption.title), part 2")
    }

    /// Show or hide the Sidekick for this recording only; Settings › Show Sidekick decides the next one.
    func setSidekickVisible(_ visible: Bool) { sidekickVisible = visible }

    func refreshSystemAudioPermission() {
        guard servicesEnabled else { return }
        let current = SystemAudioPermission.current
        if current != systemAudioPermission { systemAudioPermission = current }
    }

    func openSystemAudioSettings() { NSWorkspace.shared.open(SystemAudioPermission.settingsURL) }

    /// Reads Notifications again, such as when gob.lin comes forward after System Settings.
    func refreshNotificationStatus() async {
        guard servicesEnabled else { return }
        let status = await notifications.authorizationStatus()
        if status != notificationStatus { notificationStatus = status }
    }

    /// Allow, for Notifications. Not asked yet: macOS asks, and the row follows the answer. Turned off before: asking
    /// again shows nothing, so System Settings opens at gob.lin's row instead, and the row catches up when gob.lin
    /// comes forward again.
    func allowNotifications() async {
        guard servicesEnabled else { return }
        let status = await notifications.authorizationStatus()
        switch NotificationAccess.step(for: status) {
        case .none: break
        case .openSettings:
            logger.info("notifications are off; opening System Settings")
            openNotificationSettings()
        case .request:
            // An agent app's request is easy to miss unless gob.lin is in front.
            NSApp.activate()
            let granted = await notifications.requestAuthorization()
            logger.info("notifications requested: \(granted ? "allowed" : "not allowed", privacy: .public)")
        }
        await refreshNotificationStatus()
        // The answer can come from System Settings or a banner while gob.lin stays in the background: look again
        // every 2 s for 2 minutes, or until it's allowed.
        notificationWatch?.cancel()
        notificationWatch = Task { [weak self] in
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.refreshNotificationStatus()
                if self.notificationStatus == .authorized { return }
            }
        }
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(NotificationAccess.settingsURL(bundleID: Bundle.main.bundleIdentifier))
    }

    func refreshList() {
        let library = library
        Task {
            let list = await library.list()
            if list != meetings { meetings = list }
        }
    }

    // MARK: Screenshots

    /// For `scripts/capture-settings.sh`: shows synthetic state with nothing recording. Ignored in the running app.
    func preview(_ phase: Phase, unrecordedCall: MeetingCandidate? = nil, quiet: Bool = false,
                 systemAudio: SystemAudioPermission = .allowed, sidekickVisible: Bool = true, markedAt: Date? = nil) {
        guard !servicesEnabled else { return }
        self.phase = phase
        self.unrecordedCall = unrecordedCall
        quietQuestion = quiet ? Date() : nil
        systemAudioPermission = systemAudio
        self.sidekickVisible = sidekickVisible
        self.markedAt = markedAt
    }

    // MARK: Marks

    /// Mark This: a bookmark at this moment, labelled now or later. Returns its ID, or nil when nothing records.
    @discardableResult
    func mark() -> UUID? {
        guard case .recording(var recording) = phase else { return nil }
        let mark = LiveMark(id: UUID(), t: max(0, Date().timeIntervalSince(recording.startedAt)), label: "")
        recording.marks.append(mark)
        phase = .recording(recording)
        markedAt = Date()
        saveMarks(recording)
        return mark.id
    }

    func label(_ id: UUID, _ text: String) {
        guard case .recording(var recording) = phase, let index = recording.marks.firstIndex(where: { $0.id == id }) else { return }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recording.marks[index].label != label else { return }
        recording.marks[index].label = label
        phase = .recording(recording)
        saveMarks(recording)
    }

    /// Rewrites `marks.jsonl` off the main thread, in order: each write carries every mark so far.
    private func saveMarks(_ recording: Recording) {
        guard let directory = session?.directory else { return }
        let marks = recording.marks.map { MeetingMark(t: $0.t, label: $0.label) }
        let previous = pendingMarkWrite, logger = logger
        pendingMarkWrite = Task.detached(priority: .utility) {
            await previous?.value
            do { try MeetingMarks.write(marks, to: directory) }
            catch { logger.error("couldn't save marks: \(error.localizedDescription, privacy: .private)") }
        }
    }

    // MARK: Copy

    /// Copy All, or Copy New: the lines since the last copy. Returns how many lines went to the clipboard.
    @discardableResult
    func copyTranscript(onlyNew: Bool) -> Int {
        let lines = onlyNew ? transcriptLines.filter { !copiedLines.contains($0.id) } : transcriptLines
        copiedLines.formUnion(transcriptLines.map(\.id))
        guard !lines.isEmpty else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.plainText(lines), forType: .string)
        return lines.count
    }

    /// "[12:03] You: …", one line each; in-person lines have no speaker yet.
    nonisolated static func plainText(_ lines: [MeetingLine]) -> String {
        lines.map { line in
            let stamp = "[\(elapsed(line.start))]"
            return line.speaker.isEmpty ? "\(stamp) \(line.text)" : "\(stamp) \(line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    /// 4:07, or 1:02:03 past an hour.
    nonisolated static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "31 minutes", "40 seconds", "1 hour 5 minutes": how much a stopped recording kept.
    nonisolated static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) \(total == 1 ? "second" : "seconds")" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" }
        let rest = minutes % 60
        return "\(minutes / 60) \(minutes / 60 == 1 ? "hour" : "hours")" + (rest > 0 ? " \(rest) \(rest == 1 ? "minute" : "minutes")" : "")
    }

    // MARK: Dictation

    /// A dictation take started: key-down. Meeting chunks wait until it ends. `recordsSpan` false is for work that
    /// isn't someone speaking, such as re-transcribing a History entry: chunks wait, but nothing is left out.
    func dictationBegan(_ id: UUID, recordsSpan: Bool = true) {
        gate.beginForeground(id)
        guard recordsSpan else { return }
        takes[id] = (Date(), nil)
        setDictating()
    }

    /// The take's capture closed: key-up. The mic heard the dictation from key-down to here; cleanup and insertion
    /// come after it, and what the mic hears then belongs to the meeting.
    func dictationCaptureEnded(_ id: UUID) {
        guard takes[id]?.captureEnded == nil else { return }
        takes[id]?.captureEnded = Date()
        setDictating()
    }

    /// The take ended: its text is inserted, or it was cancelled. Its spoken span goes into the meeting being recorded.
    func dictationEnded(_ id: UUID) {
        gate.endForeground(id)
        guard let take = takes.removeValue(forKey: id) else { return }
        if takesRecorded.remove(id) == nil, let session {
            let end = take.captureEnded ?? Date()
            session.recordDictation(start: take.began, end: end)
            if let span = Self.span(take.began, end, from: session.startedAt) { dictatedSpans.append(span) }
        }
        setDictating()
    }

    /// Before a meeting closes: the spans of takes still running go in now, cut at the recording's end. A cancelled
    /// take whose cleanup is stuck (behind a loading model, on quit) would otherwise end after the meeting can take it.
    private func recordRunningTakes(_ session: MeetingSession) {
        let now = Date()
        for (id, take) in takes where !takesRecorded.contains(id) {
            session.recordDictation(start: take.began, end: take.captureEnded ?? now)
            takesRecorded.insert(id)
        }
    }

    /// A take's span in seconds from the recording's start; nil if it ended before it began.
    private static func span(_ began: Date, _ end: Date, from startedAt: Date) -> ClosedRange<Double>? {
        let lower = began.timeIntervalSince(startedAt), upper = end.timeIntervalSince(startedAt)
        return lower <= upper ? lower...upper : nil
    }

    /// What the mic heard of a dictation in this recording: finished takes, and running ones up to their key-up, or
    /// to any time yet while their mic is still open. The saved transcript leaves out the same words.
    private func dictationSpans(_ session: MeetingSession) -> [ClosedRange<Double>] {
        let startedAt = session.startedAt
        return dictatedSpans + takes.values.compactMap { take in
            let start = take.began.timeIntervalSince(startedAt)
            let end = take.captureEnded.map { $0.timeIntervalSince(startedAt) } ?? .greatestFiniteMagnitude
            return start <= end ? start...end : nil
        }
    }

    /// "You're dictating" lasts while a take's mic is open, not while its text is cleaned up and typed.
    private var speaking: Bool { takes.values.contains { $0.captureEnded == nil } }

    private func setDictating() {
        guard case .recording(var recording) = phase, recording.dictating != speaking else { return }
        recording.dictating = speaking
        phase = .recording(recording)
    }

    private func dictationWaited(_ milliseconds: Double) {
        guard session != nil else { return }
        meetingMaximumWait = max(meetingMaximumWait, milliseconds)
        logger.info("dictation began during a meeting chunk and was behind it for \(milliseconds, format: .fixed(precision: 1)) ms")
        session?.note(String(format: "a dictation began during a meeting chunk; it was behind it for %.1f ms", milliseconds))
    }

    // MARK: Recording

    private enum Source {
        case call(MeetingCandidate), inPerson
    }

    private func begin(_ source: Source, title override: String?, generation: Int) async {
        defer { starting = false }
        guard generation == startGeneration else { return }
        let target: SystemAudioTarget
        let title: String, appName: String
        var candidate: MeetingCandidate?
        switch source {
        case .call(let call):
            candidate = call
            let app = call.app
            let bundles = Set(app.processes.compactMap(\.bundleID) + [app.bundleID]).filter { !$0.hasPrefix("pid:") }
            target = .app(bundleIDs: Array(bundles), processes: app.processes.map(\.objectID))
            title = override ?? call.meetingTitle.map(MeetingDetector.cleanTitle) ?? app.name
            appName = app.name
        case .inPerson:
            target = .none
            title = override ?? "Conversation"
            appName = "In person"
        }
        let engine = speechEngine()
        let session: MeetingSession
        // Dictation's language, as the meeting's Parakeet takes it; one it doesn't know falls back to detection.
        let recognition = SpeechModelCatalog.parakeet.capabilities.options(for: speechModels.preferredLanguage)
        do {
            session = try MeetingSession(title: title, source: appName, target: target, engine: engine, recognition: recognition,
                onSegment: { [weak self] segment in Task { @MainActor in self?.append(segment) } },
                onEvent: { _ in },
                onProblem: { [weak self] problem in Task { @MainActor in self?.sessionReported(problem) } })
        } catch {
            logger.error("couldn't start: no folder: \(error.localizedDescription, privacy: .private)")
            phase = .failed("I couldn't make a folder for the recording: \(error.localizedDescription)")
            return
        }
        do {
            try await session.start()
        } catch {
            _ = await session.stop()
            await engine.unload()
            try? FileManager.default.removeItem(at: session.directory)
            logger.error("couldn't start: \(error.localizedDescription, privacy: .private)")
            guard generation == startGeneration else { return }
            phase = .failed(target == .none ? "I couldn't start recording, because the mic didn't start: \(error.localizedDescription)"
                                            : "I couldn't start recording: \(error.localizedDescription)")
            return
        }
        guard generation == startGeneration else {
            // Meetings was turned off, or the app is quitting, while capture started: nothing of it is kept, so the
            // live transcript isn't waited for.
            _ = await session.stop(transcriptDeadline: .zero)
            await engine.unload()
            try? FileManager.default.removeItem(at: session.directory)
            logger.info("start abandoned: meetings turned off or quitting")
            return
        }
        self.session = session
        // A take that ran through the last meeting's Stop is left out of this one too, when it ends.
        takesRecorded = []
        dictatedSpans = []
        let store = library.store, folder = session.directory.lastPathComponent
        Task { await store.setRecording(folder, true) }
        reportAtStart = gate.snapshot
        meetingMaximumWait = 0
        systemSoundAt = Date()
        microphoneSoundAt = Date()
        quietQuestion = nil
        transcriptLines = []
        copiedLines = []
        microphoneMidpoints = [:]
        appliedMute = MuteTimeline()
        markedAt = nil
        lidWasClosed = AudioInputDevices.lidClosed()
        if let candidate, let pid = candidate.app.pid, let call = candidate.app.callApp {
            let probe = AccessibilityProbe(pid: pid, app: call, directory: session.directory, sessionStart: session.startedAt,
                                           rawLog: debugLogging)
            probe.start()
            self.probe = probe
        }
        unrecordedCall = nil
        sidekickVisible = showSidekick
        if target != .none { refreshSystemAudioPermission() }
        var recording = Recording(title: title, app: appName, bundleID: candidate?.app.bundleID, startedAt: session.startedAt)
        recording.meetingID = folder
        recording.inPerson = target == .none
        recording.dictating = speaking
        phase = .recording(recording)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshList()
    }

    private func speechEngine() -> MeetingSpeechEngine {
        if let engine { return engine }
        let engine = MeetingSpeechEngine(gate: gate, dictationEngine: { [speechModels] in
            try await speechModels.backgroundEngine()
        }, onSource: { [weak self] source in
            Task { @MainActor in
                self?.session?.annotate { $0.speechModel = source }
                self?.session?.note("speech model: \(source)")
            }
        }, onDownload: { [weak self] fraction in
            Task { @MainActor in if self?.speechModelDownload != fraction { self?.speechModelDownload = fraction } }
        })
        self.engine = engine
        return engine
    }

    private func append(_ segment: TranscriptSegment) {
        guard case .recording(var recording) = phase, let session else { return }
        // While the call app shows you muted, the mic was never heard on the call: keep it out of the live lines as
        // the transcript will. The audio stays as recorded.
        if probe?.muteTimeline.silences(segment) == true { return }
        var segment = segment
        // A gob.lin dictation isn't meeting speech: its words stay out of the Sidekick and Copy, as out of the transcript.
        if segment.track == .microphone {
            guard let undictated = MeetingPostProcessor.removeDictation(segment, spans: dictationSpans(session)).0 else { return }
            segment = undictated
        }
        if segment.track == .microphone { microphoneMidpoints[segment.id] = (segment.start + segment.end) / 2 }
        // In person, voices are told apart only after Stop: live lines carry no speaker.
        let speaker = recording.inPerson ? "" : segment.track == .microphone ? "You" : "Them"
        let line = MeetingLine(id: segment.id, speaker: speaker, start: segment.start, text: segment.text)
        // The two tracks' chunks decode independently, so a line can arrive after a later one.
        transcriptLines.insert(line, byStart: \.start)
        recording.lines.insert(line, byStart: \.start)
        // The speech model runs again; what it missed is still left for after the call.
        if recording.captions == .failing { recording.captions = .behind }
        if recording.lines.count > Self.liveLineLimit { recording.lines.removeFirst(recording.lines.count - Self.liveLineLimit) }
        phase = .recording(recording)
    }

    /// The session's capture dropped out or came back, or the live transcript left speech for after the call.
    private func sessionReported(_ problem: MeetingSessionProblem) {
        guard case .recording(var recording) = phase else { return }
        switch problem {
        case .capture(.microphoneLost): recording.microphoneLost = true
        case .capture(.microphoneRestored): recording.microphoneLost = false
        case .capture(.systemAudioLost): recording.systemAudioLost = true
        case .capture(.systemAudioRestored): recording.systemAudioLost = false
        case .transcriptDeferred(.behind): if recording.captions == nil { recording.captions = .behind }
        case .transcriptDeferred(.failed): recording.captions = .failing
        case .writeFailed(let message):
            // A full disk: stop while what's on disk is whole, and say why. Processing still runs on what was kept.
            logger.error("recording stopped: couldn't write: \(message, privacy: .private)")
            stop(reason: MeetingStopReason.writeFailed)
            phase = .failed("I stopped recording, because I couldn't save any more of it: \(message)")
            return
        }
        if recording != self.recording {
            logger.info("recording: mic \(recording.microphoneLost ? "lost" : "ok", privacy: .public), call sound \(recording.systemAudioLost ? "lost" : "ok", privacy: .public), captions \(String(describing: recording.captions), privacy: .public)")
            phase = .recording(recording)
        }
    }

    private func tick() {
        guard case .recording(var recording) = phase, let session else { return }
        let levels = session.levels
        recording.microphoneLevel = levels.microphone
        recording.systemLevel = levels.system
        recording.backlog = session.backlog
        recording.muted = probe?.isMuted
        recording.sharing = probe?.isSharing ?? false
        if let timeline = probe?.muteTimeline, timeline != appliedMute {
            appliedMute = timeline
            dropMutedLines(from: &recording, timeline: timeline)
        }
        let now = Date()
        if levels.system > Self.quietLevel { systemSoundAt = now }
        if levels.microphone > Self.quietLevel { microphoneSoundAt = now }
        if recording != self.recording { phase = .recording(recording) }
        if recording.inPerson {
            // Nobody lets go of a mic in a room: after a long quiet stretch, ask instead of stopping.
            if quietQuestion == nil, now.timeIntervalSince(microphoneSoundAt) >= Self.conversationQuietTimeout {
                quietQuestion = now
                session.note("quiet for \(Int(Self.conversationQuietTimeout / 60)) minutes; asking whether to stop")
            } else if quietQuestion != nil, now.timeIntervalSince(microphoneSoundAt) < 5 {
                // Talking again answers it.
                quietQuestion = nil
            }
        } else if let released = recording.releasedSince, !recording.keepRecording,
                  now.timeIntervalSince(released) >= Self.releaseTimeout, now.timeIntervalSince(systemSoundAt) >= 10 {
            // Auto-stop: the call app let go of the mic a minute ago and the call has gone quiet.
            stop(reason: "call ended")
            return
        }
        // Closing the lid ends the meeting, unless it was already closed when recording began (an external display).
        let lidClosed = AudioInputDevices.lidClosed()
        if lidClosed, !lidWasClosed { stop(reason: "lid closed"); return }
        lidWasClosed = lidClosed
    }

    /// A mute read after a line was shown takes the line back, from the Sidekick, the popover and Copy.
    private func dropMutedLines(from recording: inout Recording, timeline: MuteTimeline) {
        let muted = Set(microphoneMidpoints.filter { timeline.isMuted(at: $0.value) }.keys)
        guard !muted.isEmpty else { return }
        for id in muted { microphoneMidpoints[id] = nil }
        transcriptLines.removeAll { muted.contains($0.id) }
        recording.lines.removeAll { muted.contains($0.id) }
        logger.info("took back \(muted.count, privacy: .public) live mic lines said while muted")
    }

    /// What keeps a new offer back in this phase, or nil when one may be made.
    private var offerBlocker: String? { Self.offerBlocker(phase, starting: starting) }

    private static func offerBlocker(_ phase: Phase, starting: Bool) -> String? {
        if starting { return "a recording is starting" }
        switch phase {
        case .idle, .finished, .failed: return nil
        case .off: return "off"
        case .offered(let candidate): return "offering \(candidate.id)"
        case .recording: return "recording"
        case .processing: return "processing"
        }
    }

    /// Decides again once the current change has finished: a call skipped as busy (Slack while a Zoom recording was
    /// still counting down) is offered when the recording ends, not only when the detector next sees a change.
    private func scheduleOfferCheck() {
        guard !offerCheckQueued else { return }
        offerCheckQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.offerCheckQueued = false
            self.detectorChanged()
        }
    }

    private func detectorChanged() {
        guard let detector else { return }
        if let call = unrecordedCall {
            unrecordedCall = detector.candidates.first { $0.id == call.id }
        }
        let (decision, skipped) = offerGate.update(candidates: detector.candidates, busy: offerBlocker, policy: policy(for:))
        logOffer(decision, skipped)
        switch phase {
        case .idle, .finished, .failed:
            let candidate: MeetingCandidate
            switch decision {
            case .none: return
            case .record(let call):
                start(call)
                return
            case .offer(let call): candidate = call
            }
            phase = .offered(candidate)
            unrecordedCall = candidate
            // The overlay asks; a notification asks instead while the screen is locked and the overlay can't show.
            if Self.screenLocked {
                notifications.offer(appName: candidate.app.name, bundleID: candidate.id,
                                    title: candidate.meetingTitle.map(MeetingDetector.cleanTitle))
            }
        case .offered(let candidate):
            if let current = detector.candidates.first(where: { $0.id == candidate.id }) {
                if current != candidate { phase = .offered(current) }
            } else {
                notifications.withdraw(bundleID: candidate.id)
                logger.info("offer withdrawn: \(candidate.id, privacy: .public) let go of the mic")
                phase = .idle
            }
        case .recording(var recording):
            guard let bundle = recording.bundleID else { return }
            let holding = detector.apps.first { $0.bundleID == bundle }?.isUsingMicrophone ?? false
            if holding, recording.releasedSince != nil {
                recording.releasedSince = nil
                recording.keepRecording = false
                session?.note("\(bundle) took the mic back")
                logger.info("\(bundle, privacy: .public) took the mic back; auto-stop cancelled")
            } else if !holding, recording.releasedSince == nil {
                recording.releasedSince = Date()
                session?.note("\(bundle) released the mic")
                logger.info("\(bundle, privacy: .public) released the mic; stopping in \(Int(Self.releaseTimeout), privacy: .public) s once the call is quiet")
            } else { return }
            phase = .recording(recording)
        case .off, .processing: break
        }
    }

    /// Logs an offer decision when it differs from the last one: offered, recorded at once, or skipped and why.
    private func logOffer(_ decision: MeetingOfferGate.Decision, _ skipped: [MeetingOfferGate.Skip]) {
        var parts = skipped.map { "skipped \($0.bundleID): \($0.reason)" }
        switch decision {
        case .offer(let candidate): parts.append("offered \(candidate.id)")
        case .record(let candidate): parts.append("recording \(candidate.id) (set to Always)")
        case .none: break
        }
        let line = parts.joined(separator: "; ")
        guard line != lastOfferLog else { return }
        lastOfferLog = line
        if !line.isEmpty { logger.info("offer: \(line, privacy: .public)") }
    }

    private func respond(_ response: MeetingNotifications.Response) {
        switch response {
        case .record(let bundle):
            guard let candidate = detector?.candidates.first(where: { $0.id == bundle }) else { return }
            start(candidate)
        case .notNow(let bundle):
            if case .offered(let candidate) = phase, candidate.id == bundle { dismissOffer() }
        case .show(let bundle):
            // The notification's body: ask again in the overlay, never record. Only its Record button records.
            NSApp.activate()
            let call: MeetingCandidate? = if case .offered(let candidate) = phase, candidate.id == bundle { candidate }
                                          else if let unrecorded = unrecordedCall, unrecorded.id == bundle { unrecorded } else { nil }
            if let call { offerRecalled.send(call) }
        }
    }

    /// Stops capture at once, so the audio on disk is complete even if the Mac is about to sleep, then finishes the
    /// live transcript and processes the meeting off the main thread.
    private func stop(reason: String) {
        guard case .recording = phase, session != nil, stopping == nil else { return }
        willStop()
        guard case .recording(let recording) = phase, let session else { return }
        logger.info("stopping: \(reason, privacy: .public) after \(Int(Date().timeIntervalSince(recording.startedAt)), privacy: .public) s, \(recording.marks.count, privacy: .public) marks")
        timer?.invalidate()
        timer = nil
        probe?.stop()
        probe = nil
        quietQuestion = nil
        phase = .processing(title: recording.title, meetingID: recording.meetingID)
        annotateDictation(session, reason: reason)
        recordRunningTakes(session)
        if reason == "call ended", let released = recording.releasedSince {
            // An app that lets go of the mic on mute still plays the call, so the call ends at its last sound.
            let ended = max(released, systemSoundAt)
            session.annotate { $0.callEndedAt = max(0, ended.timeIntervalSince($0.startedAt)) }
        }
        if reason == "sleep" || reason == "lid closed" {
            pendingInterruption = Interruption(reason: reason == "sleep" ? .sleep : .lidClosed, title: recording.title,
                                               meetingID: recording.meetingID, kept: Date().timeIntervalSince(recording.startedAt),
                                               at: Date(), app: recording.app, bundleID: recording.bundleID)
            // A lid closed on an external display doesn't sleep the Mac; say it shortly, unless sleep comes first.
            if reason == "lid closed" { scheduleInterruption(after: 3) }
        }
        let marks = pendingMarkWrite
        stopping = Task {
            _ = await session.stop()
            await marks?.value
            await self.engine?.unload()
            self.session = nil
            self.stopping = nil
            self.refreshList()
            self.process(session.directory)
        }
    }

    private func annotateDictation(_ session: MeetingSession, reason: String) {
        let report = gate.snapshot, start = reportAtStart
        session.annotate {
            $0.stopReason = reason
            $0.dictationTakes = report.takes - start.takes
            $0.dictationMaximumWaitMilliseconds = meetingMaximumWait
        }
        session.note("stopping: \(reason); \(report.takes - start.takes) dictations, \(report.takesBehindBackground - start.takesBehindBackground) began during a meeting chunk")
    }

    // MARK: Interruptions

    /// True while the login window covers the screen, when nothing of the overlay can be seen.
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Says a recording cut short once someone can see it: after wake, once the screen is unlocked. If the call is
    /// still on, the overlay offers to record the rest; if it ended, a notification says what was kept.
    private func scheduleInterruption(after seconds: Double) {
        guard pendingInterruption != nil else { return }
        interruptionDelivery?.cancel()
        interruptionDelivery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, var pending = self.pendingInterruption, !Self.screenLocked else { return }
            self.pendingInterruption = nil
            pending.callContinues = pending.bundleID.map { bundle in
                self.detector?.apps.contains { $0.bundleID == bundle && $0.isUsingMicrophone } ?? false
            } ?? false
            if pending.callContinues || !MeetingNotifications.available {
                self.interruption = pending
            } else {
                self.notifications.interrupted(Self.interruptionSentence(pending, withTitle: true))
            }
        }
    }

    /// "Recording stopped because the Mac went to sleep, so I kept the first 31 minutes."
    static func interruptionSentence(_ interruption: Interruption, withTitle: Bool = false) -> String {
        let cause = interruption.reason == .sleep ? "the Mac went to sleep" : "the lid closed"
        let kept = spoken(interruption.kept)
        return withTitle ? "Recording stopped because \(cause). I kept the first \(kept) of \(interruption.title)."
            : "Recording stopped because \(cause), so I kept the first \(kept)."
    }

    // MARK: Processing

    /// Speakers and echo, after Stop. It waits until no dictation take is running before it starts; diarization
    /// itself runs to the end once started (well under a second per minute of call).
    private func process(_ directory: URL) {
        guard !shuttingDown else { return }
        let gate = gate, previous = processing, store = library.store
        let id = directory.lastPathComponent
        processing = Task {
            await previous?.value
            guard !shuttingDown else { return }
            let work = Task.detached(priority: .utility) { () -> String? in
                do {
                    try await gate.waitForQuiet()
                    _ = try await store.process(id)
                    return nil
                } catch { return error.localizedDescription }
            }
            processingWork = work
            let failure = await work.value
            processingWork = nil
            // Stopped by quit: the meeting is still pending, and the next launch finishes it.
            guard !shuttingDown else { return }
            // By ID: two meetings can share a title, and the next recording may already be processing.
            if case .processing(_, let current) = phase, current == id {
                phase = failure.map { .failed("I kept the recording, but couldn't finish the transcript: \($0)") } ?? .finished(meetingID: id)
            }
            if failure == nil, let summary = try? await store.summary(id) {
                readyNotice = ReadyNotice(meetingID: id, title: summary.title, duration: summary.duration,
                                          voicesToName: summary.speakers.filter(Self.isUnnamedVoice).count)
            }
            if let failure { logger.error("meeting processing failed: \(failure, privacy: .private)") }
            else { logger.info("processing done: \(id, privacy: .private)") }
            refreshList()
        }
    }

    /// A voice nobody has named yet: "Speaker 2".
    nonisolated static func isUnnamedVoice(_ name: String) -> Bool {
        name.hasPrefix("Speaker ") && Int(name.dropFirst(8)) != nil
    }

    /// At launch: finish meetings cut short by a crash or quit (the store repairs and processes them once no
    /// dictation is running), then drop audio past the retention period.
    private func processLeftovers() {
        let store = library.store, gate = gate, logger = logger
        leftovers = Task {
            try? await gate.waitForQuiet()
            guard !Task.isCancelled else { return }
            // Each message starts with the meeting's folder name, which holds its title.
            let repaired = await store.repairUnfinished { message in logger.info("\(message, privacy: .private)") }
            let removed = await store.applyRetention()
            if !repaired.isEmpty || !removed.isEmpty { refreshList() }
        }
    }

    private func observe(_ center: NotificationCenter, _ observer: NSObjectProtocol) {
        observers.append((center, observer))
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: Quit

    /// Closes a recording on quit: capture stops and the files are finished at once, the live transcript gets two
    /// seconds to catch up, and processing waits for the next launch. A processing run already going is stopped
    /// without being called failed; its meeting stays pending, so `repairUnfinished` runs it again at launch.
    func shutdown() async {
        shuttingDown = true
        startGeneration += 1
        processingWork?.cancel()
        leftovers?.cancel()
        detector?.stop()
        timer?.invalidate()
        timer = nil
        probe?.stop()
        probe = nil
        interruptionDelivery?.cancel()
        // Dictation is ending too; let the meeting's last chunks through.
        gate.endAllForeground()
        if let session, stopping == nil {
            annotateDictation(session, reason: "quit")
            recordRunningTakes(session)
            _ = await session.stop(transcriptDeadline: .seconds(2))
            self.session = nil
        } else if let session, let stopping {
            // A Stop still waiting on the live transcript or the speech model's download gets the same two seconds;
            // then what's queued goes to deferred.jsonl for the next launch, since the app won't wait for it.
            if await !Self.finishes(stopping, within: .seconds(2)) { session.leaveQueuedForLater() }
        }
        await pendingMarkWrite?.value
        if let stopping { _ = await Self.finishes(stopping, within: .seconds(1)) }
        // A start still waiting on capture closes and removes its session.
        if starting, let startTask { _ = await Self.finishes(startTask, within: .seconds(1)) }
        await engine?.unload()
        removeObservers()
    }
}

extension MeetingsController {
    /// Whether `task` ends within `limit`; it carries on either way.
    fileprivate static func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        // A race rather than a task group, which would wait for the task anyway.
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Bool) -> Void = { value in
                if answered.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: value) }
            }
            Task { await task.value; answer(true) }
            Task { try? await Task.sleep(for: limit); answer(false) }
        }
    }
}

/// Carries the speaker model's download progress from the store's worker back to the controller, which doesn't
/// exist yet when the store is made.
@MainActor private final class DownloadRelay {
    weak var target: MeetingsController?

    nonisolated func send(_ fraction: Double?) {
        Task { @MainActor in
            guard let target = self.target, target.speakerModelDownload != fraction else { return }
            target.speakerModelDownloadChanged(fraction)
        }
    }

    nonisolated func sendSpeech(_ fraction: Double?) {
        Task { @MainActor in
            guard let target = self.target, target.speechModelDownload != fraction else { return }
            target.speechModelDownloadChanged(fraction)
        }
    }
}

extension MeetingsController {
    fileprivate func speakerModelDownloadChanged(_ fraction: Double?) { speakerModelDownload = fraction }
    fileprivate func speechModelDownloadChanged(_ fraction: Double?) { speechModelDownload = fraction }
}

extension MeetingCopy {
    /// While a meeting is processed: a model's one-time download when that's what it's waiting on.
    static func processing(download: Double?, speechModel: Double? = nil) -> String {
        if let speechModel { return "\(speechModelDownload(speechModel)) Then I'll finish the transcript." }
        guard let download else { return "Sorting out who said what…" }
        let size = MeetingSpeakerModel.files(preset: "offline").downloadBytes.formatted(.byteCount(style: .file))
        return "Downloading what I need to tell voices apart, just this once (\(Int(download * 100))% of \(size))…"
    }

    /// "Downloading the speech model for meetings, just this once (40% of 480 MB)."
    static func speechModelDownload(_ fraction: Double) -> String {
        let size = SpeechModelCatalog.parakeet.downloadBytes.formatted(.byteCount(style: .file))
        return "Downloading the speech model for meetings, just this once (\(Int(fraction * 100))% of \(size))."
    }

    /// The line that says the mic or the call's sound dropped out mid-recording, or nil while both are fine.
    static func captureLost(_ recording: MeetingsController.Recording) -> String? {
        if recording.microphoneLost {
            return recording.inPerson ? "I lost your mic, so I can't hear the room. I'll pick it up again when it's back."
                : "I lost your mic, so I'm only recording \(recording.app). I'll pick it up again when it's back."
        }
        if recording.systemAudioLost, !recording.inPerson {
            return "I lost \(recording.app)'s sound, so I'm only recording your mic. I'll keep trying."
        }
        return nil
    }

    /// The line for a live transcript that left speech for after the call.
    static func captions(_ captions: MeetingsController.Recording.Captions) -> String {
        switch captions {
        case .behind: "I fell behind on captions, so I'll transcribe some of this after the call."
        case .failing: "I can't run the speech model right now, so I'll transcribe this after the call."
        }
    }
}
