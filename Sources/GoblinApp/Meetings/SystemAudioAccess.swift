import AppKit
import Foundation
import GoblinMeetings

/// System Audio Recording (the TCC audio-capture service a process tap needs), for Settings and the setup sheet. It
/// reads `SystemAudioPermission`; when TCC can't be reached the status is unknown and nothing is blocked.
@MainActor final class SystemAudioAccess: ObservableObject {
    enum Status { case granted, denied, unknown }

    /// The setup sheet's two switches, both on until the person says otherwise.
    struct SetupChoices: Hashable, Identifiable {
        var writeNotes = true
        var rememberVoices = true
        var id: Self { self }
    }

    static let shared = SystemAudioAccess()
    /// Set when gob.lin quits partway through Meetings setup, so the next launch opens the setup sheet again. It
    /// holds the sheet's switches as they stood, so one the person turned off doesn't come back on.
    private static let resumeSetupKey = "meetings.resumeSetup"

    @Published private(set) var status: Status = .unknown
    /// System Settings was opened for this and gob.lin came forward again still without access. The switch may
    /// already be on: macOS applies one changed in System Settings only to an app opened afterwards. Captures set it.
    @Published var needsReopen = false
    /// Previews and captures set this, since they can't ask TCC for the real answer.
    var override: Status? { didSet { refresh() } }
    /// The setup sheet's switches while it is up, when a quit after opening System Settings is most likely macOS's
    /// Quit & Reopen. Nil otherwise.
    var setupChoices: SetupChoices?
    /// The last run quit that way. Read once at launch, so a sheet that never gets to open again isn't owed later.
    private(set) var resumeSetup: SetupChoices?

    /// False when TCC can't be asked at all, so an unknown status means "can't tell" rather than "not asked yet".
    var checkable: Bool { override != nil || SystemAudioPermission.checkable }

    /// System Settings has been opened for this while the setup sheet has been up.
    @Published private(set) var settingsOpened = false
    private var asking = false

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.resumeSetupKey) as? [String: Bool] {
            resumeSetup = SetupChoices(writeNotes: saved["writeNotes"] ?? false, rememberVoices: saved["rememberVoices"] ?? false)
        }
        UserDefaults.standard.removeObject(forKey: Self.resumeSetupKey)
        refresh()
    }

    func refresh() {
        let next = override ?? {
            switch SystemAudioPermission.current {
            case .allowed: .granted
            case .denied: .denied
            case .unknown: .unknown
            }
        }()
        if next != status { status = next }
        if next == .granted { needsReopen = false }
    }

    /// gob.lin came forward again, such as back from System Settings.
    func cameForward() {
        refresh()
        if status != .granted, settingsOpened { needsReopen = true }
    }

    /// Shows macOS's own prompt, which only appears once a process tap starts running (asking TCC directly showed
    /// nothing on a real Mac). The tap runs while the person answers, delivering nowhere, and stops when the task is
    /// cancelled. System Settings opens at the right pane when macOS won't ask: access was turned down, now or
    /// before, it can't be read at all, or the tap wouldn't start. Asking again while the prompt is up opens System
    /// Settings too.
    func request() async {
        refresh()
        guard status != .granted else { return }
        guard status != .denied, !asking else { return openSettings() }
        asking = true
        defer { asking = false }
        let tap = SystemAudioTap(target: .everything)
        if (try? tap.start(onEvent: { _ in }, handler: { _ in })) != nil {
            defer { tap.stop() }
            // With a readable status the tap waits for the answer however long it takes, since Allow pressed after
            // the tap has gone does nothing. Without one there is nothing to wait for beyond the prompt showing.
            let deadline = ContinuousClock.now + .seconds(20)
            while status == .unknown, checkable || ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                refresh()
            }
        } else if SystemAudioPermission.canRequest {
            _ = await SystemAudioPermission.request()
            refresh()
        }
        guard !Task.isCancelled else { return }
        if status != .granted { openSettings() }
    }

    func openSettings() {
        settingsOpened = true
        NSWorkspace.shared.open(SystemAudioPermission.settingsURL)
    }

    /// Called as gob.lin quits. Partway through setup with System Settings opened, the quit is most likely macOS's
    /// Quit & Reopen or the sheet's Reopen, so the next launch goes back to the sheet.
    func rememberSetupForNextLaunch() {
        guard let setupChoices, settingsOpened, status != .granted else { return }
        UserDefaults.standard.set(["writeNotes": setupChoices.writeNotes, "rememberVoices": setupChoices.rememberVoices],
                                  forKey: Self.resumeSetupKey)
    }

    /// The switches to reopen the sheet with, once, on the launch after `rememberSetupForNextLaunch` saved them.
    func takeResumeSetup() -> SetupChoices? {
        defer { resumeSetup = nil }
        return resumeSetup
    }

    /// The setup sheet has gone. The next one starts over from asking macOS, not from this one's trip to System
    /// Settings.
    func leftSetup() {
        setupChoices = nil
        settingsOpened = false
        // A capture sets this itself for its next sheet, before the one it has finished with goes.
        if override == nil { needsReopen = false }
    }
}

/// Opens gob.lin again once this copy has quit, for a permission macOS only applies to a newly opened app.
@MainActor enum Relaunch {
    private static var requested = false

    /// Quits, then opens gob.lin again. The quit starts the helper itself, once the person has agreed to any
    /// unsaved data going.
    static func now() {
        requested = true
        UpdateChecker.requestTermination()
    }

    /// Whether this quit is to reopen gob.lin. True once per `now()`.
    static func takeRequest() -> Bool {
        defer { requested = false }
        return requested
    }

    /// Starts the helper. False when it wouldn't start, and then gob.lin shouldn't quit.
    static func start() -> Bool {
        let bundle = Bundle.main.bundleURL
        // A helper waits for this process to go, at most 30 s in case it never does, then opens it.
        let open = bundle.pathExtension == "app" ? "/usr/bin/open \"$1\"" : "\"$1\" &"
        let target = bundle.pathExtension == "app" ? bundle.path : (Bundle.main.executablePath ?? bundle.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while /bin/kill -0 \"$0\" 2>/dev/null && [ $i -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; "
                                + "/bin/kill -0 \"$0\" 2>/dev/null || \(open)",
                             String(ProcessInfo.processInfo.processIdentifier), target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
