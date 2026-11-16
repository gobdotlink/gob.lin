import AppKit
import Combine
import SwiftUI

/// What the Sidekick shows besides the recording itself: collapsed or open, the mark being labelled, a short
/// confirmation line, and recent levels for its meters.
@MainActor
final class SidekickModel: ObservableObject {
    enum Edge: String { case left, right }

    @Published var collapsed: Bool
    @Published var edge: Edge = .right
    /// The mark whose label field has the keyboard, if any.
    @Published var editingMark: UUID?
    /// What that field holds, so hiding or collapsing the panel can keep it.
    var labelDraft = ""
    /// "Copied 12 lines.", for a couple of seconds.
    @Published var flash: String?
    @Published private(set) var microphoneLevels = Array(repeating: 0.0, count: 5)
    @Published private(set) var systemLevels = Array(repeating: 0.0, count: 5)
    /// The consent reminder at the top of the captions, until dismissed for this recording.
    @Published var showsConsent = true
    /// Captures only: open scrolled back to the oldest line, with the scroller showing.
    var previewScrolledBack = false
    var dragChanged: (CGPoint) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    var setCollapsed: (Bool) -> Void = { _ in }
    var beginLabel: (UUID) -> Void = { _ in }
    var endLabel: () -> Void = {}
    var showMenu: (NSView?) -> Void = { _ in }
    private var flashTask: Task<Void, Never>?

    init(collapsed: Bool) { self.collapsed = collapsed }

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

/// Takes the keyboard only while a mark's label is being typed; otherwise clicks never move focus off the call.
private final class SidekickWindow: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// The Sidekick's window: a non-activating panel at a screen edge, out of the overlay's corner, hidden from screen
/// sharing. Drag it anywhere; it snaps to the nearer side and remembers where it was.
@MainActor
final class SidekickController {
    static let edgeKey = "meetings.sidekick.edge"
    static let topKey = "meetings.sidekick.top"
    static let collapsedKey = "meetings.sidekick.collapsed"
    /// The visible panel; the window adds `margin` on every side for the shadow.
    static let expandedSize = CGSize(width: 296, height: 448)
    static let collapsedSize = CGSize(width: SidekickView.pillWidth + 8 + 64, height: 64)
    static let margin: CGFloat = 24
    /// From the screen's edge to the panel, as the overlay sits.
    static let inset: CGFloat = 16

    let model: SidekickModel
    private let meetings: MeetingsController
    private let defaults: UserDefaults
    private let overlayPosition: () -> OverlayPosition
    private let panel: SidekickWindow
    private var subscriptions: Set<AnyCancellable> = []
    private var shown = false
    private var dragOffset: CGPoint?
    private var previousApp: NSRunningApplication?
    private var fadeOut: Task<Void, Never>?

    init(meetings: MeetingsController, defaults: UserDefaults, overlayPosition: @escaping () -> OverlayPosition) {
        self.meetings = meetings
        self.defaults = defaults
        self.overlayPosition = overlayPosition
        model = SidekickModel(collapsed: defaults.bool(forKey: Self.collapsedKey))
        model.edge = SidekickModel.Edge(rawValue: defaults.string(forKey: Self.edgeKey) ?? "") ?? .right
        panel = SidekickWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize(collapsed: model.collapsed)),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "gob.lin Sidekick"
        // Above the call's windows, below the dictation overlay.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Never part of a screen share or recording. Newer capture APIs may ignore this, so the call app's own
        // "you're sharing" state hides the panel as well.
        panel.sharingType = .none
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: SidekickView(meetings: meetings, model: model))
        model.dragChanged = { [weak self] point in self?.drag(to: point) }
        model.dragEnded = { [weak self] in self?.endDrag() }
        model.setCollapsed = { [weak self] collapsed in self?.setCollapsed(collapsed) }
        model.beginLabel = { [weak self] id in self?.beginLabel(id) }
        model.endLabel = { [weak self] in self?.endLabel() }
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
            Task { @MainActor in self?.place(animated: false) }
        }.store(in: &subscriptions)
    }

    private static func windowSize(collapsed: Bool) -> CGSize {
        let size = collapsed ? collapsedSize : expandedSize
        return CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
    }

    // MARK: Showing

    private func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        fadeOut?.cancel()
        if show {
            model.resetLevels()
            if model.editingMark != nil { endLabel() }
            place(animated: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            // Hiding (by hand, or for a screen share) keeps what was typed; only Escape throws a label away. This runs
            // inside the update that hid the panel, which would overwrite a mark changed now, so the label goes in
            // once that update has landed. Stop saves it earlier, through `willStop`.
            if let id = model.editingMark {
                let draft = model.labelDraft
                endLabel()
                Task { @MainActor [meetings] in meetings.label(id, draft) }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            }
            fadeOut = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled, !self.shown else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// A new recording starts with the reminder showing again.
    func recordingStarted() { model.showsConsent = true }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != model.collapsed else { return }
        if model.editingMark != nil { commitLabel() }
        model.collapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedKey)
        place(animated: false)
    }

    // MARK: Placement

    private var screen: NSScreen? { panel.screen ?? NSScreen.main }

    /// The overlay's corners on this screen, both sides, since it mirrors left when the caret is in its way.
    private func overlayZones(in visible: NSRect) -> [NSRect] {
        let size = DictationOverlay.contentSize
        let y = overlayPosition() == .bottom ? visible.minY + 16 : visible.maxY - 16 - size.height
        return [NSRect(x: visible.maxX - 16 - size.width, y: y, width: size.width, height: size.height),
                NSRect(x: visible.minX + 16, y: y, width: size.width, height: size.height)].map { $0.insetBy(dx: -8, dy: -8) }
    }

    /// The panel's visible frame for a top edge on a side, kept on screen and out of the overlay's corner.
    private func frame(edge: SidekickModel.Edge, top: CGFloat, in visible: NSRect) -> NSRect {
        let size = model.collapsed ? Self.collapsedSize : Self.expandedSize
        let x = edge == .right ? visible.maxX - Self.inset - size.width : visible.minX + Self.inset
        var frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        frame.origin.y = min(max(frame.minY, visible.minY + Self.inset), visible.maxY - Self.inset - size.height)
        for zone in overlayZones(in: visible) where frame.intersects(zone) {
            if overlayPosition() == .bottom { frame.origin.y = zone.maxY }
            else { frame.origin.y = zone.minY - size.height }
        }
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return frame
    }

    private func place(animated: Bool) {
        guard let visible = screen?.visibleFrame else { return }
        let saved = defaults.object(forKey: Self.topKey) as? Double
        let top = saved.map { visible.maxY - CGFloat($0) } ?? visible.maxY - Self.inset
        setPanelFrame(frame(edge: model.edge, top: top, in: visible), animated: animated)
    }

    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        let window = frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(window, display: true)
            }
        } else {
            panel.setFrame(window, display: true)
        }
    }

    /// Follows the pointer from where it grabbed the panel.
    private func drag(to _: CGPoint) {
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil { dragOffset = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY) }
        guard let dragOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    /// Snaps to the nearer side of the screen it was dropped on and remembers the height.
    private func endDrag() {
        dragOffset = nil
        let visibleFrame = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)) } ?? screen
        guard let visible = screen?.visibleFrame else { return }
        model.edge = visibleFrame.midX < visible.midX ? .left : .right
        let snapped = frame(edge: model.edge, top: visibleFrame.maxY, in: visible)
        defaults.set(model.edge.rawValue, forKey: Self.edgeKey)
        defaults.set(Double(visible.maxY - snapped.maxY), forKey: Self.topKey)
        setPanelFrame(snapped, animated: true)
    }

    // MARK: Labels

    /// The one time the Sidekick takes the keyboard: someone chose Add Label. It hands it back afterwards.
    private func beginLabel(_ id: UUID) {
        if model.editingMark == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        if model.collapsed { setCollapsed(false) }
        model.editingMark = id
        panel.allowsKey = true
        panel.makeKey()
    }

    /// Saves the label being typed, then hands the keyboard back.
    private func commitLabel() {
        if let id = model.editingMark { meetings.label(id, model.labelDraft) }
        endLabel()
    }

    private func endLabel() {
        model.editingMark = nil
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        panel.resignKey()
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        previousApp = nil
    }

    // MARK: Menu

    private func showMenu(from view: NSView?) {
        let menu = NSMenu()
        let items: [(String, Selector?)] = [("Copy New Lines", #selector(MenuTarget.copyNew)), ("Copy All", #selector(MenuTarget.copyAll)),
                                            ("", nil), ("Collapse to Pill", #selector(MenuTarget.collapse)),
                                            ("Hide Until the Call Ends", #selector(MenuTarget.hide)),
                                            ("", nil), ("Stop Recording", #selector(MenuTarget.stop))]
        let target = MenuTarget(controller: self)
        for (title, action) in items {
            guard let action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            if action == #selector(MenuTarget.hide), meetings.recording?.inPerson == true { item.title = "Hide Until Recording Stops" }
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

    fileprivate func collapse() { setCollapsed(true) }
    fileprivate func hide() { meetings.setSidekickVisible(false) }
    fileprivate func stop() { meetings.stop() }

    func shutdown() {
        subscriptions.removeAll()
        panel.orderOut(nil)
    }
}

/// NSMenu wants an Objective-C target.
@MainActor
private final class MenuTarget: NSObject {
    weak var controller: SidekickController?
    init(controller: SidekickController) { self.controller = controller }
    @objc func copyNew() { controller?.copy(onlyNew: true) }
    @objc func copyAll() { controller?.copy(onlyNew: false) }
    @objc func collapse() { controller?.collapse() }
    @objc func hide() { controller?.hide() }
    @objc func stop() { controller?.stop() }
}
