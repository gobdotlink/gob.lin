import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
import GoblinCore
import SwiftUI

enum InsertionOutcome: Equatable {
    case idle, pending, success, readyToPaste, unverified, failure(DiagnosticFailure)
}

@MainActor
final class TextInsertionService: ObservableObject {
    @Published var destination: DictationDestination {
        didSet { defaults.set(destination.rawValue, forKey: "goblin.dictationDestination") }
    }
    @Published var trailingSpace: Bool {
        didSet { defaults.set(trailingSpace, forKey: "goblin.trailingSpace") }
    }
    @Published var watchEdits: Bool {
        didSet { defaults.set(watchEdits, forKey: "goblin.watchEditsAfterPaste") }
    }
    /// Where the last verified insertion landed, for the post-paste edit watcher.
    private(set) var lastAnchor: InsertionAnchor?
    @Published private(set) var status = "Ready to insert your dictation"
    @Published private(set) var busy = false
    @Published private(set) var hasRecoveryClipboard = false
    @Published private(set) var outcome: InsertionOutcome = .idle
    @Published private(set) var shortcutFailure: DiagnosticFailure?
    var lastTranscript: (() -> String?)?
    var onPasteRequested: (() -> Void)?
    private var recovery: ClipboardSnapshot?
    private var unverifiedChangeCount: Int?
    /// The clipboard saved ahead of a paste, valid while its change count still matches.
    private var prepared: (changeCount: Int, snapshot: ClipboardSnapshot)?
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
        destination = defaults.string(forKey: "goblin.dictationDestination").flatMap(DictationDestination.init(rawValue:)) ?? .originalField
        trailingSpace = defaults.object(forKey: "goblin.trailingSpace") as? Bool ?? true
        watchEdits = defaults.object(forKey: "goblin.watchEditsAfterPaste") as? Bool ?? true
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

    func insert(_ transcript: String, onPasteSent: (() -> Void)? = nil) async {
        await insert(transcript, originalTarget: nil, automatic: false, onPasteSent: onPasteSent)
    }

    func insert(_ transcript: String, into originalTarget: FocusedText?, onPasteSent: (() -> Void)? = nil) async {
        await insert(transcript, originalTarget: originalTarget, automatic: true, onPasteSent: onPasteSent)
    }

    private func insert(_ transcript: String, originalTarget: FocusedText?, automatic: Bool, onPasteSent: (() -> Void)?) async {
        guard !busy else { setStatus("A paste is still awaiting confirmation", outcome: .failure(.insertionNotAcknowledged)); return }
        guard !transcript.isEmpty else { setStatus("No transcript to paste", outcome: .failure(.noTranscriptAvailable)); return }
        guard AXIsProcessTrusted() else { setStatus("Allow Accessibility before inserting text", outcome: .failure(.insertionPermissionMissing)); return }
        guard !IsSecureEventInputEnabled() else { setStatus("Secure Input is active; no text was inserted", outcome: .failure(.secureInputEnabled)); return }
        busy = true
        lastAnchor = nil
        defer { busy = false }
        let text = InsertionPolicy.text(transcript, trailingSpace: trailingSpace)
        if !automatic, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
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
        guard !Task.isCancelled else {
            setStatus("Insertion cancelled; no text was inserted", outcome: .failure(.insertionTargetChanged)); return
        }
        var target: FocusedText
        if automatic {
            guard let originalTarget, originalTarget.pid != getpid(),
                  let application = NSRunningApplication(processIdentifier: originalTarget.pid), !application.isTerminated,
                  !originalTarget.secure else { readyToPaste(); return }
            if originalTarget.applicationFallback {
                guard originalTarget.isStillFocused() else { readyToPaste(); return }
                target = originalTarget
            } else {
                target = FocusedText.read(pid: originalTarget.pid, element: originalTarget.element)
                guard originalTarget.hasSameContext(as: target) else { readyToPaste(); return }
            }
        } else if let focused = FocusedText.capture(), focused.pid != getpid(), !focused.secure {
            target = focused
        } else {
            setStatus("No accessible focused text target; nothing was inserted", outcome: .failure(.insertionFailed)); return
        }
        let application = NSRunningApplication(processIdentifier: target.pid)
        let quirks = AppInsertionQuirks.forBundle(application?.bundleIdentifier ?? "", at: application?.bundleURL)
        let background = !target.isStillFocused()
        // Empty web editors may accept a value write while selected-text writes are a no-op.
        let valueInsertion = background && target.selection == NSRange(location: 0, length: 0)
            && originalTarget?.selection == target.selection && originalTarget?.value == target.value
            && (target.value == "" || target.value == "\n") && target.supportsValueInsertion
        if background {
            guard automatic, !quirks.remoteDesktop, target.window != nil,
                  valueInsertion || target.supportsDirectInsertion,
                  valueInsertion || !quirks.preferPaste || target.isApplicationFocused() else { readyToPaste(); return }
        }
        if let originalTarget, !target.applicationFallback, let selection = originalTarget.selection,
           let before = originalTarget.value, target.value == before, target.selection != selection {
            guard InsertionPolicy.expectedValue(before: before, selectedRange: selection, inserted: text) != nil,
                  isSafe(target, background: background, quirks: quirks) else { readyToPaste(); return }
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                readyToPaste(); return
            }
            let refreshed = FocusedText.read(pid: target.pid, element: target.element)
            guard target.hasSameContext(as: refreshed), refreshed.value == before, refreshed.selection == selection,
                  isSafe(refreshed, background: background, quirks: quirks) else { readyToPaste(); return }
            target = refreshed
        }
        let expected = valueInsertion ? text : target.value.flatMap { before in
            target.selection.flatMap { InsertionPolicy.expectedValue(before: before, selectedRange: $0, inserted: text,
                                                                     replacesEmptyLineBreak: quirks.emptyEditorLineBreak) }
        }
        if !quirks.remoteDesktop, let expected, expected == target.value, let selection = target.selection {
            let fresh = FocusedText.read(pid: target.pid, element: target.element)
            guard fresh.value == expected, fresh.selection == selection, !fresh.secure,
                  isSafe(target, background: background, quirks: quirks) else {
                setStatus("The target changed before confirming the matching text; clipboard preserved", outcome: .failure(.insertionTargetChanged)); return
            }
            // Use the unchanged, validated selection's UTF-16 end; equivalent text can have different lengths.
            var caret = CFRange(location: selection.location + selection.length, length: 0)
            if let range = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, range)
            }
            let observed = FocusedText.read(pid: target.pid, element: target.element)
            guard observed.value == expected, !observed.secure,
                  isSafe(target, background: background, quirks: quirks) else {
                setStatus("The target changed while confirming the matching text; clipboard preserved", outcome: .failure(.insertionTargetChanged)); return
            }
            lastAnchor = anchor(target: target, expected: expected, selection: selection, text: text, quirks: quirks)
            let caretConfirmed = observed.selection == NSRange(location: caret.location, length: 0)
            setStatus(caretConfirmed
                ? "Text already matched the dictation · clipboard preserved; caret at replacement end"
                : "Text already matched the dictation · clipboard preserved; caret placement was not confirmed", outcome: .success)
            return
        }
        if (!quirks.preferPaste || background) && !quirks.remoteDesktop && !target.applicationFallback, let expected {
            var settable = DarwinBoolean(false)
            let attribute = valueInsertion ? kAXValueAttribute : kAXSelectedTextAttribute
            if AXUIElementIsAttributeSettable(target.element, attribute as CFString, &settable) == .success, settable.boolValue {
                let fresh = FocusedText.read(pid: target.pid, element: target.element)
                guard target.hasSameContext(as: fresh), fresh.value == target.value, fresh.selection == target.selection,
                      isSafe(target, background: background, quirks: quirks, valueInsertion: valueInsertion) else {
                    setStatus("Focus or Secure Input changed before insertion", outcome: .failure(.insertionTargetChanged)); return
                }
                let result = AXUIElementSetAttributeValue(target.element, attribute as CFString, text as CFString)
                if result == .success {
                    let verified = await DirectInsertionVerification.wait(expected: expected,
                        readValue: { FocusedText.read(pid: target.pid, element: target.element).value },
                        isSafe: { self.isSafe(target, background: background, quirks: quirks, valueInsertion: valueInsertion) })
                    if verified {
                        var caretConfirmed = !valueInsertion
                        if valueInsertion, FocusedText.read(pid: target.pid, element: target.element).value == expected,
                           isSafe(target, background: background, quirks: quirks, valueInsertion: true) {
                            var caret = CFRange(location: text.utf16.count, length: 0)
                            if let range = AXValueCreate(.cfRange, &caret),
                               AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, range) == .success {
                                caretConfirmed = await DirectInsertionVerification.wait(expected: NSRange(location: caret.location, length: 0),
                                    readValue: { FocusedText.read(pid: target.pid, element: target.element).selection },
                                    isSafe: { self.isSafe(target, background: background, quirks: quirks, valueInsertion: true)
                                        && FocusedText.read(pid: target.pid, element: target.element).value == expected })
                            }
                        }
                        if let selection = target.selection {
                            lastAnchor = anchor(target: target, expected: expected, selection: selection, text: text, quirks: quirks)
                        }
                        let caretStatus = caretConfirmed ? "" : " · caret placement was not confirmed"
                        setStatus("Text landed in \(NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "the original app") · clipboard preserved\(caretStatus)", outcome: .success)
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
        guard !background else { readyToPaste(); return }
        guard let code = KeyboardLayout.pasteKeyCode() else { setStatus("Could not resolve Paste for this keyboard layout", outcome: .failure(.insertionFailed)); return }
        let preservationCount = pasteboard.changeCount
        guard let snapshot = clipboardToPreserve() else { setStatus("The current clipboard could not be preserved; nothing was pasted", outcome: .failure(.insertionClipboardBusy)); return }
        guard pasteTargetIsUnchanged(target), !Task.isCancelled, !IsSecureEventInputEnabled() else {
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
        guard await sendPaste(code: code, target: target, quirks: quirks) else {
            setStatus("Paste cancelled after focus changed; transcript remains on clipboard and the previous clipboard is recoverable", outcome: .failure(.insertionTargetChanged))
            return
        }
        setStatus("Waiting for the focused app to consume the transcript", outcome: .pending)
        onPasteSent?()
        guard expected != nil, !quirks.remoteDesktop else {
            if expected == nil, !quirks.remoteDesktop, target.role == "AXWebArea",
               await confirmForwardedPaste(text, from: target, provider: provider, ownedCount: ownedCount, snapshot: snapshot, quirks: quirks) {
                return
            }
            setStatus("Paste sent; this app does not expose edit verification. Transcript remains on clipboard; your previous clipboard is recoverable", outcome: .unverified)
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            guard pasteboard.changeCount == ownedCount else {
                setStatus("Another app changed the clipboard; its contents were preserved. Your previous clipboard remains recoverable", outcome: .failure(.insertionClipboardBusy))
                return
            }
            guard isSafe(target, background: false, quirks: quirks) else {
                setStatus("Focus changed; transcript remains on clipboard and the previous clipboard is recoverable", outcome: .failure(.insertionTargetChanged))
                return
            }
            let observed = FocusedText.read(pid: target.pid, element: target.element)
            if !quirks.remoteDesktop,
               InsertionPolicy.mayRestoreClipboard(providerRead: provider.hasBeenRead, targetPID: target.pid, focusedPID: observed.pid,
                                                    before: target.value, expected: expected, observed: observed.value, inserted: text,
                                                    ownedChangeCount: ownedCount, currentChangeCount: pasteboard.changeCount) {
                if let expected, let selection = target.selection, observed.value == expected {
                    lastAnchor = anchor(target: target, expected: expected, selection: selection, text: text, quirks: quirks)
                } else if let before = target.value, let value = observed.value,
                          let range = InsertionPolicy.pastedRange(before: before, observed: value, inserted: text) {
                    lastAnchor = anchor(target: target, expected: value, selection: NSRange(location: range.location, length: 0),
                                        text: text, quirks: quirks)
                }
                finishVerifiedPaste(restoring: snapshot)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // This deadline only abandons verification. It must never trigger a clipboard restore.
        setStatus("Paste sent; the edit could not be verified. Check the target before retrying. Transcript remains on clipboard; your previous clipboard is recoverable", outcome: .unverified)
    }

    /// A page with focus, as after selecting text in a T3 Code reply, can move a paste into one of its fields. Confirms
    /// the paste there when the app read it and the field it focused holds the only copy.
    private func confirmForwardedPaste(_ text: String, from page: FocusedText, provider: TranscriptDataProvider, ownedCount: Int,
                                       snapshot: ClipboardSnapshot, quirks: AppInsertionQuirks) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled, pasteboard.changeCount == ownedCount,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled() {
            if provider.hasBeenRead, let field = FocusedText.capture(timeout: 0.05), field.pid == page.pid, !field.secure,
               !CFEqual(field.element, page.element), let value = field.value,
               let range = InsertionPolicy.forwardedRange(of: text, in: value) {
                lastAnchor = anchor(target: field, expected: value, selection: NSRange(location: range.location, length: 0),
                                    text: text, quirks: quirks)
                // The field held nothing else, so it was empty; emptied again, it reads as a line break.
                if range.length == (value as NSString).length { lastAnchor?.normalizesEmptyLineBreak = quirks.emptyEditorLineBreak }
                finishVerifiedPaste(restoring: snapshot)
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func finishVerifiedPaste(restoring snapshot: ClipboardSnapshot) {
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
    }

    private func readyToPaste() {
        setStatus("Ready to paste. Focus a text field and press ⌥⇧⌘V, or use Paste Last Dictation.", outcome: .readyToPaste)
    }

    private func isSafe(_ target: FocusedText, background: Bool, quirks: AppInsertionQuirks, valueInsertion: Bool = false) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return false }
        if target.applicationFallback { return !background && target.isStillFocused() }
        let fresh = FocusedText.read(pid: target.pid, element: target.element)
        guard target.hasSameContext(as: fresh), target.window == nil || target.hasLiveWindow else { return false }
        if !background { return target.isStillFocused() }
        return target.hasLiveWindow && fresh.value != nil && fresh.selection != nil
            && (valueInsertion || !quirks.preferPaste || target.isApplicationFocused())
    }

    private func pasteTargetIsUnchanged(_ target: FocusedText) -> Bool {
        guard target.isStillFocused() else { return false }
        if target.applicationFallback { return true }
        let fresh = FocusedText.read(pid: target.pid, element: target.element)
        return target.hasSameContext(as: fresh) && fresh.value == target.value && fresh.selection == target.selection
            && (target.window == nil || target.hasLiveWindow)
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

    /// Consume the anchor from the latest verified insertion, if any.
    func takeLastAnchor() -> InsertionAnchor? {
        defer { lastAnchor = nil }
        return lastAnchor
    }

    /// The watcher anchor for a verified insertion: the target element plus the
    /// expected value split around the inserted span (UTF-16, like the AX ranges).
    private func anchor(target: FocusedText, expected: String, selection: NSRange, text: String,
                        quirks: AppInsertionQuirks) -> InsertionAnchor? {
        guard watchEdits, !quirks.credentialManager, !quirks.remoteDesktop else { return nil }
        let value = expected as NSString
        let end = selection.location + (text as NSString).length
        guard selection.location >= 0, end >= selection.location, end <= value.length else { return nil }
        return InsertionAnchor(pid: target.pid, element: target.element,
                               prefix: value.substring(with: NSRange(location: 0, length: selection.location)),
                               inserted: text,
                               suffix: value.substring(with: NSRange(location: end, length: value.length - end)),
                               normalizesEmptyLineBreak: quirks.emptyEditorLineBreak && target.value == "\n"
                                   && selection == NSRange(location: 0, length: 0))
    }

    /// Saves the clipboard while a dictation is still being prepared, so the paste only rereads it if it changed.
    func prepareClipboard() {
        let count = pasteboard.changeCount
        guard !busy, unverifiedChangeCount != count else { prepared = nil; return }
        prepared = ClipboardSnapshot(pasteboard: pasteboard).map { (count, $0) }
    }

    private func clipboardToPreserve() -> ClipboardSnapshot? {
        defer { prepared = nil }
        if unverifiedChangeCount == pasteboard.changeCount, let recovery { return recovery }
        if let prepared, prepared.changeCount == pasteboard.changeCount { return prepared.snapshot }
        return ClipboardSnapshot(pasteboard: pasteboard)
    }

    private func sendPaste(code: CGKeyCode, target: FocusedText, quirks: AppInsertionQuirks) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return false }
        // The target was checked just before the clipboard was written; it is checked again after the hold, before V.
        guard pasteboard.changeCount == unverifiedChangeCount else { return false }
        for event in [commandDown, keyDown, keyUp, commandUp] { event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag) }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        commandDown.post(tap: .cghidEventTap)
        // Key-up must always be sent, including cancellation/focus loss, so Command cannot stick.
        defer { commandUp.post(tap: .cghidEventTap) }
        // V carries the Command flag itself; the brief hold only orders the modifier first. Remote desktop
        // clients forward keys over the network and get longer.
        try? await Task.sleep(for: .milliseconds(quirks.remoteDesktop ? 100 : 15))
        guard !Task.isCancelled, pasteTargetIsUnchanged(target), !IsSecureEventInputEnabled(),
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
    var emptyEditorLineBreak = false
    /// Never watch edits or read text in credential managers, even outside their secure fields.
    var credentialManager = false
    var electron = false
    /// VS Code and its forks can switch to screen reader mode when an assistive app turns on their tree.
    var codeEditor = false

    /// Electron builds its web accessibility tree only for assistive apps that ask for it.
    var requestsAccessibilityTree: Bool { electron && !codeEditor && !credentialManager }

    static func forBundle(_ bundle: String, at url: URL? = nil) -> Self {
        let pasteOnly: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.google.Chrome",
                                      "company.thebrowser.Browser", "company.thebrowser.dia", "com.t3tools.t3code"]
        // Electron editors report Accessibility text writes as applied without changing the text.
        let electron = url.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        let remote: Set<String> = ["com.microsoft.rdc.macos", "com.realvnc.vncviewer", "com.teamviewer.TeamViewer", "com.anydesk.AnyDesk"]
        let credentialManagers: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7",
                                               "com.bitwarden.desktop", "com.dashlane.Dashlane",
                                               "org.keepassxc.KeePassXC", "com.lastpass.LastPass"]
        let codeEditors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.kiro.desktop", "com.google.antigravity"]
        return Self(preferPaste: electron || pasteOnly.contains(bundle) || remote.contains(bundle),
                    remoteDesktop: remote.contains(bundle),
                    emptyEditorLineBreak: electron || bundle == "com.t3tools.t3code",
                    credentialManager: credentialManagers.contains(bundle),
                    electron: electron, codeEditor: codeEditors.contains(bundle))
    }
}
