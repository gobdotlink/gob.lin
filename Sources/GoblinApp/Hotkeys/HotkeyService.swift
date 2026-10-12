import AppKit
@preconcurrency import Carbon
import GoblinCore
import SwiftUI

@MainActor
final class HotkeyService: ObservableObject {
    @Published private(set) var shortcut: HotkeyShortcut
    @Published private(set) var secureInput = false
    @Published private(set) var status = "Waiting for permissions"
    @Published private(set) var recording: HotkeyStateMachine.Recording?
    @Published private(set) var processingCount = 0
    @Published private(set) var recorderActive = false
    var onAction: ((HotkeyStateMachine.Action) -> Void)?
    private let permissions: PermissionModel
    private var state = HotkeyStateMachine()
    private var tap: HotkeyEventTap?
    private var tapGeneration = UUID()
    private var carbonIssue: String?
    private var secureTimer: Timer?
    private var holdTimer: Timer?
    private var releaseTask: Task<Void, Never>?
    private var handler: EventHandlerRef?
    private var carbonShortcut: EventHotKeyRef?
    private var carbonEscape: EventHotKeyRef?
    private var carbonPressed = false
    private var wakeObserver: NSObjectProtocol?

    init(permissions: PermissionModel) {
        self.permissions = permissions
        if let data = UserDefaults.standard.data(forKey: "goblin.dictationShortcut"),
           let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data), stored.isValid { shortcut = stored }
        else { shortcut = .fn }
        permissions.onRevocation = { [weak self] _ in self?.stop() }
        permissions.onChange = { [weak self] _, new in
            guard let self else { return }
            if new.accessibility && new.inputMonitoring { self.start() } else { self.stop() }
        }
        secureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSecureInput() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        start()
    }

    func start() {
        guard tap == nil, permissions.snapshot.accessibility, permissions.snapshot.inputMonitoring else { return }
        checkSecureInput()
        installCarbonHandler()
        registerCarbonShortcut()
        let generation = UUID()
        tapGeneration = generation
        let created = HotkeyEventTap(shortcut: shortcut, input: { [weak self] input in
            Task { @MainActor in
                guard let self, self.tapGeneration == generation else { return }
                self.receive(input)
            }
        }, result: { [weak self] succeeded in
            Task { @MainActor in
                guard let self, self.tap != nil, self.tapGeneration == generation else { return }
                if succeeded { self.permissions.reportTapWorking(); self.updateStatus() }
                else { self.stop(); self.status = "Shortcut access needs a refresh"; self.permissions.reportTapFailure() }
            }
        })
        tap = created
        configureTap()
        created.start()
    }

    func stop() {
        tap?.stop()
        tap = nil
        tapGeneration = UUID()
        holdTimer?.invalidate()
        releaseTask?.cancel()
        carbonPressed = false
        apply(state.cancel())
        unregisterCarbonShortcut()
        setCarbonEscape(false)
        status = "Waiting for permissions"
    }

    func shutdown() {
        stop()
        secureTimer?.invalidate()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
    }

    func setShortcut(_ value: HotkeyShortcut) {
        guard value.isValid else { status = "Choose a supported shortcut"; return }
        stop()
        shortcut = value
        if let encoded = try? JSONEncoder().encode(value) { UserDefaults.standard.set(encoded, forKey: "goblin.dictationShortcut") }
        recorderActive = false
        start()
    }

    func setRecorderActive(_ active: Bool) {
        recorderActive = active
        if active { apply(state.cancel()); unregisterCarbonShortcut(); setCarbonEscape(false) }
        else { registerCarbonShortcut() }
        configureTap()
    }

    func processingCompleted() {
        state.processingCompleted()
        processingCount = state.processingCount
        updateStatus()
    }

    private func restart() { stop(); permissions.refresh(); start() }

    private func receive(_ input: HotkeyEventTap.Input) {
        guard tap != nil, !recorderActive, permissions.snapshot.accessibility, permissions.snapshot.inputMonitoring else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch input {
        case .press:
            releaseTask?.cancel()
            state.press(at: now)
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply(self.state.tick(at: ProcessInfo.processInfo.systemUptime))
                }
            }
        case .release:
            holdTimer?.invalidate()
            // A small hold-back absorbs repeat release/press pairs, never clipboard restoration.
            releaseTask?.cancel()
            releaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                self.holdTimer?.invalidate()
                self.apply(self.state.release(at: now))
            }
        case .chord: apply(state.chord())
        case .escape, .reset:
            holdTimer?.invalidate()
            releaseTask?.cancel()
            apply(state.cancel())
        }
    }

    private func apply(_ actions: [HotkeyStateMachine.Action]) {
        recording = state.recording
        processingCount = state.processingCount
        configureTap()
        setCarbonEscape(recording != nil && secureInput && shortcut.keyCode != nil)
        updateStatus()
        for action in actions {
            if let onAction { onAction(action) }
            else if case .finishRecording = action { processingCompleted() }
        }
    }

    private func checkSecureInput() {
        let current = IsSecureEventInputEnabled()
        guard current != secureInput else { return }
        secureInput = current
        if current && shortcut.keyCode == nil { apply(state.cancel()) }
        configureTap()
        setCarbonEscape(recording != nil && current && shortcut.keyCode != nil)
        updateStatus()
    }

    private func configureTap() {
        tap?.configure(recording: recording != nil, suspended: recorderActive || (secureInput && shortcut.keyCode == nil), keyedFallback: secureInput)
    }

    private func updateStatus() {
        if secureInput, let carbonIssue { status = carbonIssue }
        else if secureInput { status = shortcut.keyCode == nil ? "Secure Input: choose a keyed shortcut" : "Secure Input: using keyed fallback" }
        else if recording != nil { status = "Shortcut recording state · engine not connected" }
        else if tap != nil { status = "Shortcut ready · engine not connected" }
        else { status = "Waiting for permissions" }
    }

    private func installCarbonHandler() {
        guard handler == nil else { return }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x474F424C else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { service.receiveCarbon(id: id.id, pressed: pressed) }
            return noErr
        }
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if result != noErr { carbonIssue = "Secure Input fallback unavailable (\(result))"; updateStatus() }
    }

    private func receiveCarbon(id: UInt32, pressed: Bool) {
        if id == 2 {
            if pressed, recording != nil { receive(.escape) }
            return
        }
        guard id == 1 else { return }
        // Keep accepting the paired release if Secure Input turns off during a hold.
        if pressed {
            guard IsSecureEventInputEnabled(), !recorderActive else { return }
            checkSecureInput()
            carbonPressed = true
            receive(.press)
        } else if carbonPressed { carbonPressed = false; receive(.release) }
    }

    private func registerCarbonShortcut() {
        guard carbonShortcut == nil, !recorderActive, let code = shortcut.keyCode,
              permissions.snapshot.accessibility, permissions.snapshot.inputMonitoring else { return }
        let id = EventHotKeyID(signature: 0x474F424C, id: 1)
        let result = RegisterEventHotKey(UInt32(code), shortcut.carbonModifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &carbonShortcut)
        carbonIssue = result == noErr ? nil : "Secure Input fallback: shortcut already in use (\(result))"
        updateStatus()
    }

    private func unregisterCarbonShortcut() {
        if let carbonShortcut { UnregisterEventHotKey(carbonShortcut); self.carbonShortcut = nil }
    }

    private func setCarbonEscape(_ enabled: Bool) {
        if !enabled, let carbonEscape { UnregisterEventHotKey(carbonEscape); self.carbonEscape = nil }
        if enabled, carbonEscape == nil {
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(53, 0, EventHotKeyID(signature: 0x474F424C, id: 2), GetApplicationEventTarget(), 0, &reference) == noErr { carbonEscape = reference }
        }
    }
}
