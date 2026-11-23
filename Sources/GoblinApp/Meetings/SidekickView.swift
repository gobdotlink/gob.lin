import GoblinMeetings
import SwiftUI

/// The Sidekick's window, in the overlay's dark glass: the goblin at 64 pt, who's talking, marks, the mute state and
/// Stop. Expanded, your notes take a column on the left and all of that sits in a 340 pt column on the right.
struct SidekickView: View {
    /// The traffic lights' strip: the window's own buttons share it.
    static let titlebarHeight: CGFloat = 32
    static let columnWidth: CGFloat = 340
    /// Narrower than this mid-animation, the notes wait for the room.
    private static let notesMinimumWidth: CGFloat = 560

    @ObservedObject var meetings: MeetingsController
    @ObservedObject var model: SidekickModel

    var body: some View {
        GeometryReader { proxy in
            if let recording = meetings.recording {
                let notes = model.expanded && proxy.size.width >= Self.notesMinimumWidth
                VStack(spacing: 0) {
                    titleRow
                    HStack(spacing: 0) {
                        if notes {
                            SidekickNotes(notes: meetings.typedNotes, save: meetings.setTypedNotes)
                            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5)
                        }
                        column(recording).frame(width: notes ? Self.columnWidth : proxy.size.width)
                    }
                }
            }
        }
        .background { SidekickWindowGlass() }
        .ignoresSafeArea()
        // Drags from anywhere that isn't a control or a text field, captions and title strip included, even on the
        // click that would otherwise only bring the window forward. Buttons, the scroller and the editors win.
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .foregroundStyle(.white.opacity(0.94))
        .environment(\.colorScheme, .dark)
    }

    /// Beside the traffic lights: Notes, Keep on Top and ⋯.
    private var titleRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button { model.setExpanded(!model.expanded) } label: { Image(systemName: "note.text").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(OverlayIconButtonStyle())
                .accessibilityLabel(model.expanded ? "Hide Notes" : "Show Notes").help(model.expanded ? "Hide Notes" : "Show Notes")
            Button { model.setKeepOnTop(!model.keepOnTop) } label: {
                Image(systemName: model.keepOnTop ? "pin.fill" : "pin").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(OverlayIconButtonStyle())
            .accessibilityLabel("Keep on Top").accessibilityValue(model.keepOnTop ? "On" : "Off")
            .help(model.keepOnTop ? "Kept on top of other windows" : "Keep on Top")
            Button { model.showMenu(nil) } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(OverlayIconButtonStyle()).accessibilityLabel("More")
        }
        .padding(.trailing, 10)
        .frame(height: Self.titlebarHeight)
    }

    private func column(_ recording: MeetingsController.Recording) -> some View {
        VStack(spacing: 0) {
            header(recording)
            levels(recording).padding(.horizontal, 14).padding(.bottom, 10)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            SidekickCaptions(lines: recording.lines, marks: recording.marks, inPerson: recording.inPerson, namesLive: recording.namesLive,
                             voiceOrder: recording.voiceOrder,
                             consent: model.showsConsent, flash: model.flash, model: model, meetings: meetings)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            footer(recording)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("gob.lin Sidekick")
    }

    private func header(_ recording: MeetingsController.Recording) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SidekickGoblin(markedAt: meetings.markedAt, dozing: meetings.quietQuestion != nil, looksLeft: model.onRight)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    RecordingReel()
                    Text("Recording").fontWeight(.semibold).foregroundStyle(.white.opacity(0.62))
                    Elapsed(start: recording.startedAt).foregroundStyle(.white.opacity(0.55))
                }
                .font(.status)
                Text(recording.inPerson ? "In person · \(recording.title)" : "\(recording.app) · \(recording.title)")
                    .font(.meta).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
    }

    private func levels(_ recording: MeetingsController.Recording) -> some View {
        HStack(spacing: 16) {
            if recording.inPerson {
                level(model.microphoneLevels, label: recording.dictating ? "Dictating" : "Room", idle: recording.dictating)
            } else {
                level(model.microphoneLevels, label: recording.dictating ? "Dictating" : "You",
                      idle: recording.muted == true || recording.dictating)
                level(model.systemLevels, label: "Them", idle: meetings.systemAudioPermission == .denied)
            }
            Spacer(minLength: 0)
        }
        .font(.meta).foregroundStyle(.white.opacity(0.5))
    }

    private func level(_ levels: [Double], label: String, idle: Bool) -> some View {
        HStack(spacing: 7) {
            Meter(levels: levels, idle: idle || levels.allSatisfy { $0 < 0.02 })
            Text(label)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(label) level")
    }

    @ViewBuilder private func footer(_ recording: MeetingsController.Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(recording)
            HStack(spacing: 8) {
                Button { meetings.mark() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.fill").foregroundStyle(GoblinBrand.candle)
                        Text("Mark This")
                        Text(MeetingMarkHotkey.title).foregroundStyle(.white.opacity(0.55)).fontWeight(.regular)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SidekickButtonStyle())
                .help("Drop a bookmark here. Label it now or later.")
                Button { meetings.stop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                    .buttonStyle(SidekickButtonStyle())
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 12)
    }

    /// One line on what's going into the recording: the problem when there is one, else what's recorded.
    @ViewBuilder private func statusLine(_ recording: MeetingsController.Recording) -> some View {
        if meetings.quietQuestion != nil {
            // Stop is right below; the line only needs the other answer.
            warning(Text("It's been quiet for 10 minutes. Still going?"), symbol: "waveform.slash") {
                Button("Keep Going") { meetings.keepGoing() }.buttonStyle(OverlayPillStyle())
            }
        } else if let remaining = recording.autoStopRemaining() {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = recording.autoStopRemaining() ?? remaining
                    line(left > 0 ? Text("\(recording.app) let go of the mic, so I'll stop in \(Text(MeetingsController.elapsed(left)).monospacedDigit().foregroundStyle(.white)).")
                                  : Text("\(recording.app) let go of the mic. I'll stop once the call goes quiet."), symbol: "info.circle")
                }
                Button("Keep Recording") { meetings.keepRecording() }.buttonStyle(OverlayPillStyle()).padding(.leading, 22)
            }
        } else if !recording.inPerson, meetings.systemAudioPermission == .denied {
            warning(Text("I can hear you but not \(recording.app). System Audio Recording is off."), symbol: "exclamationmark.triangle.fill") {
                Button("Open System Settings") { meetings.openSystemAudioSettings() }.buttonStyle(OverlayPillStyle(prominent: true))
            }
        } else if let lost = MeetingCopy.captureLost(recording) {
            line(Text(lost), symbol: "exclamationmark.triangle.fill", tint: Self.amber)
        } else if recording.dictating {
            line(Text("You're dictating, so I'm leaving that out of the \(recording.inPerson ? "recording" : "meeting")."), symbol: "mic.fill")
        } else if !recording.inPerson, recording.muted == true {
            line(Text("You're muted in \(recording.app), so I'm leaving your mic out."), symbol: "mic.slash.fill", tint: Self.amber)
        } else if let download = meetings.speechModelDownload {
            line(Text(MeetingCopy.speechModelDownload(download) + " Captions start after.").monospacedDigit(), symbol: "arrow.down.circle")
        } else if let captions = recording.captions {
            line(Text(MeetingCopy.captions(captions)), symbol: "captions.bubble")
        } else if recording.inPerson {
            line(Text("Recording the room from your mic."), symbol: "mic.fill")
        } else {
            line(Text("Recording your mic and \(recording.app)'s audio."), symbol: "mic.fill")
        }
    }

    static let amber = Color(red: 1, green: 0.7, blue: 0.25)

    private func line(_ text: Text, symbol: String, tint: Color = .white.opacity(0.55)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            text.foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.status)
    }

    private func warning<Actions: View>(_ text: Text, symbol: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line(text, symbol: symbol, tint: Self.amber)
            HStack(spacing: 6) { actions() }.padding(.leading, 22)
        }
    }
}

// MARK: - Pill

/// Collapsed: a capsule with the time, a level, Mark This and Expand, the goblin beside it on the side nearer the
/// screen's edge, like the overlay's. It drags from anywhere.
struct SidekickPill: View {
    static let width: CGFloat = 196
    static let goblinWidth: CGFloat = 64
    static let spacing: CGFloat = 8
    static let contentSize = CGSize(width: width + spacing + goblinWidth, height: 64)
    /// Room around the content for the glass's shadow.
    static let margin: CGFloat = 24
    static let windowSize = CGSize(width: contentSize.width + 2 * margin, height: contentSize.height + 2 * margin)

    @ObservedObject var meetings: MeetingsController
    @ObservedObject var model: SidekickModel

    var body: some View {
        Group {
            if let recording = meetings.recording { pill(recording) }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .padding(Self.margin)
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ recording: MeetingsController.Recording) -> some View {
        let levels = zip(model.microphoneLevels, model.systemLevels).map { max($0, $1) }
        return HStack(alignment: .bottom, spacing: Self.spacing) {
            if !model.onRight { goblin }
            HStack(spacing: 8) {
                RecordingReel()
                Elapsed(start: recording.startedAt).font(.status.weight(.medium)).foregroundStyle(.white.opacity(0.62))
                Meter(levels: levels, idle: levels.allSatisfy { $0 < 0.02 })
                Spacer(minLength: 0)
                Button { meetings.mark() } label: { Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(GoblinBrand.candle) }
                    .buttonStyle(OverlayIconButtonStyle()).accessibilityLabel("Mark This").help("Mark This (\(MeetingMarkHotkey.title))")
                Button { model.setCollapsed(false) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(OverlayIconButtonStyle()).accessibilityLabel("Open the Sidekick")
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(width: Self.width, height: 40)
            .background { SidekickGlass(shape: Capsule()) }
            .contentShape(Capsule())
            if model.onRight { goblin }
        }
        .foregroundStyle(.white.opacity(0.94))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("gob.lin Sidekick, collapsed")
    }

    private var goblin: some View {
        SidekickGoblin(markedAt: meetings.markedAt, dozing: meetings.quietQuestion != nil, looksLeft: model.onRight)
    }
}

// MARK: - Goblin

/// Looks toward the middle of the screen; writes a mark down with the quill for a moment; dozes through a quiet room.
private struct SidekickGoblin: View {
    let markedAt: Date?
    let dozing: Bool
    let looksLeft: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let marking = markedAt.map { context.date.timeIntervalSince($0) < 1.5 } ?? false
            let sprite: Sprite = marking ? .look : dozing ? .closed : looksLeft ? .eyesW : .eyesE
            PixelSprite(sprite: sprite, scale: 1, mirrored: false)
                .overlay(alignment: .bottomLeading) {
                    if marking { PixelSprite(sprite: .quill, scale: 1).offset(x: -2, y: 3) }
                }
                .transaction { $0.animation = nil }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

// MARK: - Notes

/// Your notes, typed during the call: a plain editor on the glass, folded into the meeting's notes afterwards. It
/// keeps its own draft, so the controller's updates never move the cursor.
private struct SidekickNotes: View {
    let notes: String
    let save: (String) -> Void
    @State private var draft = ""

    private static let font = Font.system(size: 15)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR NOTES").font(.capsLabel).tracking(0.85).foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 5)
            TextEditor(text: $draft)
                .font(Self.font).lineSpacing(4)
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Jot anything down. I'll fold it into the notes after the call.")
                            .font(Self.font).foregroundStyle(.white.opacity(0.32))
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Your notes")
            if !draft.isEmpty {
                Text("I'll fold these into the notes after the call.").font(.status).foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 5)
            }
        }
        .padding(.leading, 15).padding(.trailing, 16).padding(.top, 2).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { draft = notes }
        .onChange(of: draft) { _, now in save(now) }
        // A new recording, or notes set elsewhere; the person's own typing already matches.
        .onChange(of: notes) { _, now in if now != draft { draft = now } }
    }
}

// MARK: - Captions

/// Who said what, newest at the bottom. It follows live until you scroll back, then Back to Live returns.
private struct SidekickCaptions: View {
    let lines: [MeetingLine]
    let marks: [MeetingsController.LiveMark]
    let inPerson: Bool
    let namesLive: Bool
    let voiceOrder: [String]
    let consent: Bool
    let flash: String?
    @ObservedObject var model: SidekickModel
    let meetings: MeetingsController
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var metrics = SidekickScroller.Metrics()
    @State private var scrolling = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One paragraph of captions, headed by the name when the side changes and the time once it's moved a minute.
    private struct Turn {
        let speaker: String
        let start: Double
        let showsName: Bool
        let showsTime: Bool
        var lines: [MeetingLine]
    }

    private enum Item: Identifiable {
        case turn(Turn)
        case mark(MeetingsController.LiveMark)

        var id: String {
            switch self {
            case .turn(let turn): turn.lines[0].id.uuidString
            case .mark(let mark): mark.id.uuidString
            }
        }
    }

    /// On a call, one side's lines flow into one bubble for up to a minute; a mark splits it where it falls. In person
    /// a new bubble starts after a line that ends a sentence, since a pause there is the only live hint that someone
    /// else is talking.
    private var items: [Item] {
        var items: [Item] = []
        var pendingMarks = marks[...]
        var shownTime = -Double.infinity
        for line in lines {
            while let mark = pendingMarks.first, mark.t <= line.start {
                items.append(.mark(mark))
                pendingMarks = pendingMarks.dropFirst()
            }
            let last: Turn? = if case .turn(let turn) = items.last { turn } else { nil }
            if var turn = last, turn.speaker == line.speaker, line.start - turn.start < 60,
               !inPerson || !Self.endsSentence(turn.lines.last?.text ?? "") {
                turn.lines.append(line)
                items[items.count - 1] = .turn(turn)
                continue
            }
            let showsTime = line.start - shownTime >= 60
            if showsTime { shownTime = line.start }
            items.append(.turn(Turn(speaker: line.speaker, start: line.start,
                                    showsName: !line.speaker.isEmpty && last?.speaker != line.speaker,
                                    showsTime: showsTime, lines: [line])))
        }
        items += pendingMarks.map(Item.mark)
        return items
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).last.map { ".?!…".contains($0) } ?? false
    }

    var body: some View {
        // The call's order first, so a voice keeps its colour; the lines after it for a preview, which has no order.
        let colors = VoiceColors(voiceOrder + lines.filter { !$0.placing }.map(\.speaker))
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 11) {
                if consent {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(MeetingsController.consentLine).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.showsConsent = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).accessibilityLabel("Dismiss")
                    }
                    .font(.meta).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                }
                systemLine(inPerson ? "Voices get names after you stop. Live, I just write down what's said."
                                    : namesLive ? "I'm guessing names from voices I know. I'll check them after the call."
                                    : "Names come after the call. Live, I only know you and them.", symbol: "person.2")
                if lines.isEmpty { systemLine("Listening. The first words show up a moment after they're said.", symbol: "ellipsis") }
                ForEach(items) { item in
                    Group {
                        switch item {
                        case .turn(let turn): bubble(turn, colors: colors)
                        case .mark(let mark): SidekickMarkRow(mark: mark, model: model, meetings: meetings)
                        }
                    }
                    .transition(.opacity)
                }
                if let flash { systemLine(flash, symbol: "doc.on.doc").transition(.opacity) }
            }
            // The same gutter on both sides: the scroller floats over the right one instead of taking width.
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
            // New lines fade in. Under Reduce Motion they just appear, so nothing slides as the view follows live.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: lines.count)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Following live, new lines grow the view upward from the bottom; scrolled back, what you're reading stays put.
        .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
        // The system scroller is thick and takes width; SidekickScroller replaces it.
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: SidekickScroller.Metrics.self) { geometry in
            SidekickScroller.Metrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                                     container: geometry.containerSize.height)
        } action: { _, metrics in
            self.metrics = metrics
            if metrics.atBottom != atBottom { atBottom = metrics.atBottom }
        }
        .onScrollPhaseChange { _, phase in scrolling = phase.isScrolling }
        .onChange(of: lines.last?.id) { if atBottom { position.scrollTo(edge: .bottom) } }
        .onChange(of: marks.count) { position.scrollTo(edge: .bottom) }
        .onAppear { if model.previewScrolledBack { position.scrollTo(edge: .top) } }
        .accessibilityLabel("Live captions")
        // Captions scroll under a 14 pt fade at the top; scrolled back, a softer one at the bottom too.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Color.black
                LinearGradient(colors: [.black, atBottom ? .black : .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
            }
        }
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) {
            SidekickScroller(metrics: metrics, active: scrolling || hovering || model.previewScrolledBack) { position.scrollTo(y: $0) }
        }
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button { position.scrollTo(edge: .bottom) } label: {
                    Label("Back to Live", systemImage: "arrow.down").font(.meta.weight(.medium))
                }
                .buttonStyle(OverlayPillStyle())
                // On the panel's own glass, so the captions behind it don't show through the words.
                .background { SidekickGlass(shape: Capsule()) }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        // A fade, so it stays under Reduce Motion: in 160 ms, out 120 ms.
        .animation(.easeOut(duration: atBottom ? 0.12 : 0.16), value: atBottom)
        .frame(maxHeight: .infinity)
    }

    private func bubble(_ turn: Turn, colors: VoiceColors) -> some View {
        let pending = namesLive && turn.lines.contains(where: \.placing)
        let isYou = turn.speaker == "You"
        return TranscriptBubble(text: turn.lines.map(\.text).joined(separator: " "), isYou: isYou,
                                name: turn.showsName && !isYou ? turn.speaker : nil, nameColor: pending ? nil : colors(turn.speaker),
                                time: turn.showsTime ? MeetingsController.elapsed(turn.start) : nil, pending: pending)
            .accessibilityElement(children: .combine)
    }

    private func systemLine(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.meta).foregroundStyle(.white.opacity(0.55))
    }
}

/// A candle-tinted bookmark: its time and label, or "Marked" with Add Label.
private struct SidekickMarkRow: View {
    let mark: MeetingsController.LiveMark
    @ObservedObject var model: SidekickModel
    let meetings: MeetingsController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(GoblinBrand.candle)
            Text(MeetingsController.elapsed(mark.t)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            if model.editingMark == mark.id {
                TextField("Label it now or later", text: $text)
                    .textFieldStyle(.plain).foregroundStyle(.white).focused($focused)
                    .onSubmit { commit(handBack: true) }
                    .onExitCommand { model.endLabel(true) }
                    .onAppear { text = mark.label; DispatchQueue.main.async { focused = true } }
                    // Clicked away, maybe into the notes: the keyboard stays where it went.
                    .onChange(of: focused) { _, now in if !now, model.editingMark == mark.id { commit(handBack: false) } }
                    .onChange(of: text, initial: true) { _, now in model.labelDraft = now }
            } else if mark.label.isEmpty {
                Text("Marked").foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                Button("Add Label") { model.beginLabel(mark.id) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.62))
            } else {
                Text(mark.label).fontWeight(.medium).foregroundStyle(.white).lineLimit(2)
                Spacer(minLength: 4)
                Button { model.beginLabel(mark.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).accessibilityLabel("Edit label")
            }
        }
        .font(.status)
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GoblinBrand.candle.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(GoblinBrand.candle.opacity(0.38), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mark at \(MeetingsController.elapsed(mark.t))")
    }

    private func commit(handBack: Bool) {
        meetings.label(mark.id, text)
        model.endLabel(handBack)
    }
}

// MARK: - Scroller

/// A thin scroller for the dark glass, in place of the system one: it takes no width, shows while the captions
/// scroll or the pointer is over them, then fades. It thickens under the pointer and can be dragged.
private struct SidekickScroller: View {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0

        var overflow: CGFloat { max(0, content - container) }
        /// Within 24 pt of the newest line counts as following live.
        var atBottom: Bool { offset + container >= content - 24 }
    }

    let metrics: Metrics
    let active: Bool
    let scrollTo: (CGFloat) -> Void
    @State private var shown = false
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    /// The thumb runs clear of the 14 pt top fade and the bottom edge, 3 pt in from the panel's side.
    private static let top: CGFloat = 12, bottom: CGFloat = 6, side: CGFloat = 3
    /// The hit strip: with `side` it stays inside the captions' 14 pt gutter.
    private static let strip: CGFloat = 11
    private static let minimumThumb: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let track = max(0, proxy.size.height - Self.top - Self.bottom)
            let thumb = metrics.content > 0 ? min(track, max(Self.minimumThumb, track * metrics.container / metrics.content)) : track
            let travel = max(1, track - thumb)
            // Rubber-banding past either end squeezes nothing; the thumb just stops at the end.
            let progress = metrics.overflow > 0 ? min(1, max(0, metrics.offset / metrics.overflow)) : 0
            let wide = hovering || dragStart != nil
            ZStack(alignment: .topTrailing) {
                Color.clear
                Capsule()
                    .fill(.white.opacity(wide ? 0.5 : 0.3))
                    // 4 pt, 6 pt under the pointer; scaled rather than resized, so only a transform animates.
                    .frame(width: 6, height: thumb)
                    .scaleEffect(x: wide ? 1 : 2.0 / 3, anchor: .trailing)
                    .offset(y: Self.top + travel * progress)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStart ?? metrics.offset
                        dragStart = start
                        scrollTo(min(metrics.overflow, max(0, start + drag.translation.height * metrics.overflow / travel)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(width: Self.strip)
        .padding(.trailing, Self.side)
        .opacity(shown && metrics.overflow > 1 ? 1 : 0)
        .allowsHitTesting(shown && metrics.overflow > 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .task(id: active || dragStart != nil || hovering) {
            if active || dragStart != nil || hovering {
                withAnimation(.easeOut(duration: 0.16)) { shown = true }
            } else {
                // Lingers a moment after scrolling stops, then fades faster than it came.
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                withAnimation(.easeOut(duration: 0.12)) { shown = false }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pieces

/// The window's background: the overlay's blur and 92% bubble. The window draws its own edge, corners and shadow.
private struct SidekickWindowGlass: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay(Rectangle().fill(GoblinBrand.bubble)).ignoresSafeArea()
    }
}

/// The overlay's bubble, for the Sidekick's pill and capsules: blur, 92% bubble, a hairline and a soft shadow.
private struct SidekickGlass<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(GoblinBrand.bubble))
            .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}

/// A neon ring with a dot: this is recording. A shape, so it never reads as a status light.
struct RecordingReel: View {
    var body: some View {
        Circle().strokeBorder(GoblinBrand.neon, lineWidth: 1.5)
            .overlay(Circle().fill(GoblinBrand.neon).frame(width: 3, height: 3))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// Elapsed time since `start`, ticking each second.
struct Elapsed: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(MeetingsController.elapsed(context.date.timeIntervalSince(start))).monospacedDigit()
        }
    }
}

/// A capsule on glass: the Sidekick's two closing buttons.
private struct SidekickButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.status.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.14), in: Capsule())
            .contentShape(Capsule())
    }
}
