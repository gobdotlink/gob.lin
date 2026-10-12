import AppKit
@preconcurrency import ApplicationServices

struct FocusedText {
    let pid: pid_t
    let element: AXUIElement
    let value: String?
    let selection: NSRange?
    let secure: Bool
    let applicationFallback: Bool

    static func capture() -> FocusedText? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FocusedText(pid: app.processIdentifier, element: AXUIElementCreateApplication(app.processIdentifier),
                               value: nil, selection: nil, secure: false, applicationFallback: true)
        }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return read(pid: pid, element: element)
    }

    static func read(pid: pid_t, element: AXUIElement) -> FocusedText {
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
        raw = nil
        let subrole = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw) == .success ? raw as? String : nil
        return FocusedText(pid: pid, element: element, value: value, selection: selection, secure: subrole == "AXSecureTextField", applicationFallback: false)
    }

    func isStillFocused() -> Bool {
        guard let current = Self.capture() else { return false }
        return current.pid == pid && (applicationFallback || CFEqual(current.element, element))
    }
}
