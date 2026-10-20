import GoblinCore
import GoblinEngines
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DictionaryModel: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published var error: String?
    @Published private(set) var lastFailure: DiagnosticFailure?
    private let repository: DictionaryRepository
    private(set) var available = false

    init(repository: DictionaryRepository = .applicationDefault) {
        self.repository = repository
        do { entries = try repository.load(); available = true }
        catch { lastFailure = .dictionaryUnavailable; self.error = "Could not load your dictionary: \(error.localizedDescription)" }
    }

    func put(_ entry: DictionaryEntry) -> Bool {
        var next = entries.filter { $0.id != entry.id }
        next.append(entry)
        return persist(next)
    }

    func delete(_ entry: DictionaryEntry) { _ = persist(entries.filter { $0.id != entry.id }) }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { _ = persist(try DictionaryRepository.importing(String(contentsOf: url, encoding: .utf8), into: entries)) }
        catch { lastFailure = .dictionaryUnavailable; self.error = "Could not import the word list: \(error.localizedDescription)" }
    }

    private func persist(_ next: [DictionaryEntry]) -> Bool {
        guard available else {
            lastFailure = .dictionaryUnavailable
            error = "Your dictionary could not be loaded. Fix the file before saving to avoid losing existing entries."
            return false
        }
        do { try repository.save(next); entries = try DictionaryRepository.validated(next); error = nil; lastFailure = nil; return true }
        catch { lastFailure = .dictionaryUnavailable; self.error = error.localizedDescription; return false }
    }
}

struct DictionarySettingsView: View {
    @ObservedObject var model: DictionaryModel
    @ObservedObject var service: SpeechModelService
    @AppStorage private var rewriteData: Data
    @State private var editing: DictionaryEntry?
    @State private var importing = false
    @State private var preview: (request: PreviewRequest, usage: SpeechDictionaryUsage)?
    @State private var previewError: (request: PreviewRequest, message: String)?

    init(model: DictionaryModel, service: SpeechModelService, defaults: UserDefaults = .standard) {
        self.model = model; self.service = service
        _rewriteData = AppStorage(wrappedValue: Data(), RewriteSettingsStore.preferenceKey, store: defaults)
    }

    private struct PreviewRequest: Hashable {
        let modelID: String
        let directory: URL
        let terms: [String]
        let installed: Bool
    }

    private var request: PreviewRequest {
        PreviewRequest(modelID: service.selectedModel.id, directory: service.directory, terms: model.entries.map(\.spelling),
                       installed: PinnedSpeechModelStore.isDownloaded(model: service.selectedModel, directory: service.directory))
    }
    private var cleanupEnabled: Bool {
        guard let settings = try? JSONDecoder().decode(RewriteSettings.self, from: rewriteData) else { return false }
        return settings.enabled && settings.cleanup != .none
    }

    var body: some View {
        let current = request
        let usage = preview?.request == current ? preview?.usage : nil
        Section {
            LabeledContent {
                Text(service.selectedModel.name)
            } label: {
                Text("Speech Model")
                if service.selectedModel.capabilities.customVocabulary { Text("Spelling hints · whole terms in alphabetical order") }
            }
            if !model.available {
                StatusRow(.problem, Text("I couldn't load your dictionary."))
            } else if !service.selectedModel.capabilities.customVocabulary {
                StatusRow(.off, Text("\(service.selectedModel.name) doesn't support a native dictionary. I don't send terms during recognition."))
            } else if model.entries.isEmpty {
                StatusRow(.ready, Text("\(service.selectedModel.name) supports a native dictionary. I'll send the terms you add automatically."))
            } else if let usage {
                StatusRow(usage.excluded.isEmpty ? .ready : .waiting,
                          Text("I send \(usage.included.count) of \(model.entries.count) terms to \(service.selectedModel.name).").monospacedDigit()) {
                    Text("\(usage.tokenCount)/\(usage.tokenLimit) tokens").monospacedDigit()
                }
            } else if !current.installed {
                StatusRow(.waiting, Text("Prepare \(service.selectedModel.name) in Model settings so I can check which terms fit."))
            } else if let error = previewError, error.request == current {
                StatusRow(.problem, Text("I couldn't check the dictionary limit: \(error.message)"))
            } else {
                StatusRow(.waiting, Text("I'm checking which terms fit…"))
            }
        } header: { Text("Native Recognition") }
        .task(id: current) {
            guard model.available, service.selectedModel.capabilities.customVocabulary, current.installed, !current.terms.isEmpty else { return }
            do {
                let result = try await WhisperSpeechEngine.dictionaryUsage(terms: current.terms, model: service.selectedModel, directory: current.directory)
                try Task.checkCancellation()
                preview = (current, result)
            } catch {
                guard !Task.isCancelled else { return }
                previewError = (current, error.localizedDescription)
            }
        }
        Section {
            StatusRow(cleanupEnabled ? .ready : .off,
                      Text(cleanupEnabled ? "I include all your preferred spellings in the Cleanup prompt, including terms beyond the native limit."
                                         : "Cleanup is off. I don't send your dictionary to a rewrite model."))
        } header: { Text("Cleanup") }
        Section {
            if model.entries.isEmpty {
                ContentUnavailableView("Add your vocabulary", systemImage: "character.book.closed",
                    description: Text("Add a preferred spelling and optional “sounds like” aliases. Import a text file with one term per line."))
            } else {
                ForEach(model.entries.sorted { $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending }) { entry in
                    if usage?.excluded.first == entry.spelling {
                        StatusRow(.waiting, Text("The terms below don't fit. I don't send them to recognition."))
                    }
                    LabeledContent {
                        HStack {
                            Button("Edit") { editing = entry }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(entry) }.labelStyle(.iconOnly)
                                .accessibilityLabel("Delete \(entry.spelling)")
                        }
                    } label: {
                        Text(entry.spelling).font(.body.monospaced())
                        if !entry.aliases.isEmpty { Text("sounds like: " + entry.aliases.joined(separator: ", ")) }
                        if usage?.excluded.contains(entry.spelling) == true { Text("Not sent to recognition").foregroundStyle(.secondary) }
                    }
                }
            }
            StatusRow(model.entries.isEmpty ? .off : .ready,
                      Text("I apply exact “sounds like” aliases after recognition with every model, including terms beyond the native limit."))
        } header: {
            HStack {
                Text("Terms")
                Spacer()
                Group {
                    Button("Import Words…") { importing = true }.disabled(!model.available)
                    Button("Add Term", systemImage: "plus") { editing = DictionaryEntry(spelling: "") }.disabled(!model.available)
                        .prominent()
                }
                .textCase(nil).font(.callout).controlSize(.small)
            }
        }
        .sheet(item: $editing) { entry in DictionaryEntryEditor(entry: entry, model: model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            switch result {
            case .success(let url): model.importFile(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("Dictionary", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct DictionaryEntryEditor: View {
    let entry: DictionaryEntry
    @ObservedObject var model: DictionaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var spelling: String
    @State private var aliases: String
    @State private var error: String?

    init(entry: DictionaryEntry, model: DictionaryModel) {
        self.entry = entry
        self.model = model
        _spelling = State(initialValue: entry.spelling)
        _aliases = State(initialValue: entry.aliases.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(entry.spelling.isEmpty ? "Add term" : "Edit term") {
                    TextField("Preferred spelling", text: $spelling)
                }
                Section {
                    TextEditor(text: $aliases).font(.body.monospaced()).frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Sounds like aliases")
                } header: { Text("Sounds like — one alias per line") } footer: {
                    Text("For example, “day review” → “Dev review”. Aliases match whole words without crossing punctuation.")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .formStyle(.grouped).frame(height: 330)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.put(DictionaryEntry(id: entry.id, spelling: spelling, aliases: aliases.components(separatedBy: .newlines))) {
                        dismiss()
                    } else { error = model.error; model.error = nil }
                }.keyboardShortcut(.defaultAction).disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom], GoblinBrand.pagePadding)
        }
        .frame(width: 460)
    }
}
