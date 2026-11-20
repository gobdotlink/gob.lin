import AppKit
import Combine
import SwiftUI

/// What the Sidekick shows besides the recording itself: window or pill, notes or not, the mark being labelled, a
/// short confirmation line, and recent levels for its meters.
@MainActor
final class SidekickModel: ObservableObject {
    /// The pill instead of the window.
    @Published var collapsed: Bool
    /// The notes column beside the captions.
    @Published var expanded: Bool
    @Published var keepOnTop: Bool
    /// The window (or the pill) is on the right half of its screen: the goblin looks left, and sits on the pill's right.
    @Published var onRight = true
    /// The mark whose label field has the keyboard, if any.
    @Published var editingMark: UUID?
    /// What that field holds, so hiding or collapsing the window can keep it.
    var labelDraft = ""
    /// "Copied 12 lines.", for a couple of seconds.
    @Published var flash: String?
    @Published private(set) var microphoneLevels = Array(repeating: 0.0, count: 5)
    @Published private(set) var systemLevels = Array(repeating: 0.0, count: 5)
    /// The consent reminder at the top of the captions, until dismissed for this recording.
    @Published var showsConsent = true
    /// Captures only: open scrolled back to the oldest line, with the scroller showing.
    var previewScrolledBack = false
    var setCollapsed: (Bool) -> Void = { _ in }
    var setExpanded: (Bool) -> Void = { _ in }
    var setKeepOnTop: (Bool) -> Void = { _ in }
    var beginLabel: (UUID) -> Void = { _ in }
    /// Ends the label being typed. `handBack` returns the keyboard to the app that had it; false when the keyboard
    /// already went somewhere else, like the notes.
    var endLabel: (_ handBack: Bool) -> Void = { _ in }
    var showMenu: (NSView?) -> Void = { _ in }
    private var flashTask: Task<Void, Never>?

    init(collapsed: Bool = false, expanded: Bool = false, keepOnTop: Bool = true) {
        self.collapsed = collapsed
        self.expanded = expanded
        self.keepOnTop = keepOnTop
    }

    func push(microphone: Float, system: Float) {
        microphoneLevels = Array((microphoneLevels + [Self.meter(microphone)]).suffix(5))
        systemLevels = Array((systemLevels + [Self.meter(system)]).suffix(5))
    }

    func resetLevels() {
        microphoneLevels = Array(repeating: 0, count: 5)
        systemLevels = microphoneLevels
    }

    func say(_ line: String) {
        flash = line
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    /// −55 dB is silence and −10 dB a full bar.
    static func meter(_ decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, Double(decibels + 55) / 45))
    }
}

/// The Sidekick's window: titled, resizable and in Mission Control, but a non-activating panel that takes the keyboard
/// only for a text field (the notes, a mark's label). A click or a drag anywhere else leaves it with the call.
class SidekickWindow: NSPanel {
    /// The yellow light collapses to the pill instead of the Dock.
    var onMiniaturize: () -> Void = {}
    /// Escape, outside a label field: leave the notes and hand the keyboard back.
    var onEscape: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        title = "Sidekick"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        // In Mission Control and on every Space, over full-screen calls; never in ⌘` (the app stays an accessory).
        collectionBehavior = [.managed, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Never part of a screen share or recording. Newer capture APIs may ignore this, so the call app's own
        // "you're sharing" state hides the window as well.
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performMiniaturize(_ sender: Any?) { onMiniaturize() }
    override func miniaturize(_ sender: Any?) { onMiniaturize() }
    override func cancelOperation(_ sender: Any?) { onEscape() }

    /// A click on the notes or a label field takes the keyboard and places the cursor at once; without this the first
    /// click only makes the window key and a second one is needed.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, let content = contentView, let frame = content.superview {
            var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let current = view, !(current is NSText || current is NSTextField) { view = current.superview }
            if view != nil { makeKey() }
        }
        super.sendEvent(event)
    }
}

/// The pill: a borderless, non-activating panel that floats, drags from anywhere and never takes the keyboard.
final class SidekickPillWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Sidekick"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the Sidekick while a meeting records: a real window that starts at the top right, out of the overlay's
/// corner, remembers a compact and an expanded frame, and collapses to the pill. Hidden from screen sharing.
@MainActor
final class SidekickController: NSObject, NSWindowDelegate {
    static let collapsedKey = "meetings.sidekick.collapsed"
    static let expandedKey = "meetings.sidekick.expanded"
    static let keepOnTopKey = "meetings.sidekick.keepOnTop"
    static let compactFrameKey = "meetings.sidekick.compactFrame"
    static let expandedFrameKey = "meetings.sidekick.expandedFrame"
    static let compactSize = CGSize(width: 320, height: 480)
    static let compactMinimum = CGSize(width: 300, height: 360)
    static let expandedSize = CGSize(width: 860, height: 600)
    static let expandedMinimum = CGSize(width: 640, height: 420)
    /// From the screen's edge to the window, as the overlay sits.
    static let inset: CGFloat = 16

    let model: SidekickModel
    private let meetings: MeetingsController
    private let defaults: UserDefaults
    private let overlayPosition: () -> OverlayPosition
    private let window: SidekickWindow
    private let pill: SidekickPillWindow
    private var subscriptions: Set<AnyCancellable> = []
    private var shown = false
    /// Frames this controller sets aren't the person's, so they aren't remembered.
    private var settingFrame = false
    /// The app that had the keyboard before the Sidekick took it, to hand it back.
    private var previousApp: NSRunningApplication?
    private var fadeOut: Task<Void, Never>?
    private var pillSettle: Task<Void, Never>?

    init(meetings: MeetingsController, defaults: UserDefaults, overlayPosition: @escaping () -> OverlayPosition) {
        self.meetings = meetings
        self.defaults = defaults
        self.overlayPosition = overlayPosition
        model = SidekickModel(collapsed: defaults.bool(forKey: Self.collapsedKey), expanded: defaults.bool(forKey: Self.expandedKey),
                              keepOnTop: defaults.object(forKey: Self.keepOnTopKey) as? Bool ?? true)
        window = SidekickWindow(contentRect: NSRect(origin: .zero, size: Self.compactSize))
        pill = SidekickPillWindow(contentRect: NSRect(origin: .zero, size: SidekickPill.windowSize))
        super.init()
        window.minSize = model.expanded ? Self.expandedMinimum : Self.compactMinimum
        window.alphaValue = 0
        pill.alphaValue = 0
        applyLevel()
        window.contentView = NSHostingView(rootView: SidekickView(meetings: meetings, model: model))
        pill.contentView = NSHostingView(rootView: SidekickPill(meetings: meetings, model: model))
        window.delegate = self
        pill.delegate = self
        window.onMiniaturize = { [weak self] in self?.setCollapsed(true) }
        window.onEscape = { [weak self] in self?.escape() }
        model.setCollapsed = { [weak self] collapsed in self?.setCollapsed(collapsed) }
        model.setExpanded = { [weak self] expanded in self?.setExpanded(expanded) }
        model.setKeepOnTop = { [weak self] onTop in self?.setKeepOnTop(onTop) }
        model.beginLabel = { [weak self] id in self?.beginLabel(id) }
        model.endLabel = { [weak self] handBack in self?.endLabel(handBack: handBack) }
        model.showMenu = { [weak self] view in self?.showMenu(from: view) }
        meetings.willStop = { [weak self] in if self?.model.editingMark != nil { self?.commitLabel() } }
        meetings.$phase.combineLatest(meetings.$sidekickVisible).sink { [weak self] phase, visible in
            guard let self else { return }
            if case .recording(let recording) = phase {
                self.model.push(microphone: recording.microphoneLevel, system: recording.systemLevel)
                self.setShown(visible && !recording.sharing)
            } else {
                self.setShown(false)
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }.store(in: &subscriptions)
    }

    private var current: NSWindow { model.collapsed ? pill : window }

    // MARK: Showing

    private func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        fadeOut?.cancel()
        if show {
            model.resetLevels()
            if model.editingMark != nil { endLabel(handBack: false) }
            if model.collapsed { placePill(from: windowFrame(expanded: model.expanded)) } else { setWindowFrame(windowFrame(expanded: model.expanded), animated: false) }
            let showing = current
            showing.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                showing.animator().alphaValue = 1
            }
        } else {
            // Hiding (by hand, or for a screen share) keeps what was typed; only Escape throws a label away. This runs
            // inside the update that hid the window, which would overwrite a mark changed now, so the label goes in
            // once that update has landed. Stop saves it earlier, through `willStop`.
            if let id = model.editingMark {
                let draft = model.labelDraft
                endLabel(handBack: true)
                Task { @MainActor [meetings] in meetings.label(id, draft) }
            }
            let hiding = current
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                hiding.animator().alphaValue = 0
            }
            fadeOut = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled, !self.shown else { return }
                self.window.orderOut(nil)
                self.pill.orderOut(nil)
            }
        }
    }

    /// A new recording starts with the reminder showing again.
    func recordingStarted() { model.showsConsent = true }

    /// The pill in place of the window, near where the window's top right was, or the window back at its frame.
    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != model.collapsed else { return }
        if model.editingMark != nil { commitLabel() }
        let from = window.isVisible ? window.frame : windowFrame(expanded: model.expanded)
        model.collapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedKey)
        guard shown else { return }
        if collapsed {
            if window.isKeyWindow { handBack() }
            placePill(from: from)
            pill.alphaValue = 1
            pill.orderFrontRegardless()
            window.orderOut(nil)
        } else {
            setWindowFrame(windowFrame(expanded: model.expanded), animated: false)
            window.alphaValue = 1
            window.orderFrontRegardless()
            pill.orderOut(nil)
        }
    }

    /// Notes beside the captions, in the same window at its remembered expanded frame; or back to compact.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != model.expanded else { return }
        if model.collapsed { setCollapsed(false) }
        model.expanded = expanded
        defaults.set(expanded, forKey: Self.expandedKey)
        window.minSize = expanded ? Self.expandedMinimum : Self.compactMinimum
        guard shown else { return }
        setWindowFrame(windowFrame(expanded: expanded), animated: true)
    }

    private func setKeepOnTop(_ onTop: Bool) {
        model.keepOnTop = onTop
        defaults.set(onTop, forKey: Self.keepOnTopKey)
        applyLevel()
    }

    /// Above the call's windows and below the dictation overlay, or an ordinary window. The pill always floats.
    private func applyLevel() { window.level = model.keepOnTop ? .floating : .normal }

    // MARK: Frames

    /// The overlay's corners on this screen, both sides, since it mirrors left when the caret is in its way.
    private func overlayZones(in visible: NSRect) -> [NSRect] {
        let size = DictationOverlay.contentSize
        let y = overlayPosition() == .bottom ? visible.minY + 16 : visible.maxY - 16 - size.height
        return [NSRect(x: visible.maxX - 16 - size.width, y: y, width: size.width, height: size.height),
                NSRect(x: visible.minX + 16, y: y, width: size.width, height: size.height)].map { $0.insetBy(dx: -8, dy: -8) }
    }

    /// The first placement: the top right of the screen, 16 pt in, clear of the overlay's corner.
    private func firstFrame(in visible: NSRect) -> NSRect {
        let size = Self.compactSize
        var frame = NSRect(x: visible.maxX - Self.inset - size.width, y: visible.maxY - Self.inset - size.height,
                           width: size.width, height: size.height)
        for zone in overlayZones(in: visible) where frame.intersects(zone) {
            if overlayPosition() == .bottom { frame.origin.y = max(frame.minY, zone.maxY) } else { frame.origin.y = zone.minY - size.height }
        }
        return Self.clamp(frame, to: visible)
    }

    /// The remembered frame for compact or expanded, kept on screen. Expanded with nothing remembered grows from the
    /// compact frame toward the middle of the screen.
    private func windowFrame(expanded: Bool) -> NSRect {
        let compact = savedFrame(Self.compactFrameKey).map(Self.onScreen)
            ?? firstFrame(in: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: Self.compactSize))
        guard expanded else { return compact }
        if let saved = savedFrame(Self.expandedFrameKey) { return Self.onScreen(saved) }
        let visible = Self.visible(for: compact)
        let size = Self.expandedSize
        let right = compact.midX > visible.midX
        let frame = NSRect(x: right ? compact.maxX - size.width : compact.minX, y: compact.maxY - size.height,
                           width: size.width, height: size.height)
        return Self.clamp(frame, to: visible)
    }

    private func savedFrame(_ key: String) -> NSRect? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let frame = NSRectFromString(string)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    /// The visible frame of the screen showing most of `frame`, or the main screen's when none does.
    private static func visible(for frame: NSRect) -> NSRect {
        let best = NSScreen.screens.max { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }
        if let best, best.visibleFrame.intersects(frame) { return best.visibleFrame }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? frame
    }

    private static func onScreen(_ frame: NSRect) -> NSRect { clamp(frame, to: visible(for: frame)) }

    /// Inside `visible`, shrunk to fit if it must.
    private static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    private func setWindowFrame(_ frame: NSRect, animated: Bool) {
        settingFrame = true
        if animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.frameSettled() }
            }
        } else {
            window.setFrame(frame, display: true)
            frameSettled()
        }
    }

    private func frameSettled() {
        settingFrame = false
        updateSide()
    }

    /// The pill's capsule and goblin with their top right where the window's was, on screen.
    private func placePill(from frame: NSRect) {
        let visible = Self.visible(for: frame)
        let size = SidekickPill.contentSize
        let content = Self.clamp(NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height, width: size.width, height: size.height),
                                 to: visible)
        // Judged where the pill lands, as after a drag, so settling never moves its goblin.
        model.onRight = content.midX > visible.midX
        pill.setFrame(content.insetBy(dx: -SidekickPill.margin, dy: -SidekickPill.margin), display: true)
    }

    private func keepOnScreen() {
        guard shown else { return }
        if model.collapsed {
            let content = pill.frame.insetBy(dx: SidekickPill.margin, dy: SidekickPill.margin)
            let kept = Self.onScreen(content)
            if kept != content { pill.setFrame(kept.insetBy(dx: -SidekickPill.margin, dy: -SidekickPill.margin), display: true) }
        } else {
            let kept = Self.onScreen(window.frame)
            if kept != window.frame { setWindowFrame(kept, animated: false) }
        }
    }

    /// The goblin looks toward the middle of the screen from wherever the window is.
    private func updateSide() {
        let frame = window.frame
        let onRight = frame.midX > Self.visible(for: frame).midX
        if model.onRight != onRight { model.onRight = onRight }
    }

    /// Once the pill stops moving, its goblin moves to the side nearer the screen's edge, and the capsule stays put.
    private func pillMoved() {
        pillSettle?.cancel()
        pillSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            // Held still mid-drag: settle once it's let go.
            while NSEvent.pressedMouseButtons != 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard let self, !Task.isCancelled else { return }
            let frame = self.pill.frame
            let onRight = frame.midX > Self.visible(for: frame).midX
            guard onRight != self.model.onRight else { return }
            let shift = SidekickPill.goblinWidth + SidekickPill.spacing
            self.model.onRight = onRight
            self.pill.setFrameOrigin(NSPoint(x: frame.minX + (onRight ? shift : -shift), y: frame.minY))
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === pill { pillMoved(); return }
        rememberFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        rememberFrame()
    }

    private func rememberFrame() {
        guard !settingFrame, shown, !model.collapsed else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: model.expanded ? Self.expandedFrameKey : Self.compactFrameKey)
        updateSide()
    }

    /// The red light hides the Sidekick until the call ends, like the menu's Hide; Show Sidekick brings it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Non-activating, so the call app is still in front and gets the keyboard back afterwards.
        if previousApp == nil, let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
    }

    func windowDidResignKey(_ notification: Notification) { previousApp = nil }

    // MARK: Labels

    /// Someone chose Add Label: the field takes the keyboard, and hands it back afterwards.
    private func beginLabel(_ id: UUID) {
        if previousApp == nil, let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        if model.collapsed { setCollapsed(false) }
        model.editingMark = id
        window.makeKey()
    }

    /// Saves the label being typed, then hands the keyboard back.
    private func commitLabel() {
        if let id = model.editingMark { meetings.label(id, model.labelDraft) }
        endLabel(handBack: true)
    }

    private func endLabel(handBack: Bool) {
        model.editingMark = nil
        if handBack, window.isKeyWindow { self.handBack() }
    }

    private func escape() {
        if model.editingMark != nil { endLabel(handBack: true) } else if window.isKeyWindow { handBack() }
    }

    /// Gives the keyboard back to the app that had it.
    private func handBack() {
        let app = previousApp
        window.makeFirstResponder(nil)
        window.resignKey()
        if let app, app != .current { app.activate() }
        previousApp = nil
    }

    // MARK: Menu

    private func showMenu(from view: NSView?) {
        let menu = NSMenu()
        let items: [(String, Selector?)] = [("Copy New Lines", #selector(MenuTarget.copyNew)), ("Copy All", #selector(MenuTarget.copyAll)),
                                            ("", nil), (model.expanded ? "Hide Notes" : "Show Notes", #selector(MenuTarget.toggleNotes)),
                                            ("Keep on Top", #selector(MenuTarget.toggleOnTop)),
                                            ("Collapse to Pill", #selector(MenuTarget.collapse)),
                                            ("Hide Until the Call Ends", #selector(MenuTarget.hide)),
                                            ("", nil), ("Stop Recording", #selector(MenuTarget.stop))]
        let target = MenuTarget(controller: self)
        for (title, action) in items {
            guard let action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            if action == #selector(MenuTarget.hide), meetings.recording?.inPerson == true { item.title = "Hide Until Recording Stops" }
            if action == #selector(MenuTarget.toggleOnTop) { item.state = model.keepOnTop ? .on : .off }
            if action == #selector(MenuTarget.collapse) { item.isHidden = model.collapsed }
            menu.addItem(item)
        }
        let location = view.map { NSPoint(x: 0, y: $0.bounds.maxY + 4) } ?? NSEvent.mouseLocation
        // Tracked here, synchronously, so the target lives as long as the menu.
        withExtendedLifetime(target) { _ = menu.popUp(positioning: nil, at: location, in: view) }
    }

    fileprivate func copy(onlyNew: Bool) {
        let count = meetings.copyTranscript(onlyNew: onlyNew)
        model.say(count == 0 ? (onlyNew ? "Nothing new since your last copy." : "Nothing said yet.")
                  : "Copied \(count) \(count == 1 ? "line" : "lines").")
    }

    fileprivate func toggleNotes() { setExpanded(!model.expanded) }
    fileprivate func toggleOnTop() { setKeepOnTop(!model.keepOnTop) }
    fileprivate func collapse() { setCollapsed(true) }
    fileprivate func hide() { meetings.setSidekickVisible(false) }
    fileprivate func stop() { meetings.stop() }

    func shutdown() {
        subscriptions.removeAll()
        window.orderOut(nil)
        pill.orderOut(nil)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// NSMenu wants an Objective-C target.
@MainActor
private final class MenuTarget: NSObject {
    weak var controller: SidekickController?
    init(controller: SidekickController) { self.controller = controller }
    @objc func copyNew() { controller?.copy(onlyNew: true) }
    @objc func copyAll() { controller?.copy(onlyNew: false) }
    @objc func toggleNotes() { controller?.toggleNotes() }
    @objc func toggleOnTop() { controller?.toggleOnTop() }
    @objc func collapse() { controller?.collapse() }
    @objc func hide() { controller?.hide() }
    @objc func stop() { controller?.stop() }
}
