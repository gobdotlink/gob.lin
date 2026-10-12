import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor
final class PermissionModel: ObservableObject {
    enum Permission: String { case microphone, accessibility, inputMonitoring }

    struct Snapshot: Equatable {
        var microphone: AVAuthorizationStatus
        var accessibility: Bool
        var inputMonitoring: Bool
        var ready: Bool { microphone == .authorized && accessibility && inputMonitoring }
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var staleAccessibility = false
    @Published private(set) var lastRevoked: Permission?
    var onChange: ((Snapshot, Snapshot) -> Void)?
    var onRevocation: ((Permission) -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var onboarding: NSWindowController?
    private var awaitingSettingsReturn = false
    private let monitorSystem: Bool

    init(snapshot: Snapshot? = nil, monitorSystem: Bool = true) {
        self.monitorSystem = monitorSystem
        self.snapshot = snapshot ?? Self.readSnapshot()
        guard monitorSystem else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // Opening the status window is safe; permission requests happen only from its buttons.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.snapshot.ready else { return }
            self.showOnboarding()
        }
    }

    func refresh() {
        guard monitorSystem else { return }
        let old = snapshot
        let new = Self.readSnapshot()
        snapshot = new
        if old.accessibility && !new.accessibility { revoked(.accessibility) }
        if old.inputMonitoring && !new.inputMonitoring { revoked(.inputMonitoring) }
        if old.microphone == .authorized && new.microphone != .authorized { revoked(.microphone) }
        if old != new { onChange?(old, new) }
        if awaitingSettingsReturn && old != new {
            awaitingSettingsReturn = false
            showOnboarding()
        }
    }

    func reportTapFailure() {
        staleAccessibility = snapshot.accessibility
        showOnboarding()
    }

    func reportTapWorking() { staleAccessibility = false }

    func request(_ permission: Permission) {
        guard monitorSystem else { return }
        switch permission {
        case .microphone:
            guard snapshot.microphone == .notDetermined else { openSettings(permission); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh(); self?.showOnboarding() }
            }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            openSettings(permission)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            openSettings(permission)
        }
    }

    func openSettings(_ permission: Permission) {
        guard monitorSystem else { return }
        let pane: String
        switch permission {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        awaitingSettingsReturn = true
        NSWorkspace.shared.open(url)
    }

    func showOnboarding() {
        guard monitorSystem else { return }
        if onboarding == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(permissions: self)))
            window.title = "Welcome to gob.lin"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 590, height: 540))
            window.center()
            window.isReleasedWhenClosed = false
            onboarding = NSWindowController(window: window)
        }
        onboarding?.showWindow(nil)
        onboarding?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    private func revoked(_ permission: Permission) {
        lastRevoked = permission
        onRevocation?(permission)
        showOnboarding()
    }

    private static func readSnapshot() -> Snapshot {
        Snapshot(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                 accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }
}
