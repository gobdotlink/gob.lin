import AppKit
import SwiftUI

enum OverlayPhase: Equatable {
    case hidden, arming, listening, transcribing, polishing, error(String)

    var caption: String {
        switch self {
        case .hidden: ""
        case .arming: "getting ready…"
        case .listening: "autism recording in progress"
        case .transcribing: "turning voice into words…"
        case .polishing: "polishing your words…"
        case .error(let message): message
        }
    }
}

enum OverlayPosition: String, CaseIterable {
    case bottom, top
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var phase: OverlayPhase = .hidden
    @Published var committedText = ""
    @Published var tentativeText = ""
    @Published var audioLevel: Double = 0
    @Published var textHeight: Double = 44
    var cancel: () -> Void = {}
    var sizeChanged: (CGSize) -> Void = { _ in }
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
    private var screen: NSScreen?
    private var displayObserver: NSObjectProtocol?
    var position: OverlayPosition = .bottom { didSet { reposition() } }

    init() {
        panel = DictationPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
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
        model.sizeChanged = { [weak self] size in
            guard let self else { return }
            let available = self.screen?.visibleFrame.size ?? CGSize(width: 800, height: 600)
            self.panel.setContentSize(CGSize(width: min(size.width, max(240, available.width - 32)),
                height: min(size.height, max(100, available.height - 32))))
            self.reposition()
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    @discardableResult
    func begin(onCancel: @escaping () -> Void) -> UUID {
        hideTask?.cancel()
        sessionID = UUID()
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        model.committedText = ""
        model.tentativeText = ""
        model.audioLevel = 0
        model.textHeight = 44
        model.cancel = onCancel
        model.phase = .arming
        reposition()
        panel.orderFrontRegardless()
        return sessionID
    }

    func update(_ phase: OverlayPhase, committed: String? = nil, tentative: String? = nil,
                level: Double? = nil, session: UUID) {
        if session != sessionID { return }
        if phase == .hidden { hide(session: session); return }
        hideTask?.cancel()
        model.phase = phase
        if let committed { model.committedText = committed }
        if let tentative { model.tentativeText = tentative }
        let textHeight = min(130, max(44, Double(model.committedText.count + model.tentativeText.count) / 48 * 20))
        model.textHeight = max(model.textHeight, textHeight)
        if let level { model.audioLevel = level.isFinite ? min(1, max(0, level)) : 0 }
        panel.orderFrontRegardless()
    }

    func hide(session: UUID? = nil) {
        if let session, session != sessionID { return }
        hideTask?.cancel()
        model.phase = .hidden
        sessionID = UUID()
        panel.orderOut(nil)
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
        hide()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    private func reposition() {
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == number
        }) ?? NSScreen.main else { return }
        self.screen = screen
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = position == .bottom ? visible.minY + 18 : visible.maxY - panel.frame.height - 18
        panel.setFrameOrigin(NSPoint(x: max(visible.minX + 8, x), y: max(visible.minY + 8, y)))
    }
}
