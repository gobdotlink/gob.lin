import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import GoblinCore
import SwiftUI

enum InsertionOutcome: Equatable {
    case idle, pending, success, failure(DiagnosticFailure)
}

@MainActor
final class TextInsertionService: ObservableObject {
    @Published var trailingSpace: Bool {
        didSet { defaults.set(trailingSpace, forKey: "goblin.trailingSpace") }
    }
    @Published private(set) var status = "Ready to insert into your focused app"
    @Published private(set) var busy = false
    @Published private(set) var hasRecoveryClipboard = false
    @Published private(set) var outcome: InsertionOutcome = .idle
    @Published private(set) var shortcutFailure: DiagnosticFailure?
    var lastTranscript: (() -> String?)?
    var onPasteRequested: (() -> Void)?
    private var recovery: ClipboardSnapshot?
    private var unverifiedChangeCount: Int?
    private var providers: [TranscriptDataProvider] = []
    private var previousApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var layoutObserver: NSObjectProtocol?
    private var carbonHandler: EventHandlerRef?
    private var pasteHotkey: EventHotKeyRef?
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let registerShortcuts: Bool
    static let syntheticEventTag: Int64 = 0x474F424C

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard, registerShortcuts: Bool = true) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.registerShortcuts = registerShortcuts
        trailingSpace = defaults.object(forKey: "goblin.trailingSpace") as? Bool ?? true
        guard registerShortcuts else { return }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { previousApplication = app }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                if app.processIdentifier != getpid() { self?.previousApplication = app }
            }
        }
        registerPasteHotkey()
        layoutObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let pasteHotkey = self.pasteHotkey { UnregisterEventHotKey(pasteHotkey); self.pasteHotkey = nil }
                self.registerPasteHotkey()
            }
        }
    }

    func insert(_ transcript: String) async {
        guard !busy else { setStatus("A paste is still awaiting confirmation", outcome: .failure(.insertionNotAcknowledged)); return }
        guard !transcript.isEmpty else { setStatus("No transcript to paste", outcome: .failure(.noTranscriptAvailable)); return }
        guard AXIsProcessTrusted() else { setStatus("Allow Accessibility before inserting text", outcome: .failure(.insertionPermissionMissing)); return }
        guard !IsSecureEventInputEnabled() else { setStatus("Secure Input is active; no text was inserted", outcome: .failure(.secureInputEnabled)); return }
        busy = true
        defer { busy = false }
        let text = InsertionPolicy.text(transcript, trailingSpace: trailingSpace)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            guard let previousApplication, !previousApplication.isTerminated else {
                setStatus("Focus the app you want to paste into first", outcome: .failure(.insertionTargetChanged)); return
            }
            previousApplication.activate()
            let until = ProcessInfo.processInfo.systemUptime + 1
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApplication.processIdentifier,
                  ProcessInfo.processInfo.systemUptime < until {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier else {
                setStatus("The intended app did not regain focus; nothing was inserted", outcome: .failure(.insertionTargetChanged)); return
            }
        }
        guard !Task.isCancelled, let target = FocusedText.capture(), target.pid != getpid(), !target.secure,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            setStatus("No accessible focused text target; nothing was inserted", outcome: .failure(.insertionFailed)); return
        }
        let bundle = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier ?? ""
        let quirks = AppInsertionQuirks.forBundle(bundle)
        let expected = target.value.flatMap { before in
            target.selection.flatMap { InsertionPolicy.expectedValue(before: before, selectedRange: $0, inserted: text) }
        }
        if !quirks.remoteDesktop, let expected, expected == target.value, let selection = target.selection {
            let fresh = FocusedText.read(pid: target.pid, element: target.element)
            guard fresh.value == expected, fresh.selection == selection, !fresh.secure,
                  target.isStillFocused(), !Task.isCancelled, !IsSecureEventInputEnabled() else {
                setStatus("The target changed before confirming the matching text; clipboard preserved", outcome: .failure(.insertionTargetChanged)); return
            }
            // Use the unchanged, validated selection's UTF-16 end; equivalent text can have different lengths.
            var caret = CFRange(location: selection.location + selection.length, length: 0)
            if let range = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, range)
            }
            let observed = FocusedText.read(pid: target.pid, element: target.element)
            guard observed.value == expected, !observed.secure, target.isStillFocused(),
                  !Task.isCancelled, !IsSecureEventInputEnabled() else {
                setStatus("The target changed while confirming the matching text; clipboard preserved", outcome: .failure(.insertionTargetChanged)); return
            }
            let caretConfirmed = observed.selection == NSRange(location: caret.location, length: 0)
            setStatus(caretConfirmed
                ? "Text already matched the dictation · clipboard preserved; caret at replacement end"
                : "Text already matched the dictation · clipboard preserved; caret placement was not confirmed", outcome: .success)
            return
        }
        if !quirks.preferPaste && !target.applicationFallback, let expected {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
                guard target.isStillFocused(), !Task.isCancelled, !IsSecureEventInputEnabled() else {
                    setStatus("Focus or Secure Input changed before insertion", outcome: .failure(.insertionTargetChanged)); return
                }
                let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
                if result == .success {
                    let verified = await DirectInsertionVerification.wait(expected: expected,
                        readValue: { FocusedText.read(pid: target.pid, element: target.element).value },
                        isSafe: { target.isStillFocused() && !IsSecureEventInputEnabled() })
                    if verified {
                        setStatus("Direct insertion verified in the focused app · clipboard preserved", outcome: .success)
                    } else {
                        setStatus("The app accepted an Accessibility write but did not confirm the edit; no duplicate paste was attempted", outcome: .failure(.insertionNotAcknowledged))
                    }
                    return
                }
                // A timeout may have applied the write: never retry a possibly successful insertion.
                guard result == .attributeUnsupported || result == .notImplemented else {
                    setStatus("Accessibility could not confirm insertion (\(result.rawValue)); no duplicate paste was attempted", outcome: .failure(.insertionNotAcknowledged)); return
                }
            }
        }
        guard let code = KeyboardLayout.pasteKeyCode() else { setStatus("Could not resolve Paste for this keyboard layout", outcome: .failure(.insertionFailed)); return }
        let preservationCount = pasteboard.changeCount
        guard let snapshot = clipboardToPreserve() else { setStatus("The current clipboard could not be preserved; nothing was pasted", outcome: .failure(.insertionClipboardBusy)); return }
        guard target.isStillFocused(), !Task.isCancelled, !IsSecureEventInputEnabled() else {
            setStatus("Focus or Secure Input changed before paste", outcome: .failure(.insertionTargetChanged)); return
        }
        let provider = TranscriptDataProvider(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        guard pasteboard.changeCount == preservationCount else { setStatus("Clipboard changed before paste; nothing was overwritten", outcome: .failure(.insertionClipboardBusy)); return }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            recovery = snapshot
            hasRecoveryClipboard = true
            // Keep recovery while gob.lin's own cleared/partial clipboard retains this count.
            unverifiedChangeCount = pasteboard.changeCount
            setStatus("Could not prepare the transcript clipboard; previous contents remain recoverable", outcome: .failure(.insertionClipboardBusy)); return
        }
        let ownedCount = pasteboard.changeCount
        // Keep promised data alive after an unverified paste or while another app is still reading.
        providers = [provider]
        recovery = snapshot
        hasRecoveryClipboard = true
        unverifiedChangeCount = ownedCount
        guard await sendPaste(code: code, target: target) else {
            setStatus("Paste cancelled after focus changed; transcript remains on clipboard and the previous clipboard is recoverable", outcome: .failure(.insertionTargetChanged))
            return
        }
        setStatus("Waiting for the focused app to consume the transcript", outcome: .pending)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            guard pasteboard.changeCount == ownedCount else {
                setStatus("Another app changed the clipboard; its contents were preserved. Your previous clipboard remains recoverable", outcome: .failure(.insertionClipboardBusy))
                return
            }
            guard target.isStillFocused() else {
                setStatus("Focus changed; transcript remains on clipboard and the previous clipboard is recoverable", outcome: .failure(.insertionTargetChanged))
                return
            }
            let observed = FocusedText.read(pid: target.pid, element: target.element)
            if !quirks.remoteDesktop,
               InsertionPolicy.mayRestoreClipboard(providerRead: provider.hasBeenRead, targetPID: target.pid, focusedPID: observed.pid,
                                                    before: target.value, expected: expected, observed: observed.value,
                                                    ownedChangeCount: ownedCount, currentChangeCount: pasteboard.changeCount) {
                if snapshot.restore(to: pasteboard) {
                    recovery = nil
                    hasRecoveryClipboard = false
                    unverifiedChangeCount = nil
                    providers.removeAll()
                    setStatus("Paste verified in the focused app · clipboard restored", outcome: .success)
                } else {
                    unverifiedChangeCount = pasteboard.changeCount
                    setStatus("Paste verified, but clipboard restore failed; recovery remains available", outcome: .failure(.insertionClipboardBusy))
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // This deadline only abandons verification. It must never trigger a clipboard restore.
        setStatus("This app did not expose paste confirmation. Transcript remains on clipboard; your previous clipboard is recoverable", outcome: .failure(.insertionNotAcknowledged))
    }

    func restorePreviousClipboard() {
        guard !busy, let recovery else { return }
        if recovery.restore(to: pasteboard) {
            self.recovery = nil
            hasRecoveryClipboard = false
            unverifiedChangeCount = nil
            providers.removeAll()
            setStatus("Previous clipboard restored by your request", outcome: .success)
        } else {
            unverifiedChangeCount = pasteboard.changeCount
            setStatus("Clipboard restore failed; recovery remains available", outcome: .failure(.insertionClipboardBusy))
        }
    }

    func shutdown() {
        if unverifiedChangeCount == pasteboard.changeCount {
            // Materialize promised text before the provider process exits; this never restores recovery.
            _ = pasteboard.string(forType: .string)
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver); self.layoutObserver = nil }
        if let pasteHotkey { UnregisterEventHotKey(pasteHotkey); self.pasteHotkey = nil }
        if let carbonHandler { RemoveEventHandler(carbonHandler); self.carbonHandler = nil }
    }

    private func clipboardToPreserve() -> ClipboardSnapshot? {
        if unverifiedChangeCount == pasteboard.changeCount, let recovery { return recovery }
        return ClipboardSnapshot(pasteboard: pasteboard)
    }

    private func sendPaste(code: CGKeyCode, target: FocusedText) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return false }
        guard target.isStillFocused(), pasteboard.changeCount == unverifiedChangeCount else { return false }
        for event in [commandDown, keyDown, keyUp, commandUp] { event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag) }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        commandDown.post(tap: .cghidEventTap)
        // Key-up must always be sent, including cancellation/focus loss, so Command cannot stick.
        defer { commandUp.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, target.isStillFocused(), !IsSecureEventInputEnabled(),
              pasteboard.changeCount == unverifiedChangeCount else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func registerPasteHotkey() {
        guard registerShortcuts else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x474F4250 else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<TextInsertionService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let onPasteRequested = service.onPasteRequested { onPasteRequested(); return }
                guard let text = service.lastTranscript?(), !text.isEmpty else {
                    service.setStatus("No transcript to paste", outcome: .failure(.noTranscriptAvailable)); return
                }
                Task { @MainActor in await service.insert(text) }
            }
            return noErr
        }
        if carbonHandler == nil {
            let handlerResult = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &carbonHandler)
            guard handlerResult == noErr else { shortcutFailure = .hotkeyUnavailable; setStatus("Paste-last shortcut unavailable (\(handlerResult))", outcome: .failure(.hotkeyUnavailable)); return }
        }
        guard let keyCode = KeyboardLayout.pasteKeyCode() else { shortcutFailure = .hotkeyUnavailable; setStatus("Paste-last shortcut could not resolve V in this layout", outcome: .failure(.hotkeyUnavailable)); return }
        let result = RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | optionKey | shiftKey), EventHotKeyID(signature: 0x474F4250, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &pasteHotkey)
        shortcutFailure = result == noErr ? nil : .hotkeyUnavailable
        if result != noErr { setStatus("Paste-last shortcut is already in use; use the menu item", outcome: .failure(.hotkeyUnavailable)) }
    }

    private func setStatus(_ message: String, outcome: InsertionOutcome) {
        status = message
        self.outcome = outcome
    }
}

struct AppInsertionQuirks {
    var preferPaste = false
    var remoteDesktop = false

    static func forBundle(_ bundle: String) -> Self {
        let pasteOnly: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                                      "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap", "com.google.Chrome",
                                      "company.thebrowser.Browser", "company.thebrowser.dia", "com.t3tools.t3code"]
        let remote: Set<String> = ["com.microsoft.rdc.macos", "com.realvnc.vncviewer", "com.teamviewer.TeamViewer", "com.anydesk.AnyDesk"]
        return Self(preferPaste: pasteOnly.contains(bundle) || remote.contains(bundle) || bundle.lowercased().contains("paseo"),
                    remoteDesktop: remote.contains(bundle))
    }
}
