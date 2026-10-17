import AppKit

private final class PasteOnlyEditor: NSTextView {
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector) == "setAccessibilitySelectedText:" { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        attribute != .selectedText && super.accessibilityIsAttributeSettable(attribute)
    }
}

private final class UnconfirmedEditor: NSTextView {
    override func setAccessibilitySelectedText(_ selectedText: String?) {}
}

@main
struct OriginalFieldTarget {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        menu.addItem(item)
        app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 160, y: 260, width: 520, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Original field acceptance target"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let editors: [NSTextView] = [NSTextView(), PasteOnlyEditor(), UnconfirmedEditor()]
        for (index, editor) in editors.enumerated() {
            editor.frame = NSRect(x: 20, y: 210 - index * 95, width: 480, height: 75)
            editor.string = index == 0 ? "left 🧌 right" : "draft"
            editor.font = .systemFont(ofSize: 18)
            editor.setAccessibilityIdentifier(["direct", "paste-only", "unconfirmed"][index])
            content.addSubview(editor)
        }
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editors[0])
        editors[0].setSelectedRange(NSRange(location: 5, length: 2))
        app.activate()
        withExtendedLifetime((window, editors)) { app.run() }
    }
}
