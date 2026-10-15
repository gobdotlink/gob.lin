import GoblinCore
import SwiftUI

enum HistoryScope: Hashable {
    case insights, entries(HistoryFilter)
    static let all = Self.entries(.all)
}

/// Settings › History: how much to keep. Browsing lives in the History window.
struct HistorySettingsView: View {
    @ObservedObject var model: HistoryModel
    let open: (HistoryScope) -> Void
    @State private var showingRetention = false

    var body: some View {
        Section {
            LabeledContent("Keep at most") { Text(model.retention.maximumUnstarredCount.map { "\($0.formatted()) dictations" } ?? "Everything") }
            LabeledContent("Delete after") { Text(model.retention.maximumAgeDays.map { "\($0.formatted()) days" } ?? "Never") }
            StatusRow(.ready, Text("Starred dictations are always kept.")) {
                Button("Change…") { showingRetention = true }
            }
        } header: { CapsHeader("Keep") }
        Section {
            StatusRow(model.store == nil ? .problem : .ready,
                      Text(model.store == nil ? "History is unavailable right now." : "\(model.counts.total.formatted()) dictations with their audio, on this Mac.")) {
                Button("Open History") { open(.all) }
            }
            StatusRow(.ready, Text("Words per day, your pace, and the apps you talk to most.")) {
                Button("Open Insights") { open(.insights) }
            }
        } header: { CapsHeader("Stored") }
        .sheet(isPresented: $showingRetention) { HistoryRetentionView(model: model) }
        .task { await model.reload() }
    }
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
                    TextField("Keep at most", text: $count, prompt: Text("Everything"))
                    TextField("Delete after (days)", text: $age, prompt: Text("Never"))
                    if let error { StatusRow(.problem, Text(error)) }
                } header: { CapsHeader("Keep") } footer: {
                    Text("Starred dictations are always kept. Applying a limit deletes older unstarred dictations and their audio.")
                }
            }
            .formStyle(.grouped).frame(height: 230)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and Apply") {
                    let countValue = Int(count)
                    let ageValue = Int(age)
                    guard (count.isEmpty || countValue.map { $0 >= 0 } == true),
                          (age.isEmpty || ageValue.map { $0 >= 1 } == true) else {
                        error = "Use a count of zero or more and at least one day, or leave a limit empty."
                        return
                    }
                    Task {
                        await model.saveRetention(HistoryRetention(maximumUnstarredCount: countValue, maximumAgeDays: ageValue))
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction).tint(GoblinBrand.moss)
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
