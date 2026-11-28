import AppKit
import GoblinMeetings
import SwiftUI

/// The meeting at a glance, in the bar under its page: play, the time, and one thin lane per voice in its colour with
/// the candle flags of the marks and a playhead. Clicking anywhere plays from there; hovering a stretch names it.
/// The voices' names, talk times and menus are the cast line at the top of the page, so the strip carries none.
struct MeetingPlayerStrip: View {
    let duration: Double
    let lanes: [MeetingLane]
    let marks: [MeetingMark]
    let colors: VoiceColors
    @ObservedObject var player: MeetingPlayer
    let audioDeleted: Bool

    private static let laneHeight: CGFloat = 4
    private static let laneGap: CGFloat = 2

    private var length: Double { max(duration, lanes.flatMap(\.stretches).map(\.end).max() ?? 0, marks.map(\.t).max() ?? 0, 1) }
    private var stripHeight: CGFloat {
        max(16, CGFloat(lanes.count) * (Self.laneHeight + Self.laneGap) - Self.laneGap + 8)
    }

    var body: some View {
        HStack(spacing: 10) {
            if audioDeleted || !player.hasAudio {
                Label(audioDeleted ? "Audio deleted. The transcript, names and marks stay." : "No audio for this meeting.",
                      systemImage: "speaker.slash")
                    .font(.status).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.meta.weight(.bold)).foregroundStyle(.white)
                        .offset(x: player.playing ? 0 : 1)
                        .frame(width: 24, height: 24).background(GoblinBrand.moss, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: .option)
                .help(player.playing ? "Pause (⌥Space)" : "Play (⌥Space)")
                .accessibilityLabel(player.playing ? "Pause" : "Play from \(MeetingTimeline.clock(player.time))")
                Text("\(MeetingTimeline.clock(player.time)) / \(MeetingTimeline.clock(length))")
                    .font(.meta).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                strip
            }
        }
        .frame(minHeight: 24)
    }

    private var strip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    let y = 4 + CGFloat(index) * (Self.laneHeight + Self.laneGap)
                    Capsule().fill(.primary.opacity(0.07)).frame(width: width, height: Self.laneHeight).offset(y: y)
                    ForEach(lane.stretches) { stretch in
                        let on = player.playingRange == stretch.start...max(stretch.start, stretch.end)
                        Capsule()
                            .fill((colors(lane.name) ?? GoblinBrand.moss).opacity(on || !player.playing ? 1 : 0.55))
                            .frame(width: max(3, x(stretch.end - stretch.start, width)), height: Self.laneHeight)
                            .offset(x: x(stretch.start, width), y: y)
                            .help("\(lane.name) · \(MeetingTimeline.clock(stretch.start))–\(MeetingTimeline.clock(stretch.end))")
                    }
                }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(GoblinBrand.candle)
                        .offset(x: x(mark.t, width) - 1, y: -8)
                        .help("\(MeetingTimeline.clock(mark.t)) · \(mark.label ?? "Marked")")
                        .accessibilityHidden(true)
                }
                if player.playing || player.time > 0 {
                    Rectangle().fill(GoblinBrand.mossText).frame(width: 1.5, height: stripHeight).offset(x: x(player.time, width))
                }
            }
            .frame(width: width, height: stripHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            // Clicking plays from that moment, on the track of whoever was talking there.
            .gesture(SpatialTapGesture().onEnded { tap in
                let seconds = max(0, min(length, Double(tap.location.x / max(width, 1)) * length))
                let stretch = lanes.flatMap(\.stretches).first { $0.start <= seconds && seconds <= $0.end }
                player.play(seconds...(stretch?.end ?? seconds + 30), track: stretch?.track)
            })
        }
        .frame(height: stripHeight)
        .accessibilityElement()
        .accessibilityLabel("Meeting timeline")
        .accessibilityValue("\(MeetingTimeline.clock(player.time)) of \(MeetingTimeline.clock(length))")
        .accessibilityAdjustableAction { direction in
            let step = 15.0
            player.seek(max(0, min(length, player.time + (direction == .increment ? step : -step))))
        }
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat { CGFloat(seconds / length) * width }
}
