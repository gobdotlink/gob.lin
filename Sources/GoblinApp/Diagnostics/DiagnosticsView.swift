import GoblinCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    @State private var includeDeviceNames = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostics").font(.title.bold())
                        Text("A clear view of what gob.lin needs and what went wrong.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.labelStyle(.iconOnly)
                        .accessibilityLabel("Refresh diagnostics")
                }
                if model.hasWarning {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.warnings, id: \.area) { warning in
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(warning.area.title).font(.headline)
                                    Text(warning.message).font(.callout)
                                }
                            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                } else { Label("No active warnings", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                GroupBox("Environment") {
                    VStack(spacing: 9) {
                        LabeledContent("Version", value: GoblinMetadata.version)
                        LabeledContent("Microphone", value: model.environment.microphonePermission.rawValue.capitalized)
                        LabeledContent("Accessibility", value: model.environment.accessibilityPermission.rawValue.capitalized)
                        LabeledContent("Input Monitoring", value: model.environment.inputMonitoringPermission.rawValue.capitalized)
                        LabeledContent("Secure Input", value: model.environment.secureInput ? "Enabled" : "Disabled")
                        LabeledContent("Speech engine", value: model.environment.engineStatus.rawValue.capitalized)
                        LabeledContent("Microphones available", value: String(model.environment.microphoneNames.count))
                        if let name = model.environment.defaultMicrophoneName { LabeledContent("Default microphone", value: name) }
                    }.padding(8)
                }
                GroupBox("Latest dictation timing") {
                    VStack(alignment: .leading, spacing: 7) {
                        if let timings = model.latestTimings {
                            ForEach(DiagnosticsReport.timingLines(timings), id: \.self) { Text($0).monospacedDigit() }
                        } else { Text("No dictation timings recorded yet.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if !model.events.isEmpty {
                    HStack {
                        Text("Recent errors").font(.headline)
                        Spacer()
                        Button("Clear recent errors") { model.clearRecentErrors() }
                    }
                    ForEach(model.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.failure.area.title + " · " + event.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            Text(event.failure.message).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                Divider()
                Toggle("Include microphone names in copied diagnostics", isOn: $includeDeviceNames)
                Text("Copied diagnostics contain versions, permissions, stage timings, and typed errors. Transcript text, keys, request bodies, and file paths are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let message = model.copyMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Copy diagnostics", systemImage: "doc.on.doc") { model.copyDiagnostics(includeDeviceNames: includeDeviceNames) }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(24)
        }
        .background(GoblinBrand.background).tint(GoblinBrand.accent).preferredColorScheme(.dark)
        .onAppear { model.refresh() }
    }
}
