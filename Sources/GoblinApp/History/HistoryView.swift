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
            let section = SettingsSection.history
            PaneHeader(title: section.rawValue, comment: section.comment) {
                Button("Retention…", systemImage: "clock") { showingRetention = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }.labelStyle(.iconOnly)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts or app names", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search history")
                if !model.searchText.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { model.searchText = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .padding(.horizontal, GoblinBrand.pagePadding).padding(.vertical, 12)
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.errorMessage = nil }.labelStyle(.iconOnly)
                }
                .padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .bottom], GoblinBrand.pagePadding)
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
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .bottom], GoblinBrand.pagePadding)
            }
            Divider()
            if model.entries.isEmpty, !model.isLoading {
                // One empty state for the whole page, not an empty list beside an empty detail.
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No dictations yet" : "No matches",
                          systemImage: model.searchText.isEmpty ? "waveform" : "magnifyingglass")
                } description: {
                    Text(model.searchText.isEmpty ? "Hold your shortcut and talk. Raw text, final text, and original audio stay together here."
                                                  : "Nothing matches “\(model.searchText)”.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(model.entries) { entry in row(entry).tag(entry.id) }
                        if model.hasMore {
                            Button("Load older dictations") { Task { await model.loadMore() } }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 280, maxHeight: .infinity)
                    Group {
                        if let entry = model.entries.first(where: { $0.id == selectedID }) {
                            details(entry)
                        } else {
                            ContentUnavailableView("Select a dictation", systemImage: "text.alignleft")
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: model.searchText) { await model.reload() }
        .onChange(of: model.entries.map(\.id), initial: true) { _, ids in
            if selectedID.map({ ids.contains($0) }) != true { selectedID = ids.first }
        }
        .sheet(isPresented: $showingRetention) { HistoryRetentionView(model: model) }
        .alert("Delete this dictation and its saved audio?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let entry = deleteCandidate { Task { await model.delete(entry) } }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
        .onDisappear { model.stopAudio() }
        // Take the width offered instead of the split view's ideal, so the sidebar keeps its width.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 420)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.finalText.isEmpty ? "Empty transcript" : entry.finalText).lineLimit(2)
            HStack(spacing: 4) {
                if entry.starred { Image(systemName: "star.fill").foregroundStyle(GoblinBrand.yellow).accessibilityLabel("Starred") }
                Text("\(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))\(entry.targetApplicationName.map { " · " + $0 } ?? "")")
                    .lineLimit(1)
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func details(_ entry: HistoryEntry) -> some View {
        Form {
            Section {
                HStack {
                    Text(entry.createdAt, format: .dateTime.weekday(.wide).month().day().hour().minute()).font(.headline)
                    Spacer()
                    Button(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.fill" : "star") {
                        Task { await model.setStarred(!entry.starred, entry: entry) }
                    }.labelStyle(.iconOnly).foregroundStyle(entry.starred ? GoblinBrand.yellow : .secondary)
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteCandidate = entry }.labelStyle(.iconOnly)
                }
                if let warning = entry.processingWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            transcript("Final text", text: entry.finalText)
            transcript("Raw text", text: entry.rawText)
            Section {
                ViewThatFits(in: .horizontal) {
                    reprocessControls(entry)
                    reprocessControls(entry, vertical: true)
                }
            } footer: {
                if model.retranscribeAction == nil { Text("Re-transcription is unavailable right now.") }
            }
            Section("Details") {
                LabeledContent("App", value: entry.targetApplicationName ?? "Not recorded")
                LabeledContent("Tone", value: entry.tone)
                LabeledContent("Words") { Text("\(entry.wordCount)").monospacedDigit() }
                LabeledContent("Audio") { Text(String(format: "%.1f seconds", entry.audioDuration)).monospacedDigit() }
                LabeledContent("Model", value: entry.model.isEmpty ? "Not recorded" : entry.model)
                DisclosureGroup("Latency breakdown") {
                    LabeledContent("Capture", value: milliseconds(entry.latencies.captureMilliseconds))
                    LabeledContent("Silence trimming", value: milliseconds(entry.latencies.trimMilliseconds))
                    LabeledContent("Recognition", value: milliseconds(entry.latencies.asrMilliseconds))
                    LabeledContent("Rewrite", value: milliseconds(entry.latencies.rewriteMilliseconds))
                    LabeledContent("Insertion", value: milliseconds(entry.latencies.insertionMilliseconds))
                }
                .monospacedDigit()
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private func reprocessControls(_ entry: HistoryEntry, vertical: Bool = false) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        return layout {
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
    }

    private func transcript(_ title: String, text: String) -> some View {
        Section {
            Text(text.isEmpty ? "No text" : text).textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copy(text) }.labelStyle(.titleAndIcon).controlSize(.small)
                    .accessibilityLabel("Copy " + title.lowercased())
            }
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
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Maximum unstarred dictations", text: $count, prompt: Text("Keep all"))
                    TextField("Maximum age in days", text: $age, prompt: Text("No limit"))
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                } header: { Text("Retention") } footer: {
                    Text("Keep everything by leaving both limits empty. Starred dictations are always kept. Applying limits deletes older unstarred dictations and their saved audio.")
                }
            }
            .formStyle(.grouped).frame(height: 230)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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
                }.keyboardShortcut(.defaultAction).tint(GoblinBrand.tint)
            }
            .padding([.horizontal, .bottom], GoblinBrand.pagePadding)
        }
        .frame(width: 440)
        .onAppear {
            count = model.retention.maximumUnstarredCount.map(String.init) ?? ""
            age = model.retention.maximumAgeDays.map(String.init) ?? ""
        }
    }
}
