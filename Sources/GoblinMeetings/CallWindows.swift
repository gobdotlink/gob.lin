import Foundation

/// One top-level window of a call app, as Accessibility reports it: its role, subrole and title, nothing inside it.
public struct CallWindow: Sendable, Hashable {
    public let role: String
    public let subrole: String
    public let title: String

    public init(role: String, subrole: String, title: String) {
        self.role = role
        self.subrole = subrole
        self.title = title
    }

    /// For the debug log: "AXWindow/AXStandardWindow "<x> - <x> - Slack" (27)". Each part of the title becomes
    /// `<x>` unless it is an app name or a call word, so no channel, person or message reaches the log.
    public var shape: String {
        "\(role)\(subrole.isEmpty ? "" : "/" + subrole) \"\(Self.titleShape(title))\" (\(title.count))"
    }

    private static let keptWords: Set<String> = ["slack", "huddle", "zoom", "zoom meeting", "microsoft teams", "teams",
                                                  "facetime", "webex", "discord", "meeting", "call"]

    /// "general - Acme - Slack" → "<x> - <x> - Slack"; "Huddle with Alex" → "<x huddle>".
    public static func titleShape(_ title: String) -> String {
        guard !title.isEmpty else { return "" }
        let pattern = try! NSRegularExpression(pattern: "\\s[-–—|]\\s|:\\s")
        let ns = title as NSString
        var shape = "", cursor = 0
        func part(_ range: NSRange) -> String {
            let text = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return "" }
            if keptWords.contains(text.lowercased()) { return text }
            return text.lowercased().contains("huddle") ? "<x huddle>" : "<x>"
        }
        for match in pattern.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            shape += part(NSRange(location: cursor, length: match.range.location - cursor)) + ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return shape + part(NSRange(location: cursor, length: ns.length - cursor))
    }
}

/// How much of a call app's Accessibility tree a recording may read, for its mute and sharing state.
public enum AccessibilityScope: Sendable, Hashable {
    /// Every window and every element: Zoom, whose windows are all part of the call.
    case wholeApp
    /// Browsers: only windows titled like a meeting, and only pages there whose address is a meeting provider's
    /// (`isMeetingPage`), never the tab strip or toolbar.
    case meetingPages
    /// Only windows that are clearly the call, never the app's main window, with a small element budget. When no
    /// window is clearly the call, nothing is read.
    case callWindows(CallWindowRule)
    /// Nothing is read.
    case nothing

    /// Elements read per window per pass.
    public var budget: Int {
        switch self {
        case .wholeApp, .meetingPages: 6_000
        case .callWindows: 400
        case .nothing: 0
        }
    }

    /// Whether this window is read at all.
    public func reads(_ window: CallWindow) -> Bool {
        switch self {
        case .wholeApp: true
        case .meetingPages: MeetingDetector.looksLikeMeeting(window.title)
        case .callWindows(let rule): rule.isCallWindow(window)
        case .nothing: false
        }
    }

    /// Whether text is read from the window's top, rather than only inside a web page (`AXWebArea`).
    public var readsWholeWindow: Bool {
        switch self {
        case .meetingPages: false
        case .wholeApp, .callWindows, .nothing: true
        }
    }

    /// Whether an element and everything below it is left out. In a browser, outside the page: the tab strip and the
    /// toolbar, so other tabs' titles stay out. In a call window: lists, tables and text entry, where chat messages
    /// and drafts live.
    public func skips(role: String, insidePage: Bool) -> Bool {
        switch self {
        case .wholeApp, .nothing: false
        case .meetingPages: !insidePage && (role == "AXTabGroup" || role == "AXToolbar")
        case .callWindows: ["AXList", "AXTable", "AXOutline", "AXTextArea", "AXTextField", "AXComboBox"].contains(role)
        }
    }

    /// Whether a browser page may be read: only a web area whose address is a supported meeting provider's, so a
    /// window that is merely titled like a meeting ("Meet - anything") can't put its own mute buttons in the reading.
    /// The window title is only a hint for which windows to look in.
    public static func isMeetingPage(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let hosts: Set<String> = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
                                  "app.slack.com", "facetime.apple.com"]
        return hosts.contains(host) || host == "zoom.us" || host.hasSuffix(".zoom.us")
    }

    /// Electron apps (Slack) build their web content's Accessibility tree only when asked with `AXManualAccessibility`.
    public var needsManualAccessibility: Bool {
        if case .callWindows = self { return true }
        return false
    }
}

/// How a call window is told from the app's other windows, by role, subrole and title alone.
public enum CallWindowRule: Sendable, Hashable {
    /// Slack's huddle window or its mini (picture-in-picture) window, never the main or a conversation window.
    case slackHuddle

    public func isCallWindow(_ window: CallWindow) -> Bool {
        switch self {
        case .slackHuddle: SlackWindows.isHuddle(window)
        }
    }

    /// The meeting's title from the call window, when one is open.
    public func title(_ windows: [CallWindow]) -> String? {
        switch self {
        case .slackHuddle: SlackWindows.huddleTitle(windows)
        }
    }
}

/// Slack's windows. The main window, and any conversation opened in its own window, is an `AXStandardWindow` titled
/// "<conversation> - <workspace> - Slack" that never says "huddle"; those are never read. A huddle shows in its own
/// window or a floating mini window. Their exact roles and titles aren't confirmed yet, so only these count:
/// - a floating window (`AXFloatingWindow`, `AXSystemFloatingWindow`), which Slack uses for nothing but calls;
/// - a standard window whose title says "Huddle" and isn't shaped like a conversation window, or is shaped like one
///   whose conversation part starts "Huddle" (channel names are lower case, so a #huddle channel doesn't match).
/// Anything else, dialogs and sheets included, isn't read.
public enum SlackWindows {
    static let separators = "\\s[-–—|]\\s"
    static let floating: Set<String> = ["AXFloatingWindow", "AXSystemFloatingWindow"]

    /// "<conversation> - <workspace> - Slack".
    public static func isConversationShaped(_ title: String) -> Bool {
        let parts = parts(title)
        return parts.count >= 3 && parts.last?.caseInsensitiveCompare("Slack") == .orderedSame
    }

    public static func isHuddle(_ window: CallWindow) -> Bool {
        guard window.role == "AXWindow" else { return false }
        if floating.contains(window.subrole) { return true }
        guard window.subrole == "AXStandardWindow" else { return false }
        if isConversationShaped(window.title) { return startsWithHuddle(parts(window.title).first ?? "") }
        return window.title.range(of: "huddle", options: .caseInsensitive) != nil
    }

    /// "Slack huddle", or the huddle window's own title less "Slack" and the workspace: "Huddle with Alex Kim".
    public static func huddleTitle(_ windows: [CallWindow]) -> String? {
        let huddles = windows.filter(isHuddle)
        guard !huddles.isEmpty else { return nil }
        for window in huddles {
            var parts = parts(window.title).filter { $0.caseInsensitiveCompare("Slack") != .orderedSame }
            if isConversationShaped(window.title) { parts = Array(parts.prefix(1)) }
            guard let named = parts.first(where: { $0.range(of: "huddle", options: .caseInsensitive) != nil }) else { continue }
            let title = named.trimmingCharacters(in: .whitespaces)
            if title.caseInsensitiveCompare("Huddle") == .orderedSame || title.caseInsensitiveCompare("Slack huddle") == .orderedSame { continue }
            return title.count > 80 ? String(title.prefix(80)) + "…" : title
        }
        return "Slack huddle"
    }

    private static func startsWithHuddle(_ text: String) -> Bool {
        guard text.hasPrefix("Huddle") else { return false }
        let rest = text.dropFirst(6)
        return rest.isEmpty || rest.first == " " || rest.first == ":"
    }

    private static func parts(_ title: String) -> [String] {
        title.replacingOccurrences(of: separators, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension CallApp {
    /// A window that is clearly this app's call, seen over Accessibility.
    public func showsCallWindow(_ windows: [CallWindow]) -> Bool {
        guard case .callWindows(let rule) = scope else { return false }
        return windows.contains(where: rule.isCallWindow)
    }

    /// Held the mic long enough to be worth asking about, or already shows its call window.
    public func isLikelyMeeting(heldFor seconds: TimeInterval, windows: [CallWindow]) -> Bool {
        seconds >= minimumMicTime || showsCallWindow(windows)
    }

    /// The meeting's title for a native app: the call window's (Slack: "Slack huddle"), else a window titled like a
    /// meeting, else the app's name. Slack's other windows name a conversation, so they're never used.
    public func meetingTitle(_ windows: [CallWindow]) -> String {
        if case .callWindows(let rule) = scope { return rule.title(windows) ?? name }
        return windows.map(\.title).first(where: MeetingDetector.looksLikeMeeting) ?? name
    }
}
