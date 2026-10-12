import AppKit
import GoblinCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var selectedID: UUID?
    @State private var deleteCandidate: HistoryEntry?
    @State private var showingRetention = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.errorMessage = nil }.labelStyle(.iconOnly)
                }
                .padding(12).background(.orange.opacity(0.1))
            }
            if !model.pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unsaved dictations — copy or retry before quitting").font(.headline)
                    ForEach(model.pending) { item in
                        HStack {
                            Text(item.entry.rawText).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Copy raw") { copy(item.entry.rawText) }
                        }
                    }
                    Button("Retry saving") { Task { await model.retryPending() } }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1))
            }
            NavigationSplitView {
                List(selection: $selectedID) {
                    ForEach(model.entries) { entry in
                        HStack(alignment: .top) {
                            if entry.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.finalText.isEmpty ? "Empty transcript" : entry.finalText).lineLimit(2)
                                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4).tag(entry.id)
                    }
                    if model.hasMore {
                        Button("Load older dictations") { Task { await model.loadMore() } }
                    }
                }
                .overlay {
                    if model.entries.isEmpty, !model.isLoading {
                        ContentUnavailableView(model.searchText.isEmpty ? "No dictations yet" : "No matches",
                                               systemImage: "text.bubble", description: Text("Raw text, final text, and original audio stay together here."))
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                if let entry = model.entries.first(where: { $0.id == selectedID }) {
                    details(entry)
                } else {
                    ContentUnavailableView("Select a dictation", systemImage: "text.alignleft")
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search transcripts or app names")
        .task(id: model.searchText) { await model.reload() }
        .toolbar {
            Button("Retention", systemImage: "clock") { showingRetention = true }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
        }
        .sheet(isPresented: $showingRetention) { HistoryRetentionView(model: model) }
        .alert("Delete this dictation and its saved audio?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let entry = deleteCandidate { Task { await model.delete(entry); selectedID = nil } }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
        .onDisappear { model.stopAudio() }
        .frame(minWidth: 700, minHeight: 420)
    }

    private func details(_ entry: HistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(entry.createdAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                    Spacer()
                    Button(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.fill" : "star") {
                        Task { await model.setStarred(!entry.starred, entry: entry) }
                    }.labelStyle(.iconOnly)
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteCandidate = entry }.labelStyle(.iconOnly)
                }
                LabeledContent("App", value: entry.targetApplicationName ?? "Not recorded")
                LabeledContent("Tone", value: entry.tone)
                LabeledContent("Words", value: "\(entry.wordCount)")
                LabeledContent("Audio", value: String(format: "%.1f seconds", entry.audioDuration))
                LabeledContent("Model", value: entry.model.isEmpty ? "Not recorded" : entry.model)
                if let warning = entry.processingWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Divider()
                transcript("Final text", text: entry.finalText)
                transcript("Raw text", text: entry.rawText)
                HStack {
                    Button(model.playingEntryID == entry.id ? "Stop audio" : "Play audio", systemImage: "play.fill") {
                        Task { await model.play(entry) }
                    }.disabled(entry.audioFilename == nil)
                    Button("Re-transcribe") { Task { await model.reprocess(entry, transcribe: true) } }
                        .disabled(model.retranscribeAction == nil || entry.audioFilename == nil)
                        .help(model.retranscribeAction == nil ? "Unavailable until a speech engine is selected." : "Create a new dictation from the original, untrimmed audio.")
                    Button("Rewrite") { Task { await model.reprocess(entry, transcribe: false) } }
                        .disabled(model.rewriteAction == nil)
                        .help(model.rewriteAction == nil ? "Enable and configure AI cleanup to rewrite this dictation." : "Save rewritten text as a new entry; the original stays intact.")
                }
                if model.retranscribeAction == nil {
                    Text("Re-transcription becomes available after the speech engine benchmark.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Latency breakdown") {
                    LabeledContent("Capture", value: milliseconds(entry.latencies.captureMilliseconds))
                    LabeledContent("Silence trimming", value: milliseconds(entry.latencies.trimMilliseconds))
                    LabeledContent("Recognition", value: milliseconds(entry.latencies.asrMilliseconds))
                    LabeledContent("Rewrite", value: milliseconds(entry.latencies.rewriteMilliseconds))
                    LabeledContent("Insertion", value: milliseconds(entry.latencies.insertionMilliseconds))
                }
            }
            .padding(24)
        }
    }

    private func transcript(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") { copy(text) }
            }
            Text(text.isEmpty ? "No text" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

struct HistoryRetentionView: View {
    @ObservedObject var model: HistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = ""
    @State private var age = ""
    @State private var error: String?

    var body: some View {
        Form {
            Text("Keep everything by leaving both limits empty. Starred dictations are always kept.")
            Text("Applying limits deletes older unstarred dictations and their saved audio.").foregroundStyle(.secondary)
            TextField("Maximum unstarred dictations", text: $count)
            TextField("Maximum age in days", text: $age)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save and apply") {
                    let countValue = Int(count)
                    let ageValue = Int(age)
                    guard (count.isEmpty || countValue.map { $0 >= 0 } == true),
                          (age.isEmpty || ageValue.map { $0 >= 1 } == true) else {
                        error = "Use a count of zero or greater and an age of at least one day, or leave a limit empty."
                        return
                    }
                    Task {
                        await model.saveRetention(HistoryRetention(maximumUnstarredCount: countValue, maximumAgeDays: ageValue))
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear {
            count = model.retention.maximumUnstarredCount.map(String.init) ?? ""
            age = model.retention.maximumAgeDays.map(String.init) ?? ""
        }
    }
}
