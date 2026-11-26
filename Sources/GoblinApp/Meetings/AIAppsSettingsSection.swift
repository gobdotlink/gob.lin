import AppKit
import GoblinMeetings
import SwiftUI

/// Whether Claude Code, Codex (with ChatGPT for Mac) and the Claude app have gob.lin's meetings server, and adding or
/// removing it.
@MainActor
final class AIAppsModel: ObservableObject {
    struct Failure: Equatable {
        var app: AIApp
        var connecting: Bool
        var message: String
    }

    @Published private(set) var states: [AIApp: AIAppConnectionState] = [:]
    @Published private(set) var busy: Set<AIApp> = []
    @Published private(set) var failure: Failure?
    /// The Claude processes that were running when its settings changed. Claude reads them at launch, so until those
    /// quit, a connection isn't used yet and a disconnected session can still read.
    @Published private(set) var claudeSessions: Set<pid_t> = []
    var claudeNeedsReopen: Bool { !claudeSessions.isEmpty }

    let command: [String]
    /// Off for previews and captures, which show set states instead of this Mac's.
    private var discovers = true

    init(executable: URL? = Bundle.main.executableURL) {
        command = AIAppConnections.serverCommand(executable: (executable ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath())
    }

    func usePreview(_ states: [AIApp: AIAppConnectionState], failure: Failure? = nil) {
        discovers = false
        self.states = states
        self.failure = failure
    }

    func refresh() async {
        guard discovers else { return }
        let command = command
        await withTaskGroup(of: (AIApp, AIAppConnectionState).self) { group in
            for app in AIApp.allCases where !busy.contains(app) {
                group.addTask { (app, await AIAppConnections.state(app, command: command)) }
            }
            for await (app, state) in group { states[app] = state }
        }
        claudeSessions = claudeSessions.filter { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
        // Put right elsewhere (in the app, or by hand) since it failed here.
        if let failure, let state = states[failure.app], failure.connecting ? state == .connected : !state.isRegistered { self.failure = nil }
    }

    func connect(_ app: AIApp) { change(app, connecting: true) }
    func disconnect(_ app: AIApp) { change(app, connecting: false) }

    private func change(_ app: AIApp, connecting: Bool) {
        guard discovers, !busy.contains(app) else { return }
        busy.insert(app)
        failure = nil
        let command = command
        Task {
            do {
                if connecting { try await AIAppConnections.connect(app, command: command) } else { try await AIAppConnections.disconnect(app) }
                if app == .claudeDesktop {
                    claudeSessions.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "").map(\.processIdentifier))
                }
            } catch {
                failure = Failure(app: app, connecting: connecting, message: error.localizedDescription)
            }
            states[app] = await AIAppConnections.state(app, command: command)
            busy.remove(app)
        }
    }
}

/// Settings › Meeting Recording › AI apps.
struct AIAppsSettingsSection: View {
    @ObservedObject var model: AIAppsModel

    var body: some View {
        Section {
            ForEach(AIApp.allCases) { app in
                LabeledContent {
                    control(app)
                } label: {
                    HStack(spacing: 8) {
                        AppIcon(bundleIdentifier: app.bundleIdentifier, size: 18, symbol: "terminal")
                        Text(app.title)
                    }
                    Text(line(app)).rowDetail()
                    if app == .codex { Text("Codex, the Codex app and ChatGPT for Mac share one setting, so this connects all three.") }
                }
            }
            statusRow
        } header: { CapsHeader("AI apps") } footer: {
            Text("Connecting adds gob.lin to the app's MCP servers; Copy Command lets you add it to another app yourself. An app with gob.lin added can list your meetings, search what was said, and read transcripts and notes whenever it chooses, usually when you ask about a meeting, and what it reads goes to its maker under your own plan. It can't record, change or delete anything, never gets the audio, and gets no meeting data while Meetings is off. Disconnect takes gob.lin out of the app's settings; quit the app to end a session it already started.")
        }
        .task { await model.refresh() }
        // Back from the app or Terminal: see whether it was connected or removed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder private func control(_ app: AIApp) -> some View {
        if model.busy.contains(app) {
            ProgressView().controlSize(.small).accessibilityLabel("Changing \(app.title)")
        } else {
            switch model.states[app] {
            case .connected?: Button("Disconnect") { model.disconnect(app) }
            case .connectedElsewhere?, .disabled?:
                HStack(spacing: 8) {
                    Button("Disconnect") { model.disconnect(app) }
                    Button("Connect") { model.connect(app) }
                }
            case .notConnected?: Button("Connect") { model.connect(app) }
            case .notInstalled?, nil: Button("Connect") {}.disabled(true)
            }
        }
    }

    private func line(_ app: AIApp) -> String {
        switch model.states[app] {
        case nil: return "Looking…"
        case .notInstalled?: return "Not installed on this Mac."
        case .notConnected?:
            if app == .claudeDesktop && model.claudeNeedsReopen { return "Disconnected. Quit Claude to end any session it may still have." }
            return "Not connected. Once it is, what it reads goes to \(app.company)."
        case .disabled?: return "Added, but turned off in Codex. Connect turns it back on."
        case .connectedElsewhere(let path)?:
            if FileManager.default.fileExists(atPath: path) { return "Connected to another copy of gob.lin. Connect points it at this one." }
            return "Set up for a copy of gob.lin that's gone. Connect points it at this one."
        case .connected?:
            if app == .claudeDesktop && model.claudeNeedsReopen { return "Connected. Quit and reopen Claude to use it." }
            return "Connected. It can search and read your meetings."
        }
    }

    @ViewBuilder private var statusRow: some View {
        // Only entries that can start a server: another copy that's gone can't.
        let connected = AIApp.allCases.filter { app in
            switch model.states[app] {
            // Claude connected while it was open can't read until it's reopened.
            case .connected?: !(app == .claudeDesktop && model.claudeNeedsReopen)
            case .connectedElsewhere(let path)?: FileManager.default.fileExists(atPath: path)
            default: false
            }
        }
        if model.states.isEmpty {
            StatusRow(.off, Text("Looking for AI apps…")) { copyButton }
        } else if let failure = model.failure {
            StatusRow(.problem, Text("I couldn't \(failure.connecting ? "connect" : "disconnect") \(failure.app.title). \(failure.message)")) { copyButton }
        } else if connected.isEmpty {
            StatusRow(model.claudeNeedsReopen ? .waiting : .off,
                      Text(model.claudeNeedsReopen
                           ? (model.states[.claudeDesktop]?.isRegistered == true ? "Quit and reopen Claude to use the connection."
                                                                                 : "No AI app is connected. Quit Claude to end any session it may still have.")
                           : "No AI app can read your meetings.")) { copyButton }
        } else {
            StatusRow(.ready, Text("\(ListFormatter.localizedString(byJoining: connected.map(\.title))) can read your meetings, never change them."
                                   + claudeReopen)) { copyButton }
        }
    }

    /// Claude changed while it was open: what reopening it does.
    private var claudeReopen: String {
        guard model.claudeNeedsReopen else { return "" }
        return model.states[.claudeDesktop]?.isRegistered == true ? " Claude reads it once you reopen it." : " Quit Claude to end any session it may still have."
    }

    /// For any other app that takes MCP servers.
    private var copyButton: some View {
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AIAppConnections.shellCommand(model.command), forType: .string)
        }
        .help("The command that starts gob.lin's meetings server, for another app that takes MCP servers.")
    }
}
