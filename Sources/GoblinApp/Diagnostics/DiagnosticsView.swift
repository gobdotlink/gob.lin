import GoblinCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    @State private var includeDeviceNames = false

    var body: some View {
        Section {
            if model.hasWarning {
                ForEach(model.warnings, id: \.area) { warning in
                    Label {
                        Text(warning.area.title)
                        Text(warning.message)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LightState.waiting.color) }
                }
            } else {
                Label("No active warnings", systemImage: "checkmark.circle.fill").foregroundStyle(GoblinBrand.mossText)
            }
        } header: {
            HStack {
                Text("Status")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.labelStyle(.iconOnly).controlSize(.small)
                    .accessibilityLabel("Refresh diagnostics")
            }
        }
        .onAppear { model.refresh() }
        Section("Environment") {
            LabeledContent("Version") { Text(GoblinMetadata.version).monospaced() }
            LabeledContent("Microphone", value: model.environment.microphonePermission.rawValue.capitalized)
            LabeledContent("Accessibility", value: model.environment.accessibilityPermission.rawValue.capitalized)
            LabeledContent("Input Monitoring (not required)", value: model.environment.inputMonitoringPermission.rawValue.capitalized)
            LabeledContent("Secure Input", value: model.environment.secureInput ? "Enabled" : "Disabled")
            LabeledContent("Speech engine", value: model.environment.engineStatus.rawValue.capitalized)
            LabeledContent("Microphones available", value: String(model.environment.microphoneNames.count))
            if let name = model.environment.defaultMicrophoneName { LabeledContent("Default microphone", value: name) }
        }
        Section("Latest dictation timing") {
            if let timings = model.latestTimings {
                // "Capture: 9000.0 ms" drawn like the Environment rows above it.
                ForEach(DiagnosticsReport.timingLines(timings), id: \.self) { line in
                    let parts = line.split(separator: ": ", maxSplits: 1).map(String.init)
                    LabeledContent(parts[0]) { Text(parts.count > 1 ? parts[1] : "").monospacedDigit() }
                }
            } else { Text("No dictation timings recorded yet.").foregroundStyle(.secondary) }
        }
        if !model.events.isEmpty {
            Section {
                ForEach(model.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.failure.area.title + " · " + event.date.formatted(date: .omitted, time: .standard))
                            .font(.meta.monospaced()).foregroundStyle(.secondary)
                        Text(event.failure.message).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Recent errors")
                    Spacer()
                    Button("Clear Recent Errors") { model.clearRecentErrors() }.textCase(nil).tracking(0).font(.status).controlSize(.small)
                }
            }
        }
        Section {
            LabeledContent {
                Text("~/Library/Logs/gob.lin").font(.status.monospaced()).textSelection(.enabled)
            } label: {
                Text("Development logs")
                Text(model.logStatus).rowDetail()
            }
            HStack {
                Button("Reveal Logs", systemImage: "folder") { model.revealLogs() }
                Button("Export Recent Logs…", systemImage: "square.and.arrow.up") { model.exportLogs(includeDeviceNames: includeDeviceNames) }
                Button("Reveal Crash Reports") { model.revealCrashReports() }
            }
        } header: { Text("Logs") } footer: {
            Text("Logs hold build, launch, operation and process IDs. Audio, transcripts, keys, clipboard contents and device names are left out. Crash reports are shared separately.")
        }
        Section {
            Toggle("Include microphone names", isOn: $includeDeviceNames)
            HStack {
                if let message = model.copyMessage { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy Diagnostics", systemImage: "doc.on.doc") { model.copyDiagnostics(includeDeviceNames: includeDeviceNames) }
                    .prominent()
            }
        } header: { Text("Share") } footer: {
            Text("Copies and exports hold versions, permissions, timings and typed errors. Transcripts, keys, request bodies and file paths are left out.")
        }
    }
}
