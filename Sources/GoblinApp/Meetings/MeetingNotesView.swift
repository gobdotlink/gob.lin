import AppKit
import GoblinMeetings
import SwiftUI

/// The notes on a meeting's page, as one document: the summary, action items to tick off, decisions, the template's
/// sections, the marks, and what the person typed in the Sidekick, each item with the moment it came from. Voices
/// without a name are links that open Who's This?. Under them, a byline with the model and template, and the earlier
/// versions. Rewriting happens in the bar under the page (`MeetingAskBar`); while there are no notes, this says what
/// it takes to get them.
struct MeetingNotesSection: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    /// The meeting was processed again after these notes were written.
    let stale: Bool
    /// speakers.json, so a renamed voice reads with its new name.
    let names: [String: String]
    /// typed-notes.md: what the person typed in the Sidekick.
    var typedNotes: String? = nil
    /// Earlier versions, newest first, to go back to.
    var earlier: [MeetingNotesHistory.Version] = []
    /// Shown names that need a name: written as links that ask who they are.
    var unnamed: Set<String> = []
    @ObservedObject var model: MeetingNotesModel
    @ObservedObject var player: MeetingPlayer
    var onName: (String) -> Void = { _ in }
    /// A time in the notes: play from it and show it in the transcript.
    var onMoment: (Double) -> Void = { _ in }
    var onDone: (Int, Bool) -> Void = { _, _ in }
    var onRestore: (String) -> Void = { _ in }
    var onWrite: () -> Void = {}

    private var writing: Bool { model.writing.contains(meeting.id) }

    /// Stale notes keep the names their voices had when written: processing again may have numbered voices anew.
    private var shown: [String: String] { stale ? (notes?.written.names ?? names) : names }
    private var failure: String? { model.failures[meeting.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if writing {
                // The goblin only while there are no notes yet, an empty state; a rewrite is a line.
                MeetingWritingLine(text: writingLine, goblin: notes == nil).padding(.bottom, 14)
            } else if let failure {
                notice {
                    StatusRow(notes == nil ? .problem : .waiting, Text(failure)) {
                        if model.settings != nil, failure != MeetingNotesError.tooShort.localizedDescription {
                            Button("Try Again", action: onWrite)
                        }
                    }
                }
            } else if stale, notes != nil {
                notice {
                    StatusRow(.waiting, Text("The transcript changed after I wrote these notes.")) {
                        Button("Write Again", action: onWrite).disabled(model.settings == nil)
                    }
                }
            }
            if let notes {
                content(notes).opacity(writing ? 0.4 : 1).animation(.easeOut(duration: 0.16), value: writing)
                byline(notes).padding(.top, 22)
            } else if writing {
                MeetingPlaceholderLines()
            } else if failure == nil {
                empty
            }
            if notes == nil, let typed = typedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
                yourNotes(typed).padding(.top, 22)
            }
        }
        // Links are the voices that need a name: moss, like every interactive job.
        .tint(GoblinBrand.mossText)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.voiceScheme, let name = url.host(percentEncoded: false) ?? url.path.removingPercentEncoding else {
                return .systemAction
            }
            onName(name)
            return .handled
        })
        .task { if model.tools.isEmpty { model.refresh() } }
    }

    private var writingLine: String {
        // The run's own settings, which a template or an ask may have set for this meeting only.
        guard let active = model.active[meeting.id] else { return "I'm writing the notes." }
        if let ask = active.ask { return "I'm rewriting the notes: “\(ask)”." }
        return notes == nil ? "I'm writing the notes with \(model.describe(active))."
            : "I'm rewriting the notes with the \(active.template.name) template."
    }

    // MARK: No notes yet

    @ViewBuilder private var empty: some View {
        if meeting.state != .ready {
            placeholder("I'll write the notes once the transcript is done.")
        } else if let settings = model.settings {
            HStack(spacing: 14) {
                PixelSprite(sprite: .look, scale: 1).frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No notes for this one yet.").font(.row.weight(.semibold))
                    Text(model.consented
                         ? "Pick a template below, or tell me what you want, and I'll write them from the transcript."
                         : "I can write notes with \(model.describe(settings)). The transcript goes to \(settings.tool.company).")
                        .font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Write Notes", action: onWrite).prominent()
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
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
                .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: Notes

    private func content(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !notes.summary.isEmpty {
                Text(linked(notes.resolve(notes.summary, names: shown))).font(.transcript).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !notes.actionItems.isEmpty {
                heading("Action items")
                ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { index, item in
                    actionRow(item, index: index, notes: notes)
                }
            }
            if !notes.decisions.isEmpty {
                heading("Decisions")
                ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, decision in
                    let decided = decision.status == .decided
                    line(at: decision.at) {
                        Image(systemName: decided ? "checkmark.circle" : "questionmark.circle")
                            .foregroundStyle(decided ? AnyShapeStyle(GoblinBrand.mossText) : AnyShapeStyle(GoblinBrand.candleText))
                    } text: {
                        let status = Text(decided ? "" : decision.status == .open ? "  Still open" : "  No agreement")
                            .font(.status.weight(.medium)).foregroundStyle(GoblinBrand.candleText)
                        Text("\(Text(linked(notes.resolve(decision.text, names: shown))))\(status)")
                    }
                }
            }
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                Text(notes.resolve(section.heading, names: shown)).font(.cardTitle).padding(.top, 20).padding(.bottom, 4)
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    line(at: item.at) { Text("•").foregroundStyle(.secondary) } text: { Text(linked(notes.resolve(item.text, names: shown))) }
                }
            }
            if !notes.marks.isEmpty {
                heading("Your marks")
                ForEach(Array(notes.marks.enumerated()), id: \.offset) { _, mark in
                    line(at: mark.t) {
                        Image(systemName: "flag.fill").foregroundStyle(GoblinBrand.candle)
                    } text: {
                        let label = mark.label.map { Text($0 + ": ").fontWeight(.semibold) } ?? Text("")
                        Text("\(label)\(Text(linked(notes.resolve(mark.note, names: shown))))")
                    }
                }
            }
            if let typed = typedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
                yourNotes(typed).padding(.top, 20)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        CapsHeader(title).padding(.top, 22).padding(.bottom, 6)
    }

    /// An action item, ticked off right here: the owner in semibold, the task, the due words quieter, then its time.
    private func actionRow(_ item: MeetingNotes.ActionItem, index: Int, notes: MeetingNotes) -> some View {
        let done = item.done == true
        let owner = notes.ownerName(item, names: shown)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { done }, set: { onDone(index, $0) })) {
                let who = owner.map { Text("\(Text(linked($0)).fontWeight(.semibold))  ") } ?? Text("")
                let due = item.due.map { Text("  " + notes.resolve($0, names: shown)).font(.status).foregroundStyle(.secondary) } ?? Text("")
                Text("\(who)\(Text(linked(notes.resolve(item.task, names: shown))))\(due)")
            }
            .toggleStyle(.checkbox).tint(GoblinBrand.moss)
            .font(.transcript)
            .foregroundStyle(done ? .secondary : .primary)
            .strikethrough(done, color: .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(done ? "Done. Untick if it's still to do." : "Tick when it's done.")
            if let at = item.at { timeButton(at) }
        }
        .padding(.vertical, 3)
    }

    /// One item: a glyph, the text, and the moment it came from.
    private func line<Glyph: View, Words: View>(at: Double?, @ViewBuilder glyph: () -> Glyph, @ViewBuilder text: () -> Words) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyph().font(.status.weight(.medium)).frame(width: 16).accessibilityHidden(true)
            text().font(.transcript).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let at { timeButton(at) }
        }
        .padding(.vertical, 3)
    }

    private func timeButton(_ at: Double) -> some View {
        Button { onMoment(at) } label: {
            Text(MeetingTimeline.clock(at)).font(.meta).monospacedDigit().foregroundStyle(GoblinBrand.mossText)
                .padding(.horizontal, 5).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play from here and show it in the transcript")
        .accessibilityLabel("Play from \(MeetingTimeline.clock(at))")
    }

    /// What the person typed during the call, as typed, marked as theirs with a moss edge.
    private func yourNotes(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsHeader("Your notes")
            Text(text).font(.transcript).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(GoblinBrand.moss).frame(width: 2) }
            Text("You typed these in the Sidekick during the call.").font(.meta).foregroundStyle(.secondary).padding(.leading, 12)
        }
    }

    private func byline(_ notes: MeetingNotes) -> some View {
        HStack(spacing: 6) {
            Text(MeetingNotesSection.byline(notes.written, model: model)).font(.meta).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !earlier.isEmpty {
                Menu(earlier.count == 1 ? "1 earlier version" : "\(earlier.count) earlier versions") {
                    ForEach(earlier, id: \.id) { version in
                        Button("Go Back to \(MeetingNotesSection.versionName(version.notes.written))") { onRestore(version.id) }
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.visible).fixedSize()
                .font(.meta).foregroundStyle(GoblinBrand.mossText)
                .disabled(writing)
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Hairline() }
    }

    /// "Written with GPT-6.2-Sol through Codex · Auto template · 21:50", and what was asked when there was an ask.
    static func byline(_ written: MeetingNotes.Provenance, model: MeetingNotesModel) -> String {
        let name = written.model.flatMap { id in model.option(written.tool, id)?.title } ?? written.model
        let by = name.map { "Written with \($0) through \(written.tool.title)" } ?? "Written with \(written.tool.title)"
        var parts = [by, "\(written.template.name) template", written.createdAt.formatted(date: .omitted, time: .shortened)]
        if let ask = written.ask { parts.insert("asked: “\(ask)”", at: 2) }
        return parts.joined(separator: " · ")
    }

    /// An earlier version, as the menu names it: what was asked or the template, and when.
    static func versionName(_ written: MeetingNotes.Provenance) -> String {
        let what = written.ask.map { "“\($0.count > 40 ? String($0.prefix(40)) + "…" : $0)”" } ?? "the \(written.template.name) template"
        return "\(what) · \(written.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static let voiceScheme = "goblin-voice"

    /// The text with each voice that needs a name made a moss link that asks who they are; links carry their own underline.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        // Stale notes keep the numbers voices had then; a link would name whoever has that number now.
        guard !stale else { return result }
        for name in unnamed {
            guard let url = URL(string: "\(Self.voiceScheme)://\(name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name)") else { continue }
            var start = result.startIndex
            while start < result.endIndex, let range = result[start...].range(of: name) {
                result[range].link = url
                start = range.upperBound
            }
        }
        return result
    }

    private func notice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
            .padding(.bottom, 14)
    }
}

/// The goblin writing: look down with the quill, and one line on what it's doing.
struct MeetingWritingLine: View {
    let text: String
    var goblin = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if goblin {
                PixelSprite(sprite: .look, scale: 1)
                    .overlay(alignment: .bottomLeading) { PixelSprite(sprite: .quill, scale: 1).offset(x: -2, y: 3) }
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, goblin ? 6 : 0)
        }
    }
}

/// Where notes will be, while the first ones are written.
struct MeetingPlaceholderLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array([0.92, 0.78, 0.4, 0.85, 0.7, 0.88].enumerated()), id: \.offset) { index, width in
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.08)).frame(width: geometry.size.width * width, height: 10)
                }
                .frame(height: 10)
                .padding(.top, index == 2 ? 12 : 0)
            }
        }
        .opacity(dim ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Writing the notes")
    }
}

// MARK: - The bar under the page

/// Under a meeting's page: the player strip, then the template the notes follow and a field to say what to change.
/// Picking a template rewrites the notes with it; an ask rewrites them with those words on top of the template.
/// Every rewrite can be undone from the page.
struct MeetingAskBar<Strip: View>: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    @ObservedObject var model: MeetingNotesModel
    let strip: Strip
    let onWrite: (_ template: NotesTemplate?, _ ask: String?) -> Void
    let onEditTemplates: () -> Void

    @State private var ask = ""
    @FocusState private var focused: Bool

    static var suggestions: [String] { ["Make it shorter", "Only the action items", "Draft a follow-up email", "More detail on the decisions"] }

    private var writing: Bool { model.writing.contains(meeting.id) }
    private var canWrite: Bool { model.settings != nil && meeting.state == .ready && !writing }
    private var current: NotesTemplate { notes?.written.template ?? model.template }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            strip
            if focused, ask.isEmpty, canWrite {
                HStack(spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    }
                }
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                templateMenu
                field
            }
            if let settings = model.settings, !model.consented, canWrite {
                Text("Writing notes sends the transcript to \(settings.tool.company).").font(.meta).foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.14), value: focused)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    private var templateMenu: some View {
        let custom = model.customTemplates
        let builtIn = model.allTemplates.filter { template in !custom.contains { $0.id == template.id } }
        return Menu {
            Section(notes == nil ? "Write with" : "Rewrite with") {
                ForEach(builtIn) { template in templateButton(template) }
            }
            if !custom.isEmpty {
                Section("Yours") { ForEach(custom) { template in templateButton(template) } }
            }
            Divider()
            Button("Edit Templates…", action: onEditTemplates)
        } label: {
            Label(current.name, systemImage: "doc.text")
        }
        .menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule).fixedSize()
        .disabled(!canWrite)
        .help(notes == nil ? "The template the notes follow" : "Picking a template rewrites the notes with it")
    }

    private func templateButton(_ template: NotesTemplate) -> some View {
        Button { onWrite(template, nil) } label: {
            if template.id == current.id, notes != nil { Label(template.name, systemImage: "checkmark") } else { Text(template.name) }
            if !template.detail.isEmpty { Text(template.detail) }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField(canWrite ? (notes == nil ? "Tell me what you want in the notes…" : "Tell me what to change…")
                      : writing ? "Writing…" : model.settings == nil ? "Choose a notes model in Settings to write notes" : "Notes come once the transcript is done",
                      text: $ask)
                .textFieldStyle(.plain).font(.row)
                .focused($focused)
                .onSubmit { send(ask) }
                .accessibilityLabel(notes == nil ? "What you want in the notes" : "What to change in the notes")
            Button { send(ask) } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(GoblinBrand.moss.opacity(MeetingNotesPrompt.cleanAsk(ask) == nil ? 0.35 : 1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(MeetingNotesPrompt.cleanAsk(ask) == nil || !canWrite)
            .help(notes == nil ? "Write the notes" : "Rewrite the notes")
            .accessibilityLabel(notes == nil ? "Write the notes" : "Rewrite the notes")
        }
        .padding(.leading, 12).padding(.trailing, 4).frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(GoblinBrand.moss) : AnyShapeStyle(.primary.opacity(0.14)), lineWidth: focused ? 1 : 0.5))
        .disabled(!canWrite)
    }

    private func send(_ text: String) {
        guard let clean = MeetingNotesPrompt.cleanAsk(text), canWrite else { return }
        ask = ""
        focused = false
        onWrite(nil, clean)
    }
}

// MARK: - Needs you

/// What on a meeting's page waits for the person: voices with no name yet, then words the notes model thinks are
/// misheard names, each shown in the line it came from with a play button, Keep As Heard and Fix, or all at once with
/// Fix All. A fixed name is offered to the Dictionary. Gone once nothing waits.
struct MeetingNeedsYou: View {
    let meeting: StoredMeeting
    let notes: MeetingNotes?
    let turns: [TranscriptTurn]
    /// Voices that need a name, longest talker first.
    let unnamed: [MeetingLane]
    @ObservedObject var model: MeetingNotesModel
    @ObservedObject var player: MeetingPlayer
    let onWho: () -> Void
    /// Adds spellings to the Dictionary; says what happened.
    var addToDictionary: ([String]) -> String? = { _ in nil }
    let onChanged: () -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var reviewing = false
    /// What Fix All fixed, for its Undo.
    @State private var fixedAll: [String] = []
    @State private var failure: String?
    @State private var settling = FixSettling()
    /// Names just fixed, offered to the Dictionary.
    @State private var offer: [String] = []
    @State private var added: String?

    private var suggested: [MeetingNotes.SpellingFix] {
        guard meeting.state == .ready else { return [] }
        return notes?.fixes.filter { $0.kind == .suggested && !$0.dismissed } ?? []
    }

    var body: some View {
        let words = suggested
        // Put back one by one over the transcript, they're no longer Fix All's to undo.
        let undoable = fixedAll.filter { heard in notes?.fixes.contains { $0.heard == heard && $0.isActive } ?? false }
        let shows = !unnamed.isEmpty || !words.isEmpty || failure != nil || !undoable.isEmpty || !offer.isEmpty || added != nil
        VStack(alignment: .leading, spacing: 8) {
            if !unnamed.isEmpty || !words.isEmpty || failure != nil { card(words) }
            if !undoable.isEmpty {
                MeetingChangeLine(message: undoable.count == 1 ? "Fixed a misheard name." : "Fixed \(undoable.count) misheard names.") {
                    undo(undoable)
                }
            }
            if !offer.isEmpty { dictionaryOffer }
            if let added {
                Label(added, systemImage: "checkmark").font(.status).foregroundStyle(.secondary)
                    .task { try? await Task.sleep(for: .seconds(3)); self.added = nil }
            }
        }
        .padding(.top, shows ? 18 : 0)
        .onChange(of: notes?.fixes ?? []) { _, fixes in settling.settle(fixes) }
        // Notes deleted: what Fix All fixed went with them, and the Undo mustn't come back for notes written later.
        .onChange(of: notes == nil) { _, gone in if gone { fixedAll = [] } }
    }

    private func card(_ words: [MeetingNotes.SpellingFix]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure {
                StatusRow(.problem, Text(failure)) { Button("Dismiss") { self.failure = nil } }
            }
            if let first = unnamed.first {
                row {
                    Text(unnamed.count == 1 ? "I need a name for \(Text(first.name).fontWeight(.semibold)). They talked for \(MeetingTimeline.length(first.talkSeconds))."
                         : "I need names for \(unnamed.count) voices.")
                } actions: {
                    Button("Who's This?", action: onWho).prominent()
                }
            }
            if !unnamed.isEmpty, !words.isEmpty { Hairline() }
            if words.count == 1, let fix = words.first {
                wordRow(fix)
            } else if words.count > 1 {
                row {
                    Text(reviewing ? "\(words.count) words may be misheard names." : summary(words))
                } actions: {
                    HStack(spacing: 8) {
                        if !reviewing, words.contains(where: settling.contains) {
                            ProgressView().controlSize(.small).accessibilityLabel("Fixing names")
                        }
                        Button(reviewing ? "Done" : "Review…") { reviewing.toggle() }
                        Button("Fix All") { fixAll(words) }.prominent().disabled(words.contains(where: settling.contains))
                    }
                }
                if reviewing {
                    ForEach(words, id: \.heard) { fix in wordRow(fix).padding(.leading, 17) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LightState.waiting.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(LightState.waiting.color.opacity(0.4), lineWidth: 0.5))
    }

    /// A line that waits on the person, in ordinary text, with its actions on the right; they go under it when narrow.
    private func row<Words: View, Actions: View>(@ViewBuilder _ words: () -> Words, @ViewBuilder actions: () -> Actions) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                StatusLight(state: .waiting)
                words().font(.status).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                actions().font(.status)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    StatusLight(state: .waiting)
                    words().font(.status).fixedSize(horizontal: false, vertical: true)
                }
                actions().font(.status).padding(.leading, 17)
            }
        }
    }

    /// One word: what was heard and what it may be, then the line it was heard in, to read or play, and the two answers.
    private func wordRow(_ fix: MeetingNotes.SpellingFix) -> some View {
        let context = Self.context(of: fix.heard, in: turns)
        return VStack(alignment: .leading, spacing: 6) {
            row {
                let lines = Text(fix.count > 1 ? "  \(fix.count) lines" : "").font(.meta).foregroundStyle(.secondary)
                Text("“\(fix.heard)” may be a misheard name: \(Text(fix.meant).fontWeight(.semibold)).\(lines)")
            } actions: {
                HStack(spacing: 8) {
                    if settling.contains(fix) { ProgressView().controlSize(.small).accessibilityLabel("Fixing “\(fix.heard)”") }
                    Button("Keep As Heard") { settle([fix]) { try await model.dismissFix(meeting.id, heard: fix.heard) } }
                        .help("Leave “\(fix.heard)” as it is in this meeting")
                    Button("Fix") { fix1(fix) }.prominent()
                }
                .disabled(settling.contains(fix))
            }
            if let context {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { player.play(context.turn.start...context.turn.end, track: context.turn.track) } label: {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(GoblinBrand.moss, in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasAudio)
                    .accessibilityLabel("Play the line with “\(fix.heard)”")
                    Text(context.text).font(.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 17)
            }
        }
    }

    /// The first line `heard` appears in, cut to the words around it, with the heard word in ordinary text and semibold.
    static func context(of heard: String, in turns: [TranscriptTurn]) -> (turn: TranscriptTurn, text: AttributedString)? {
        let regex = MeetingNotesFixer.pattern(for: heard)
        for turn in turns {
            let text = turn.text as NSString
            guard let match = regex.firstMatch(in: turn.text, range: NSRange(location: 0, length: text.length)) else { continue }
            let reach = 60
            let start = max(0, match.range.location - reach), end = min(text.length, NSMaxRange(match.range) + reach)
            var before = text.substring(with: NSRange(location: start, length: match.range.location - start))
            var after = text.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
            // Cut at a word, not mid-word.
            if start > 0, let space = before.firstIndex(of: " ") { before = "…" + before[before.index(after: space)...] }
            if end < text.length, let space = after.lastIndex(of: " ") { after = after[..<space] + "…" }
            var word = AttributedString(text.substring(with: match.range))
            word.foregroundColor = .primary
            word.inlinePresentationIntent = .stronglyEmphasized
            return (turn, AttributedString("“\(turn.speaker): " + before) + word + AttributedString(after + "”"))
        }
        return nil
    }

    /// The Dictionary offer after a name is fixed.
    private var dictionaryOffer: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed").foregroundStyle(GoblinBrand.mossText).accessibilityHidden(true)
            Text("Add \(ListFormatter.localizedString(byJoining: offer)) to the Dictionary, so dictation and later meetings spell \(offer.count == 1 ? "it" : "them") right?")
                .font(.status).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Not Now") { offer = [] }.font(.status)
            Button("Add") {
                added = addToDictionary(offer)
                offer = []
            }
            .font(.status).prominent()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(GoblinBrand.selection, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    /// “Myra Saul” → Mira Sol, “Oak offer” → Okafor and 2 more.
    private func summary(_ words: [MeetingNotes.SpellingFix]) -> String {
        let shown = words.prefix(3).map { "“\($0.heard)” → \($0.meant)" }.joined(separator: ", ")
        let more = words.count > 3 ? " and \(words.count - 3) more" : ""
        return "\(words.count) words may be misheard names: \(shown)\(more)."
    }

    private func fix1(_ fix: MeetingNotes.SpellingFix) {
        settle([fix]) {
            try await model.applyFix(meeting.id, heard: fix.heard)
            offer = [fix.meant]
            let id = meeting.id, store = model
            undoManager?.registerUndo(withTarget: model) { _ in
                Task { @MainActor in try? await store.suggestFixes(id, heard: [fix.heard]); onChanged() }
            }
            undoManager?.setActionName("Fix “\(fix.heard)”")
        }
    }

    private func fixAll(_ words: [MeetingNotes.SpellingFix]) {
        let heard = words.map(\.heard)
        settle(words) {
            try await model.applyFixes(meeting.id, heard: heard)
            fixedAll = heard
            reviewing = false
            offer = words.map(\.meant)
            let id = meeting.id, store = model
            undoManager?.registerUndo(withTarget: model) { _ in
                Task { @MainActor in try? await store.suggestFixes(id, heard: heard); onChanged() }
            }
            undoManager?.setActionName("Fix All")
        }
    }

    private func undo(_ heard: [String]) {
        fixedAll = []
        offer = []
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
