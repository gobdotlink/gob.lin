import GoblinCore
import SwiftUI

/// A speech bubble in the corner with the goblin beside it. Always dark glass, so it reads over any app.
struct DictationOverlay: View {
    /// Transparent margin around the content that holds the shadow and the hands.
    static let margin: CGFloat = 22
    static let bubbleWidth: CGFloat = 404
    static let contentSize = CGSize(width: bubbleWidth + 12 + 128, height: 184)
    static var panelSize: CGSize { CGSize(width: contentSize.width + 2 * margin, height: contentSize.height + 2 * margin) }

    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if model.mirrored { OverlayGoblin(model: model) }
            OverlayBubble(model: model, reduceMotion: reduceMotion)
            if !model.mirrored { OverlayGoblin(model: model) }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height,
               alignment: Alignment(horizontal: model.mirrored ? .leading : .trailing, vertical: model.edge == .bottom ? .bottom : .top))
        .opacity(model.presented ? 1 : 0)
        .offset(y: model.presented || reduceMotion ? 0 : (model.edge == .bottom ? 8 : -8))
        .padding(Self.margin)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Goblin

/// The face and one hand carry the state. Frames swap; they never tween.
private struct OverlayGoblin: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let mirrored = model.mirrored
        PixelSprite(sprite: face, scale: 2, mirrored: mirrored)
            .overlay(alignment: mirrored ? .bottomTrailing : .bottomLeading) {
                if hand == .quill { PixelSprite(sprite: .quill, scale: 2, mirrored: mirrored).offset(x: mirrored ? 4 : -4, y: 6) }
            }
            .overlay(alignment: mirrored ? .bottomLeading : .bottomTrailing) {
                if hand == .palm { PixelSprite(sprite: .palm, scale: 2, mirrored: !mirrored).offset(x: mirrored ? -18 : 18, y: -6) }
            }
            .overlay(alignment: .topLeading) {
                if case .milestone = model.visiblePhase {
                    PixelSprite(sprite: .spark, scale: 2).offset(x: -6, y: 4)
                    PixelSprite(sprite: .spark, scale: 2).offset(x: 122, y: 30)
                }
            }
            .transaction { $0.animation = nil }
    }

    private var face: Sprite {
        switch model.visiblePhase {
        case .hidden, .arming: .shut
        case .listening: model.mouthOpen ? .yap : .shut
        case .transcribing: .look
        case .polishing: .squint
        case .inserted: .closed
        case .milestone: .cackle
        case .readyToPaste: .side
        case .error(let notice): NoticeCopy(notice).face
        }
    }

    private var hand: Sprite? {
        switch model.visiblePhase {
        case .transcribing: .quill
        case .error(let notice): NoticeCopy(notice).hand
        default: nil
        }
    }
}

// MARK: - Bubble

private struct OverlayBubble: View {
    @ObservedObject var model: OverlayModel
    let reduceMotion: Bool
    @State private var textHeight: CGFloat = 21
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var compact: Bool {
        switch model.visiblePhase {
        case .arming: true
        case .inserted(let result): result.notice == nil
        default: false
        }
    }

    var body: some View {
        content
            .padding(compact ? EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12) : EdgeInsets(top: 11, leading: 16, bottom: 13, trailing: 12))
            .frame(width: compact ? nil : DictationOverlay.bubbleWidth, height: compact ? 42 : nil, alignment: .leading)
            .fixedSize(horizontal: compact, vertical: true)
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(GoblinBrand.bubble))
                    .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
                    .shadow(color: glow, radius: 16)
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            }
            .overlay(alignment: model.mirrored ? .bottomLeading : .bottomTrailing) {
                BubbleTail().fill(GoblinBrand.bubble)
                    .frame(width: 10, height: 16)
                    .scaleEffect(x: model.mirrored ? -1 : 1)
                    .offset(x: model.mirrored ? -9 : 9, y: compact ? -13 : -24)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white.opacity(0.94))
            .accessibilityElement(children: .contain)
    }

    private var borderColor: Color {
        if case .milestone = model.visiblePhase { return GoblinBrand.candle.opacity(0.5) }
        return .white.opacity(0.1)
    }

    private var glow: Color {
        if case .milestone = model.visiblePhase { return GoblinBrand.candle.opacity(0.2) }
        return .clear
    }

    @ViewBuilder private var content: some View {
        switch model.visiblePhase {
        case .hidden, .arming:
            HStack(spacing: 10) {
                Meter(levels: model.levels, idle: true)
                Text("Warming up the mic…").font(.system(size: 14))
                DarkKey("esc").padding(.leading, 2)
            }
        case .listening:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Meter(levels: model.levels, idle: false)
                    HStack(spacing: 6) {
                        Text(model.handsFree ? "Hands-free" : "Listening").fontWeight(.semibold).foregroundStyle(.white.opacity(0.58))
                        ElapsedTime(start: model.listeningStarted).foregroundStyle(.white.opacity(0.38))
                    }
                    .font(.system(size: 12))
                    Spacer(minLength: 8)
                    if model.handsFree {
                        HStack(spacing: 6) { Text("tap"); DarkKey("fn"); Text("to finish") }
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    Button(action: model.cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(OverlayIconButtonStyle())
                        .accessibilityLabel("Cancel dictation")
                        .help("Cancel dictation (Esc)")
                }
                .frame(height: 24)
                if let notice = model.microphoneNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash.fill").foregroundStyle(Color(red: 1, green: 0.48, blue: 0.43))
                        Text(notice).fontWeight(.semibold)
                    }
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                }
                words(caret: true)
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 0) {
                words(caret: false).padding(.top, 2)
                Subline {
                    WorkingDots(reduceMotion: reduceMotion)
                    Text("Transcribing").fontWeight(.semibold).foregroundStyle(.white.opacity(0.82))
                    Spacer(minLength: 8)
                    Text(audioDetail)
                }
            }
        case .polishing:
            VStack(alignment: .leading, spacing: 0) {
                Shimmer(text: model.committedText + model.tentativeText, reduceMotion: reduceMotion).padding(.top, 2)
                Subline {
                    Image(systemName: "sparkles").foregroundStyle(GoblinBrand.neon)
                    Text("Cleaning up").fontWeight(.semibold).foregroundStyle(.white.opacity(0.82))
                    Text(model.cleanupLabel)
                    Spacer(minLength: 8)
                }
            }
        case .inserted(let result):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(GoblinBrand.neon)
                    Group {
                        if let application = result.application { Text("Text landed in \(Text(application).fontWeight(.semibold))") }
                        else { Text("Text delivered") }
                    }
                    .font(.system(size: 13.5))
                    Text("\(result.words.formatted()) \(result.words == 1 ? "word" : "words") · \(result.seconds.formatted(.number.precision(.fractionLength(2)))) s")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                }
                if let notice = result.notice {
                    Subline { Text(NoticeCopy(notice).sentence).fixedSize(horizontal: false, vertical: true) }
                }
            }
        case .readyToPaste(let application):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(GoblinBrand.neon)
                    Text(application.map { "Ready to paste into \($0)" } ?? "Ready to paste")
                        .font(.system(size: 14, weight: .semibold))
                }
                Subline {
                    Text("Focus a text field, then press ⌥⇧⌘V. Your words are in History.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .milestone(let words):
            HStack(spacing: 12) {
                PixelSprite(sprite: .candle, scale: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(words.formatted()) words yapped.").font(.system(size: 14, weight: .semibold))
                    Text(model.deliveryApplication.map { "Text landed in \($0)" } ?? "About \(max(1, words / 250).formatted()) pages you didn't type.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
        case .error(let notice):
            let copy = NoticeCopy(notice)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: copy.symbol).font(.system(size: 15)).foregroundStyle(copy.tint).padding(.top, 1)
                    Text(copy.sentence).font(.system(size: 14)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                if copy.detail != nil || copy.action != nil {
                    Subline {
                        if let detail = copy.detail { Text(detail).lineLimit(1) }
                        Spacer(minLength: 8)
                        if let action = copy.action {
                            Button(action.title) { model.perform(action.action) }.buttonStyle(OverlayPillStyle())
                        }
                    }
                }
            }
        }
    }

    private var audioDetail: String {
        let seconds = Int((model.audioSeconds ?? 0).rounded())
        return "\(model.modelName) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) of audio"
    }

    /// Firm words at 94%, tentative ones at 42%. Up to four lines; older ones scroll under a top fade.
    private func words(caret: Bool) -> some View {
        let empty = model.committedText.isEmpty && model.tentativeText.isEmpty
        let text: Text = empty
            ? Text(model.previewUnavailable ? "Recording · live preview unavailable" : "Go ahead, I'm listening.").foregroundStyle(.white.opacity(0.35))
            : Text("\(Text(model.committedText).foregroundStyle(.white.opacity(0.94)))\(Text(model.tentativeText).foregroundStyle(.white.opacity(0.42)))\(Text(caret ? "▎" : "").foregroundStyle(GoblinBrand.neon))")
        let overflow = textHeight > 84
        return ScrollView(.vertical) {
            text.font(.system(size: 15)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(height: min(max(textHeight, 21), 84))
        .mask(LinearGradient(stops: [.init(color: overflow ? .clear : .black, location: 0), .init(color: .black, location: overflow ? 0.17 : 0)],
                             startPoint: .top, endPoint: .bottom))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: min(textHeight, 84))
        .accessibilityLabel(empty ? "Listening" : model.committedText + model.tentativeText)
    }
}

/// What the goblin says when something goes wrong: one first-person sentence, a face, and maybe a hand.
private struct NoticeCopy {
    var symbol = "exclamationmark.triangle.fill"
    var tint = Color(red: 1, green: 0.84, blue: 0.04)
    var sentence: String
    var detail: String?
    var face = Sprite.side
    var hand: Sprite?
    var action: (title: String, action: OverlayAction)?

    init(_ notice: OverlayNotice) {
        sentence = notice.message
        guard let failure = notice.failure else { return }
        switch failure {
        case .rewriteTimeout:
            sentence = "Cleanup took too long, so I typed your words as you said them."
            detail = "Cleanup › no answer within 4 s"; face = .sheepish
        case .rewriteTransport:
            sentence = "I couldn't reach the cleanup service, so I typed your words as you said them."
            detail = "Cleanup › provider unreachable"; face = .sheepish
        case .rewriteHTTPStatus(let status):
            sentence = "Cleanup failed, so I typed your words as you said them."
            detail = "Cleanup › the provider answered \((100...599).contains(status) ? "HTTP \(status)" : "with an error")"; face = .sheepish
        case .rewriteInvalidResponse:
            sentence = "Cleanup came back empty, so I typed your words as you said them."
            detail = "Cleanup › no usable text"; face = .sheepish
        case .rewriteConfiguration:
            sentence = "Cleanup isn't set up yet, so I typed your words as you said them."
            face = .sheepish; action = ("Cleanup Settings…", .cleanupSettings)
        case .microphoneUnavailable:
            symbol = "mic.slash.fill"; tint = Color(red: 1, green: 0.48, blue: 0.43)
            sentence = "I can't hear anything. No microphone is connected."
            detail = "Audio › no input device"; face = .squint; hand = .palm
            action = ("Choose Microphone…", .audioSettings)
        case .microphoneCaptureFailed:
            symbol = "mic.slash.fill"; tint = Color(red: 1, green: 0.48, blue: 0.43)
            sentence = "The microphone stopped working, so I couldn't finish."
            detail = "Audio › recording failed"; face = .squint; hand = .palm
            action = ("Audio Settings…", .audioSettings)
        case .microphoneMuted:
            symbol = "mic.slash.fill"; tint = Color(red: 1, green: 0.48, blue: 0.43)
            sentence = "I only heard silence. Your microphone may be muted."
            detail = "Audio › no sound arrived"; face = .squint; hand = .palm
            action = ("Audio Settings…", .audioSettings)
        case .microphonePermissionMissing:
            symbol = "mic.slash.fill"; tint = Color(red: 1, green: 0.48, blue: 0.43)
            sentence = "I'm not allowed to listen yet."
            detail = "Permissions › Microphone"; face = .squint; hand = .palm; action = ("Open Setup…", .setup)
        case .secureInputEnabled:
            symbol = "lock.fill"; tint = Color(red: 1, green: 0.7, blue: 0.25)
            sentence = "That's a password field, so I didn't type there."
            detail = "Insert › Secure Input is on"; hand = .palm
        case .requiredPermissionsMissing, .insertionPermissionMissing:
            symbol = "lock.fill"; tint = Color(red: 1, green: 0.7, blue: 0.25)
            sentence = "I can't type for you until Accessibility is allowed."
            detail = "Permissions › Accessibility"; hand = .palm; action = ("Open Setup…", .setup)
        case .insertionTargetChanged:
            sentence = "The original field is unavailable. Focus a text field and press ⌥⇧⌘V."
            detail = "Your words are in History"
        case .insertionClipboardBusy:
            sentence = "The clipboard changed, so I didn't type it. It's in History."
            detail = "Insert › clipboard busy"
        case .insertionNotAcknowledged:
            sentence = "That app didn't confirm the text arrived. Check it before trying again."
            detail = "Insert › not confirmed"
        case .insertionFailed:
            sentence = "I couldn't type it in. It's in History."
            detail = "Insert › nothing accepted the text"
        case .noTranscriptAvailable:
            sentence = "I didn't catch any words."; face = .squint
        case .transcriptionFailed:
            sentence = "I couldn't make out the words. The recording is in History."
            detail = "Speech › recognition failed"; face = .squint
        case .modelUnavailable, .modelLoadFailed:
            sentence = "My speech model isn't ready yet."
            detail = "Model › check Model settings"; face = .squint
        case .hotkeyUnavailable:
            sentence = "The talk key isn't working right now."
            detail = "Talk key › check General settings"
        default:
            break
        }
    }
}

// MARK: - Pieces

private struct Subline<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            HStack(spacing: 8) { content }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                .frame(minHeight: 24).padding(.top, 7)
        }
        .padding(.top, 8)
    }
}

/// Five neon bars from the last five levels, oldest first.
private struct Meter: View {
    let levels: [Double]
    let idle: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let level = levels.indices.contains(index) ? levels[index] : 0
                Capsule().fill(idle ? Color.white.opacity(0.25) : GoblinBrand.neon)
                    .frame(width: 3, height: idle ? 4 : 4 + level * 14)
            }
        }
        .frame(width: 23, height: 18)
        .accessibilityLabel("Microphone level")
    }
}

private struct ElapsedTime: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start ?? context.date)))
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
        }
    }
}

private struct WorkingDots: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(.white).opacity(index == step ? 1 : 0.3).frame(width: 5, height: 5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A soft highlight sweeps the words every 900 ms. Under Reduce Motion the words stay still.
private struct Shimmer: View {
    let text: String
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? -1 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 1.6 - 0.3
            Text(text.isEmpty ? " " : text).font(.system(size: 15)).lineSpacing(3).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: .white.opacity(0.94), location: max(0, phase - 0.12)),
                    .init(color: Color(red: 0.73, green: 0.96, blue: 0.81), location: max(0, min(1, phase))),
                    .init(color: .white.opacity(0.94), location: min(1, phase + 0.12)),
                ], startPoint: .leading, endPoint: .trailing))
        }
        .accessibilityLabel(text)
    }
}

private struct DarkKey: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control1: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.31),
                      control2: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.midY - rect.height * 0.04))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control1: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.midY + rect.height * 0.04),
                      control2: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.31))
        path.closeSubpath()
        return path
    }
}

private struct OverlayPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 24)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.14), in: Capsule())
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
                .foregroundStyle(.white.opacity(hovering || configuration.isPressed ? 0.9 : 0.62))
                .frame(width: 24, height: 24)
                .background(.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.12 : 0.08), in: Circle())
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}
