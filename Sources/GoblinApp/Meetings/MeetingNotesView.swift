import AppKit
import GoblinMeetings
import SwiftUI

/// The Notes part of a meeting's page: the summary, decisions, action items, the template's sections and a line per
/// mark, each with the moment it came from; the spelling fixes made to the transcript; and while there are no notes,
/// what it takes to get them.
struct MeetingNotesSection: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    /// The meeting was processed again after these notes were written.
    let stale: Bool
    /// speakers.json, so a renamed voice reads with its new name.
    let names: [String: String]
    @ObservedObject var model: MeetingNotesModel
    @ObservedObject var player: MeetingPlayer
    let onChanged: () -> Void

    @State private var editFailure: String?

    private var writing: Bool { model.writing.contains(meeting.id) }

    /// Stale notes keep the names their voices had when written: processing again may have numbered voices anew.
    private var shown: [String: String] { stale ? (notes?.written.names ?? names) : names }
    private var failure: String? { model.failures[meeting.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CapsHeader("Notes")
                if let notes {
                    Text("· " + byline(notes)).font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if notes != nil, meeting.state == .ready { menu }
            }
            .padding(.leading, 6)
            if let editFailure {
                notice { StatusRow(.problem, Text(editFailure)) { Button("Dismiss") { self.editFailure = nil } } }
            }
            if writing {
                notice { StatusRow(.waiting, Text(writingLine)) { ProgressView().controlSize(.small) } }
            } else if let failure {
                notice {
                    StatusRow(notes == nil ? .problem : .waiting, Text(failure)) {
                        if model.settings != nil, failure != MeetingNotesError.tooShort.localizedDescription {
                            Button("Try Again") { write() }
                        }
                    }
                }
            } else if stale, notes != nil {
                notice {
                    StatusRow(.waiting, Text("The transcript changed after I wrote these notes.")) {
                        Button("Write Again") { write() }.disabled(model.settings == nil)
                    }
                }
            }
            if let notes {
                content(notes)
                fixes(notes)
            } else if !writing, failure == nil {
                empty
            }
        }
        .task { if model.tools.isEmpty { model.refresh() } }
    }

    private var writingLine: String {
        // The run's own model, which "Write Again With" may have set for this meeting only.
        model.active[meeting.id].map { "I'm writing the notes with \(model.describe($0))." } ?? "I'm writing the notes."
    }

    private func byline(_ notes: MeetingNotes) -> String {
        let model = notes.written.model.flatMap { id in self.model.option(notes.written.tool, id)?.title } ?? notes.written.model
        return [model ?? notes.written.tool.title, notes.written.template.name].joined(separator: " · ")
    }

    // MARK: No notes yet

    @ViewBuilder private var empty: some View {
        if meeting.state != .ready {
            placeholder("I'll write the notes once the transcript is done.")
        } else if let settings = model.settings {
            notice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.consented ? "No notes for this one yet."
                         : "I can write notes with \(model.describe(settings)). The transcript goes to \(settings.tool.company).")
                        .font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Write Notes") { write() }.prominent()
                }
            }
        } else if model.scanning || model.tools.isEmpty {
            placeholder("Looking for Codex and Claude Code on this Mac…")
        } else if model.choice == .none {
            placeholder("Notes are off. Choose a notes model in Settings › Meeting Recording to get them.")
        } else if let tool = model.unlistedTool {
            placeholder("\(tool.title) is signed in, but I couldn't get its models. Check Again in Settings › Meeting Recording.")
        } else {
            placeholder("Install Codex or Claude Code and sign in, and I'll write notes here: a summary, decisions and action items.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Label(text, systemImage: "doc.text")
            .font(.status).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous)
                .strokeBorder(.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: Notes

    private func content(_ notes: MeetingNotes) -> some View {
        Plate {
            VStack(alignment: .leading, spacing: 14) {
                if !notes.summary.isEmpty {
                    Text(notes.resolve(notes.summary, names: shown)).font(.row).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !notes.actionItems.isEmpty {
                    block("Action items") {
                        ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { _, item in
                            line(symbol: "circle", at: item.at) {
                                actionText(item, notes: notes)
                            }
                        }
                    }
                }
                if !notes.decisions.isEmpty {
                    block("Decisions") {
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, decision in
                            line(symbol: decision.status == .decided ? "checkmark" : "questionmark", at: decision.at) {
                                Text(notes.resolve(decision.text, names: shown))
                                    + Text(decision.status == .decided ? "" : decision.status == .open ? "  Still open" : "  No agreement")
                                    .font(.meta).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                    block(notes.resolve(section.heading, names: shown)) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            line(symbol: nil, at: item.at) { Text(notes.resolve(item.text, names: shown)) }
                        }
                    }
                }
                if !notes.marks.isEmpty {
                    block("Your marks") {
                        ForEach(Array(notes.marks.enumerated()), id: \.offset) { _, mark in
                            line(symbol: "flag.fill", tint: GoblinBrand.candle, at: mark.t) {
                                (mark.label.map { Text($0 + ": ").fontWeight(.semibold) } ?? Text(""))
                                    + Text(notes.resolve(mark.note, names: shown))
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionText(_ item: MeetingNotes.ActionItem, notes: MeetingNotes) -> Text {
        let owner = notes.ownerName(item, names: shown).map { Text($0 + "  ").fontWeight(.semibold) } ?? Text("")
        let due = item.due.map { Text("  " + notes.resolve($0, names: shown)).font(.meta).foregroundColor(.secondary) } ?? Text("")
        return owner + Text(notes.resolve(item.task, names: shown)) + due
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.row.weight(.semibold))
            content()
        }
    }

    /// One item: a glyph, the text, and the moment it came from, which plays from there.
    private func line<Content: View>(symbol: String?, tint: Color? = nil, at: Double?, @ViewBuilder _ text: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) } else { Text("•") }
            }
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
            .frame(width: 12)
            .accessibilityHidden(true)
            text().font(.row).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let at {
                Button { play(at) } label: {
                    Text(MeetingTimeline.clock(at)).font(.meta).monospacedDigit()
                        .foregroundStyle(player.hasAudio ? AnyShapeStyle(GoblinBrand.mossText) : AnyShapeStyle(.tertiary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!player.hasAudio)
                .accessibilityLabel(player.hasAudio ? "Play from \(MeetingTimeline.clock(at))" : "At \(MeetingTimeline.clock(at))")
            }
        }
        .padding(.vertical, 1)
    }

    private func play(_ at: Double) {
        player.play(max(0, at - 1)...(at + 30))
    }

    // MARK: Fixes

    @ViewBuilder private func fixes(_ notes: MeetingNotes) -> some View {
        let active = notes.fixes.filter(\.isActive)
        let suggested = notes.fixes.filter { $0.kind == .suggested && !$0.dismissed }
        if !active.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam").foregroundStyle(GoblinBrand.mossText).accessibilityHidden(true)
                Text(fixedLine(active)).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu("Undo") {
                    ForEach(active, id: \.heard) { fix in
                        Button("Put Back “\(fix.heard)”") { change { try await model.dismissFix(meeting.id, heard: fix.heard) } }
                    }
                }
                .menuStyle(.button).fixedSize().font(.status)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(GoblinBrand.selection, in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            .padding(.top, 6)
        }
        if !suggested.isEmpty {
            notice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggested.count == 1 ? "One more word may be a misheard name:" : "These may be misheard names too:")
                        .font(.status).foregroundStyle(.secondary)
                    ForEach(suggested, id: \.heard) { fix in
                        HStack(spacing: 8) {
                            Text("“\(fix.heard)” → \(fix.meant)").font(.row)
                            if fix.count > 1 { Text("\(fix.count) lines").font(.meta).foregroundStyle(.secondary) }
                            Spacer(minLength: 8)
                            Button("Not Now") { change { try await model.dismissFix(meeting.id, heard: fix.heard) } }
                            Button("Fix") { change { try await model.applyFix(meeting.id, heard: fix.heard) } }
                        }
                    }
                }
            }
        }
    }

    private func fixedLine(_ fixes: [MeetingNotes.SpellingFix]) -> String {
        let shown = fixes.prefix(3).map { "\($0.heard) → \($0.meant)" }.joined(separator: ", ")
        let more = fixes.count > 3 ? " and \(fixes.count - 3) more" : ""
        return "I fixed \(fixes.count == 1 ? "a misheard name" : "\(fixes.count) misheard names") in the transcript: \(shown)\(more)."
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            // Without a notes model these could only fail; another model below still works.
            Button("Write Again") { write() }.disabled(model.settings == nil)
            Menu("Write Again With") {
                Section("Template") {
                    ForEach(model.allTemplates) { template in
                        Button(template.name) { write(template: template) }.disabled(model.settings == nil)
                    }
                }
                ForEach(NotesTool.allCases) { tool in
                    if let options = model.readyModels[tool] {
                        Section(tool.title) {
                            ForEach(options) { option in
                                Button(option.title) { write(tool: tool, model: option) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Copy Notes") { copy() }
            Button("Delete Notes", role: .destructive) { change { try await model.deleteNotes(meeting.id) } }
        } label: {
            IconButtonLabel(symbol: "ellipsis")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(writing)
        .accessibilityLabel("Notes")
    }

    private func write(template: NotesTemplate? = nil, tool: NotesTool? = nil, model option: NotesModelOption? = nil) {
        var settings = model.settings
        if let tool, let option {
            settings = NotesSettings(tool: tool, model: option.id, effort: option.defaultEffort,
                                     template: settings?.template ?? model.template, style: settings?.style ?? model.style)
        }
        if let template { settings?.template = template }
        model.write(meeting.id, override: settings) { onChanged() }
    }

    private func copy() {
        guard let notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingNotesFile.markdown(notes, title: meeting.title, names: shown), forType: .string)
    }

    private func change(_ edit: @escaping () async throws -> Void) {
        Task {
            do {
                try await edit()
                editFailure = nil
            } catch {
                editFailure = "I couldn't save that change: \(error.localizedDescription)"
            }
            onChanged()
        }
    }

    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GoblinBrand.caseBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .padding(.top, 6)
    }
}
