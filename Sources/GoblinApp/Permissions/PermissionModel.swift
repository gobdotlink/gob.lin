import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import SwiftUI
import Security
import os

@MainActor
final class PermissionModel: ObservableObject {
    enum Permission: String { case microphone, accessibility, inputMonitoring }

    struct Snapshot: Equatable {
        var microphone: AVAuthorizationStatus
        var accessibility: Bool
        var inputMonitoring: Bool
        var ready: Bool { microphone == .authorized && accessibility && inputMonitoring }

        var diagnosticFields: [String: String] {
            let microphoneStatus: String
            switch microphone {
            case .authorized: microphoneStatus = "authorized"
            case .notDetermined: microphoneStatus = "not_determined"
            case .denied: microphoneStatus = "denied"
            case .restricted: microphoneStatus = "restricted"
            @unknown default: microphoneStatus = "unknown"
            }
            return ["microphone": microphoneStatus, "accessibility": accessibility ? "allowed" : "not_allowed",
                    "input_monitoring": inputMonitoring ? "allowed" : "not_allowed"]
        }

        func isGranted(_ permission: Permission) -> Bool {
            switch permission {
            case .microphone: microphone == .authorized
            case .accessibility: accessibility
            case .inputMonitoring: inputMonitoring
            }
        }
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var tapFailure: HotkeyEventTap.StartFailure?
    @Published private(set) var lastRevoked: Permission?
    var onChange: ((Snapshot, Snapshot) -> Void)?
    var onRevocation: ((Permission) -> Void)?
    var onRetry: (() -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    private var onboarding: NSWindowController?
    private var awaitingSettingsReturn = false
    private let monitorSystem: Bool

    init(snapshot: Snapshot? = nil, monitorSystem: Bool = true) {
        self.monitorSystem = monitorSystem
        self.snapshot = snapshot ?? Self.readSnapshot()
        guard monitorSystem else { return }
        Self.logDiagnostic("launch_identity", fields: Self.launchIdentity)
        for (permission, status) in self.snapshot.diagnosticFields {
            Self.logDiagnostic("permission_initial", fields: ["permission": permission, "status": status])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.returnedToApp() }
            }
        // Opening the status window is safe; permission requests happen only from its buttons.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.snapshot.ready else { return }
            self.showOnboarding()
        }
    }

    func refresh() {
        guard monitorSystem else { return }
        updateSnapshot(Self.readSnapshot())
    }

    func updateSnapshot(_ new: Snapshot) {
        let old = snapshot
        snapshot = new
        guard old != new else { return }
        if old.accessibility && !new.accessibility { revoked(.accessibility) }
        if old.inputMonitoring && !new.inputMonitoring { revoked(.inputMonitoring) }
        if old.microphone == .authorized && new.microphone != .authorized { revoked(.microphone) }
        if let lastRevoked, new.isGranted(lastRevoked) { self.lastRevoked = nil }
        if monitorSystem {
            for (permission, status) in new.diagnosticFields where old.diagnosticFields[permission] != status {
                Self.logDiagnostic("permission_changed", fields: ["permission": permission,
                    "previous": old.diagnosticFields[permission] ?? "unknown", "status": status])
            }
        }
        onChange?(old, new)
    }

    func checkAgain() {
        refresh()
        onRetry?()
    }

    private func returnedToApp() {
        refresh()
        guard awaitingSettingsReturn else { return }
        awaitingSettingsReturn = false
        onRetry?()
        showOnboarding()
    }

    func reportTapFailure(_ failure: HotkeyEventTap.StartFailure) {
        refresh()
        tapFailure = failure
        if monitorSystem { Self.logDiagnostic("tap_start", fields: snapshot.diagnosticFields.merging(["result": failure.rawValue]) { _, new in new }) }
        showOnboarding()
    }

    func reportTapBlocked() {
        if monitorSystem { Self.logDiagnostic("tap_start", fields: snapshot.diagnosticFields.merging(["result": "blocked_by_permissions"]) { _, new in new }) }
    }

    func reportTapWorking() {
        tapFailure = nil
        if monitorSystem { Self.logDiagnostic("tap_start", fields: ["result": "started"]) }
    }

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
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func revoked(_ permission: Permission) {
        lastRevoked = permission
        onRevocation?(permission)
        showOnboarding()
    }

    // Local development metadata stays separate from the shareable diagnostics report.
    static let launchIdentity: [String: String] = {
        var fields = ["bundle_path": Bundle.main.bundleURL.path,
                      "executable_path": Bundle.main.executableURL?.path ?? "unknown",
                      "bundle_id": Bundle.main.bundleIdentifier ?? "unbundled",
                      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                      "pid": String(ProcessInfo.processInfo.processIdentifier)]
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        var requirement: SecRequirement?
        var requirementText: CFString?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
               let information = information as? [String: Any] {
                fields["signing_identifier"] = information[kSecCodeInfoIdentifier as String] as? String
                if let hash = information[kSecCodeInfoUnique as String] as? Data {
                    fields["cdhash"] = hash.map { String(format: "%02x", $0) }.joined()
                }
            }
            if let staticCode, SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
               SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess {
                fields["designated_requirement"] = requirementText as String?
            }
        }
        return fields
    }()

    private static let logger = Logger(subsystem: "app.goblin.dictation.permissions", category: "recovery")

    private static func logDiagnostic(_ event: String, fields: [String: String]) {
        let metadata = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
        logger.notice("\(event, privacy: .public) · \(metadata, privacy: .public)")
    }

    private static func readSnapshot() -> Snapshot {
        Snapshot(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                 accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }
}
