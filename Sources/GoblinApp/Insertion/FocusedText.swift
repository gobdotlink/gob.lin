import AppKit
import Carbon
import GoblinCore
import IOKit
@preconcurrency import ApplicationServices

/// Text read near a field while the user speaks; `field` ties it to the field it was read around.
/// Unchecked: an AXUIElement is an immutable handle that is safe to pass between threads.
struct NearbyText: @unchecked Sendable {
    let field: AXUIElement
    let text: String
    let elements: Int
    let milliseconds: Double
}

struct FocusedText {
    let pid: pid_t
    let element: AXUIElement
    let value: String?
    let selection: NSRange?
    let secure: Bool
    let applicationFallback: Bool
    var role: String? = nil
    var window: AXUIElement? = nil
    var document: String? = nil
    var identity: [String: String] = [:]

    static func capture(timeout: Float = 0.25) -> FocusedText? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return FocusedText(pid: app.processIdentifier, element: AXUIElementCreateApplication(app.processIdentifier),
                               value: nil, selection: nil, secure: false, applicationFallback: true)
        }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return nil }
        let result = read(pid: pid, element: element)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? result : nil
    }

    static func read(pid: pid_t, element: AXUIElement) -> FocusedText {
        let secure = attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField"
        let role = attribute(element, kAXRoleAttribute) as? String
        let window = elementAttribute(element, kAXWindowAttribute)
        if let window { AXUIElementSetMessagingTimeout(window, 0.05) }
        let document = window.flatMap { attribute($0, kAXDocumentAttribute) as? String }
        guard !secure else {
            return FocusedText(pid: pid, element: element, value: nil, selection: nil, secure: true,
                               applicationFallback: false, role: role, window: window, document: document)
        }
        var identity: [String: String] = [:]
        for name in [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            identity[name] = attribute(element, name) as? String
        }
        if document == nil, let window {
            identity["windowTitle"] = attribute(window, kAXTitleAttribute) as? String
        }
        var raw: CFTypeRef?
        let value = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success ? raw as? String : nil
        raw = nil
        var selection: NSRange?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
           let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            let ax = unsafeDowncast(raw, to: AXValue.self)
            var range = CFRange()
            if AXValueGetValue(ax, .cfRange, &range) { selection = NSRange(location: range.location, length: range.length) }
        }
        return FocusedText(pid: pid, element: element, value: value, selection: selection, secure: false,
                           applicationFallback: false, role: role, window: window, document: document, identity: identity)
    }

    /// The app, window title and text around the cursor, for cleanup, with `nearby` text when it was read from this
    /// field. Never for password fields.
    func dictationContext(application: String?, nearby: NearbyText? = nil) -> DictationContext? {
        guard !secure else { return nil }
        let title = identity["windowTitle"] ?? window.flatMap { Self.attribute($0, kAXTitleAttribute) as? String }
        let nearbyText = nearby.flatMap { CFEqual($0.field, element) ? $0.text : nil }
        return DictationContext(application: application, windowTitle: title, fieldText: value, selection: selection, nearbyText: nearbyText)
    }

    @MainActor private static var treesRequested: Set<pid_t> = []

    /// Asks an Electron app to build its accessibility tree, once per process. True when this call asked: the tree
    /// arrives a moment later.
    @MainActor static func requestAccessibilityTree(pid: pid_t) -> Bool {
        guard !treesRequested.contains(pid) else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        // A busy app can miss the request, so it's asked again next take rather than never.
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success { treesRequested.insert(pid) }
        return true
    }

    /// The text before `pid`'s focused field in its window, such as the messages above a message box. Runs off the main
    /// thread while the user speaks; each element read has its own timeout, and the walk stops at `budget`.
    static func nearbyText(pid: pid_t, budget: Duration = .milliseconds(600)) -> NearbyText? {
        let start = ContinuousClock.now
        func timed(_ element: AXUIElement) -> AXUIElement { AXUIElementSetMessagingTimeout(element, 0.1); return element }
        guard let field = elementAttribute(timed(AXUIElementCreateApplication(pid)), kAXFocusedUIElementAttribute).map(timed),
              attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        let found = DictationContext.textBefore(field,
            parent: { attribute($0, kAXRoleAttribute) as? String == kAXWindowRole ? nil : elementAttribute($0, kAXParentAttribute).map(timed) },
            children: { (attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(timed) },
            text: { element in
                switch attribute(element, kAXRoleAttribute) as? String {
                case kAXStaticTextRole: attribute(element, kAXValueAttribute) as? String ?? ""
                // Other fields' contents stay unread, password fields above all.
                case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole: ""
                default: nil
                }
            },
            isSame: { CFEqual($0, $1) }, deadline: start.advanced(by: budget))
        let elapsed = start.duration(to: .now).components
        return NearbyText(field: field, text: found.text, elements: found.visited,
                          milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }

    var supportsDirectInsertion: Bool {
        canSetTextAttribute(kAXSelectedTextAttribute)
    }

    var supportsValueInsertion: Bool {
        canSetTextAttribute(kAXValueAttribute)
    }

    private func canSetTextAttribute(_ attribute: String) -> Bool {
        guard !applicationFallback, !secure, value != nil, selection != nil,
              role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func hasSameContext(as other: FocusedText) -> Bool {
        guard pid == other.pid, CFEqual(element, other.element), !other.secure,
              role == other.role, document == other.document, identity == other.identity else { return false }
        switch (window, other.window) {
        case (nil, nil): return true
        case (let first?, let second?): return CFEqual(first, second)
        default: return false
        }
    }

    /// Web editors can route a selection replacement through their app's active editor.
    func isApplicationFocused() -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        return Self.elementAttribute(app, kAXFocusedUIElementAttribute).map { CFEqual($0, element) } ?? false
    }

    var hasLiveWindow: Bool {
        guard let window else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        return windows.contains { CFEqual($0, window) }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    func isStillFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if applicationFallback { return true }
        // Focus checks must not re-read the editor's value/range on every paste poll.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return CFEqual(raw, element)
    }
}

/// Secure Input is one switch for the whole session: while any app guards a password field, it's on for all of them.
/// It only stops gob.lin typing into the app holding it; the password fields themselves are refused by `FocusedText.secure`.
enum SecureInput {
    /// The app macOS names as holding Secure Input. A hint only: it can name an app that has since let go.
    static var holder: pid_t? {
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        let session = users.first { $0["kCGSSessionOnConsoleKey"] as? Bool == true } ?? users.first
        return (session?["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }

    /// True when Secure Input is on and held by `pid`, or by an app macOS doesn't name.
    static func guards(_ pid: pid_t) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        guard let holder, holder > 0 else { return true }
        return holder == pid
    }
}
