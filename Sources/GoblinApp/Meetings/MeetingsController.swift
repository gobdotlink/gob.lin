import AppKit
import Combine
import Foundation
import GoblinEngines
import GoblinMeetings
import os
import UserNotifications

/// Meeting recording, without any UI: the Meetings switch, the "Record this call?" offer, one recording at a time with
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
        /// When the call app let go of the mic; recording stops `releaseTimeout` later once the call is quiet.
        var releasedSince: Date?
        /// How long after the app lets go of the mic recording stops: 60 s for a call app, 10 s for a browser.
        var releaseTimeout: TimeInterval = MeetingsController.releaseTimeout
        /// The meeting's folder name, its ID in `MeetingStore`.
        var meetingID = ""
        /// Moments marked so far, in time order.
        var marks: [LiveMark] = []
        /// A gob.lin dictation is running; its words stay out of the meeting.
        var dictating = false
        /// Keep Recording was chosen after the call app let go of the mic: no auto-stop until it takes it back.
        var keepRecording = false
        /// A conversation in the room, recorded from the mic alone: no call app, no You/Them, no mute state.
        var inPerson = false
        /// The call's voices are told apart as it goes, so its lines carry a name ("Sam Okafor", "Speaker 3") instead of
        /// Them; a line still says Them until its voice is placed. The names are checked again after Stop.
        var namesLive = false
        /// Every name its lines have carried this call, in the order they first did: a voice keeps its colour when an
        /// earlier one gets a name, or when its first lines scroll out of the live ones.
        var voiceOrder: [String] = []
        /// The mic stopped and hasn't come back; it's tried again every few seconds.
        var microphoneLost = false
        /// The mic being recorded, and why.
        var microphone: MeetingMicrophone?
        /// The mic is muted, at zero volume or sending only silence.
        var microphoneSilence: InputSilence?
        /// The call's sound stopped arriving after the output device changed; the tap is tried again every few seconds.
        var systemAudioLost = false
        /// Nil while the live transcript keeps up.
        var captions: Captions?

        /// Seconds of auto-stop countdown left, while the call app has let go of the mic.
        func autoStopRemaining(at date: Date = Date()) -> TimeInterval? {
            guard let releasedSince, !keepRecording else { return nil }
            return max(0, releaseTimeout - date.timeIntervalSince(releasedSince))
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
        /// Meetings is off: no detector, no model, nothing loaded.
        case off
        case idle
        /// A call app has held the mic for 2 s.
        case offered(MeetingCandidate)
        case recording(Recording)
        /// Recording stopped; the transcript is being finished and speakers sorted out.
        case processing(title: String, meetingID: String)
        case finished(meetingID: String)
        case failed(String)

        /// The call being offered, if any.
        var offeredID: String? { if case .offered(let candidate) = self { candidate.id } else { nil } }

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
    static let unopenedKey = "meetings.unopened"
    /// Legacy list of apps not to ask about; read once into `appPoliciesKey` as Never.
    static let neverAskKey = "meetings.neverAskBundles"
    /// `[bundleID: "ask" | "always" | "never"]`. Apps not listed are Ask.
    static let appPoliciesKey = "meetings.appPolicies"
    /// Bool, default true: show the Sidekick while recording.
    static let showSidekickKey = "meetings.showSidekick"
    /// Bool, default false: the elapsed time beside the menu-bar goblin while recording.
    static let menuBarTimeKey = "meetings.menuBarTime"
    /// How long after the call app lets go of the mic recording stops, once the call audio is quiet too. Zoom and Slack
    /// can let go of it briefly mid-call (a device change, a huddle moving to a window), so they get a minute.
    nonisolated static let releaseTimeout: TimeInterval = 60
    /// The same for a call in a browser tab. Meet keeps the mic while muted and lets go only when you leave, and people
    /// stopped by hand within seconds of leaving rather than wait a minute, so a browser stops after 10 quiet seconds.
    nonisolated static let browserReleaseTimeout: TimeInterval = 10
    static let quietLevel: Float = -50
    /// Live lines kept for the Sidekick's scroll-back; Copy All reads every line.
    static let liveLineLimit = 1_000

    @Published private(set) var phase: Phase = .off {
        didSet {
            // Levels and live lines change the recording many times a second; only a change of kind is logged.
            if phase.name != oldValue.name { logger.notice("phase: \(oldValue.name, privacy: .public) → \(self.phase.name, privacy: .public)") }
            // The offer for that call ended, however it ended: what was heard goes with it.
            if let listening, phase.offeredID != listening.id { discardListening() }
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
    /// The meeting whose Who's this? should open as soon as its page shows, from the popover's Who's This?.
    @Published var askWhoMeetingID: String?
    /// The newest finished meeting nobody has opened yet, for the popover's ready card. Kept across launches, so a
    /// call that finished while the popover was closed still gets its card.
    @Published private(set) var unopenedMeetingID: String? {
        didSet { defaults.set(unopenedMeetingID, forKey: Self.unopenedKey) }
    }
    /// How far the speaker model's one-time download has got (0...1) while processing waits on it; nil otherwise.
    @Published private(set) var speakerModelDownload: Double?
    /// How far the meeting's own speech model has downloaded (0...1), the first time a meeting needs it because
    /// dictation uses another model; nil otherwise.
    @Published private(set) var speechModelDownload: Double?

    /// Remember voices was just turned on and I'm making voiceprints from the meetings already recorded.
    @Published private(set) var learningVoices = false
    /// The people known by voice, refreshed whenever People or a meeting's names change.
    @Published private(set) var people: [Person] = []
    /// Remember voices was turned off but some voiceprints couldn't be deleted; Settings offers Try Again.
    @Published private(set) var voiceCleanupFailure: String?
    /// The last change to People that didn't save, for the People page to say.
    @Published var peopleEditFailure: String?
    /// Learning from the meetings already recorded stopped on an error (the voice model wouldn't download, say);
    /// Settings offers Try Again.
    @Published private(set) var voiceLearningFailure: String?

    /// What processing is doing, for the popover, settings and the meeting's page.
    var processingLine: String { MeetingCopy.processing(download: speakerModelDownload, speechModel: speechModelDownload) }

    /// Whether processing is downloading a model rather than sorting out voices.
    var processingDownloads: Bool { speakerModelDownload != nil || speechModelDownload != nil }

    let library: MeetingLibrary
    /// Notes after each call, and the settings for them.
    private(set) var notes: MeetingNotesModel!
    /// The dictionary's spellings, which notes may correct a misheard name to. Set by the app model.
    var vocabulary: @MainActor () -> [String] = { [] }
    let defaults: UserDefaults
    private let servicesEnabled: Bool
    private let gate: SpeechPriorityGate
    private let speechModels: SpeechModelService
    private let notifications = MeetingNotifications()
    private let logger = Logger(subsystem: "app.goblin.dictation", category: "meetings")
    private var detector: MeetingDetector?
    /// The call the overlay last asked about and when, for the meeting's events.log. Only that call, from that same
    /// stretch on the mic, uses it.
    private var offered: (id: String, since: Date, at: Date)?
    /// Learning voices from the meetings already recorded, after Remember voices was turned on.
    private var voiceLearning: Task<Void, Never>?
    /// Deleting every voiceprint after Remember voices was turned off. Turning it back on waits for this first, so the
    /// deleting can't take away what the new learning writes.
    private var voiceCleanup: Task<Void, Never>?
    private var engine: MeetingSpeechEngine?
    /// The call heard since it was offered, in memory only. Held only while that call's offer is up: any change of
    /// `phase` away from it discards it, and a yes hands it to the recording (`start`). Nothing else holds it.
    private var listening: (id: String, buffer: OfferBuffer)?
    /// The offer's buffer while its recording starts, so a dictation ending meanwhile still reaches it.
    private var accepting: OfferBuffer?
    /// Live lines transcribed while the recording was starting, shown once it has.
    private var earlySegments: [TranscriptSegment] = []
    /// The speech model already said in this recording's events.log, so the offer's announcement isn't said twice.
    private var notedSpeechSource: String?
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
    /// This recording's live speakers, so an update from a recording that already ended is ignored.
    private var liveToken = UUID()
    private var liveSnapshot: LiveSpeakers.Snapshot?
    /// Call-track lines the speaker model hasn't placed yet, and the voice of each line it has.
    private var unplacedSegments: [UUID: TranscriptSegment] = [:]
    private var lineVoices: [UUID: Int] = [:]
    /// Lines said before the audio the speaker model got: they stay Them.
    private var neverPlaced: Set<UUID> = []
    private var liveSpeakersOn = false
    /// The lines Copy New or Copy All has already copied.
    private var copiedLines: Set<UUID> = []
    private var microphoneSoundAt = Date()
    private var pendingInterruption: Interruption?
    private var interruptionDelivery: Task<Void, Never>?
    private var pendingMarkWrite: Task<Void, Never>?
    /// Waits a second after the last keystroke in the Sidekick's notes, then saves them.
    private var typedNotesSave: Task<Void, Never>?
    private var pendingTypedNotesWrite: Task<Void, Never>?
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
        let rememberVoices = DefaultsFlag(defaults, key: Self.rememberVoicesKey)
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
        }, rememberVoices: { rememberVoices.value }, voiceModelDownload: relay.send)
        let people = library.people
        // Names in People read right in every transcript, even meetings they weren't matched in.
        MeetingVocabulary.peopleNames = { rememberVoices.value ? people.people().map(\.name) : [] }
        MeetingDetector.removeLog(unless: defaults.bool(forKey: MeetingStorage.debugLogKey))
        var policies = (defaults.dictionary(forKey: Self.appPoliciesKey) as? [String: String] ?? [:])
            .compactMapValues(AppPolicy.init(rawValue:))
        for bundle in defaults.stringArray(forKey: Self.neverAskKey) ?? [] where policies[bundle] == nil { policies[bundle] = .never }
        appPolicies = policies
        neverAsk = policies.filter { $0.value == .never }.map(\.key).sorted()
        notes = MeetingNotesModel(defaults: defaults, store: library.store, discovers: servicesEnabled, vocabulary: { [weak self] in self?.vocabulary() ?? [] })
        notes.meetingsEnabled = { [weak self] in self?.enabled ?? false }
        unopenedMeetingID = defaults.string(forKey: Self.unopenedKey)
        // Remember voices was turned off but deleting didn't finish (a quit, a failure): finish it now, whether or not
        // Meetings is on, and say so if it still can't.
        if servicesEnabled, !defaults.bool(forKey: Self.rememberVoicesKey) {
            let store = library.store
            // Kept as the pending cleanup, so turning Remember voices on straight away waits for it.
            voiceCleanup = Task { if await store.hasVoiceprints() { await forgetVoices() } }
        }
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
    /// alone. With Meetings off it's always false, so dictation pauses and mutes exactly as it does without Meetings. It
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

    // MARK: Meetings switch

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        refreshSystemAudioPermission()
        defaults.set(on, forKey: Self.enabledKey)
        objectWillChange.send()
        if on {
            logger.notice("meetings turned on")
            activate()
            // Launched with Meetings off, the list was never read: the popover, the status menu and a ready card need it.
            refreshList()
            Task {
                if NotificationAccess.step(for: await notifications.authorizationStatus()) == .request {
                    let granted = await notifications.requestAuthorization()
                    logger.notice("notifications requested when turning on: \(granted ? "allowed" : "not allowed", privacy: .public)")
                }
                await refreshNotificationStatus()
            }
        } else {
            logger.notice("meetings turned off")
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
                // An offer stays up through sleep, but stops listening: a yes after wake records from then.
                self?.discardListening()
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
        resumePendingLearning()
    }

    private func deactivate() async {
        startGeneration += 1
        discardListening()
        // Nothing reads meetings while Meetings is off: learning stops, still pending, and carries on when it's back on.
        voiceLearning?.cancel()
        voiceLearning = nil
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
        // What this call said since its offer goes into the recording; another call's offer is dropped.
        let heard = takeListening(for: candidate)
        accepting = heard
        if case .offered(let offered) = phase { notifications.withdraw(bundleID: offered.id) }
        // A call recorded and then stopped by hand isn't offered again until its app lets go of the mic. Only this
        // call: another app on the mic is asked about once the recording ends.
        offerGate.hold(candidate)
        logger.notice("starting: \(candidate.id, privacy: .public)")
        let generation = startGeneration
        startTask = Task { await begin(.call(candidate), title: title, generation: generation, heard: heard) }
    }

    /// Records the room from the mic alone: people talking around the laptop, with no call. No detection, no
    /// Accessibility probe and no auto-stop; after 10 quiet minutes the overlay asks whether to stop.
    func startConversation() {
        guard canStart else { return }
        starting = true
        discardListening()
        if case .offered(let offered) = phase { notifications.withdraw(bundleID: offered.id) }
        logger.notice("starting: in person")
        let generation = startGeneration
        startTask = Task { await begin(.inPerson, title: nil, generation: generation, heard: nil) }
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
        logger.notice("offer declined: \(candidate.id, privacy: .public)\(neverForThisApp ? ", never for this app" : "", privacy: .public)")
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
        if self.policy(for: bundleID) != policy { logger.notice("policy for \(bundleID, privacy: .public): \(policy.rawValue, privacy: .public)") }
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

    /// Asks the Meetings page to select this meeting; with `askWho`, also to open Who's this? on its first unnamed voice.
    func show(meetingID: String, askWho: Bool = false) {
        focusedMeetingID = meetingID
        if askWho { askWhoMeetingID = meetingID }
        if unopenedMeetingID == meetingID { unopenedMeetingID = nil }
    }

    /// Done with the popover's ready card without opening the meeting.
    func dismissUnopened() { unopenedMeetingID = nil }

    /// The meeting's transcript as Markdown on the clipboard. Returns whether there was one to copy.
    @discardableResult
    func copyTranscript(_ meetingID: String) async -> Bool {
        guard let markdown = try? await library.store.markdown(meetingID) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        return true
    }

    /// The ready chip for `meetingID` was shown: clears that meeting's finished state only. With notes, the chip can
    /// come after another meeting has finished or failed, and that one's state stays until it's seen.
    func acknowledge(meetingID: String) {
        if case .finished(let finished) = phase, finished == meetingID { phase = enabled ? .idle : .off }
    }

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
            logger.notice("notifications are off; opening System Settings")
            openNotificationSettings()
        case .request:
            // An agent app's request is easy to miss unless gob.lin is in front.
            NSApp.activate()
            let granted = await notifications.requestAuthorization()
            logger.notice("notifications requested: \(granted ? "allowed" : "not allowed", privacy: .public)")
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
            refreshPeople()
        }
    }

    // MARK: Remember voices

    static let rememberVoicesKey = "meetings.rememberVoices"
    /// Set while learning from the meetings already recorded hasn't finished, so a quit doesn't leave it half done.
    static let learningPendingKey = "meetings.learningVoicesPending"

    /// Keep voice samples on this Mac and name people from them. Off by default: a voiceprint identifies someone.
    var rememberVoices: Bool { defaults.bool(forKey: Self.rememberVoicesKey) }

    /// Turning it on learns from the meetings already recorded; turning it off forgets every voice.
    func setRememberVoices(_ on: Bool) {
        guard on != rememberVoices else { return }
        objectWillChange.send()
        defaults.set(on, forKey: Self.rememberVoicesKey)
        logger.notice("remember voices \(on ? "on" : "off", privacy: .public)")
        let store = library.store
        if on {
            voiceCleanupFailure = nil
            learnFromRecordedMeetings()
        } else {
            defaults.removeObject(forKey: Self.learningPendingKey)
            // Learning still running stops first, so it can't write voiceprints back after they're deleted.
            let learning = voiceLearning
            learning?.cancel()
            voiceLearning = nil
            voiceCleanup = Task {
                await learning?.value
                await forgetVoices()
            }
        }
    }

    /// Learning from the meetings already recorded was cut short (a quit, a crash, Meetings turned off): carry on once
    /// launch repair is done. Only while Meetings is on.
    private func resumePendingLearning() {
        guard servicesEnabled, enabled, rememberVoices, defaults.bool(forKey: Self.learningPendingKey) else { return }
        Task { [weak self] in
            await self?.leftovers?.value
            guard let self, self.enabled else { return }
            self.learnFromRecordedMeetings()
        }
    }

    /// Learns voices from the meetings already recorded, after any pending cleanup. Try Again after a failure runs it again
    /// without forgetting what's already learned.
    func learnFromRecordedMeetings() {
        guard rememberVoices, voiceLearning == nil || !learningVoices else { return }
        let store = library.store, cleanup = voiceCleanup
        voiceLearningFailure = nil
        learningVoices = true
        defaults.set(true, forKey: Self.learningPendingKey)
        voiceLearning = Task {
            await cleanup?.value
            guard !Task.isCancelled else { learningVoices = false; return }
            let work = Task.detached(priority: .utility) { () -> Result<Int, Error> in
                do { return .success(try await store.learnVoices()) } catch { return .failure(error) }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            learningVoices = false
            switch result {
            case .success(let named):
                logger.notice("learned voices: \(named, privacy: .public) named")
                defaults.removeObject(forKey: Self.learningPendingKey)
            case .failure(let error) where error is CancellationError || Task.isCancelled: logger.notice("learning voices stopped")
            case .failure(let error):
                logger.error("learning voices failed: \(error.localizedDescription, privacy: .private)")
                voiceLearningFailure = error.localizedDescription
            }
            refreshList()
            NotificationCenter.default.post(name: .meetingsEdited, object: nil)
        }
    }

    /// Deletes every voiceprint; a failure stays in Settings with Try Again until it works.
    func forgetVoices() async {
        do {
            try await library.store.forgetVoices()
            voiceCleanupFailure = nil
        } catch {
            logger.error("couldn't forget voices: \(error.localizedDescription, privacy: .private)")
            voiceCleanupFailure = error.localizedDescription
        }
        refreshList()
    }

    func refreshPeople() {
        let list = library.people.people()
        if list != people { people = list }
    }

    /// Runs a People edit, then refreshes everything that shows names.
    func editPeople(_ change: (PeopleStore) throws -> Void) {
        do {
            try change(library.people)
            peopleEditFailure = nil
        } catch {
            logger.error("couldn't change People: \(error.localizedDescription, privacy: .private)")
            peopleEditFailure = error.localizedDescription
        }
        refreshPeople()
        NotificationCenter.default.post(name: .meetingsEdited, object: nil)
    }

    // MARK: Screenshots

    /// For `scripts/capture-settings.sh`: the popover's ready card for a synthetic meeting. Ignored in the running app.
    func previewUnopened(_ meetingID: String?) {
        guard !servicesEnabled else { return }
        unopenedMeetingID = meetingID
    }

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

    // MARK: Your notes

    /// What the person typed in the expanded Sidekick during this recording.
    @Published private(set) var typedNotes = ""

    /// The expanded Sidekick's notes field, on every edit.
    func setTypedNotes(_ text: String) {
        guard text != typedNotes else { return }
        typedNotes = text
        guard case .recording = phase, session != nil else { return }
        typedNotesSave?.cancel()
        typedNotesSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveTypedNotes()
        }
    }

    /// Saves the current notes now, pending or not, so Stop and Quit leave the latest in the folder even when an
    /// earlier autosave failed.
    private func flushTypedNotes() {
        guard session != nil else { return }
        saveTypedNotes()
    }

    /// Rewrites `typed-notes.md` off the main thread, in order, like `saveMarks`. The text itself is never logged.
    private func saveTypedNotes() {
        typedNotesSave?.cancel()
        typedNotesSave = nil
        guard let directory = session?.directory else { return }
        let text = typedNotes, previous = pendingTypedNotesWrite, logger = logger
        pendingTypedNotesWrite = Task.detached(priority: .utility) {
            await previous?.value
            do { try MeetingTypedNotes.write(text, to: directory) }
            catch { logger.error("couldn't save typed notes: \(error.localizedDescription, privacy: .private)") }
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

    /// A dictation take started; `began` is its key-down. Meeting chunks wait until it ends. `recordsSpan` false is for
    /// work that isn't someone speaking, such as re-transcribing a History entry: chunks wait, but nothing is left out.
    func dictationBegan(_ id: UUID, at began: Date = Date(), recordsSpan: Bool = true) {
        gate.beginForeground(id)
        guard recordsSpan else { return }
        takes[id] = (began, nil)
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
        } else if session == nil, let heard = listening?.buffer ?? accepting {
            // During an offer: kept with what was heard, and left out of the recording too if it's a yes.
            heard.noteDictation(start: take.began, end: take.captureEnded ?? Date())
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
        logger.notice("dictation began during a meeting chunk and was behind it for \(milliseconds, format: .fixed(precision: 1)) ms")
        session?.note(String(format: "a dictation began during a meeting chunk; it was behind it for %.1f ms", milliseconds))
    }

    // MARK: Recording

    private enum Source {
        case call(MeetingCandidate), inPerson
    }

    /// `heard` is the call's offer buffer, when it was listening: its audio, mute changes and dictations open the
    /// recording. On every way out it's discarded, which after a hand-off leaves alone what the session now owns.
    private func begin(_ source: Source, title override: String?, generation: Int, heard: OfferBuffer?) async {
        let acceptedAt = Date()
        defer {
            starting = false
            heard?.discard()
            if accepting === heard { accepting = nil }
            earlySegments = []
        }
        guard generation == startGeneration else { return }
        let target: SystemAudioTarget
        let title: String, appName: String
        var candidate: MeetingCandidate?
        switch source {
        case .call(let call):
            candidate = call
            target = Self.target(for: call)
            title = override ?? call.meetingTitle.map(MeetingDetector.cleanTitle) ?? call.app.name
            appName = call.app.name
        case .inPerson:
            target = .none
            title = override ?? "Conversation"
            appName = "In person"
        }
        let engine = speechEngine()
        let token = UUID()
        liveToken = token
        liveSnapshot = nil
        unplacedSegments = [:]
        lineVoices = [:]
        neverPlaced = []
        liveSpeakersOn = target != .none
        // A call's voices are told apart as it records; in the room they're sorted out after Stop.
        let live = target == .none ? nil : LiveSpeakers(voices: library.voices, log: { [logger] message in
            logger.notice("\(message, privacy: .private)")
        }, onUpdate: { [weak self] snapshot in Task { @MainActor in self?.placeSpeakers(snapshot, token: token) } })
        live?.start()
        let session: MeetingSession
        // Dictation's language, as the meeting's Parakeet takes it; one it doesn't know falls back to detection.
        let recognition = SpeechModelCatalog.parakeet.capabilities.options(for: speechModels.preferredLanguage)
        do {
            session = try MeetingSession(title: title, source: appName, target: target, cancelsEchoLive: true, engine: engine,
                recognition: recognition, defaults: defaults, liveSpeakers: live,
                onSegment: { [weak self] segment in Task { @MainActor in self?.append(segment) } },
                onEvent: { _ in },
                onProblem: { [weak self] problem in Task { @MainActor in self?.sessionReported(problem) } })
        } catch {
            live?.stop()
            logger.error("couldn't start: no folder: \(error.localizedDescription, privacy: .private)")
            phase = .failed("I couldn't make a folder for the recording: \(error.localizedDescription)")
            return
        }
        do {
            try await session.start(handingOver: heard)
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
            logger.notice("start abandoned: meetings turned off or quitting")
            return
        }
        self.session = session
        live?.record(in: session.directory)
        // A take that ran through the last meeting's Stop is left out of this one too, when it ends.
        takesRecorded = []
        dictatedSpans = []
        // Takes that ended while the offer was up, on the recording's clock now that it starts where the offer did.
        for take in heard?.dictations ?? [] {
            session.recordDictation(start: take.start, end: take.end)
            if let span = Self.span(take.start, take.end, from: session.startedAt) { dictatedSpans.append(span) }
        }
        notedSpeechSource = nil
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
            if let heardProbe = heard?.claimProbe(pid: pid) {
                // Reading since the offer: its mute changes move onto the recording's clock.
                heardProbe.attach(directory: session.directory, sessionStart: session.startedAt, rawLog: debugLogging)
                self.probe = heardProbe
            } else {
                let probe = AccessibilityProbe(pid: pid, app: call, directory: session.directory, sessionStart: session.startedAt,
                                               rawLog: debugLogging)
                probe.start()
                self.probe = probe
            }
        }
        unrecordedCall = nil
        sidekickVisible = showSidekick
        typedNotesSave?.cancel()
        typedNotesSave = nil
        typedNotes = ""
        if target != .none { refreshSystemAudioPermission() }
        var recording = Recording(title: title, app: appName, bundleID: candidate?.app.bundleID, startedAt: session.startedAt)
        recording.meetingID = folder
        recording.inPerson = target == .none
        if candidate?.app.callApp?.kind == .browser { recording.releaseTimeout = Self.browserReleaseTimeout }
        if let candidate {
            let askedAt = offered.flatMap { $0.id == candidate.id && $0.since == candidate.since ? $0.at : nil }
            session.note(Self.startNote(candidate, offeredAt: askedAt, acceptedAt: acceptedAt, startedAt: session.startedAt))
        }
        offered = nil
        recording.dictating = speaking
        phase = .recording(recording)
        // The offer may have loaded the model before this recording existed, with nowhere to say so.
        Task { [weak self] in
            if let source = await engine.announced { self?.noteSpeechSource(source, in: session) }
        }
        // The heard stretch can be transcribed before the phase changes.
        let early = earlySegments
        earlySegments = []
        for segment in early { append(segment) }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshList()
    }

    /// Which mic meetings record, remembered; the Sidekick's mic menu sets it, and the recording follows within a second.
    var meetingMicrophone: MeetingMicrophonePreference {
        get { .load(defaults) }
        set { newValue.save(defaults) }
    }

    private func speechEngine() -> MeetingSpeechEngine {
        if let engine { return engine }
        let engine = MeetingSpeechEngine(gate: gate, dictationEngine: { [speechModels] in
            try await speechModels.backgroundEngine()
        }, onSource: { [weak self] source in
            Task { @MainActor in if let self, let session = self.session { self.noteSpeechSource(source, in: session) } }
        }, onDownload: { [weak self] fraction in
            Task { @MainActor in if self?.speechModelDownload != fraction { self?.speechModelDownload = fraction } }
        })
        self.engine = engine
        return engine
    }

    /// Which speech model the live transcript uses, in session.json and once in events.log.
    private func noteSpeechSource(_ source: String, in session: MeetingSession) {
        guard session === self.session, source != notedSpeechSource else { return }
        notedSpeechSource = source
        session.annotate { $0.speechModel = source }
        session.note("speech model: \(source)")
    }

    /// The system audio a call records: its app and helpers, followed across restarts by bundle ID.
    private static func target(for call: MeetingCandidate) -> SystemAudioTarget {
        let app = call.app
        let bundles = Set(app.processes.compactMap(\.bundleID) + [app.bundleID]).filter { !$0.hasPrefix("pid:") }
        return .app(bundleIDs: Array(bundles), processes: app.processes.map(\.objectID))
    }

    /// From the moment a call is offered, hear it into memory, so a yes keeps how the call began; only with both
    /// permissions granted already, since an offer must never raise a prompt. The mute state is read and the speech
    /// model loaded from then too. Nothing of it reaches disk unless the offer is accepted.
    private func listen(to candidate: MeetingCandidate) {
        discardListening()
        guard OfferBuffer.permitted else { return }
        let probe = candidate.app.pid.flatMap { pid in
            candidate.app.callApp.map { AccessibilityProbe(pid: pid, app: $0, directory: nil, sessionStart: Date()) }
        }
        let buffer = OfferBuffer(microphone: MicrophoneCapture(call: Self.target(for: candidate), defaults: defaults),
                                 system: SystemAudioTap(target: Self.target(for: candidate)),
                                 probe: probe, engine: speechEngine())
        listening = (candidate.id, buffer)
        buffer.start()
    }

    /// Takes the offer's buffer for a recording of `candidate`; a buffer for any other call is discarded.
    private func takeListening(for candidate: MeetingCandidate) -> OfferBuffer? {
        guard let listening else { return nil }
        self.listening = nil
        if listening.id == candidate.id { return listening.buffer }
        listening.buffer.discard()
        return nil
    }

    /// Stops listening to an offered call and drops all of it. With nothing recording or starting, the meeting's own
    /// speech model goes too, as after a recording; dictation's is never unloaded from here.
    private func discardListening() {
        guard let listening else { return }
        self.listening = nil
        listening.buffer.discard()
        if session == nil, !starting, stopping == nil, let engine { Task { await engine.unload() } }
    }

    private func append(_ segment: TranscriptSegment) {
        guard case .recording(var recording) = phase, let session else {
            // A starting recording's first lines, from what was heard before the yes: shown once it's recording.
            if starting { earlySegments.append(segment) }
            return
        }
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
        var speaker = recording.inPerson ? "" : segment.track == .microphone ? "You" : "Them"
        var placing = false
        if segment.track == .system, liveSpeakersOn {
            switch liveSnapshot.map({ LiveSpeakers.placement(of: segment, in: $0) }) ?? .waiting {
            case .voice(let voice):
                lineVoices[segment.id] = voice
                speaker = liveSnapshot.flatMap { liveNames($0)[voice] } ?? speaker
            case .never: neverPlaced.insert(segment.id)
            case .waiting:
                unplacedSegments[segment.id] = segment
                placing = true
            }
        }
        let line = MeetingLine(id: segment.id, speaker: speaker, start: segment.start, text: segment.text, placing: placing)
        if !placing, !recording.voiceOrder.contains(speaker) { recording.voiceOrder.append(speaker) }
        // The two tracks' chunks decode independently, so a line can arrive after a later one.
        transcriptLines.insert(line, byStart: \.start)
        recording.lines.insert(line, byStart: \.start)
        // The speech model runs again; what it missed is still left for after the call.
        if recording.captions == .failing { recording.captions = .behind }
        if recording.lines.count > Self.liveLineLimit { recording.lines.removeFirst(recording.lines.count - Self.liveLineLimit) }
        phase = .recording(recording)
    }

    /// A snapshot's names as they may be shown now: with Remember voices turned off since it was sent, only "Speaker N".
    private func liveNames(_ snapshot: LiveSpeakers.Snapshot) -> [Int: String] {
        library.voices.enabled() ? snapshot.names : snapshot.numbered
    }

    /// The speaker model placed more of the call: lines it reached get their voice, and a voice named from People
    /// renames its earlier lines too.
    private func placeSpeakers(_ snapshot: LiveSpeakers.Snapshot, token: UUID) {
        guard token == liveToken, case .recording(var recording) = phase else { return }
        liveSnapshot = snapshot
        for (id, segment) in unplacedSegments {
            switch LiveSpeakers.placement(of: segment, in: snapshot) {
            case .waiting: continue
            case .voice(let voice): lineVoices[id] = voice
            case .never: neverPlaced.insert(id)
            }
            unplacedSegments[id] = nil
        }
        let lineVoices = lineVoices, neverPlaced = neverPlaced, names = liveNames(snapshot)
        func named(_ line: MeetingLine) -> MeetingLine {
            var line = line
            if let voice = lineVoices[line.id], let name = names[voice] {
                line.speaker = name
                line.placing = false
            } else if neverPlaced.contains(line.id) {
                line.placing = false
            }
            return line
        }
        recording.lines = recording.lines.map(named)
        transcriptLines = transcriptLines.map(named)
        for line in recording.lines where !line.placing && !recording.voiceOrder.contains(line.speaker) {
            recording.voiceOrder.append(line.speaker)
        }
        recording.namesLive = true
        phase = .recording(recording)
    }

    /// The session's capture dropped out or came back, or the live transcript left speech for after the call.
    private func sessionReported(_ problem: MeetingSessionProblem) {
        guard case .recording(var recording) = phase else { return }
        switch problem {
        case .capture(.microphoneLost): recording.microphoneLost = true
        case .capture(.microphoneRestored): recording.microphoneLost = false
        case .capture(.microphoneSilence(let silence)): recording.microphoneSilence = silence
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
            logger.notice("recording: mic \(recording.microphoneLost ? "lost" : "ok", privacy: .public), call sound \(recording.systemAudioLost ? "lost" : "ok", privacy: .public), captions \(String(describing: recording.captions), privacy: .public)")
            phase = .recording(recording)
        }
    }

    private func tick() {
        guard case .recording(var recording) = phase, let session else { return }
        let levels = session.levels
        recording.microphoneLevel = levels.microphone
        recording.systemLevel = levels.system
        recording.backlog = session.backlog
        recording.microphone = session.microphoneInUse
        let trouble = session.captureTrouble
        recording.microphoneLost = trouble.microphoneLost
        recording.microphoneSilence = trouble.microphoneSilence
        recording.systemAudioLost = trouble.systemAudioLost
        recording.muted = probe?.isMuted
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
                  now.timeIntervalSince(released) >= recording.releaseTimeout,
                  now.timeIntervalSince(systemSoundAt) >= min(10, recording.releaseTimeout) {
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
        logger.notice("took back \(muted.count, privacy: .public) live mic lines said while muted")
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
            offered = (candidate.id, candidate.since, Date())
            unrecordedCall = candidate
            listen(to: candidate)
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
                logger.notice("offer withdrawn: \(candidate.id, privacy: .public) let go of the mic")
                phase = .idle
            }
        case .recording(var recording):
            guard let bundle = recording.bundleID else { return }
            let holding = detector.apps.first { $0.bundleID == bundle }?.isUsingMicrophone ?? false
            if holding, recording.releasedSince != nil {
                recording.releasedSince = nil
                recording.keepRecording = false
                session?.note("\(bundle) took the mic back")
                logger.notice("\(bundle, privacy: .public) took the mic back; auto-stop cancelled")
            } else if !holding, recording.releasedSince == nil {
                recording.releasedSince = Date()
                session?.note("\(bundle) released the mic")
                logger.notice("\(bundle, privacy: .public) released the mic; stopping in \(Int(recording.releaseTimeout), privacy: .public) s once the call is quiet")
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
        if !line.isEmpty { logger.notice("offer: \(line, privacy: .public)") }
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
        logger.notice("stopping: \(reason, privacy: .public) after \(Int(Date().timeIntervalSince(recording.startedAt)), privacy: .public) s, \(recording.marks.count, privacy: .public) marks")
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
        flushTypedNotes()
        let marks = pendingMarkWrite, typedNotesWrite = pendingTypedNotesWrite
        stopping = Task {
            _ = await session.stop()
            await marks?.value
            await typedNotesWrite?.value
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
            if let failure { logger.error("meeting processing failed: \(failure, privacy: .private)") }
            else { logger.notice("processing done: \(id, privacy: .private)") }
            refreshList()
            guard failure == nil else { return }
            // The popover's ready card as soon as the transcript is there; the notes fill in its title when they come.
            unopenedMeetingID = id
            // Notes on their own task, so the next meeting's processing doesn't wait for a model; the ready chip waits
            // for them, so it has the title they found.
            Task { [weak self] in
                guard let self else { return }
                if await self.notes.afterProcessing(id, allowed: { [weak self] in self.map { $0.enabled && !$0.shuttingDown } ?? false }) { self.refreshList() }
                guard !self.shuttingDown, let summary = try? await store.summary(id) else { return }
                self.readyNotice = ReadyNotice(meetingID: id, title: summary.title, duration: summary.duration,
                                               voicesToName: summary.speakers.filter(Self.isUnnamedVoice).count)
            }
        }
    }

    /// The first line of a call's events.log: when its app took the mic, when I asked, when the person answered, and
    /// where the recording's timeline begins, so a transcript that starts late says whether the person joined late or
    /// answered late. Heard from the offer, the recording begins about when I asked, however late the answer.
    nonisolated static func startNote(_ candidate: MeetingCandidate, offeredAt: Date?, acceptedAt: Date, startedAt: Date) -> String {
        let clock = ISO8601DateFormatter()
        var parts = ["\(candidate.id) took the mic at \(clock.string(from: candidate.since))"]
        if let offeredAt, offeredAt >= candidate.since {
            parts.append(String(format: "asked %.0f s later", offeredAt.timeIntervalSince(candidate.since)))
            parts.append(String(format: "answered %.0f s after asking", acceptedAt.timeIntervalSince(offeredAt)))
            parts.append(String(format: "recording began %.0f s after asking", startedAt.timeIntervalSince(offeredAt)))
        } else {
            parts.append(String(format: "recording began %.0f s later without asking", startedAt.timeIntervalSince(candidate.since)))
        }
        return parts.joined(separator: "; ")
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
            let repaired = await store.repairUnfinished { message in logger.notice("\(message, privacy: .private)") }
            let removed = await store.applyRetention()
            if !repaired.isEmpty || !removed.isEmpty { refreshList() }
            // The ready card first, as after Stop; notes follow.
            await announceRepaired(repaired, store: store)
            // Meetings finished now, after a quit or crash, get their notes as they would have after Stop. Only those
            // that processed: the repaired list includes failed attempts.
            for id in repaired where (try? await store.summary(id))?.state == .ready {
                guard !Task.isCancelled else { return }
                if await notes.afterProcessing(id, allowed: { [weak self] in self.map { $0.enabled && !$0.shuttingDown } ?? false }) {
                    refreshList()
                }
            }
        }
    }

    /// A meeting finished at launch, after a quit or crash cut it short, gets the ready card like any other, unless a
    /// newer meeting already has it.
    private func announceRepaired(_ ids: [String], store: MeetingStore) async {
        var newest: MeetingSummary?
        for id in ids {
            guard let summary = try? await store.summary(id), summary.state == .ready else { continue }
            if summary.startedAt > (newest?.startedAt ?? .distantPast) { newest = summary }
        }
        guard let newest else { return }
        if let current = unopenedMeetingID, let shown = try? await store.summary(current), shown.startedAt >= newest.startedAt { return }
        unopenedMeetingID = newest.id
    }

    /// The ready card's meeting while the card can show: nothing more urgent holds the popover's meeting module and the
    /// meeting is finished. The recent-meetings list leaves out only this one.
    var visibleUnopenedMeeting: MeetingSummary? {
        guard enabled, let id = unopenedMeetingID else { return nil }
        switch phase {
        case .recording, .processing, .failed: return nil
        default: return meetings.first { $0.id == id && $0.state == .ready }
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
        discardListening()
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
        flushTypedNotes()
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
        await pendingTypedNotesWrite?.value
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
/// A Bool in UserDefaults read from background work. UserDefaults is thread-safe; it just isn't marked Sendable.
private final class DefaultsFlag: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(_ defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    var value: Bool { defaults.bool(forKey: key) }
}

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
        // The speaker model, the echo canceller or the voice model, alone or together: no one size is right for all.
        return "Downloading what I need to sort out who said what, just this once (\(Int(download * 100))%)…"
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
        if let silence = recording.microphoneSilence {
            let mic = recording.microphone?.device.name ?? "Your mic"
            let whom = recording.inPerson ? "the room" : "you"
            return switch silence {
            case .muted: "\(mic) is muted, so I can't hear \(whom)."
            case .volumeAtZero: "\(mic)'s input volume is at zero, so I can't hear \(whom)."
            case .silent: "\(mic) is sending only silence, so I can't hear \(whom)."
            }
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
