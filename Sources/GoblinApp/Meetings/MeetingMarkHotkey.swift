import AppKit
@preconcurrency import Carbon
import GoblinMeetings
import os

/// ⌃⌥M marks the moment while a meeting records, calls and conversations alike. Registered only while recording, so
/// the combination stays free for other apps the rest of the time.
///
/// Three routes, so a press always lands once:
/// - a Carbon hot key, from any app, which needs no permission and swallows the press;
/// - a local key monitor, for a press delivered to gob.lin itself (the Sidekick while a label is typed, Settings, or
///   a key event posted straight to gob.lin), which never reaches the hot key;
/// - a global key monitor, only when another app already owns ⌃⌥M and the hot key can't be registered.
@MainActor
final class MeetingMarkHotkey {
    static let title = "⌃⌥M"
    private static let signature: OSType = 0x474F_424D // "GOBM"
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var layoutObserver: NSObjectProtocol?
    private var mKeyCode = MeetingMarkShortcut.ansiKeyCode
    private let onPress: () -> Void
    private let logger = Logger(subsystem: "app.goblin.dictation", category: "meetings")

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    /// True while ⌃⌥M marks, by any route.
    var isRegistered: Bool { hotkey != nil || localMonitor != nil }

    /// The Carbon hot key failed; ⌃⌥M then works from other apps only through the global monitor.
    private(set) var registrationStatus: OSStatus = noErr

    func register() {
        guard !isRegistered else { return }
        // M wherever the layout puts it; ANSI M otherwise.
        mKeyCode = KeyboardLayout.keyCode(producing: "m") ?? MeetingMarkShortcut.ansiKeyCode
        registrationStatus = registerHotKey()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = Key(event)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.matches(key) else { return false }
                self.logger.info("mark shortcut pressed inside gob.lin")
                self.onPress()
                return true
            }
            return handled ? nil : event
        }
        reportRegistration()
        // Another layout can put M on another key: the hot key follows it, as the paste shortcut does.
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutChanged() }
        }
    }

    private func layoutChanged() {
        guard isRegistered else { return }
        let code = KeyboardLayout.keyCode(producing: "m") ?? MeetingMarkShortcut.ansiKeyCode
        guard code != mKeyCode else { return }
        mKeyCode = code
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        registrationStatus = registerHotKey()
        reportRegistration()
    }

    /// Logs the hot key, or falls back to the global monitor when another app owns ⌃⌥M.
    private func reportRegistration() {
        if registrationStatus == noErr {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            globalMonitor = nil
            logger.info("mark shortcut registered: keyCode \(self.mKeyCode, privacy: .public)")
        } else {
            // Another app owns ⌃⌥M. A global monitor still sees the press there (with Accessibility), though it can't
            // keep it from that app.
            if globalMonitor == nil {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let key = Key(event)
                    MainActor.assumeIsolated {
                        guard let self, self.matches(key) else { return }
                        self.logger.info("mark shortcut pressed, seen by the global monitor")
                        self.onPress()
                    }
                }
            }
            logger.error("""
                mark shortcut hot key unavailable (OSStatus \(self.registrationStatus, privacy: .public)); \
                global monitor \(self.globalMonitor == nil ? "unavailable" : "on", privacy: .public)
                """)
        }
    }

    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        layoutObserver = nil
    }

    /// What the monitors need from a key event, read where the event arrives.
    private struct Key: Sendable {
        let code: UInt16
        let characters: String?
        let flags: UInt
        let isRepeat: Bool

        init(_ event: NSEvent) {
            code = event.keyCode
            characters = event.charactersIgnoringModifiers
            flags = event.modifierFlags.rawValue
            isRepeat = event.isARepeat
        }
    }

    private func matches(_ key: Key) -> Bool {
        !key.isRepeat && MeetingMarkShortcut.matches(keyCode: key.code, charactersIgnoringModifiers: key.characters,
                                                     modifierFlags: key.flags, mKeyCode: mKeyCode)
    }

    private func registerHotKey() -> OSStatus {
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == MeetingMarkHotkey.signature else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<MeetingMarkHotkey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    owner.logger.info("mark shortcut pressed")
                    owner.onPress()
                }
                return noErr
            }
            let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(),
                                                &handler)
            guard installed == noErr else { return installed }
        }
        return RegisterEventHotKey(UInt32(mKeyCode), UInt32(controlKey | optionKey), EventHotKeyID(signature: Self.signature, id: 1),
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotkey)
    }
}
