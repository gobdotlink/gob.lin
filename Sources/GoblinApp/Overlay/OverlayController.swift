import AppKit
@preconcurrency import ApplicationServices
import GoblinCore
import SwiftUI

/// What the overlay is showing. Errors carry the failure so the goblin can pick its face and words.
enum OverlayPhase: Equatable {
    case hidden, arming, listening, transcribing, polishing
    case inserted(OverlayResult)
    case readyToPaste(application: String?)
    case milestone(words: Int)
    case error(OverlayNotice)

    var caption: String {
        switch self {
        case .hidden: ""
        case .arming: "Warming up the mic…"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .polishing: "Cleaning up"
        case .inserted: "Typed"
        case .readyToPaste: "Ready to paste"
        case .milestone: "Milestone"
        case .error: "Needs attention"
        }
    }

    var hasWords: Bool {
        switch self { case .listening, .transcribing, .polishing: true; default: false }
    }
}

struct OverlayResult: Equatable {
    var application: String?
    var words: Int
    /// Key-up to text, in seconds.
    var seconds: Double
    var notice: OverlayNotice? = nil
}

struct OverlayNotice: Equatable {
    var failure: DiagnosticFailure?
    var message: String

    init(_ failure: DiagnosticFailure) { self.failure = failure; message = failure.message }
    init(message: String, failure: DiagnosticFailure? = nil) { self.failure = failure; self.message = message }
}

/// Buttons the overlay can offer; the app decides where each one goes.
enum OverlayAction { case setup, audioSettings, cleanupSettings }

enum OverlayPosition: String, CaseIterable {
    case bottom, top
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var phase: OverlayPhase = .hidden {
        didSet {
            if phase != .hidden { visiblePhase = phase }
            if case .inserted(let result) = phase { deliveryApplication = result.application }
            if phase == .listening, listeningStarted == nil { listeningStarted = Date() }
        }
    }
    /// The last shown phase, so the exit animation keeps its content instead of blanking.
    @Published private(set) var visiblePhase: OverlayPhase = .arming
    /// Drives the enter/exit animation; layout is unaffected, so the panel never resizes mid-animation.
    @Published var presented = true
    @Published var edge: OverlayPosition = .bottom
    /// Bottom-left (or top-left) instead of right, because the caret was in the corner at key-down.
    @Published var mirrored = false
    @Published var committedText = ""
    @Published var tentativeText = ""
    @Published var handsFree = false
    private(set) var deliveryApplication: String?
    @Published var listeningStarted: Date?
    /// Seconds of audio, frozen when listening ends.
    @Published var audioSeconds: Double?
    /// "Light · Cerebras" while cleaning up.
    @Published var cleanupLabel = ""
    var modelName = "Parakeet"
    @Published var audioLevel: Double = 0 {
        didSet {
            levels = Array((levels + [audioLevel]).suffix(Self.levelHistory))
            updateMouth()
        }
    }
    /// Recent levels, newest last; the meter shows them oldest to newest.
    @Published var levels = Array(repeating: 0.0, count: OverlayModel.levelHistory)
    /// Shut or yap, with hysteresis and at most 12 changes a second, so the mouth never flaps.
    @Published private(set) var mouthOpen = false
    @Published var previewUnavailable = false
    /// Shown inside Listening while the microphone delivers only silence.
    @Published var microphoneNotice: String?
    static let levelHistory = 5
    var cancel: () -> Void = {}
    var perform: (OverlayAction) -> Void = { _ in }
    var sizeChanged: (CGSize) -> Void = { _ in }
    private var mouthChanged = Date.distantPast

    private func updateMouth() {
        let open = mouthOpen ? audioLevel > 0.12 : audioLevel > 0.18
        guard open != mouthOpen, Date().timeIntervalSince(mouthChanged) >= 1.0 / 12 else { return }
        mouthOpen = open
        mouthChanged = Date()
    }

    func resetForSession() {
        committedText = ""
        tentativeText = ""
        levels = Array(repeating: 0, count: Self.levelHistory)
        audioLevel = 0
        mouthOpen = false
        mouthChanged = .distantPast
        previewUnavailable = false
        microphoneNotice = nil
        listeningStarted = nil
        audioSeconds = nil
        cleanupLabel = ""
        deliveryApplication = nil
        mirrored = false
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel: DictationPanel
    private var sessionID = UUID()
    private var hideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?
    private var screen: NSScreen?
    private var displayObserver: NSObjectProtocol?
    private var completionNotices: [OverlayPhase] = []
    var position: OverlayPosition = .bottom { didSet { model.edge = position; reposition() } }

    init() {
        panel = DictationPanel(contentRect: NSRect(origin: .zero, size: DictationOverlay.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.title = "gob.lin Dictation"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DictationOverlay(model: model))
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    @discardableResult
    func begin(onCancel: @escaping () -> Void) -> UUID {
        hideTask?.cancel()
        orderOutTask?.cancel()
        sessionID = UUID()
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        model.resetForSession()
        model.cancel = onCancel
        model.phase = .arming
        // Render the collapsed frame first so the entrance has somewhere to start from.
        if !panel.isVisible { model.presented = false }
        // Settle the cleared content first: resizing inside the animated update drops the animation.
        panel.contentView?.layoutSubtreeIfNeeded()
        reposition()
        panel.orderFrontRegardless()
        // From the current on-screen value: a session that starts mid-exit reverses smoothly.
        withAnimation(Self.motion(enter: true)) { model.presented = true }
        avoidCaret(session: sessionID)
        return sessionID
    }

    func update(_ phase: OverlayPhase, committed: String? = nil, tentative: String? = nil,
                level: Double? = nil, previewUnavailable: Bool = false, session: UUID) {
        if session != sessionID { return }
        if phase == .hidden { hide(session: session); return }
        hideTask?.cancel()
        if model.phase == .listening, phase != .listening, model.audioSeconds == nil, let started = model.listeningStarted {
            model.audioSeconds = Date().timeIntervalSince(started)
        }
        if model.phase != phase {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.14)) { model.phase = phase }
        }
        if let committed, committed != model.committedText { model.committedText = committed }
        if let tentative, tentative != model.tentativeText { model.tentativeText = tentative }
        if previewUnavailable { model.previewUnavailable = true }
        if let level { model.audioLevel = level.isFinite ? min(1, max(0, level)) : 0 }
    }

    func setMicrophoneNotice(_ notice: String?, session: UUID) {
        guard session == sessionID, model.microphoneNotice != notice else { return }
        model.microphoneNotice = notice
    }

    func hide(session: UUID? = nil) {
        if let session, session != sessionID { return }
        hideTask?.cancel()
        model.phase = .hidden
        sessionID = UUID()
        withAnimation(Self.motion(enter: false)) { model.presented = false }
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            // ponytail: fixed wait matching the exit's duration; a completion callback if timing drifts.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.model.phase == .hidden else { return }
            self.panel.orderOut(nil)
            if !self.completionNotices.isEmpty {
                let notice = self.completionNotices.removeFirst()
                self.showCompletion(notice, session: UUID())
            }
        }
    }

    /// Older results wait for the current recording's overlay instead of replacing its words.
    func showCompletion(_ phase: OverlayPhase, session: UUID) {
        if session != sessionID, model.phase != .hidden {
            completionNotices.append(phase)
            return
        }
        let current = session == sessionID ? session : begin(onCancel: {})
        update(phase, session: current)
        hide(after: 3, session: current)
    }

    /// In 140 ms, out 120 ms, ease-out. Reduce Motion keeps the fade and drops the movement in the view.
    private static func motion(enter: Bool) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: enter ? 0.14 : 0.12)
    }

    func hide(after seconds: Double, session: UUID) {
        guard session == sessionID else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            guard let self, !Task.isCancelled, session == self.sessionID else { return }
            self.hide(session: session)
        }
    }

    func shutdown() {
        completionNotices.removeAll()
        hide()
        orderOutTask?.cancel()
        panel.orderOut(nil)
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    private func reposition() {
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == number
        }) ?? NSScreen.main else { return }
        self.screen = screen
        panel.setFrameOrigin(Self.origin(in: screen.visibleFrame, position: position, mirrored: model.mirrored))
    }

    /// The visible bubble and goblin sit 16 pt from the corner; the transparent margin holds shadows and hands.
    private static func origin(in visible: NSRect, position: OverlayPosition, mirrored: Bool) -> NSPoint {
        let margin = DictationOverlay.margin, size = DictationOverlay.panelSize
        let x = mirrored ? visible.minX + 16 - margin : visible.maxX - 16 - size.width + margin
        let y = position == .bottom ? visible.minY + 16 - margin : visible.maxY - 16 - size.height + margin
        return NSPoint(x: x, y: y)
    }

    /// If the focused caret sits where the overlay will be, move to the other corner before any words show.
    private func avoidCaret(session: UUID) {
        guard let screen else { return }
        let zone = NSRect(origin: Self.origin(in: screen.visibleFrame, position: position, mirrored: false),
                          size: DictationOverlay.panelSize).insetBy(dx: -8, dy: -8)
        Task.detached(priority: .userInitiated) {
            guard let caret = CaretLocator.caretRect() else { return }
            await MainActor.run { [weak self] in
                guard let self, session == self.sessionID, zone.intersects(caret),
                      self.model.phase == .arming || (self.model.phase == .listening && self.model.committedText.isEmpty) else { return }
                self.model.mirrored = true
                self.reposition()
            }
        }
    }
}

/// The focused text caret in Cocoa screen coordinates, read with a short Accessibility timeout.
enum CaretLocator {
    nonisolated static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.05)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(bounds, to: AXValue.self), .cgRect, &rect), !rect.isNull,
              let height = NSScreen.screens.first?.frame.height else { return nil }
        // Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
        return NSRect(x: rect.minX, y: height - rect.maxY, width: max(rect.width, 1), height: max(rect.height, 1))
    }
}
