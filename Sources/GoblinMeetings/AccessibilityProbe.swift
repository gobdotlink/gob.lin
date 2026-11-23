import ApplicationServices
import Foundation

/// Reads the call app's Accessibility tree about once a second for its mute state and who's in the call. Keeps
/// mute.jsonl and participants.json; the window's raw text goes to accessibility.jsonl only with `MeetingStorage.debugLogging` on, for test captures.
/// The call app's `AccessibilityScope` says which windows and elements are walked.
/// Made without a folder (while a call is offered) it keeps mute changes in memory and writes nothing, not even the
/// raw log, until `attach` gives it the recording's folder.
public final class AccessibilityProbe: @unchecked Sendable {
    public let pid: pid_t
    private let scope: AccessibilityScope
    private let readsCallState: Bool
    private let queue = DispatchQueue(label: "gob.lin.meetings.ax-probe", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var previous: Set<String> = []
    private var lastFull = Date.distantPast
    private var enhancedWasSet: Bool?
    private var manualWasSet: Bool?
    nonisolated(unsafe) private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                     kAXValueAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as [CFString]

    /// The recording's files. Nil until `attach`: nothing is written.
    private struct Files {
        let mute: URL
        let participants: URL
        /// accessibility.jsonl, or nil when the raw log is off.
        let raw: URL?
    }

    private var files: Files?
    /// Mute changes made before `attach`, as mute.jsonl would have them.
    private var unwritten: [(t: Double, muted: Bool, unknown: Bool)] = []
    private var collector = MeetingParticipants.Collector()
    private var savedParticipants = MeetingParticipants()
    private var sessionStart: Date
    private var muted: Bool?
    /// When a pass first saw no mute signal while the state was known; it goes unknown `staleAfter` later.
    private var signalLostAt: Date?
    private var timeline = MuteTimeline()

    public convenience init(pid: pid_t, isBrowser: Bool, directory: URL, sessionStart: Date,
                            rawLog: Bool = MeetingStorage.debugLogging) {
        self.init(pid: pid, scope: isBrowser ? .meetingPages : .wholeApp, readsCallState: true, directory: directory,
                  sessionStart: sessionStart, rawLog: rawLog)
    }

    public convenience init(pid: pid_t, app: CallApp, directory: URL?, sessionStart: Date,
                            rawLog: Bool = MeetingStorage.debugLogging) {
        self.init(pid: pid, scope: app.scope, readsCallState: app.readsCallState, directory: directory,
                  sessionStart: sessionStart, rawLog: rawLog)
    }

    /// `readsCallState` false leaves mute unknown whatever the windows say: the app's phrases aren't
    /// known, and a chat line that happened to read "Unmute my audio" mustn't take your mic lines out.
    /// A nil `directory` keeps everything in memory until `attach`.
    public init(pid: pid_t, scope: AccessibilityScope, readsCallState: Bool, directory: URL?, sessionStart: Date,
                rawLog: Bool = MeetingStorage.debugLogging) {
        self.pid = pid
        self.scope = scope
        self.readsCallState = readsCallState
        self.sessionStart = sessionStart
        if let directory { attach(directory: directory, sessionStart: sessionStart, rawLog: rawLog) }
    }

    /// Starts writing into the recording's folder, with times from `sessionStart`. The mute changes read so far move
    /// onto that clock and go into mute.jsonl first; a change from before it becomes the state at 0. Participants seen
    /// so far are saved on the next pass. Only the first call does anything.
    public func attach(directory: URL, sessionStart start: Date, rawLog: Bool) {
        let raw = rawLog ? directory.appendingPathComponent(MeetingStorage.accessibilityFile) : nil
        let files = Files(mute: directory.appendingPathComponent(MeetingStorage.muteFile),
                          participants: directory.appendingPathComponent(MeetingStorage.participantsFile), raw: raw)
        lock.withLock {
            guard self.files == nil else { return }
            let shift = sessionStart.timeIntervalSince(start)
            let moved = unwritten.map { (t: $0.t + shift, muted: $0.muted, unknown: $0.unknown) }
            let before = moved.last { $0.t < 0 }.map { (t: 0.0, muted: $0.muted, unknown: $0.unknown) }
            let lines = (before.map { [$0] } ?? []) + moved.filter { $0.t >= 0 }
            var rebuilt = MuteTimeline()
            for line in lines { rebuilt.record(line.muted, at: line.t) }
            timeline = rebuilt
            unwritten = []
            sessionStart = start
            if let raw { FileManager.default.createFile(atPath: raw.path, contents: nil) }
            let text = lines.map { Self.muteLine(muted: $0.muted, unknown: $0.unknown, at: $0.t) }.joined()
            FileManager.default.createFile(atPath: files.mute.path, contents: Data(text.utf8))
            self.files = files
        }
    }

    /// How long a mute state lasts once the call app stops showing any sign of it (a browser switched to another
    /// tab, a toolbar hidden): then it's unknown, and nothing more is left out.
    public static let staleAfter: TimeInterval = 30

    /// Roles a toolbar control has: only these can say the mute state with a toolbar phrase, so a chat line or a
    /// caption that happens to read "turn on microphone" says nothing.
    static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton",
                                            "AXToggle", "AXSwitch"]

    /// One logged line, "<depth> <role>/<subrole>: <text>", as its role and lowercased text.
    static func parse(_ line: String) -> (role: String, text: String) {
        let parts = line.split(separator: ":", maxSplits: 1)
        let text = parts.count == 2 ? parts[1].lowercased().trimmingCharacters(in: .whitespaces) : ""
        let head = parts.first.map(String.init) ?? ""
        let roleAndSubrole = head.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        return (roleAndSubrole.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "", text)
    }

    /// The call's own mute state, strongest signal first. Zoom: the toolbar button "Unmute my audio" / "Mute my
    /// audio", the "You are muted now" banner, and the self tile "<my name>, Computer audio muted" (other people's
    /// tiles say the same about them, so the self name comes from "<name> (Host, me)" or the account
    /// button "Zoom, <name>, In a Zoom Meeting"). Meet: the "Turn on microphone" / "Turn off microphone" button.
    /// Toolbar phrases count only on a control (`controlRoles`), and the banner only as a whole element's text.
    /// Order-free, since a snapshot replayed from diffs has no order.
    public static func muteState<S: Sequence>(_ lines: S) -> Bool? where S.Element == String {
        let elements = lines.map(parse)
        let texts = elements.map(\.text)
        let controls = elements.filter { controlRoles.contains($0.role) }.map(\.text)
        let rules: [(String, Bool)] = [("unmute my audio", true), ("mute my audio", false),
                                       ("turn on microphone", true), ("turn off microphone", false)]
        // A participant's name can read like a control ("More options for Unmute my audio", or a tile's button named
        // "Unmute my audio"), so controls that disagree say nothing, and the signals below decide.
        let said = Set(rules.filter { phrase, _ in controls.contains { isControl($0, phrase) } }.map(\.1))
        if said.count == 1, let muted = said.first { return muted }
        // An element's text joins its title, description, value and identifier with " | ".
        let banner = texts.contains { text in
            text.components(separatedBy: " | ").contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .!")) == "you are muted now" }
        }
        if banner { return true }
        var me: String?
        for text in texts {
            if let range = text.range(of: " (host, me)") ?? text.range(of: " (me)") { me = String(text[..<range.lowerBound]); break }
            if text.hasPrefix("zoom, "), text.contains(", in a zoom meeting") {
                me = text.dropFirst(6).components(separatedBy: ", in a zoom meeting").first
            }
        }
        guard let me, !me.isEmpty else { return nil }
        // The self tile reads "<me>, Computer audio muted" or "<me> (Host, me), Computer audio muted".
        func selfTile(_ text: String, _ state: String) -> Bool {
            // The state is looked for only after the name: a name can itself read ", computer audio muted".
            guard text.hasPrefix(me) else { return false }
            let afterName = text.index(text.startIndex, offsetBy: me.count)
            guard let range = text.range(of: ", computer audio " + state, range: afterName..<text.endIndex) else { return false }
            let between = text[afterName..<range.lowerBound]
            return between.isEmpty || (between.hasPrefix(" (") && between.hasSuffix(")"))
        }
        if texts.contains(where: { selfTile($0, "unmuted") }) { return false }
        if texts.contains(where: { selfTile($0, "muted") }) { return true }
        return nil
    }

    /// Whether one part of a control's text is the phrase itself, or the phrase and its shortcut ("turn on microphone
    /// (⌘ + d)"). The phrase inside a longer label, such as "more options for unmute my audio", isn't the control.
    static func isControl(_ text: String, _ phrase: String) -> Bool {
        text.components(separatedBy: " | ").contains { part in
            let part = part.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            guard part.hasPrefix(phrase) else { return false }
            let shortcut = part.dropFirst(phrase.count).trimmingCharacters(in: .whitespaces)
            return shortcut.isEmpty || (shortcut.hasPrefix("(") && shortcut.hasSuffix(")") && shortcut.contains { "⌘⌥⇧⌃+".contains($0) })
        }
    }

    /// Replays a recording's accessibility log into mute.jsonl, for logs taken before the rules changed. A recording
    /// without the raw log keeps its mute.jsonl as it is, and nil comes back.
    public static func rebuildMuteLog(directory: URL, sessionStart: Date) throws -> Int? {
        let logURL = directory.appendingPathComponent(MeetingStorage.accessibilityFile)
        guard FileManager.default.fileExists(atPath: logURL.path) else { return nil }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        var current: Set<String> = []
        var state: Bool?
        var lostAt: Double?
        var output = ""
        var changes = 0
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = row["t"] as? Double else { continue }
            // The same expiry as a live recording: no sign of the state for `staleAfter`, and it's unknown.
            if let lost = lostAt, state != nil, t >= lost + staleAfter {
                if state == true {
                    changes += 1
                    output += Self.muteLine(muted: false, unknown: true, at: lost + staleAfter - sessionStart.timeIntervalSince1970)
                }
                state = nil
                lostAt = nil
            }
            // Rows that only note sharing or an error don't describe the window.
            guard row["lines"] != nil || row["added"] != nil || row["removed"] != nil else { continue }
            if let lines = row["lines"] as? [String] { current = Set(lines) }
            current.subtract((row["removed"] as? [String]) ?? [])
            current.formUnion((row["added"] as? [String]) ?? [])
            if let muted = muteState(current) {
                lostAt = nil
                if muted != state {
                    state = muted
                    changes += 1
                    output += Self.muteLine(muted: muted, at: t - sessionStart.timeIntervalSince1970)
                }
            } else if state != nil, lostAt == nil {
                lostAt = t
            }
        }
        try output.write(to: directory.appendingPathComponent(MeetingStorage.muteFile), atomically: true, encoding: .utf8)
        return changes
    }

    /// The call's mute state as last read, or nil before the call app showed one.
    public var isMuted: Bool? { lock.withLock { muted } }

    /// Every mute change so far, on the session's clock: what mute.jsonl holds.
    public var muteTimeline: MuteTimeline { lock.withLock { timeline } }

    /// How long one Accessibility message to the call app may take; a pass that hits it stops early and tries again.
    static let messagingTimeout: Float = 0.5

    /// Starts reading on the probe's own queue; nothing here sends the call app a message on the caller's thread.
    public func start() {
        guard AXIsProcessTrusted() else {
            append(["t": Date().timeIntervalSince1970, "error": "Accessibility permission is off"])
            return
        }
        // Nothing to read: mute stays unknown and nothing is walked.
        if scope == .nothing { return }
        lock.withLock { running = true }
        queue.async { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            if scope == .meetingPages {
                // Chrome builds its web accessibility tree only for assistive clients.
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
                enhancedWasSet = (value as? Bool) ?? false
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            if scope.needsManualAccessibility {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &value)
                manualWasSet = (value as? Bool) ?? false
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            loop(app)
        }
    }

    /// Ends the loop; the app's Accessibility switches are put back on the probe's queue once the last pass is done.
    public func stop() {
        lock.withLock { running = false }
        queue.async { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            if scope == .meetingPages, enhancedWasSet == false {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            if scope.needsManualAccessibility, manualWasSet == false {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            }
        }
    }

    private func loop(_ app: AXUIElement) {
        // The raw log this pass writes to: none before `attach`, and its first pass after writes the whole window.
        var logging: URL?
        while lock.withLock({ running }) {
            let started = Date()
            var lines: [String] = []
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
               let windows = windows as? [AXUIElement] {
                for window in windows {
                    AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
                    var values: CFArray?
                    AXUIElementCopyMultipleAttributeValues(window, Self.windowAttributes, [], &values)
                    let array = (values as? [Any]) ?? []
                    func string(_ index: Int) -> String { index < array.count ? (array[index] as? String) ?? "" : "" }
                    guard scope.reads(CallWindow(role: string(0), subrole: string(1), title: string(2))) else { continue }
                    var budget = scope.budget
                    var visited: Set<Int> = []
                    walk(window, depth: 0, inWeb: scope.readsWholeWindow, into: &lines, budget: &budget, visited: &visited)
                }
            }
            let duration = Date().timeIntervalSince(started)
            if readsCallState { updateMute(Self.muteState(lines), at: started) }
            let current = Set(lines)
            let added = lines.filter { !previous.contains($0) }
            collector.add(added)
            saveParticipantsIfChanged()
            let raw = lock.withLock { files?.raw }
            if raw != logging { logging = raw; lastFull = .distantPast }
            if raw != nil {
                let now = Date()
                if now.timeIntervalSince(lastFull) >= 60 {
                    lastFull = now
                    append(["t": now.timeIntervalSince1970, "kind": "full", "ms": Int(duration * 1_000), "lines": lines])
                } else if current != previous {
                    append(["t": now.timeIntervalSince1970, "kind": "diff", "ms": Int(duration * 1_000),
                            "added": added, "removed": previous.subtracting(current).sorted()])
                }
            }
            previous = current
            Thread.sleep(forTimeInterval: max(0.5, 1 - duration))
        }
    }

    nonisolated(unsafe) private static let windowAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute] as CFArray

    /// In a browser only the page is walked (`AXWebArea` and below), never the tab strip or toolbar,
    /// so other tabs' titles stay out of the log. In a call window, lists and text entry are skipped.
    private func walk(_ element: AXUIElement, depth: Int, inWeb: Bool, into lines: inout [String], budget: inout Int,
                      visited: inout Set<Int>) {
        // Zoom's tree has cycles (the toolbar is its own descendant), so never visit an element twice.
        guard depth < 40, budget > 0, visited.insert(Int(bitPattern: CFHash(element))).inserted else { return }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, [], &values)
        // The app stopped answering: end this pass rather than wait on every element left.
        if status == .cannotComplete { budget = 0; return }
        guard status == .success, let array = values as? [Any] else { return }
        func string(_ index: Int) -> String {
            guard index < array.count, let text = array[index] as? String else { return "" }
            return text.count > 160 ? String(text.prefix(160)) + "…" : text
        }
        let role = string(0), subrole = string(1)
        let text = [string(2), string(3), string(4), string(5)].filter { !$0.isEmpty }.joined(separator: " | ")
        if scope.skips(role: role, insidePage: inWeb) { return }
        // In a browser, a page counts only when its address is a meeting provider's; nothing in any other page is read.
        if scope == .meetingPages, role == "AXWebArea", !AccessibilityScope.isMeetingPage(Self.url(of: element)) { return }
        let inside = inWeb || role == "AXWebArea"
        if inside, !text.isEmpty { lines.append("\(depth) \(role)\(subrole.isEmpty ? "" : "/" + subrole): \(text)") }
        if array.count > 6, let children = array[6] as? [AXUIElement] {
            for child in children { walk(child, depth: depth + 1, inWeb: inside, into: &lines, budget: &budget, visited: &visited) }
        }
    }

    /// A web area's address (`AXURL`), or nil when the browser doesn't give one.
    private static func url(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        return (value as? String).flatMap(URL.init(string:))
    }

    /// Applies one pass's reading. A state seen is kept; once no pass has shown one for `staleAfter`, it's unknown,
    /// and a mute that was on ends there, so a tab switched away from the call doesn't leave the mic out for good.
    func updateMute(_ state: Bool?, at date: Date) {
        lock.withLock {
            let t = date.timeIntervalSince(sessionStart)
            guard let change = muteChange(state, at: date, t: t) else { return }
            // Under the lock, so `attach` can't write mute.jsonl in between and put a change out of order.
            if let files { Self.appendMute(change.muted, unknown: change.unknown, at: t, to: files.mute) }
            else { unwritten.append((t, change.muted, change.unknown)) }
        }
    }

    /// The change one reading makes, if any. Call with the lock held.
    private func muteChange(_ state: Bool?, at date: Date, t: Double) -> (muted: Bool, unknown: Bool)? {
        if let state {
            signalLostAt = nil
            guard state != muted else { return nil }
            muted = state
            timeline.record(state, at: t)
            return (state, false)
        }
        guard muted != nil else { return nil }
        guard let lost = signalLostAt else { signalLostAt = date; return nil }
        guard date.timeIntervalSince(lost) >= Self.staleAfter else { return nil }
        let wasMuted = muted == true
        muted = nil
        signalLostAt = nil
        guard wasMuted else { return nil }
        timeline.record(false, at: t)
        return (false, true)
    }

    /// One mute.jsonl line; an expired mute is written as unmuted, marked unknown.
    static func muteLine(muted: Bool, unknown: Bool = false, at t: Double) -> String {
        "{\"t\":\(String(format: "%.2f", t)),\"muted\":\(muted)\(unknown ? ",\"unknown\":true" : "")}\n"
    }

    private static func appendMute(_ muted: Bool, unknown: Bool, at t: Double, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // A full disk throws here rather than ending the app; the recording stops on its own audio's failed write.
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(Self.muteLine(muted: muted, unknown: unknown, at: t).utf8))
        try? handle.close()
    }

    /// participants.json follows the call as people join; written whole each time, so it's never half a file.
    private func saveParticipantsIfChanged() {
        let participants = collector.participants
        guard let url = lock.withLock({ files?.participants }), participants != savedParticipants,
              let data = try? JSONEncoder.pretty.encode(participants) else { return }
        do {
            try data.write(to: url, options: .atomic)
            savedParticipants = participants
        } catch {}
    }

    private func append(_ object: [String: Any]) {
        guard let url = lock.withLock({ files?.raw }), let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        try? handle.close()
    }
}
