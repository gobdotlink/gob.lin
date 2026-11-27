import AppKit
import GoblinMeetings
import SwiftUI

/// The whole meeting at a glance: candle flags for marks on top, one lane per voice, a time axis, and the
/// transport. Clicking a stretch plays it; clicking a lane's name names, renames or merges that voice.
struct MeetingTimelineView: View {
    let meeting: StoredMeeting
    let lanes: [MeetingLane]
    let marks: [MeetingMark]
    let colors: VoiceColors
    @ObservedObject var player: MeetingPlayer
    let audioDeleted: Bool
    let onName: (MeetingLane) -> Void
    let onRename: (MeetingLane) -> Void
    let onMerge: (MeetingLane, MeetingLane) -> Void

    static let nameWidth: CGFloat = 124
    static let metaWidth: CGFloat = 48

    private var duration: Double {
        max(meeting.duration, lanes.flatMap(\.stretches).map(\.end).max() ?? 0, marks.map(\.t).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !marks.isEmpty { marksRow }
            VStack(spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    if index > 0 { Hairline() }
                    laneRow(lane)
                }
            }
            axis.padding(.top, 4)
            transport.padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.035), radius: 1, y: 1)
    }

    /// A row with the name column, a track the width of the meeting, and the right-hand meta column.
    private func row<Name: View, Track: View, Meta: View>(height: CGFloat, @ViewBuilder name: () -> Name,
                                                          @ViewBuilder track: @escaping (CGFloat) -> Track,
                                                          @ViewBuilder meta: () -> Meta) -> some View {
        // Clear fills keep both side columns their width even when a row leaves them empty.
        HStack(spacing: 0) {
            ZStack(alignment: .leading) { Color.clear; name() }.frame(width: Self.nameWidth)
            GeometryReader { geometry in track(geometry.size.width) }
            ZStack(alignment: .trailing) { Color.clear; meta() }.frame(width: Self.metaWidth)
        }
        .frame(height: height)
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat { CGFloat(seconds / duration) * width }

    private var marksRow: some View {
        row(height: 22) {
            CapsHeader("Marks")
        } track: { width in
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Button { player.seek(mark.t) } label: {
                        Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(GoblinBrand.candle)
                            .frame(width: 16, height: 18, alignment: .bottomLeading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(MeetingTimeline.clock(mark.t)) · \(mark.label ?? "No label yet")")
                    .accessibilityLabel("Mark at \(MeetingTimeline.clock(mark.t)): \(mark.label ?? "no label")")
                    .offset(x: x(mark.t, width) - 2)
                }
            }
            .frame(width: width, height: 22, alignment: .bottomLeading)
        } meta: { EmptyView() }
    }

    private func laneRow(_ lane: MeetingLane) -> some View {
        row(height: 32) {
            laneName(lane).padding(.trailing, 8)
        } track: { width in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.06)).frame(height: 18)
                ForEach(lane.stretches) { stretch in
                    let range = stretch.start...max(stretch.start, stretch.end)
                    let on = player.playingRange == range
                    Button { player.play(range, track: stretch.track) } label: {
                        RoundedRectangle(cornerRadius: Radius.tiny, style: .continuous)
                            .fill(fill(lane, on: on))
                            .frame(width: max(2, x(stretch.end - stretch.start, width)), height: 14)
                            .contentShape(Rectangle().inset(by: -3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasAudio)
                    .help("\(lane.name) · \(MeetingTimeline.clock(stretch.start))–\(MeetingTimeline.clock(stretch.end))")
                    .accessibilityLabel("\(lane.name), \(MeetingTimeline.clock(stretch.start)) to \(MeetingTimeline.clock(stretch.end))")
                    .offset(x: x(stretch.start, width))
                }
                if player.playing || player.time > 0 {
                    Rectangle().fill(GoblinBrand.mossText).frame(width: 1.5, height: 32).offset(x: x(player.time, width))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: width, height: 32, alignment: .leading)
        } meta: {
            Text(MeetingTimeline.length(lane.talkSeconds)).font(.meta).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.name), talked \(MeetingTimeline.length(lane.talkSeconds))")
    }

    private func fill(_ lane: MeetingLane, on: Bool) -> AnyShapeStyle {
        if lane.needsName { return AnyShapeStyle(LightState.waiting.color.opacity(on ? 1 : 0.55)) }
        return AnyShapeStyle((colors(lane.name) ?? GoblinBrand.moss).opacity(on ? 1 : 0.62))
    }

    @ViewBuilder private func laneName(_ lane: MeetingLane) -> some View {
        if lane.needsName {
            Button { onName(lane) } label: {
                HStack(spacing: 6) {
                    StatusLight(state: .waiting)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lane.name).font(.status.weight(.medium)).lineLimit(1)
                        Text("Who's this?").font(.meta).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(lane.name). Who's this?")
        } else {
            Menu {
                Button("Rename…") { onRename(lane) }
                let others = lanes.filter { $0.id != lane.id }
                if !others.isEmpty {
                    Section("Merge Into") { ForEach(others) { other in Button(other.name) { onMerge(lane, other) } } }
                }
                Divider()
                Button("Play Their First Stretch") {
                    if let first = lane.stretches.first { player.play(first.start...first.end, track: first.track) }
                }
                .disabled(!player.hasAudio)
            } label: {
                HStack(spacing: 4) {
                    Text(lane.name).font(.status.weight(.medium)).foregroundStyle(colors(lane.name) ?? .primary)
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Options for \(lane.name)")
        }
    }

    private static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static func axisLabelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: axisFont]).width)
    }

    private var axis: some View {
        let zeroWidth = Self.axisLabelWidth(MeetingTimeline.clock(0))
        let maxWidth = Self.axisLabelWidth(MeetingTimeline.clock(duration))
        let spacing = max(maxWidth, zeroWidth + 12) + 16
        return row(height: 14) { EmptyView() } track: { width in
            let ticks = width > 0
                ? MeetingTimeline.ticks(duration: duration, width: Double(width), minimumSpacing: Double(spacing))
                : []
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { tick in
                    Text(MeetingTimeline.clock(tick)).font(.meta).foregroundStyle(.tertiary).monospacedDigit()
                        .fixedSize()
                        .offset(x: tick == 0 ? 0 : x(tick, width) - 12)
                }
            }
            .frame(width: width, alignment: .topLeading)
        } meta: { EmptyView() }
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            if audioDeleted || !player.hasAudio {
                Image(systemName: "speaker.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(audioDeleted ? "Audio deleted. The transcript, names and marks stay." : "No audio for this meeting.")
            } else {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.meta.weight(.bold)).foregroundStyle(.white)
                        .offset(x: player.playing ? 0 : 1)
                        .frame(width: 26, height: 26).background(GoblinBrand.moss, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing ? "Pause" : "Play from \(MeetingTimeline.clock(player.time))")
                Text("\(MeetingTimeline.clock(player.time)) / \(MeetingTimeline.clock(duration))").monospacedDigit()
                if let range = player.playingRange, let lane = lanes.first(where: { $0.stretches.contains { $0.start == range.lowerBound } }) {
                    Text("**\(lane.name)** · \(MeetingTimeline.clock(range.lowerBound))–\(MeetingTimeline.clock(range.upperBound))")
                        .monospacedDigit().lineLimit(1)
                } else if !lanes.isEmpty {
                    Text("Click a stretch to play it").lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.status).foregroundStyle(.secondary)
        .padding(.top, 10)
        .overlay(alignment: .top) { Hairline() }
    }
}
