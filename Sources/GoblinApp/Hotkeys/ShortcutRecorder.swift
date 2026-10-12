import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var service: HotkeyService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictation shortcut").font(.largeTitle.bold())
            Text("Hold for push-to-talk. Tap once for hands-free, then tap again to finish. Escape cancels while recording.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShortcutRecorder(service: service)
            HStack {
                Button("Fn / Globe") { service.setShortcut(.fn) }
                Button("Right Option") { service.setShortcut(.rightOption) }
                Button("Option + Space") { service.setShortcut(.optionSpace) }
            }
            Label(service.status, systemImage: service.secureInput ? "lock.trianglebadge.exclamationmark" : "keyboard")
                .foregroundStyle(service.secureInput ? .orange : .secondary)
            if service.secureInput {
                Text("Another app enabled Secure Input. Modifier-only shortcuts are paused. A keyed shortcut uses the system fallback, including key release.")
                    .foregroundStyle(.orange)
            }
            Divider()
            Text("Using Fn / Globe? Set System Settings → Keyboard → “Press Globe key to” → Do Nothing. Some non-Apple keyboards do not send Fn to macOS; use Right Option or Option + Space.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Shortcut capture is ready. Audio capture and recognition will connect after the speech-engine benchmark.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 540, maxWidth: 800, minHeight: 400, maxHeight: 650, alignment: .topLeading)
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var service: HotkeyService
    @State private var monitor: Any?
    @State private var candidate: HotkeyShortcut?
    @State private var hint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(service.shortcut.label).font(.title2.monospaced()).frame(minWidth: 150, alignment: .leading)
                Button(service.recorderActive ? "Cancel" : "Record shortcut") {
                    if service.recorderActive { end() } else { begin() }
                }
            }
            if service.recorderActive { Text("Press your shortcut, then release it.").foregroundStyle(.tint) }
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { end() }
    }

    private func begin() {
        candidate = nil
        hint = ""
        service.setRecorderActive(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { receive(event) }
            return nil
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        service.setRecorderActive(false)
        candidate = nil
    }

    private func receive(_ event: NSEvent) {
        let flags = event.cgEvent?.flags.intersection(HotkeyShortcut.relevantFlags) ?? []
        if event.type == .keyDown {
            candidate = nil
            if event.keyCode == 53 { end(); return }
            guard !flags.isEmpty, !flags.contains(.maskSecondaryFn) else {
                hint = "Use Fn alone, or a key with Command, Option, Control or Shift."
                return
            }
            let label = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            service.setShortcut(HotkeyShortcut(keyCode: event.keyCode, modifiers: flags.rawValue, modifier: nil, keyLabel: label))
            end()
            return
        }
        if flags.isEmpty, let candidate { service.setShortcut(candidate); end(); return }
        switch flags {
        case .maskSecondaryFn: candidate = .fn
        case .maskAlternate:
            candidate = event.keyCode == 61 ? .rightOption : HotkeyShortcut(keyCode: nil, modifiers: flags.rawValue, modifier: .option, keyLabel: "Option")
        case .maskCommand: candidate = HotkeyShortcut(keyCode: nil, modifiers: flags.rawValue, modifier: .command, keyLabel: "Command")
        case .maskControl: candidate = HotkeyShortcut(keyCode: nil, modifiers: flags.rawValue, modifier: .control, keyLabel: "Control")
        case .maskShift: candidate = HotkeyShortcut(keyCode: nil, modifiers: flags.rawValue, modifier: .shift, keyLabel: "Shift")
        default: candidate = nil
        }
    }
}
