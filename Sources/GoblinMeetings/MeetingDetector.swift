import AppKit
import ApplicationServices
import Foundation
import os

/// A call app that is holding the microphone, with the window title that suggests a meeting.
public struct MeetingCandidate: Sendable, Hashable, Identifiable {
    public var id: String { app.bundleID }
    public let app: AudioClientApp
    public let since: Date
    public let meetingTitle: String?
    /// True once the app has held the mic long enough to be worth asking about (2 s, as Hex does; 20 s for Slack, whose
    /// clips and settings mic test take the mic too), or sooner once its call window shows.
    public let isLikelyMeeting: Bool

    public init(app: AudioClientApp, since: Date, meetingTitle: String?, isLikelyMeeting: Bool) {
        self.app = app
        self.since = since
        self.meetingTitle = meetingTitle
        self.isLikelyMeeting = isLikelyMeeting
    }
}

/// Polls the HAL once a second for which apps use the microphone and speakers, and reads call apps' window titles
/// over Accessibility. Both run on a background queue with a short Accessibility timeout, so a hung call app never
/// stalls the main thread (the talk key, the overlay); results are applied on the main actor. With
/// `MeetingStorage.debugLogging` on it also logs every start and stop to detection.jsonl, so a test capture shows
/// whether muting releases the mic.
@MainActor public final class MeetingDetector {
    public private(set) var apps: [AudioClientApp] = []
    public private(set) var candidates: [MeetingCandidate] = []
    public var onChange: (() -> Void)?
    private var timer: Timer?
    private let pollQueue = DispatchQueue(label: "gob.lin.meetings.detector", qos: .utility)
    /// A poll is reading on `pollQueue`; the next tick waits for it rather than piling up behind a slow app.
    private var polling = false
    private var running = false
    private var micSince: [String: Date] = [:]
    private var playing: Set<String> = []
    /// Window shapes last logged, by bundle ID, for apps read only in their call windows or not at all.
    private var loggedShapes: [String: [String]] = [:]
    private let logger = Logger(subsystem: "app.goblin.dictation", category: "meetings")
    /// detection.jsonl, or nil when the debug log is off.
    private let logURL: URL?

    /// Beside the Meetings folder.
    nonisolated public static var logFile: URL {
        MeetingStorage.root.deletingLastPathComponent().appendingPathComponent("detection.jsonl")
    }

    public init(debugLog: Bool = MeetingStorage.debugLogging) {
        if debugLog {
            try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            logURL = Self.logFile
        } else {
            logURL = nil
        }
    }

    /// At launch: without the debug log, a detection.jsonl left by an earlier build or capture goes.
    nonisolated public static func removeLog(at url: URL = logFile, unless debugLog: Bool = MeetingStorage.debugLogging) {
        guard !debugLog else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func start() {
        running = true
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// Reads the audio process list and the windows of apps on the mic off the main thread, then applies them here.
    private func poll() {
        guard running, !polling else { return }
        polling = true
        // The debug log names the windows of any app that starts using the mic; otherwise only call apps are read.
        let logsTitles = logURL != nil, known = Set(micSince.keys)
        Self.read(running: AudioClientApp.running(), logsTitles: logsTitles, known: known, on: pollQueue) { [weak self] apps, windows in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.polling = false
                if self.running { self.apply(apps, windows: windows) }
            }
        }
    }

    /// The part of a poll that may block: the HAL's process list and the windows of apps on the mic, on `queue`.
    nonisolated private static func read(running: [AudioClientApp.Running], logsTitles: Bool, known: Set<String>, on queue: DispatchQueue,
                                         then deliver: @escaping @Sendable ([AudioClientApp], [pid_t: [CallWindow]]) -> Void) {
        queue.async {
            let apps = AudioClientApp.current(running: running)
            var windows: [pid_t: [CallWindow]] = [:]
            for app in apps where app.isUsingMicrophone {
                guard let pid = app.pid, app.callApp != nil || (logsTitles && !known.contains(app.bundleID)) else { continue }
                windows[pid] = Self.windows(pid)
            }
            deliver(apps, windows)
        }
    }

    private func apply(_ apps: [AudioClientApp], windows read: [pid_t: [CallWindow]]) {
        func windowsOf(_ pid: pid_t?) -> [CallWindow] { pid.flatMap { read[$0] } ?? [] }
        let now = Date()
        var changed = apps != self.apps
        let micApps = Set(apps.filter(\.isUsingMicrophone).map(\.bundleID))
        for app in apps where app.isUsingMicrophone && micSince[app.bundleID] == nil {
            micSince[app.bundleID] = now
            log(["event": "mic_start", "app": app.name, "bundle": app.bundleID,
                 // Only meeting-like titles: other browser windows are none of our business.
                 "titles": windowsOf(app.pid).map(\.title).filter(Self.looksLikeMeeting).joined(separator: " | ")])
            changed = true
        }
        for (bundle, since) in micSince where !micApps.contains(bundle) {
            micSince[bundle] = nil
            log(["event": "mic_stop", "bundle": bundle, "held_seconds": String(format: "%.1f", now.timeIntervalSince(since))])
            changed = true
        }
        let nowPlaying = Set(apps.filter(\.isPlayingAudio).map(\.bundleID))
        for bundle in nowPlaying.subtracting(playing) { log(["event": "output_start", "bundle": bundle]) }
        for bundle in playing.subtracting(nowPlaying) { log(["event": "output_stop", "bundle": bundle]) }
        playing = nowPlaying

        var candidates: [MeetingCandidate] = []
        for app in apps where app.isUsingMicrophone {
            guard let call = app.callApp, let since = micSince[app.bundleID] else { continue }
            let windows = windowsOf(app.pid)
            logShapes(windows, of: call, bundleID: app.bundleID)
            let title: String?
            if call.kind == .browser {
                title = windows.map(\.title).first { Self.looksLikeMeeting($0) }
                guard title != nil else { continue }
            } else {
                title = call.meetingTitle(windows)
            }
            candidates.append(MeetingCandidate(app: app, since: since, meetingTitle: title,
                                               isLikelyMeeting: call.isLikelyMeeting(heldFor: now.timeIntervalSince(since),
                                                                                     windows: windows)))
        }
        loggedShapes = loggedShapes.filter { micApps.contains($0.key) }
        if candidates != self.candidates { changed = true }
        self.apps = apps
        self.candidates = candidates
        if changed { onChange?() }
    }

    nonisolated public static func looksLikeMeeting(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["meet - ", "meet – ", "meet.google.com", "zoom meeting", "zoom webinar", "| microsoft teams",
                "teams meeting", "huddle", "facetime"].contains { lower.contains($0) }
    }

    /// "Meet – abc-defg-hij – Microphone recording - Google Chrome – Will" → "Meet – abc-defg-hij".
    nonisolated public static func cleanTitle(_ title: String) -> String {
        var title = title
        let browsers = "Google Chrome|Chrome|Arc|Dia|Microsoft Edge|Brave|Firefox|Safari"
        // The browser name is the last part, optionally followed by a profile name ("- Google Chrome – Will").
        title = title.replacingOccurrences(of: "\\s[-–—]\\s(\(browsers))(\\s[-–—]\\s[^-–—]*)?$", with: "", options: .regularExpression)
        let indicators = "Microphone recording|Camera recording|Camera and microphone recording|Audio playing|Audio muted|Memory usage[^–-]*|High memory usage[^–-]*"
        title = title.replacingOccurrences(of: "\\s[-–—]\\s(\(indicators))", with: "", options: .regularExpression)
        return title.trimmingCharacters(in: .whitespaces)
    }

    nonisolated(unsafe) private static let windowAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute] as CFArray

    /// How long one Accessibility message to a call app may take before it's given up on.
    nonisolated public static let messagingTimeout: Float = 0.25

    /// Each window's role, subrole and title over Accessibility, nothing inside it; empty without permission. Each
    /// message gives up after `messagingTimeout`, so a hung app costs a poll its windows, not the caller's thread.
    nonisolated public static func windows(_ pid: pid_t?) -> [CallWindow] {
        guard let pid, AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.map { window in
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            var values: CFArray?
            AXUIElementCopyMultipleAttributeValues(window, windowAttributes, [], &values)
            let array = (values as? [Any]) ?? []
            func string(_ index: Int) -> String { index < array.count ? (array[index] as? String) ?? "" : "" }
            return CallWindow(role: string(0), subrole: string(1), title: string(2))
        }
    }

    /// For apps read only in their call windows, or not at all: each window's role, subrole and title shape, at debug
    /// level, whenever they change. A real call then shows which window to read without any of its text.
    private func logShapes(_ windows: [CallWindow], of call: CallApp, bundleID: String) {
        switch call.scope {
        case .wholeApp, .meetingPages: return
        case .callWindows, .nothing: break
        }
        let shapes = windows.map { "\($0.shape)\(call.showsCallWindow([$0]) ? " call" : "")" }
        guard shapes != loggedShapes[bundleID] else { return }
        loggedShapes[bundleID] = shapes
        logger.debug("windows of \(bundleID, privacy: .public): \(shapes.joined(separator: "; "), privacy: .public)")
    }

    private func log(_ fields: @autoclosure () -> [String: String]) {
        guard let logURL else { return }
        var object: [String: String] = fields()
        object["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        try? handle.close()
    }
}
