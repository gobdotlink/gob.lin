import AppKit

final class PasteOnlyTextView: NSTextView {
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector) == "setAccessibilitySelectedText:" { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .selectedText { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }
}

@main
struct NativeDictationTarget {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 200, y: 250, width: 600, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "gob.lin native dictation target"
        let text = PasteOnlyTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        text.font = .systemFont(ofSize: 18)
        window.contentView = text
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        app.activate()
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("target-text.txt")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { try? text.string.write(to: output, atomically: true, encoding: .utf8) }
        }
        withExtendedLifetime(timer) { app.run() }
    }
}
