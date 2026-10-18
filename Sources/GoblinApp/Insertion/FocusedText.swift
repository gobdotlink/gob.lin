import AppKit
@preconcurrency import ApplicationServices

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
