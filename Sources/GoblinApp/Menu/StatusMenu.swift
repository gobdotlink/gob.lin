import AppKit
import SwiftUI

/// One entry in the popover's ⋯ menu or the menu-bar icon's right-click menu. Both are built from
/// the same lists, so they can't drift apart.
struct MenuCommand {
    var title: String
    var shortcut: KeyboardShortcut?
    var enabled = true
    var perform: () -> Void
}

extension AppModel {
    /// The popover's ⋯ menu, in sections.
    var moreMenu: [[MenuCommand]] {
        let missing = (permissions.snapshot.microphone == .authorized ? 0 : 1) + (permissions.snapshot.accessibility ? 0 : 1)
        return [
            [MenuCommand(title: missing == 0 ? "Permissions…" : "Permissions… (\(missing) off)") { self.permissions.showOnboarding() },
             MenuCommand(title: "Diagnostics…") { self.openSettings(.diagnostics) },
             MenuCommand(title: "Copy Diagnostics") { self.diagnostics.copyDiagnostics() }],
            [MenuCommand(title: "Check for Updates…", enabled: !updates.isBusy) { self.openSettings(.about); self.updates.check() },
             MenuCommand(title: "About gob.lin") { self.openSettings(.about) }],
            [MenuCommand(title: "Quit gob.lin", shortcut: KeyboardShortcut("q")) { UpdateChecker.requestTermination() }],
        ]
    }

    /// The right-click menu: the ⋯ menu under the daily actions, and a way out of a recording.
    var statusMenu: [[MenuCommand]] {
        let cancel = MenuCommand(title: "Cancel Dictation", shortcut: KeyboardShortcut(.escape, modifiers: [])) { self.cancelRecording() }
        return (isRecording ? [[cancel]] : []) + [[
            MenuCommand(title: "Paste Last Dictation", shortcut: KeyboardShortcut("v", modifiers: [.option, .shift, .command]),
                        enabled: canPasteLastTranscript) { self.pasteLastTranscript() },
            MenuCommand(title: "Settings…", shortcut: KeyboardShortcut(",")) { self.openSettings(.general) },
        ]] + moreMenu
    }
}

/// The menu-bar extra only answers the left click. A right click or Control-click on the icon
/// opens the status menu instead of the popover.
@MainActor
enum StatusMenu {
    static func install(model: @escaping @MainActor () -> AppModel?) {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let button = event.window?.contentView?.statusBarButton, let window = button.window, let model = model() else { return false }
                model.closePopover?()
                // Tracked right here, never from a task or the main queue: the menu's loop would hold the
                // main actor, and the talk key's release and Esc would wait until it closed.
                button.highlight(true)
                NSMenu(model.statusMenu).popUp(positioning: nil, at: NSPoint(x: window.frame.minX, y: window.frame.minY - 4), in: nil)
                button.highlight(false)
                return true
            }
            return handled ? nil : event
        }
    }
}

private extension NSView {
    var statusBarButton: NSStatusBarButton? {
        self as? NSStatusBarButton ?? subviews.lazy.compactMap(\.statusBarButton).first
    }
}

private extension NSMenu {
    convenience init(_ sections: [[MenuCommand]]) {
        self.init()
        autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 { addItem(.separator()) }
            section.forEach { addItem(CommandItem($0)) }
        }
    }
}

private final class CommandItem: NSMenuItem {
    private let perform: () -> Void

    init(_ command: MenuCommand) {
        perform = command.perform
        super.init(title: command.title, action: #selector(run), keyEquivalent: command.shortcut.map { String($0.key.character) } ?? "")
        target = self
        isEnabled = command.enabled
        let modifiers = command.shortcut?.modifiers ?? []
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        keyEquivalentModifierMask = mask
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { perform() }
}
