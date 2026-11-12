import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @ObservedObject var service: HotkeyService
    @State private var monitor: Any?
    @State private var capture = ShortcutCapture()
    /// Off when a big keycap beside the recorder already shows the key.
    var showsCurrent = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                if service.recorderActive {
                    if let preview = capture.preview { KeyCombo(label: preview.label) }
                    else { Text("press keys…").font(.status.monospaced()).foregroundStyle(GoblinBrand.mossText) }
                } else if showsCurrent {
                    KeyCombo(label: service.shortcut.label)
                }
                Button(service.recorderActive ? "Cancel" : "Record New Key…") {
                    if service.recorderActive { end() } else { begin() }
                }
            }
            Group {
                if service.recorderActive {
                    Text("Press any key or combination, then let go. If nothing shows up, the keyboard isn't sending that key to the Mac.")
                        .foregroundStyle(.secondary)
                } else if let caution = service.shortcut.caution {
                    Text(caution).foregroundStyle(.orange)
                }
            }
            .font(.meta).multilineTextAlignment(.trailing).frame(maxWidth: 260, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: service.recorderActive) { _, active in
            if !active { removeMonitor() }
        }
        .onDisappear { end() }
    }

    private func begin() {
        removeMonitor()
        service.setRecorderActive(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard MainActor.assumeIsolated({ service.recorderActive }) else { return event }
            MainActor.assumeIsolated { receive(event) }
            return nil
        }
    }

    private func end() {
        removeMonitor()
        service.setRecorderActive(false)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        capture = ShortcutCapture()
    }

    private func receive(_ event: NSEvent) {
        let flags = event.cgEvent?.flags.rawValue ?? 0
        switch event.type {
        case .keyDown:
            let label = HotkeyShortcut.keyName(event.keyCode, characters: event.characters(byApplyingModifiers: []))
            capture.keyDown(code: event.keyCode, flags: flags, label: label, isRepeat: event.isARepeat)
        case .keyUp:
            if let shortcut = capture.keyUp(code: event.keyCode) { save(shortcut) }
        default:
            capture.modifierChanged(code: event.keyCode, flags: flags)
            guard capture.finished != nil else { return }
            // A short wait lets a keyboard macro that taps a modifier before its key finish arriving.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if service.recorderActive, let shortcut = capture.finished { save(shortcut) }
            }
        }
    }

    private func save(_ shortcut: HotkeyShortcut) {
        service.setShortcut(shortcut)
        end()
    }
}
