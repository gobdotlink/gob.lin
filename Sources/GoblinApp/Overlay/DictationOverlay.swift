import SwiftUI

struct DictationOverlay: View {
    /// Transparent margin around the pill that holds its shadow.
    static let shadowMargin: CGFloat = 22

    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listening: Bool { model.phase == .listening }
    private var hasText: Bool { !model.committedText.isEmpty || !model.tentativeText.isEmpty }
    private var isError: Bool { if case .error = model.visiblePhase { true } else { false } }
    private var indicator: Int { model.visiblePhase == .listening ? 0 : isError ? 1 : 2 }
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: listening && model.audioLevel > 0.15 ? Sprites.yap : Sprites.shut)
                .resizable().interpolation(.none).frame(width: 64, height: 64)
                .accessibilityHidden(true).padding(.bottom, -22)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        switch indicator {
                        case 0: LevelRipple(levels: model.levels, reduceMotion: reduceMotion).accessibilityLabel("Microphone level")
                        case 1: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GoblinBrand.yellow)
                        default: ProgressView().controlSize(.small).accessibilityLabel(model.visiblePhase.caption)
                        }
                    }
                    .frame(width: 40, height: 28)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: indicator)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        caption.fixedSize(horizontal: false, vertical: true)
                        if !isError { BlinkingCursor(steady: reduceMotion) }
                    }
                    .font(.custom("VT323-Regular", size: 19, relativeTo: .body))
                    .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Button(action: model.cancel) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(OverlayIconButtonStyle())
                        .accessibilityLabel("Cancel dictation")
                        .help(listening ? "Cancel dictation (Esc)" : "Cancel dictation")
                }
                if hasText {
                    ScrollView {
                        Text("\(Text(model.committedText).foregroundStyle(.white))\(Text(model.tentativeText).foregroundStyle(.secondary))")
                            .font(.system(size: 15)).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.disabled)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .frame(height: model.textHeight)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background {
                // Opaque for legibility over any desktop. Only the shape casts the shadow, so the text
                // is never rasterized through a shadow layer that changes as the pill grows.
                shape.fill(GoblinBrand.background)
                    // Light catching the top edge, fading into the brand green.
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.2), GoblinBrand.accent.opacity(0.22)],
                                                               startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .overlay(alignment: .top) {
                // The sprite's fingers sit on rows 46–52; centre them on the pill's top edge so they grip it.
                Image(nsImage: Sprites.hands).resizable().interpolation(.none)
                    .frame(width: 44, height: 59).offset(y: -49).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // Emerge from, and retreat to, the screen edge the overlay lives on.
        .scaleEffect(model.presented || reduceMotion ? 1 : 0.94, anchor: model.edge == .bottom ? .bottom : .top)
        .offset(y: model.presented || reduceMotion ? 0 : (model.edge == .bottom ? 10 : -10))
        .opacity(model.presented ? 1 : 0)
        .padding(.top, 8).padding(.horizontal, Self.shadowMargin).padding(.bottom, Self.shadowMargin)
        .frame(width: 440 + 2 * Self.shadowMargin).fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.sizeChanged($0) }
        .preferredColorScheme(.dark)
    }

    private var caption: Text {
        let caption = model.visiblePhase.caption
        guard caption.hasPrefix("autism ") else { return Text(verbatim: caption) }
        return Text("\(Text(verbatim: "autism").foregroundStyle(GoblinBrand.accent))\(Text(verbatim: String(caption.dropFirst(6))))")
    }
}

/// Decoded once: level ticks must not reload artwork from disk.
@MainActor private enum Sprites {
    static let shut = GoblinBrand.sprite("goblin-shut")
    static let yap = GoblinBrand.sprite("goblin-yap")
    static let hands = GoblinBrand.sprite("hands")
}

/// Mirrored meter: the newest level sits in the middle and older ones ripple outward.
private struct LevelRipple: View {
    let levels: [Double]
    let reduceMotion: Bool
    private let falloff = [1.0, 0.82, 0.62, 0.42]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                let distance = abs(index - 3)
                let level = levels.indices.contains(levels.count - 1 - distance) ? levels[levels.count - 1 - distance] : 0
                Capsule().fill(GoblinBrand.accent)
                    .frame(width: 3, height: 4 + level * falloff[distance] * 22)
            }
        }
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.86), value: levels)
    }
}

/// Terminal block cursor. Steady under Reduce Motion.
private struct BlinkingCursor: View {
    let steady: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = steady || Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Text(verbatim: "█").foregroundStyle(GoblinBrand.accent).opacity(on ? 1 : 0)
        }
        .padding(.leading, 4)
        .accessibilityHidden(true)
    }
}

/// Pressed state responds on press, not release.
private struct OverlayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconButton(configuration: configuration) }

    private struct IconButton: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0.05), in: Circle())
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}
