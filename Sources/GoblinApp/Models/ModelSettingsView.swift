import AppKit
import GoblinEngines
import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var service: SpeechModelService
    @State private var selectionError: String?

    var body: some View {
        Section {
            Picker("Model", selection: Binding(get: { service.selectedModel.id }, set: { id in
                do { try service.selectModel(id: id); selectionError = nil }
                catch { selectionError = error.localizedDescription }
            })) {
                ForEach(service.models) { model in Text(model.name).tag(model.id) }
            }.disabled(service.models.count == 1 || !service.canChangeModel)
            if let selectionError { Text(selectionError).foregroundStyle(.orange) }
            LabeledContent("Runtime", value: service.selectedModel.runtime)
            DisclosureGroup {
                Text(service.selectedModel.capabilities.languageCodes.map {
                    Locale.current.localizedString(forLanguageCode: $0) ?? $0
                }.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            } label: {
                LabeledContent("Languages", value: "\(service.selectedModel.capabilities.languageCodes.count) · detected automatically")
            }
        } header: { Text("Speech model") } footer: { Text("Loads at launch. Your audio is transcribed locally.") }
        Section("Status") {
            status
            if service.activeSessionCount > 0 {
                Label(service.activeSessionCount == 1 ? "In use by 1 dictation" : "In use by \(service.activeSessionCount) dictations",
                      systemImage: "mic.fill").foregroundStyle(.secondary)
            }
            if let timing = service.lastLoadTiming {
                LabeledContent(timing.cache == .installed ? "New installation load" : "Cached model load") {
                    Text(String(format: "%.0f ms", timing.runtimeLoadMilliseconds)).monospacedDigit()
                }
                LabeledContent("Total preparation") {
                    Text(String(format: "%.0f ms", timing.preparationMilliseconds)).monospacedDigit()
                }
            }
        }
        Section {
            Picker("Unload after idle", selection: $service.idleTimeout) {
                ForEach(ModelIdleTimeout.allCases) { timeout in Text(timeout.label).tag(timeout) }
            }
            LabeledContent("Model files") { Button("Open model folder") { NSWorkspace.shared.open(service.directory) } }
        } header: { Text("Memory") } footer: {
            Text("The model stays loaded throughout recording and recognition. After an idle unload, it reloads while the next recording starts. Downloaded files stay on disk for offline use.")
        }
    }

    @ViewBuilder private var status: some View {
        switch service.state {
        case .notPrepared:
            Label("Model preparation has not started", systemImage: "arrow.down.circle")
            Button("Prepare model") { service.preload() }
        case .preparing(let progress):
            Label(phaseLabel(progress.phase), systemImage: "cpu")
            if let fraction = progress.fractionCompleted, progress.phase == .downloading {
                ProgressView(value: fraction).accessibilityLabel("Download progress")
            } else { ProgressView().controlSize(.small) }
            if let component = progress.component { Text(component).font(.callout).foregroundStyle(.secondary) }
            if let start = service.preparationStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(Int(max(0, context.date.timeIntervalSince(start)))) seconds elapsed")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if progress.phase == .compiling || progress.phase == .loading {
                Text("On first use, macOS may compile the model for several minutes. Preparation continues without a time limit.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if progress.phase == .downloading {
                Text("Interrupted downloads retain partial files. Network stalls retry automatically; you can retry again after a failure.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Cancel preparation") { service.cancelPreparation() }.disabled(service.activeSessionCount > 0)
        case .ready: Label("Ready · available offline", systemImage: "checkmark.circle.fill").foregroundStyle(GoblinBrand.mossText)
        case .unloading: Label("Unloading idle model…", systemImage: "memorychip")
        case .unloaded:
            Label("Unloaded to free memory", systemImage: "memorychip")
            Button("Load now") { service.retry() }
        case .cancelling:
            Label("Cancelling · waiting for model work to finish…", systemImage: "hourglass")
        case .cancelled:
            Label("Preparation cancelled · downloaded files kept", systemImage: "pause.circle")
            Button("Resume preparation") { service.retry() }
        case .failed(let message):
            Label("Model preparation failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            HStack {
                Button("Retry") { service.retry() }
                Button("Download again", role: .destructive) { Task { await service.repair() } }
            }.disabled(!service.canChangeModel)
            Text("Retry keeps partial downloads. Download again replaces the cached model to repair damaged files.")
                .font(.caption).foregroundStyle(.secondary)
        case .stopped: Text("The speech model service has stopped.").foregroundStyle(.secondary)
        }
    }

    private func phaseLabel(_ phase: SpeechModelPreparationProgress.Phase) -> String {
        switch phase {
        case .checkingCache: "Checking model integrity…"
        case .downloading: "Downloading speech model…"
        case .compiling: "Preparing Core ML…"
        case .loading: "Loading speech model…"
        }
    }
}
