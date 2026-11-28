import AppKit
import GoblinMeetings
import SwiftUI

/// The transcript beside a meeting's notes, as a script: the time in a gutter, the name in the voice's colour when the
/// speaker changes, then the words. Marks sit between the lines as candle flags. Words I respelled have a dotted
/// underline; a line's context menu corrects a word by hand or puts a respelled one back. Clicking a line plays it,
/// and the line playing takes the moss selection tint. Opened from the toolbar, or at a moment from a time in the
/// notes.
struct MeetingTranscriptPanel: View {
    static let width: CGFloat = 320

    let turns: [TranscriptTurn]
    let marks: [MeetingMark]
    let colors: VoiceColors
    /// Voices the person can name from here: a name that needs one opens Who's This?.
    let unnamed: Set<String>
    /// Shown names that mean this Mac's person.
    let you: Set<String>
    /// Processing is done: no lines means nobody said anything, not that they're still coming.
    var finished = false
    @ObservedObject var player: MeetingPlayer
    /// How many lines and how long the audio is kept.
    let summary: String?
    /// The moment to show: set from a time in the notes, then scrolled to once.
    @Binding var focus: Focus?
    let onName: (String) -> Void
    /// Correct a word everywhere it was heard; true when it was saved.
    let onCorrect: (_ heard: String, _ meant: String, _ addToDictionary: Bool) async -> Bool
    let onPutBack: (TranscriptTurn.Respelling) -> Void
    let onCopy: () async -> String?
    let onClose: () -> Void

    @State private var search = ""
    @State private var correcting: UUID?

    /// A moment to show: a time in the notes, or a clip's own line.
    struct Focus: Equatable {
        var at: Double
        var line: UUID?
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Row: Identifiable {
        case turn(TranscriptTurn, showsName: Bool, showsTime: Bool)
        case mark(MeetingMark, Int)

        var id: String {
            switch self {
            case .turn(let turn, _, _): turn.id.uuidString
            case .mark(let mark, let index): "mark-\(index)-\(mark.t)"
            }
        }
        var start: Double {
            switch self {
            case .turn(let turn, _, _): turn.start
            case .mark(let mark, _): mark.t
            }
        }
    }

    /// Turns with each mark placed before the first turn after it; the name when the speaker changes, the time then
    /// too, or once it has moved a minute.
    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var marks = self.marks.enumerated().map { ($0.element, $0.offset) }[...]
        var rows: [Row] = []
        var previous: String?
        var shownTime = -Double.infinity
        for turn in turns {
            while let next = marks.first, next.0.t <= turn.start {
                if query.isEmpty { rows.append(.mark(next.0, next.1)) }
                marks.removeFirst()
            }
            if !query.isEmpty, !turn.text.localizedCaseInsensitiveContains(query), !turn.speaker.localizedCaseInsensitiveContains(query) { continue }
            let showsName = previous != turn.speaker
            let showsTime = showsName || turn.start - shownTime >= 60
            if showsTime { shownTime = turn.start }
            rows.append(.turn(turn, showsName: showsName, showsTime: showsTime))
            previous = turn.speaker
        }
        if query.isEmpty { rows += marks.map { .mark($0.0, $0.1) } }
        return rows
    }

    var body: some View {
        // Once per redraw: playback redraws the panel, and the rows only change with the lines, marks and search.
        let rows = self.rows
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if turns.isEmpty {
                            Text(finished ? "Nobody said anything I could make out." : "The transcript comes once I've sorted out who said what.")
                                .font(.status).foregroundStyle(.secondary)
                                .padding(12)
                        } else if rows.isEmpty {
                            Text("No lines with “\(search)”.").font(.status).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .turn(let turn, let showsName, let showsTime): line(turn, showsName: showsName, showsTime: showsTime).id(row.id)
                            case .mark(let mark, _): markRow(mark).id(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
                .onChange(of: focus, initial: true) { _, wanted in
                    guard let wanted else { return }
                    focus = nil
                    // The clip's own line, or the line being said at that moment, found in the whole transcript. A
                    // search is cleared only when it hides that line; the scroll waits for the row to be there.
                    guard let turn = wanted.line.flatMap({ id in turns.first { $0.id == id } })
                            ?? turns.last(where: { $0.start <= wanted.at + 0.01 }) ?? turns.first else { return }
                    if !search.isEmpty, !rows.contains(where: { $0.id == turn.id.uuidString }) { search = "" }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(turn.id.uuidString, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: Self.width)
        .background(GoblinBrand.plate)
        .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.1)).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CapsHeader("Transcript")
                if let summary { Text(summary).font(.meta).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if !turns.isEmpty { CopyIconButton(title: "Copy Transcript", text: onCopy) }
                Button(action: onClose) { IconButtonLabel(symbol: "xmark") }
                    .buttonStyle(.plain).help("Hide Transcript").accessibilityLabel("Hide Transcript")
            }
            if !turns.isEmpty { SearchField(prompt: "Find in transcript", text: $search) }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func line(_ turn: TranscriptTurn, showsName: Bool, showsTime: Bool) -> some View {
        let playing = player.playing && player.time >= turn.start - 0.1 && player.time <= turn.end + 0.1
        let unnamedVoice = unnamed.contains(turn.speaker)
        let respelled = turn.respelled ?? []
        return VStack(alignment: .leading, spacing: 2) {
            if showsName {
                Group {
                    if unnamedVoice {
                        Button { onName(turn.speaker) } label: { speakerName(turn.speaker, unnamed: true) }
                            .buttonStyle(.plain)
                            .help("Who's This?")
                            .accessibilityLabel("\(turn.speaker), no name yet. Who's This?")
                    } else {
                        speakerName(turn.speaker, unnamed: false)
                    }
                }
                .padding(.leading, 46)
            }
            // The line itself is a button: a click, Space or VoiceOver plays exactly this line.
            Button { if player.hasAudio { player.play(turn.start...turn.end, track: turn.track) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(showsTime ? MeetingTimeline.clock(turn.start) : "").font(.meta).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 38, alignment: .leading)
                    Text(Self.marked(turn.text, respelled: respelled)).font(.row).lineSpacing(2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(turn.speaker) at \(MeetingTimeline.clock(turn.start)): \(turn.text)")
            .accessibilityHint(player.hasAudio ? "Plays this line" : "")
            .accessibilityAction(named: "Correct Spelling") { correcting = turn.id }
        }
        .padding(.horizontal, 6).padding(.vertical, showsName ? 6 : 3)
        .background(playing ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .help(respelled.isEmpty ? "" : respelled.map { "I respelled “\($0.heard)” as \($0.meant)." }.joined(separator: " "))
        .contextMenu {
            if player.hasAudio { Button("Play From Here") { player.play(turn.start...(turn.start + 3_600), track: turn.track) } }
            if unnamedVoice { Button("Who's This?…") { onName(turn.speaker) } }
            Button("Correct Spelling…") { correcting = turn.id }
            if !respelled.isEmpty {
                Section("Respelled") {
                    ForEach(respelled, id: \.self) { fix in Button("Put Back “\(fix.heard)”") { onPutBack(fix) } }
                }
            }
            Divider()
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(turn.speaker): \(turn.text)", forType: .string)
            }
        }
        .popover(isPresented: Binding(get: { correcting == turn.id }, set: { if !$0 { correcting = nil } }), arrowEdge: .leading) {
            CorrectSpellingView(turn: turn, turns: turns, onCorrect: onCorrect) { correcting = nil }
        }
    }

    private func speakerName(_ name: String, unnamed: Bool) -> some View {
        Text(name).font(.meta.weight(.semibold)).foregroundStyle(you.contains(name) ? GoblinBrand.mossText : colors(name) ?? .secondary)
            .underline(unnamed, pattern: .dash)
    }

    private func markRow(_ mark: MeetingMark) -> some View {
        Button { player.seek(mark.t) } label: {
            HStack(spacing: 8) {
                Text(MeetingTimeline.clock(mark.t)).font(.meta).monospacedDigit().frame(width: 38, alignment: .leading)
                Label(mark.label ?? "Marked", systemImage: "flag.fill").font(.status.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(GoblinBrand.candleText)
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark at \(MeetingTimeline.clock(mark.t)): \(mark.label ?? "no label")")
        .accessibilityHint("Moves the playhead here")
    }

    /// The words, with each respelled one given a dotted underline.
    static func marked(_ text: String, respelled: [TranscriptTurn.Respelling]) -> AttributedString {
        var result = AttributedString(text)
        for fix in respelled {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: fix.meant, options: [.caseInsensitive]) {
                result[range].underlineStyle = Text.LineStyle(pattern: .dot, color: GoblinBrand.mossText)
                searchStart = range.upperBound
            }
        }
        return result
    }
}

/// Fixing a misheard word by hand: what was heard, how it should be spelled, how many lines change, and whether the
/// Dictionary should learn it so dictation and later meetings get it right.
struct CorrectSpellingView: View {
    let turn: TranscriptTurn
    let turns: [TranscriptTurn]
    let onCorrect: (_ heard: String, _ meant: String, _ addToDictionary: Bool) async -> Bool
    let onDone: () -> Void

    @State private var heard = ""
    @State private var meant = ""
    @State private var addToDictionary = true
    @State private var saving = false
    @FocusState private var focused: Field?

    private enum Field { case heard, meant }

    private var cleanHeard: String? { MeetingCorrections.normalized(heard) }
    private var cleanMeant: String? { MeetingCorrections.normalized(meant) }
    private var heardLines: Int {
        guard let cleanHeard else { return 0 }
        let regex = MeetingNotesFixer.pattern(for: cleanHeard)
        return turns.filter { regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }.count
    }

    /// Lines a correction really changes, by the same rules the transcript text is respelled with: a line that
    /// already has the right spelling doesn't count.
    static func changedLines(heard: String, meant: String, in turns: [TranscriptTurn]) -> Int {
        MeetingNotesFixer.changedCount(turns.map(\.text), with: [MeetingNotes.SpellingFix(heard: heard, meant: meant, count: 0, kind: .applied)])
    }
    /// Lines the typed correction changes, counted once per redraw for the line, the button and its title.
    private var lines: Int {
        guard let cleanHeard, let cleanMeant else { return 0 }
        return Self.changedLines(heard: cleanHeard, meant: cleanMeant, in: turns)
    }
    private func canSave(_ lines: Int) -> Bool { cleanHeard != nil && cleanMeant != nil && cleanHeard != cleanMeant && lines > 0 && !saving }

    var body: some View {
        let lines = self.lines
        let heardLines = self.heardLines
        return VStack(alignment: .leading, spacing: 10) {
            Text("Correct Spelling").font(.cardTitle)
            Text("“\(turn.text)”").font(.status).foregroundStyle(.secondary).lineLimit(3)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Heard as").font(.status)
                    TextField("Word or phrase", text: $heard).textFieldStyle(.roundedBorder).focused($focused, equals: .heard)
                        .onSubmit { focused = .meant }
                }
                GridRow {
                    Text("Should be").font(.status)
                    TextField("Right spelling", text: $meant).textFieldStyle(.roundedBorder).focused($focused, equals: .meant)
                        .onSubmit { save(lines) }
                }
            }
            Text(cleanHeard == nil ? "Type the word as it appears in the line."
                 : heardLines == 0 ? "“\(cleanHeard ?? "")” isn't in this meeting's transcript."
                 : cleanMeant == nil ? "Now type how it should be spelled."
                 : lines == 0 ? "Every line already spells it that way."
                 : lines == 1 ? "Changes 1 line." : "Changes \(lines) lines, everywhere it was heard.")
                .font(.meta).foregroundStyle(.secondary)
            Toggle("Add to the Dictionary, so dictation and later meetings spell it right", isOn: $addToDictionary)
                .toggleStyle(.checkbox).tint(GoblinBrand.moss).font(.status)
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(lines > 1 ? "Fix All \(lines)" : "Fix") { save(lines) }.prominent().keyboardShortcut(.defaultAction).disabled(!canSave(lines))
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = .heard }
    }

    private func save(_ lines: Int) {
        guard canSave(lines), let cleanHeard, let cleanMeant else { return }
        saving = true
        Task {
            if await onCorrect(cleanHeard, cleanMeant, addToDictionary) { onDone() }
            saving = false
        }
    }
}
