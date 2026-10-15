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
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.labelStyle(.iconOnly)
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
                ForEach(DiagnosticsReport.timingLines(timings), id: \.self) { Text($0).font(.body.monospaced()).monospacedDigit() }
            } else { Text("No dictation timings recorded yet.").foregroundStyle(.secondary) }
        }
        if !model.events.isEmpty {
            Section {
                ForEach(model.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.failure.area.title + " · " + event.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(event.failure.message).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Recent errors")
                    Spacer()
                    Button("Clear Recent Errors") { model.clearRecentErrors() }.textCase(nil).font(.callout).controlSize(.small)
                }
            }
        }
        Section {
            LabeledContent {
                Text("~/Library/Logs/gob.lin").font(.callout.monospaced()).textSelection(.enabled)
            } label: {
                Text("Development logs")
                Text(model.logStatus)
            }
            HStack {
                Button("Reveal logs", systemImage: "folder") { model.revealLogs() }
                Button("Export recent logs…", systemImage: "square.and.arrow.up") { model.exportLogs(includeDeviceNames: includeDeviceNames) }
                Button("Reveal crash reports") { model.revealCrashReports() }
            }
        } header: { Text("Logs") } footer: {
            Text("Events include build, launch, operation, and process IDs. Audio, transcripts, keys, credentials, clipboard contents, and device names are excluded. Crash reports are listed for matching and shared separately.")
        }
        Section {
            Toggle("Include microphone names in copied / exported diagnostics", isOn: $includeDeviceNames)
            HStack {
                if let message = model.copyMessage { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy diagnostics", systemImage: "doc.on.doc") { model.copyDiagnostics(includeDeviceNames: includeDeviceNames) }
                    .prominent()
            }
        } header: { Text("Share") } footer: {
            Text("Copied diagnostics contain versions, permissions, stage timings, and typed errors. Transcript text, keys, request bodies, and file paths are excluded.")
        }
    }
}
