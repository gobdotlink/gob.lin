import AppKit
import Foundation
import GoblinEngines
import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var service: SpeechModelService
    @State private var selectionError: String?
    @State private var failedModelID: String?
    @State private var showAllModels = false
    @State private var search = ""
    @State private var languageFilter = "all"
    @State private var downloadedModelIDs: Set<String> = []

    init(service: SpeechModelService, showAllModels: Bool = false, search: String = "", languageFilter: String = "all") {
        self.service = service
        _showAllModels = State(initialValue: showAllModels)
        _search = State(initialValue: search)
        _languageFilter = State(initialValue: languageFilter)
    }

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CapsHeader("Speech Model").padding(.leading, 14)
                        Spacer()
                        Picker("Catalog", selection: $showAllModels) {
                            Text("Recommended \(SpeechModelCatalog.recommended.count)").tag(false)
                            Text("All Models \(service.models.count)").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().tint(GoblinBrand.moss)
                        .frame(width: 280)
                    }
                    HStack(spacing: 8) {
                        SearchField(prompt: "Search models or languages", text: $search)
                        Picker("Supports Language", selection: $languageFilter) {
                            Text("Any Language").tag("all")
                            ForEach(catalogLanguages, id: \.self) { code in Text(languageName(code)).tag(code) }
                        }
                        .labelsHidden().frame(width: 150)
                        .help("Filter model choices; this does not change your dictation language.")
                    }
                    Plate(padding: 0) {
                        // A short list hugs its rows; a long one scrolls inside the plate.
                        let rows = VStack(spacing: 2) {
                            if catalogModels.isEmpty { emptyCatalog }
                            ForEach(catalogModels) { model in
                                SpeechModelRow(model: model, service: service,
                                    downloaded: downloadedModelIDs.contains(model.id),
                                    selectionError: service.selectionFailureModelID == model.id ? service.selectionFailure
                                        : (failedModelID == model.id ? selectionError : nil),
                                    select: { select(model) })
                            }
                        }
                        .padding(4)
                        if catalogModels.count > 5 {
                            ScrollView { rows }.frame(height: 5.5 * SpeechModelRow.height)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
                        } else { rows }
                    }
                }
            }
            .containerValue(\.plateless, true)
            Section("Dictation Language") {
                let explicit = service.selectedModel.capabilities.languageControl == .explicit
                LabeledContent {
                    if service.selectedModel.capabilities.languageControl == .fixed {
                        Text("\(languageName(service.recognitionOptions.language ?? "en")) (fixed)").foregroundStyle(.secondary)
                    } else {
                        Picker(explicit ? "Recognition language" : "Preferred language",
                               selection: Binding(get: { service.recognitionOptions.language ?? "auto" }, set: { language in
                            do { try service.selectLanguage(language); selectionError = nil }
                            catch { selectionError = error.localizedDescription; failedModelID = service.selectedModel.id }
                        })) {
                            if service.selectedModel.capabilities.automaticLanguage { Text("Automatic").tag("auto") }
                            ForEach(languages, id: \.self) { code in Text(languageName(code)).tag(code) }
                        }
                        .labelsHidden().fixedSize().disabled(service.pendingModel != nil)
                    }
                } label: {
                    Text(service.selectedModel.capabilities.languageControl == .fixed ? "Language" : explicit ? "Recognition language" : "Preferred language")
                    Text(languageHint).rowDetail()
                    if service.preferredLanguage != (service.recognitionOptions.language ?? "auto") {
                        Text("You prefer \(languageName(service.preferredLanguage)), but \(service.selectedModel.name) uses \(languageName(service.recognitionOptions.language ?? "auto")). Your preference is kept for other models.")
                    }
                }
            }
            Section {
                LabeledContent {
                    Picker("Unload after idle", selection: $service.idleTimeout) {
                        ForEach(ModelIdleTimeout.allCases) { timeout in Text(timeout.label).tag(timeout) }
                    }
                    .labelsHidden().fixedSize()
                } label: {
                    Text("Unload after idle")
                    Text("Frees memory when idle; reloads when you talk.").rowDetail()
                }
                DisclosureGroup("Model details") {
                    LabeledContent("Active model", value: service.selectedModel.name)
                    LabeledContent("Runtime", value: service.selectedModel.runtime)
                    LabeledContent("Download size", value: modelSize(service.selectedModel))
                    LabeledContent("Supported languages", value: "\(service.selectedModel.capabilities.languageCodes.count)")
                    LabeledContent("Dictionary", value: dictionarySupport(service.selectedModel))
                    if let timing = service.lastLoadTiming {
                        LabeledContent("Model load") { Text(String(format: "%.0f ms", timing.runtimeLoadMilliseconds)).monospacedDigit() }
                        LabeledContent("Total preparation") { Text(String(format: "%.0f ms", timing.preparationMilliseconds)).monospacedDigit() }
                    }
                    Button("Open Model Folder") { NSWorkspace.shared.open(service.directory) }
                    Text("Models download from their publishers and run on this Mac. Files stay on disk when memory is freed.")
                        .font(.meta).foregroundStyle(.secondary)
                }
            } header: { Text("Storage & Memory") }
        }
        .task(id: service.isPreparing) { if !service.isPreparing { await refreshDownloads() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshDownloads() }
        }
    }

    private var languageHint: String {
        switch service.selectedModel.capabilities.languageControl {
        case .fixed: "This model recognizes English only."
        case .scriptHint: "Automatic suits switching languages. A preference picks the script."
        case .hint: "Automatic detects the language. A preference is a hint."
        case .explicit: "Pick the language you speak, or Automatic if you switch."
        }
    }

    private var languages: [String] { sortedLanguages(service.selectedModel.capabilities.languageCodes) }
    private var catalogLanguages: [String] { sortedLanguages(Array(Set(service.models.flatMap(\.capabilities.languageCodes)))) }
    private var matchingModels: [SpeechModelDescriptor] {
        SpeechModelCatalog.matching(query: search, language: languageFilter == "all" ? nil : languageFilter)
    }
    private var catalogModels: [SpeechModelDescriptor] {
        var models = matchingModels.filter { showAllModels || $0.recommended }
        // The current model leads either tab, so it's visible without scrolling or switching to All Models.
        if let current = matchingModels.first(where: { $0.id == service.selectedModel.id }) {
            models.removeAll { $0.id == current.id }
            models.insert(current, at: 0)
        }
        // A pending transfer must stay visible and cancellable even if filters change.
        if let pending = service.pendingModel, !models.contains(pending) { models.insert(pending, at: 0) }
        return models
    }

    private var emptyCatalog: some View {
        VStack(spacing: 12) {
            Text(!showAllModels && languageFilter != "all" && search.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "No recommended models support \(languageName(languageFilter))."
                 : "No \(showAllModels ? "models" : "recommended models") match these filters.")
                .fontWeight(.medium)
            if !showAllModels && !matchingModels.isEmpty {
                Button("Show All Matching Models") { showAllModels = true }
            } else {
                Button("Clear Filters") { search = ""; languageFilter = "all" }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 3 * SpeechModelRow.height).multilineTextAlignment(.center)
        .padding(.horizontal, 14)
    }

    private func select(_ model: SpeechModelDescriptor) {
        selectionError = nil; failedModelID = nil
        Task {
            do { try await service.selectModel(id: model.id) }
            catch {
                selectionError = error is CancellationError ? nil : error.localizedDescription
                failedModelID = selectionError == nil ? nil : model.id
            }
        }
    }

    private func refreshDownloads() async {
        let models = service.models, selectedID = service.selectedModel.id, selectedDirectory = service.directory
        let downloaded = await Task.detached(priority: .utility) {
            Set(models.filter { model in
                let directory = model.id == selectedID ? selectedDirectory : selectedDirectory.deletingLastPathComponent()
                    .appendingPathComponent(model.cacheFolder, isDirectory: true)
                return PinnedSpeechModelStore.isDownloaded(model: model, directory: directory)
            }.map(\.id))
        }.value
        if !Task.isCancelled { downloadedModelIDs = downloaded }
    }
}

struct SpeechModelRow: View {
    let model: SpeechModelDescriptor
    @ObservedObject var service: SpeechModelService
    let downloaded: Bool
    var selectionError: String?
    let select: () -> Void
    @State private var showLanguages = false
    @State private var showProgressDetails = false
    @State private var showFailureDetails = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// A name, a summary and a details line, with 8 pt above and below.
    static let height: CGFloat = 72

    private var current: Bool { service.selectedModel.id == model.id }
    private var pending: Bool { service.pendingModel?.id == model.id }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).fontWeight(.semibold)
                Text(model.selectionSummary).font(.status).foregroundStyle(.secondary).lineLimit(1)
                // The dictionary marker is the first thing to go when the row is narrow.
                ViewThatFits(in: .horizontal) {
                    if model.capabilities.customVocabulary { details(dictionary: true) }
                    details(dictionary: false)
                }.font(.meta).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) { action }
                .font(.status).frame(width: 128)
        }
        // The current model is an inset tinted row, like first run's current permission.
        .padding(.horizontal, 10).frame(height: Self.height)
        .background(current ? (contrast == .increased ? GoblinBrand.moss.opacity(0.3) : GoblinBrand.selection) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func details(dictionary: Bool) -> some View {
        HStack(spacing: 5) {
            Text(modelSize(model)).monospacedDigit()
            Text("·")
            Button {
                showLanguages = true
            } label: {
                HStack(spacing: 3) {
                    Text(model.capabilities.languageCodes.count == 1 ? "\(languageName(model.capabilities.languageCodes[0])) only"
                         : "\(model.capabilities.languageCodes.count) languages").monospacedDigit()
                        .underline(color: GoblinBrand.mossText.opacity(0.4))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(GoblinBrand.mossText)
            .accessibilityLabel("Show languages supported by \(model.name)")
            .popover(isPresented: $showLanguages) { ModelLanguagesPopover(model: model) }
            Text("·")
            Text(model.capabilities.livePreview ? "Text while speaking" : "Text after recording")
            if dictionary {
                Text("·")
                Text("Dictionary").accessibilityLabel("Uses your dictionary during recognition")
            }
            Text("·")
            Text(model.released, format: .dateTime.month(.abbreviated).year())
                .accessibilityLabel("Released \(model.released.formatted(.dateTime.month(.wide).year()))")
        }
    }

    @ViewBuilder private var action: some View {
        if pending, let progress = service.selectionProgress {
            preparation(progress, cancellable: true)
        } else if current {
            currentAction
        } else if let selectionError {
            status(.problem, "Switch Failed")
            HStack(spacing: 8) {
                Button("Retry", action: select).disabled(!service.canChangeModel)
                failureDetails(selectionError)
            }.controlSize(.small)
        } else {
            wideButton(downloaded ? "Use Model" : "Download & Use", action: select)
                .disabled(!service.canChangeModel)
                .accessibilityLabel("\(downloaded ? "Use" : "Download and use") \(model.name)")
            Text(downloaded ? "Downloaded" : "Download required").font(.meta).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var currentAction: some View {
        switch service.state {
        case .ready:
            Label("Current", systemImage: "checkmark").fontWeight(.semibold).foregroundStyle(GoblinBrand.mossText)
            status(.ready, service.activeSessionCount > 0 ? "In use · offline" : "Ready offline")
        case .notPrepared:
            wideButton(downloaded ? "Load Model" : "Download & Use") { service.preload() }
            status(.off, "Current · not loaded")
        case .preparing(let progress):
            if service.pendingModel == nil { preparation(progress, cancellable: service.activeSessionCount == 0) }
            else { status(.waiting, "Switching…") }
        case .unloading: status(.waiting, "Freeing memory…")
        case .unloaded:
            Label("Current", systemImage: "checkmark").fontWeight(.semibold).foregroundStyle(GoblinBrand.mossText)
            status(.off, "Wakes when you talk")
            wideButton("Load Now") { service.retry() }
        case .cancelling: status(.waiting, "Cancelling…")
        case .cancelled:
            status(.off, "Preparation cancelled")
            wideButton("Resume") { service.retry() }
        case .failed(let message):
            status(.problem, "Preparation failed")
            HStack(spacing: 8) {
                Button("Retry") { service.retry() }.disabled(!service.canChangeModel)
                failureDetails(message)
            }.controlSize(.small)
        case .stopped: status(.off, "Stopped")
        }
    }

    private func wideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
    }

    private func status(_ light: LightState, _ text: String) -> some View {
        HStack(spacing: 5) {
            StatusLight(state: light)
            Text(text).font(.meta).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func preparation(_ progress: SpeechModelPreparationProgress, cancellable: Bool) -> some View {
        VStack(spacing: 6) {
            Button { showProgressDetails = true } label: {
                HStack(spacing: 4) {
                    Text(progressLabel(progress)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let fraction = progress.fractionCompleted, progress.phase == .downloading {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    } else { Image(systemName: "info.circle") }
                }.font(.meta).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showProgressDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.name).font(.row.weight(.semibold))
                    Text(progressLabel(progress))
                    if let component = progress.component { Text(component).foregroundStyle(.secondary) }
                    if let start = service.preparationStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(Int(max(0, context.date.timeIntervalSince(start)))) seconds elapsed").monospacedDigit()
                        }
                    }
                    Text(progress.phase == .downloading
                         ? "Interrupted downloads keep their progress.\(pending ? " Your current model stays available during download." : "")"
                         : "First-use preparation can take several minutes. Switching waits for active dictations to finish.")
                        .font(.status).foregroundStyle(.secondary)
                }.padding(16).frame(width: 320)
            }
            if let fraction = progress.fractionCompleted, progress.phase == .downloading {
                ProgressView(value: fraction).tint(GoblinBrand.moss).accessibilityLabel("\(model.name) download progress")
            } else { ProgressView().controlSize(.small).frame(height: 12) }
            Button("Cancel") { service.cancelPreparation() }.controlSize(.small).disabled(!cancellable)
                .accessibilityLabel("Cancel preparation of \(model.name)")
        }
    }

    private func failureDetails(_ message: String) -> some View {
        Button("Details…") { showFailureDetails = true }
            .popover(isPresented: $showFailureDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.name).font(.row.weight(.semibold))
                    Text(message).font(.status).textSelection(.enabled)
                    Text(current ? "Retry keeps downloaded files. Download Again replaces this model's cache to repair damaged files."
                         : "Retry keeps downloaded files. Your previous model selection is kept if preparation fails.")
                        .font(.status).foregroundStyle(.secondary)
                    if current {
                        Button("Download Again", role: .destructive) { Task { await service.repair() } }
                            .disabled(!service.canChangeModel)
                    }
                }.padding(16).frame(width: 320)
            }
    }

    private func progressLabel(_ progress: SpeechModelPreparationProgress) -> String {
        if progress.component == "Waiting for current dictations to finish" { return "Waiting for dictations…" }
        if progress.component == "Cancelling model switch" { return "Cancelling…" }
        switch progress.phase {
        case .checkingCache: return "Checking files…"
        case .downloading: return "Downloading…"
        case .compiling: return "Preparing on your Mac…"
        case .loading: return "Loading…"
        }
    }
}

struct ModelLanguagesPopover: View {
    let model: SpeechModelDescriptor
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var languages: [String] {
        sortedLanguages(model.capabilities.languageCodes).filter {
            search.isEmpty || languageName($0).localizedStandardContains(search) || $0.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supported Languages").font(.row.weight(.semibold))
                    Text(model.name).font(.status).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    .buttonStyle(.borderless).accessibilityLabel("Close supported languages")
            }
            TextField("Find a language", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityLabel("Find a supported language")
            ScrollView {
                if languages.isEmpty { Text("No matching language.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(languages, id: \.self) { code in Text(languageName(code)).font(.status) }
                }
            }.frame(height: 180)
            Text("\(languages.count) of \(model.capabilities.languageCodes.count) supported languages")
                .font(.meta).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 320)
        .onAppear { searchFocused = true }
    }
}

private func languageName(_ code: String) -> String {
    code == "auto" ? "Automatic" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
}
private func sortedLanguages(_ codes: [String]) -> [String] {
    codes.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
}
private func modelSize(_ model: SpeechModelDescriptor) -> String {
    ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .decimal)
}

private func dictionarySupport(_ model: SpeechModelDescriptor) -> String {
    model.capabilities.customVocabulary ? "Spelling hints while recognizing" : "Aliases and Cleanup only"
}
