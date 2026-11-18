import AppKit
import GoblinMeetings
import SwiftUI

/// One entry in the popover's ⋯ menu or the menu-bar icon's right-click menu. Both are built from
/// the same lists, so they can't drift apart.
struct MenuCommand {
    var title: String
    var shortcut: KeyboardShortcut?
    var enabled = true
    /// A second line under the title, in the native menu only.
    var subtitle: String? = nil
    /// An amber dot before the title: something there needs you.
    var attention = false
    /// Items of a submenu; `perform` isn't used when there are any.
    var submenu: [[MenuCommand]] = []
    var perform: () -> Void = {}
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
        return (isRecording ? [[cancel]] : []) + meetingMenu + [[
            MenuCommand(title: "Paste Last Dictation", shortcut: KeyboardShortcut("v", modifiers: [.option, .shift, .command]),
                        enabled: canPasteLastTranscript) { self.pasteLastTranscript() },
            MenuCommand(title: "Settings…", shortcut: KeyboardShortcut(",")) { self.openSettings(.general) },
        ]] + moreMenu
    }
}

extension AppModel {
    /// While Meetings is on: Stop and Mark This during a recording; otherwise Record for a call on the mic, and
    /// Record Conversation for people talking in the room.
    var meetingMenu: [[MenuCommand]] {
        guard meetings.enabled else { return [] }
        if meetings.isRecording {
            return [[MenuCommand(title: "Mark This (\(MeetingMarkHotkey.title))") { self.meetings.mark() },
                     MenuCommand(title: "Stop Recording") { self.meetings.stop() }], meetingsShortcuts]
        }
        var items: [MenuCommand] = []
        if let call = meetings.unrecordedCall ?? meetings.detectedCandidate {
            items.append(MenuCommand(title: "Record \(call.app.name) Call", enabled: meetings.canStart) { self.meetings.start(call) })
        }
        items.append(MenuCommand(title: "Record Conversation", enabled: meetings.canStart) { self.meetings.startConversation() })
        return [items, meetingsShortcuts]
    }

    /// Recent Meetings, with the five newest, and Open Meetings: the Meetings page without going through Settings.
    private var meetingsShortcuts: [MenuCommand] {
        let recent = meetings.meetings.filter { $0.state != .recording }.prefix(5).map { meeting in
            let toName = meeting.speakers.filter(MeetingsController.isUnnamedVoice).count
            let when = meeting.startedAt.formatted(.relative(presentation: .named))
            let subtitle = toName > 0 ? "\(when) · \(toName) \(toName == 1 ? "voice" : "voices") to name"
                : meeting.state == .processing ? "\(when) · processing" : "\(when) · \(MeetingTimeline.length(meeting.duration))"
            return MenuCommand(title: meeting.title, subtitle: subtitle, attention: toName > 0) { self.openMeeting(meeting.id) }
        }
        var items: [MenuCommand] = []
        if !recent.isEmpty {
            var submenu = [Array(recent)]
            // The newest meeting with a finished transcript.
            if let last = meetings.meetings.first(where: { $0.state == .ready }) {
                submenu.append([MenuCommand(title: "Copy Transcript of \(last.title)") { Task { await self.meetings.copyTranscript(last.id) } }])
            }
            items.append(MenuCommand(title: "Recent Meetings", submenu: submenu))
        }
        items.append(MenuCommand(title: "Open Meetings") { self.openMeeting() })
        return items
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
            for command in section {
                if command.submenu.isEmpty {
                    addItem(CommandItem(command))
                } else {
                    let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
                    item.submenu = NSMenu(command.submenu)
                    item.isEnabled = command.enabled
                    addItem(item)
                }
            }
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
        if let subtitle = command.subtitle { self.subtitle = subtitle }
        if command.attention { image = Self.attentionDot }
        let modifiers = command.shortcut?.modifiers ?? []
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        keyEquivalentModifierMask = mask
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The status lights' amber, as a menu item's leading dot.
    private static let attentionDot: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor(LightState.waiting.color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = "Needs names"
        return image
    }()

    @objc private func run() { perform() }
}
