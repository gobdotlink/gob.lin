import AppKit
import GoblinMeetings
import SwiftUI

/// The Notes tab of a meeting's page: the summary, decisions, action items, the template's sections and a line per
/// mark, each with the moment it came from; and while there are no notes, what it takes to get them. Misheard names
/// are asked about in `MeetingNeedsYou`, and the ones fixed are listed over the transcript (`MeetingFixedNamesLine`).
struct MeetingNotesSection: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    /// The meeting was processed again after these notes were written.
    let stale: Bool
    /// speakers.json, so a renamed voice reads with its new name.
    let names: [String: String]
    /// typed-notes.md, for Copy Notes.
    var typedNotes: String? = nil
    @ObservedObject var model: MeetingNotesModel
    @ObservedObject var player: MeetingPlayer
    /// The page's Notes / Transcript switch, which takes the place of the Notes label.
    var tabs: AnyView? = nil
    let onChanged: () -> Void

    @State private var editFailure: String?

    private var writing: Bool { model.writing.contains(meeting.id) }

    /// Stale notes keep the names their voices had when written: processing again may have numbered voices anew.
    private var shown: [String: String] { stale ? (notes?.written.names ?? names) : names }
    private var failure: String? { model.failures[meeting.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let tabs {
                    tabs
                    Spacer(minLength: 8)
                    if let notes { Text(byline(notes)).font(.meta).foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    CapsHeader("Notes")
                    if let notes { Text("· " + byline(notes)).font(.meta).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 8)
                }
                // What was typed has its own tab and copy button, so this copies the written notes alone.
                if let notes {
                    CopyIconButton(title: "Copy Notes") { MeetingNotesFile.markdown(notes, title: meeting.title, names: shown) }
                }
                if notes != nil, meeting.state == .ready { menu }
            }
            .padding(.leading, tabs == nil ? 6 : 0)
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
        NSPasteboard.general.setString(MeetingNotesFile.markdown(notes, title: meeting.title, names: shown, typedNotes: typedNotes), forType: .string)
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

// MARK: Misheard names

/// What on a meeting's page waits for the person: voices with no name yet, and words the notes model thinks are
/// misheard names, each with Fix or Not Now, or all at once with Fix All. Gone once nothing waits; after Fix All a
/// moss line says so, with Undo.
struct MeetingNeedsYou: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    /// Voices that need a name, in the order the page lists them.
    let unnamed: [MeetingLane]
    @ObservedObject var model: MeetingNotesModel
    let onWho: (MeetingLane) -> Void
    let onChanged: () -> Void

    @State private var reviewing = false
    /// What Fix All fixed, for its Undo.
    @State private var fixedAll: [String] = []
    @State private var failure: String?
    @State private var settling = FixSettling()

    private var suggested: [MeetingNotes.SpellingFix] {
        guard meeting.state == .ready else { return [] }
        return notes?.fixes.filter { $0.kind == .suggested && !$0.dismissed } ?? []
    }

    var body: some View {
        let words = suggested
        // Put back one by one over the transcript, they're no longer Fix All's to undo.
        let undoable = fixedAll.filter { heard in notes?.fixes.contains { $0.heard == heard && $0.isActive } ?? false }
        VStack(alignment: .leading, spacing: 0) {
            if !unnamed.isEmpty || !words.isEmpty || failure != nil {
                card(words).padding(.top, 12)
            }
            if !undoable.isEmpty {
                MeetingChangeLine(message: undoable.count == 1 ? "Fixed a misheard name." : "Fixed \(undoable.count) misheard names.") {
                    undo(undoable)
                }
                .padding(.top, 12)
            }
        }
        .onChange(of: notes?.fixes ?? []) { _, fixes in settling.settle(fixes) }
        // Notes deleted: what Fix All fixed went with them, and the Undo mustn't come back for notes written later.
        .onChange(of: notes == nil) { _, gone in if gone { fixedAll = [] } }
    }

    private func card(_ words: [MeetingNotes.SpellingFix]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsHeader("Needs you")
            if let failure {
                StatusRow(.problem, Text(failure)) { Button("Dismiss") { self.failure = nil } }
            }
            if let first = unnamed.first {
                StatusRow(.waiting, Text(unnamed.count == 1 ? "I need a name for \(first.name)." : "I need names for \(unnamed.count) voices.")) {
                    Button("Who's This?") { onWho(first) }.prominent()
                }
            }
            if !unnamed.isEmpty, !words.isEmpty { Hairline().padding(.vertical, 2) }
            if words.count == 1, let fix = words.first {
                StatusRow(.waiting, Text("“\(fix.heard)” may be a misheard name: \(fix.meant).")) {
                    HStack(spacing: 8) {
                        if settling.contains(fix) { ProgressView().controlSize(.small).accessibilityLabel("Fixing “\(fix.heard)”") }
                        Button("Not Now") { settle([fix]) { try await model.dismissFix(meeting.id, heard: fix.heard) } }
                        Button("Fix") { settle([fix]) { try await model.applyFix(meeting.id, heard: fix.heard) } }.prominent()
                    }
                    .disabled(settling.contains(fix))
                }
            } else if words.count > 1 {
                StatusRow(.waiting, Text(reviewing ? "\(words.count) words may be misheard names." : summary(words))) {
                    HStack(spacing: 8) {
                        if !reviewing, words.contains(where: settling.contains) {
                            ProgressView().controlSize(.small).accessibilityLabel("Fixing names")
                        }
                        Button(reviewing ? "Done" : "Review…") { reviewing.toggle() }
                        Button("Fix All") { fixAll(words) }.prominent()
                            .disabled(words.contains(where: settling.contains))
                    }
                }
                if reviewing {
                    ForEach(words, id: \.heard) { fix in
                        HStack(spacing: 8) {
                            Text("“\(fix.heard)” → \(fix.meant)").font(.row)
                            Text(fix.count == 1 ? "1 line" : "\(fix.count) lines").font(.meta).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if settling.contains(fix) { ProgressView().controlSize(.small).accessibilityLabel("Fixing “\(fix.heard)”") }
                            Button("Not Now") { settle([fix]) { try await model.dismissFix(meeting.id, heard: fix.heard) } }
                            Button("Fix") { settle([fix]) { try await model.applyFix(meeting.id, heard: fix.heard) } }
                        }
                        .font(.status)
                        .disabled(settling.contains(fix))
                        .padding(.leading, 17)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(LightState.waiting.color.opacity(0.45), lineWidth: 0.5))
    }

    /// “Myra Saul” → Mira Sol, “Oak offer” → Okafor and 2 more.
    private func summary(_ words: [MeetingNotes.SpellingFix]) -> String {
        let shown = words.prefix(3).map { "“\($0.heard)” → \($0.meant)" }.joined(separator: ", ")
        let more = words.count > 3 ? " and \(words.count - 3) more" : ""
        return "\(words.count) words may be misheard names: \(shown)\(more)."
    }

    private func fixAll(_ words: [MeetingNotes.SpellingFix]) {
        let heard = words.map(\.heard)
        settle(words) {
            try await model.applyFixes(meeting.id, heard: heard)
            fixedAll = heard
            reviewing = false
        }
    }

    private func undo(_ heard: [String]) {
        fixedAll = []
        Task {
            do { try await model.suggestFixes(meeting.id, heard: heard) } catch {
                failure = "I couldn't put those words back: \(error.localizedDescription)"
            }
            onChanged()
        }
    }

    private func settle(_ fixes: [MeetingNotes.SpellingFix], _ edit: @escaping () async throws -> Void) {
        guard settling.begin(fixes) else { return }
        Task {
            do {
                try await edit()
                failure = nil
            } catch {
                settling.cancel(fixes)
                failure = "I couldn't save that change: \(error.localizedDescription)"
            }
            onChanged()
        }
    }
}

/// Over the transcript: the misheard names fixed in it, with an Undo menu that puts each word back.
struct MeetingFixedNamesLine: View {
    let meetingID: String
    let notes: MeetingNotes
    @ObservedObject var model: MeetingNotesModel
    let onChanged: () -> Void

    @State private var settling = FixSettling()
    @State private var failure: String?

    var body: some View {
        let active = notes.fixes.filter(\.isActive)
        VStack(alignment: .leading, spacing: 6) {
            if let failure {
                StatusRow(.problem, Text(failure)) { Button("Dismiss") { self.failure = nil } }
                    .padding(.horizontal, 12)
            }
            if !active.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "character.cursor.ibeam").foregroundStyle(GoblinBrand.mossText).accessibilityHidden(true)
                    Text(Self.line(active)).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if active.contains(where: settling.contains) {
                        ProgressView().controlSize(.small).accessibilityLabel("Putting words back")
                    }
                    Menu("Undo") {
                        ForEach(active, id: \.heard) { fix in
                            Button("Put Back “\(fix.heard)”") { putBack(fix) }.disabled(settling.contains(fix))
                        }
                    }
                    .menuStyle(.button).fixedSize().font(.status)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(GoblinBrand.selection, in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            }
        }
        .onChange(of: notes.fixes) { _, fixes in settling.settle(fixes) }
    }

    private func putBack(_ fix: MeetingNotes.SpellingFix) {
        guard settling.begin([fix]) else { return }
        Task {
            do {
                try await model.dismissFix(meetingID, heard: fix.heard)
                failure = nil
            } catch {
                settling.cancel([fix])
                failure = "I couldn't save that change: \(error.localizedDescription)"
            }
            onChanged()
        }
    }

    static func line(_ fixes: [MeetingNotes.SpellingFix]) -> String {
        let shown = fixes.prefix(3).map { "\($0.heard) → \($0.meant)" }.joined(separator: ", ")
        let more = fixes.count > 3 ? " and \(fixes.count - 3) more" : ""
        return "I fixed \(fixes.count == 1 ? "a misheard name" : "\(fixes.count) misheard names") in the transcript: \(shown)\(more)."
    }
}

/// Fixes being applied, turned down or put back, by what was heard, as they were when clicked. Each stays until the
/// reloaded notes show it changed, since respelling the transcript can take several seconds, and can't be clicked
/// again meanwhile.
struct FixSettling {
    private var clicked: [String: MeetingNotes.SpellingFix] = [:]

    func contains(_ fix: MeetingNotes.SpellingFix) -> Bool { clicked[fix.heard] != nil }

    /// False when any of them is already on its way.
    mutating func begin(_ fixes: [MeetingNotes.SpellingFix]) -> Bool {
        guard !fixes.contains(where: contains) else { return false }
        for fix in fixes { clicked[fix.heard] = fix }
        return true
    }

    mutating func cancel(_ fixes: [MeetingNotes.SpellingFix]) {
        for fix in fixes { clicked[fix.heard] = nil }
    }

    /// Drops each fix the reloaded notes show changed.
    mutating func settle(_ fixes: [MeetingNotes.SpellingFix]) {
        clicked = clicked.filter { heard, was in fixes.contains { $0.heard == heard && $0 == was } }
    }
}
