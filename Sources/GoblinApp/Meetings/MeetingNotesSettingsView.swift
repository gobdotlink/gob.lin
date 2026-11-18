import AppKit
import GoblinMeetings
import SwiftUI

/// Settings › Meeting Recording › Notes: which installed tool and model write the notes, how hard it thinks, the
/// template and style, whether notes come after each call, and what's on this Mac.
struct MeetingNotesSettingsSection: View {
    @ObservedObject var model: MeetingNotesModel
    @State private var editingTemplates = false

    var body: some View {
        Section {
            LabeledContent {
                Picker("Notes model", selection: Binding(get: { model.choice }, set: { model.choice = $0 })) {
                    Text("Best Available").tag(MeetingNotesModel.Choice.automatic)
                    ForEach(NotesTool.allCases) { tool in
                        if let options = model.readyModels[tool] {
                            Section(tool.title) {
                                ForEach(options) { option in
                                    Text(option.title).tag(MeetingNotesModel.Choice.model(tool, option.id))
                                }
                            }
                        }
                    }
                    if case .model(let tool, let id) = model.choice, model.option(tool, id) == nil {
                        Text("\(id) (\(tool.title))").tag(model.choice)
                    }
                    Divider()
                    Text("None").tag(MeetingNotesModel.Choice.none)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            } label: {
                Text("Notes model")
                Text(modelLine).rowDetail()
                Text("Notes run through Codex or Claude Code as installed and signed in on this Mac, so they count toward that plan's limits. gob.lin never sees your sign-in. Best Available picks, from what's signed in, the model that kept closest to what was said when tested on real calls: GPT-6.2-Sol through Codex, or Fable through Claude Code.")
            }
            if let settings = model.settings, let modelID = settings.model, let option = model.option(settings.tool, modelID), !option.efforts.isEmpty {
                LabeledContent {
                    Picker("Thinking", selection: Binding(get: { model.effort }, set: { model.effort = $0 })) {
                        Text("Default").tag(String?.none)
                        Divider()
                        ForEach(option.efforts, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                } label: {
                    Text("Thinking")
                    Text("Now \((settings.effort ?? option.defaultEffort ?? "the model's default").capitalized). Higher takes longer and uses more of your plan.").rowDetail()
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("Template", selection: Binding(get: { model.template.id }, set: { id in
                        if let template = model.allTemplates.first(where: { $0.id == id }) { model.template = template }
                    })) {
                        ForEach(NotesTemplate.builtIns) { Text($0.name).tag($0.id) }
                        if !model.customTemplates.isEmpty {
                            Divider()
                            ForEach(model.customTemplates) { Text($0.name).tag($0.id) }
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    Button("Edit…") { editingTemplates = true }
                }
            } label: {
                Text("Template")
                Text(model.template.detail.isEmpty ? "Your own template." : model.template.detail).rowDetail()
                Text("Every template gets a summary, decisions, action items and a line for each mark. The template decides the rest. Write your own with Edit….")
            }
            LabeledContent {
                Picker("Style", selection: Binding(get: { model.style }, set: { model.style = $0 })) {
                    ForEach(NotesStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(GoblinBrand.moss)
            } label: {
                Text("Style")
            }
            Toggle(isOn: Binding(get: { model.afterEachCall }, set: { model.afterEachCall = $0 })) {
                Text("Write notes after each call")
                Text("Starts once the transcript is ready. Otherwise, Write Notes on a meeting.").rowDetail()
            }
            .disabled(model.choice == .none)
            statusRow
        } header: { CapsHeader("Notes") }
        .task { model.refresh() }
        // Back from Terminal after `codex login` or `claude auth login`: look again, so the tool shows up signed in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .sheet(isPresented: $editingTemplates) { NotesTemplatesSheet(model: model) { editingTemplates = false } }
    }

    /// What leaves the Mac, in one line.
    private var modelLine: String {
        if model.choice == .none { return "Off. Transcripts stay on this Mac." }
        guard let settings = model.settings else {
            if model.scanning { return "Looking for Codex and Claude Code…" }
            if let tool = model.unlistedTool { return "\(tool.title) is signed in, but I couldn't get its models. Check Again below." }
            return "Needs Codex or Claude Code, installed and signed in."
        }
        let prefix = model.choice == .automatic ? "\(model.describe(settings)). " : ""
        return prefix + "Transcripts go to \(settings.tool.company)."
    }

    @ViewBuilder private var statusRow: some View {
        let states = NotesTool.allCases.map { ($0, model.tools[$0] ?? .unknown) }
        if model.scanning && model.tools.isEmpty {
            StatusRow(.off, Text("Looking for Codex and Claude Code on this Mac…"))
        } else if let (tool, state) = states.first(where: { if case .signedOut = $0.1 { true } else { false } }), let install = state.install {
            StatusRow(.waiting, Text("\(found(states)). \(tool.title) \(install.version ?? "") needs you to sign in: `\(tool.loginCommand)` in Terminal.")) {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.loginCommand, forType: .string)
                }
            }
        } else if states.contains(where: { if case .ready = $0.1 { true } else { false } }) {
            StatusRow(.ready, Text(found(states) + ".")) { Button("Check Again") { model.refresh() }.disabled(model.scanning) }
        } else {
            StatusRow(.off, Text("I can't find Codex or Claude Code on this Mac. Install one and sign in, then check again.")) {
                Button("Check Again") { model.refresh() }.disabled(model.scanning)
            }
        }
    }

    /// "Codex 0.169.0 is signed in with ChatGPT, and Claude Code 2.1.323 with your Claude plan".
    private func found(_ states: [(NotesTool, MeetingNotesModel.ToolState)]) -> String {
        let ready = states.compactMap { tool, state -> String? in
            guard case .ready(let install) = state else { return nil }
            return [tool.title, install.version].compactMap { $0 }.joined(separator: " ") + (install.signIn.map { " with \($0)" } ?? "")
        }
        switch ready.count {
        case 0: return "Found nothing signed in"
        case 1: return "Signed in: " + ready[0]
        default: return "Signed in: " + ready.joined(separator: " and ")
        }
    }
}

/// The person's own templates: a name, one line on what it's for, and the instructions. A built-in can be copied to
/// start from.
struct NotesTemplatesSheet: View {
    @ObservedObject var model: MeetingNotesModel
    let onDone: () -> Void
    @State private var selectedID: String?
    @State private var draft = NotesTemplate(name: "", instructions: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes Templates").font(.cardTitle)
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 190)
                editor
            }
            HStack {
                Menu("New From") {
                    Button("Blank") { create(from: nil) }
                    Divider()
                    ForEach(NotesTemplate.builtIns) { template in Button(template.name) { create(from: template) } }
                }
                .fixedSize()
                Spacer()
                Button("Done") { saveDraft(); onDone() }.keyboardShortcut(.defaultAction).prominent().closingActions()
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
        // Esc closes the sheet without Done; edits are kept either way.
        .onDisappear { saveDraft() }
        .onAppear { if let first = model.customTemplates.first { select(first) } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            CapsHeader("Yours").padding(.leading, 6).padding(.bottom, 4)
            if model.customTemplates.isEmpty {
                Text("None yet. Start one from New From.").font(.status).foregroundStyle(.secondary).padding(.leading, 6)
            }
            ForEach(model.customTemplates) { template in
                Button {
                    guard template.id != selectedID else { return }
                    saveDraft()
                    // The saved copy: the row's own may be older than the draft just saved.
                    select(model.customTemplates.first { $0.id == template.id } ?? template)
                } label: {
                    Text(template.name.isEmpty ? "Untitled" : template.name).font(.row).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedID == template.id ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder private var editor: some View {
        if selectedID != nil {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                TextField("What it's for", text: $draft.detail).textFieldStyle(.roundedBorder)
                Text("Instructions: the sections you want and what goes in each.").font(.status).foregroundStyle(.secondary)
                TextEditor(text: $draft.instructions)
                    .font(.row).scrollContentBackground(.hidden).padding(6)
                    .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                Text("I always add a summary, decisions, action items, a line per mark and a title, and I never make things up, whatever the instructions say.")
                    .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Delete Template", role: .destructive) {
                        if let template = model.customTemplates.first(where: { $0.id == selectedID }) { model.deleteTemplate(template) }
                        selectedID = nil
                        if let first = model.customTemplates.first { select(first) }
                    }
                }
            }
        } else {
            Text("Pick a template, or start one from New From.").font(.status).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ template: NotesTemplate) {
        selectedID = template.id
        draft = template
    }

    private func create(from template: NotesTemplate?) {
        saveDraft()
        let new = NotesTemplate(name: template.map { "My \($0.name)" } ?? "New template", detail: template?.detail ?? "",
                                instructions: template?.instructions ?? "Sections: …")
        model.saveTemplate(new)
        select(new)
    }

    private func saveDraft() {
        guard selectedID != nil, model.customTemplates.contains(where: { $0.id == draft.id }) else { return }
        model.saveTemplate(draft)
    }
}
