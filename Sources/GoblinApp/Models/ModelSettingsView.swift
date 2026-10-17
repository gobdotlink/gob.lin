import AppKit
import Foundation
import GoblinEngines
import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var service: SpeechModelService
    @State private var selectionError: String?
    @State private var showAllModels = false
    @State private var search = ""
    @State private var languageFilter = "all"
    @State private var livePreviewOnly = false

    var body: some View {
        Section {
            LabeledContent("Active model", value: service.selectedModel.name)
            if let error = selectionError ?? service.selectionFailure { Text(error).foregroundStyle(.orange) }
            Text(service.selectedModel.purpose).fontWeight(.semibold)
            Text(service.selectedModel.detail).font(.callout).foregroundStyle(.secondary)
            if let pending = service.pendingModel {
                Label("Preparing \(pending.name). Your current selection stays saved until it is ready.", systemImage: "arrow.triangle.2.circlepath")
            }
            LabeledContent("Runtime", value: service.selectedModel.runtime)
            LabeledContent("Download", value: size(service.selectedModel))
            LabeledContent("Preview", value: service.selectedModel.capabilities.livePreview ? "Live text while recording" : "Text after recording")
            if service.selectedModel.capabilities.languageControl == .fixed {
                LabeledContent("Recognition language", value: "\(languageName(service.recognitionOptions.language ?? "en")) (fixed)")
            } else {
                Picker(service.selectedModel.capabilities.languageControl == .explicit ? "Recognition language" : "Preferred language",
                       selection: Binding(get: { service.recognitionOptions.language ?? "auto" }, set: { language in
                    do { try service.selectLanguage(language); selectionError = nil }
                    catch { selectionError = error.localizedDescription }
                })) {
                    if service.selectedModel.capabilities.automaticLanguage { Text("Automatic").tag("auto") }
                    ForEach(languages, id: \.self) { code in Text(languageName(code)).tag(code) }
                }.disabled(service.pendingModel != nil)
            }
            if service.preferredLanguage != (service.recognitionOptions.language ?? "auto") {
                Text("Saved preference: \(languageName(service.preferredLanguage)). This model uses \(languageName(service.recognitionOptions.language ?? "auto")); your preference is retained when you switch models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup {
                Text(service.selectedModel.capabilities.languageCodes.map {
                    Locale.current.localizedString(forLanguageCode: $0) ?? $0
                }.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            } label: {
                LabeledContent("Supported languages", value: "\(service.selectedModel.capabilities.languageCodes.count)")
            }
        } header: { Text("Speech model") } footer: {
            Text("Models download directly from their publishers, then work offline. Language changes apply to the next recording. Your audio is transcribed locally in its original language.")
        }
        Section("Status") {
            if let pending = service.pendingModel, let progress = service.selectionProgress {
                Label("Preparing \(pending.name)", systemImage: "arrow.triangle.2.circlepath")
                if let fraction = progress.fractionCompleted, progress.phase == .downloading {
                    ProgressView(value: fraction).accessibilityLabel("Model download progress")
                } else { ProgressView().controlSize(.small) }
                if let component = progress.component { Text(component).font(.caption).foregroundStyle(.secondary) }
                Text("The current model stays available during download. Switching waits for all active dictations to finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel model switch") { service.cancelPreparation() }
            }
            if service.pendingModel == nil || service.state == .ready { status }
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
            Picker("Catalog", selection: $showAllModels) {
                Text("Recommended (\(SpeechModelCatalog.recommended.count))").tag(false)
                Text("All models (\(service.models.count))").tag(true)
            }.pickerStyle(.segmented)
            if showAllModels {
                TextField("Search models or languages", text: $search)
                Picker("Filter by language", selection: $languageFilter) {
                    Text("Any language").tag("all")
                    ForEach(catalogLanguages, id: \.self) { code in Text(languageName(code)).tag(code) }
                }
                Toggle("Live preview only", isOn: $livePreviewOnly)
            }
            ForEach(catalogModels) { model in
                Button { select(model) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).fontWeight(.medium).foregroundStyle(.primary)
                            Text(model.purpose).font(.callout).foregroundStyle(.secondary)
                            Text("\(size(model)) · \(model.capabilities.languageCodes.count == 1 ? languageName(model.capabilities.languageCodes[0]) : "\(model.capabilities.languageCodes.count) languages") · \(model.capabilities.livePreview ? "Live preview" : "Text after recording")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if model.id == service.selectedModel.id {
                            Label("Selected", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Label("Use", systemImage: "arrow.right").font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!service.canChangeModel || model.id == service.selectedModel.id)
                .help(model.detail)
                .accessibilityLabel("\(model.name), \(model.purpose), \(size(model))\(model.id == service.selectedModel.id ? ", selected" : "")")
            }
            if catalogModels.isEmpty { Text("No models match these filters.").foregroundStyle(.secondary) }
        } header: { Text("Choose a model") } footer: {
            Text("Recommended choices cover common needs. The full catalog includes intermediate sizes, English-only models and language specialists. Filters only change this list; your active model and recognition language stay selected.")
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

    private var languages: [String] {
        service.selectedModel.capabilities.languageCodes.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
    }

    private var catalogModels: [SpeechModelDescriptor] {
        SpeechModelCatalog.matching(query: showAllModels ? search : "", language: showAllModels && languageFilter != "all" ? languageFilter : nil,
                                   livePreviewOnly: showAllModels && livePreviewOnly, recommendedOnly: !showAllModels)
    }

    private var catalogLanguages: [String] {
        Array(Set(service.models.flatMap(\.capabilities.languageCodes))).sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
    }

    private func select(_ model: SpeechModelDescriptor) {
        selectionError = nil
        Task {
            do { try await service.selectModel(id: model.id); selectionError = nil }
            catch { selectionError = error is CancellationError ? nil : error.localizedDescription }
        }
    }

    private func languageName(_ code: String) -> String {
        code == "auto" ? "Automatic" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }

    private func size(_ model: SpeechModelDescriptor) -> String {
        ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .decimal)
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
        case .ready: StatusRow(.ready, Text("**Ready** · available offline"))
        case .unloading: StatusRow(.waiting, Text("Unloading idle model…"))
        case .unloaded:
            StatusRow(.ready, Text("**Unloaded** to free memory · wakes when you talk")) {
                Button("Load Now") { service.retry() }
            }
        case .cancelling:
            StatusRow(.waiting, Text("Cancelling · waiting for model work to finish…"))
        case .cancelled:
            StatusRow(.off, Text("Preparation cancelled · downloaded files kept")) {
                Button("Resume Preparation") { service.retry() }
            }
        case .failed(let message):
            StatusRow(.problem, Text("**Model preparation failed**"))
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
