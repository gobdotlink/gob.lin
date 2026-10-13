import GoblinCore
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
    @State private var editing: DictionaryEntry?
    @State private var importing = false

    init(model: DictionaryModel = DictionaryModel()) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dictionary").font(.title.bold())
                    Text("Your names and jargon, spelled your way.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import words…") { importing = true }.disabled(!model.available)
                Button("Add term", systemImage: "plus") { editing = DictionaryEntry(spelling: "") }.disabled(!model.available)
                    .buttonStyle(.borderedProminent)
            }
            if model.entries.isEmpty {
                ContentUnavailableView("Add your vocabulary", systemImage: "character.book.closed",
                    description: Text("Add a preferred spelling and optional “sounds like” aliases. Import a text file with one term per line."))
            } else {
                List(model.entries.sorted { $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending }) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.spelling).font(.headline)
                            if !entry.aliases.isEmpty { Text("Sounds like: " + entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Edit") { editing = entry }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(entry) }.labelStyle(.iconOnly)
                            .accessibilityLabel("Delete \(entry.spelling)")
                    }.padding(.vertical, 6)
                }
            }
            Text("Only words you add are used. Exact aliases are active; fuzzy guessing and recognizer biasing await replay validation.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.spelling.isEmpty ? "Add term" : "Edit term").font(.title2.bold())
            TextField("Preferred spelling", text: $spelling)
            Text("Sounds like — one alias per line").font(.headline)
            TextEditor(text: $aliases).frame(height: 100).border(.quaternary)
                .accessibilityLabel("Sounds like aliases")
            Text("For example, “day review” → “Dev review”. Aliases match whole words without crossing punctuation.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.put(DictionaryEntry(id: entry.id, spelling: spelling, aliases: aliases.components(separatedBy: .newlines))) {
                        dismiss()
                    } else { error = model.error; model.error = nil }
                }.keyboardShortcut(.defaultAction).disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
}
