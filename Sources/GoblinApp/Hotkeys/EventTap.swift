import AppKit
import ApplicationServices

final class HotkeyEventTap: @unchecked Sendable {
    enum Input: Sendable { case press, release, chord, escape, reset }
    enum StartFailure: String, Error, Sendable { case creationFailed, runLoopSourceFailed }
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var stopped = false
    private var shortcut: HotkeyShortcut
    private var held = false
    private var recording = false
    private var suspended = false
    private var keyedFallback = false
    private let input: @Sendable (Input) -> Void
    private let result: @Sendable (Result<Void, StartFailure>) -> Void

    init(shortcut: HotkeyShortcut, input: @escaping @Sendable (Input) -> Void, result: @escaping @Sendable (Result<Void, StartFailure>) -> Void) {
        self.shortcut = shortcut
        self.input = input
        self.result = result
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "gob.lin hotkey event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func configure(recording: Bool, suspended: Bool, keyedFallback: Bool) {
        lock.lock()
        if suspended || suspended != self.suspended || keyedFallback != self.keyedFallback { held = false }
        self.recording = recording
        self.suspended = suspended
        self.keyedFallback = keyedFallback
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    private func run() {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyEventTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        // This modifying tap requires Accessibility; listen-only preflight does not describe its access.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { result(.failure(.creationFailed)); return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); result(.failure(.runLoopSourceFailed)); return
        }
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopped else { lock.unlock(); CFMachPortInvalidate(tap); return }
        runLoop = loop
        port = tap
        lock.unlock()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        result(.success(()))
        CFRunLoopRun()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.lock()
        runLoop = nil
        port = nil
        lock.unlock()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            held = false
            input(.reset)
            // Never query CGEventTapIsEnabled: re-enable from the callback only.
            if !stopped, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard !stopped, !suspended else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == 0x474F424C { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if code == 53, recording {
            if type == .keyDown { input(.escape) }
            return nil
        }
        if shortcut.keyCode != nil, keyedFallback { return Unmanaged.passUnretained(event) }
        if let registered = shortcut.keyCode {
            if code == registered {
                if type == .keyDown, shortcut.matches(flags: event.flags) {
                    if !held, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { held = true; input(.press) }
                    return nil
                }
                if type == .keyUp, held { held = false; input(.release); return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let down = shortcut.modifierIsDown(flags: event.flags)
            if down && !held, shortcut.isPrimaryModifierKey(code) { held = true; input(.press) }
            if !down && held {
                if shortcut.primaryModifierIsDown(flags: event.flags) { input(.chord) }
                else { held = false; input(.release) }
            }
            // Modifier events keep flowing so unrelated combinations keep their native behavior.
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, held { input(.chord) }
        return Unmanaged.passUnretained(event)
    }
}
