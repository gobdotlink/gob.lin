import GoblinCore
import SwiftUI

/// What you talked about, as a pixel word cloud packed by `WordCloudLayout`, with hover showing each word's count.
struct PixelWordCloud: View {
    let words: [InsightWord]
    /// The same seed draws the same picture, so the cloud doesn't reshuffle every time the page opens.
    let seed: UInt64
    /// "today" or "this week", for the word tooltips.
    let period: String
    @Environment(\.colorScheme) private var scheme
    @State private var width: CGFloat = 0
    @State private var layout: WordCloudLayout?
    /// What the current layout was packed from.
    @State private var drawn: Request?
    @State private var hover: Hover?

    private struct Request: Equatable { var words: [InsightWord]; var columns: Int; var seed: UInt64 }
    private struct Hover: Equatable { var word: Int; var point: CGPoint }

    var body: some View {
        let cell = WordCloudLayout.cell
        ZStack(alignment: .topLeading) {
            if let layout {
                Image(decorative: layout.image(dark: scheme == .dark, highlight: hover?.word), scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: CGFloat(layout.columns) * cell, height: CGFloat(layout.rows) * cell)
                ForEach(layout.props) { prop in
                    let sprite = Sprite(rawValue: prop.sprite.rawValue)!
                    Group {
                        if prop.peeking { PeekingGoblin(sprite: sprite, scale: 1) }
                        else { PixelSprite(sprite: sprite, scale: prop.scale, mirrored: prop.mirrored) }
                    }
                    .offset(x: prop.x, y: prop.y)
                }
                // Padding, not offset: VoiceOver frames follow layout, not where a view is drawn.
                ForEach(layout.words) { word in
                    Color.clear
                        .frame(width: CGFloat(word.width) * cell, height: CGFloat(word.height) * cell)
                        .accessibilityElement()
                        .accessibilityLabel(word.text)
                        .accessibilityValue(times(word.count))
                        .padding(.leading, CGFloat(word.x) * cell).padding(.top, CGFloat(word.y) * cell)
                }
                if let hover {
                    let word = layout.words[hover.word], point = hover.point, flip = point.x > width * 0.7
                    Text("\(word.text) · \(times(word.count)) \(period)")
                        .font(.meta.weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        .fixedSize()
                        // Flip to the pointer's left near the right edge so the label never runs off the plate.
                        .alignmentGuide(.leading) { flip ? $0.width - point.x + 12 : -point.x - 14 }
                        .alignmentGuide(.top) { _ in -max(0, point.y - 34) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        // A zero minimum, so a picture packed for a wider row never holds the row open.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: WordCloudLayout.height, maxHeight: WordCloudLayout.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase, let index = layout?.word(at: point) else { hover = nil; return }
            hover = Hover(word: index, point: point)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: Request(words: words, columns: Int(width / cell), seed: seed)) {
            let columns = Int(width / cell), words = words, seed = seed
            guard columns > 60 else { return }
            // A classic scroll bar showing or hiding moves the width by 15 pt. Packing is chaotic, so re-packing for
            // that would redraw a different cloud; keep the picture while it still fits with at most 16 pt to spare.
            if let drawn, drawn.words == words, drawn.seed == seed, (0...8).contains(columns - drawn.columns) { return }
            hover = nil
            let next = await Task.detached(priority: .userInitiated) { WordCloudLayout(words: words, columns: columns, seed: seed) }.value
            // Detached work outlives its cancelled task; a layout for an old width must not replace a newer one.
            guard !Task.isCancelled else { return }
            layout = next
            drawn = Request(words: words, columns: columns, seed: seed)
        }
    }

    private func times(_ count: Int) -> String { count == 1 ? "once" : "\(count.formatted()) times" }
}
