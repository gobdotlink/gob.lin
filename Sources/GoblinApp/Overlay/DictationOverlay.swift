import SwiftUI

struct DictationOverlay: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listening: Bool { model.phase == .listening }
    private var hasText: Bool { !model.committedText.isEmpty || !model.tentativeText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: GoblinBrand.sprite(listening && model.audioLevel > 0.15 ? "goblin-yap" : "goblin-shut"))
                .resizable().interpolation(.none).frame(width: 64, height: 64)
                .accessibilityHidden(true).padding(.bottom, -22)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if listening {
                        HStack(alignment: .center, spacing: 3) {
                            ForEach(0..<7, id: \.self) { index in
                                Capsule().fill(GoblinBrand.accent)
                                    .frame(width: 3, height: 5 + model.audioLevel * Double(index % 3 + 1) * 8)
                            }
                        }.frame(width: 40, height: 28).accessibilityLabel("Microphone level")
                    } else if case .error = model.phase {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel(model.phase.caption)
                    }
                    Text(model.phase.caption).font(.custom("VT323-Regular", size: 19, relativeTo: .body))
                        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(action: model.cancel) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel dictation")
                }
                if hasText {
                    ScrollView {
                        Text("\(Text(model.committedText).foregroundStyle(.white))\(Text(model.tentativeText.isEmpty ? "" : " " + model.tentativeText).foregroundStyle(.secondary))")
                            .font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.disabled)
                    }.frame(height: min(130, max(44, Double(model.committedText.count + model.tentativeText.count) / 48 * 20)))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(GoblinBrand.background, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(GoblinBrand.accent.opacity(0.35)))
            .overlay(alignment: .top) {
                Image(nsImage: GoblinBrand.sprite("hands")).resizable().interpolation(.none)
                    .frame(width: 44, height: 59).offset(y: -26).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(8).frame(width: 456).fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.audioLevel)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.sizeChanged($0) }
        .preferredColorScheme(.dark)
    }
}
