import CoreGraphics
import Testing
@testable import GoblinCore

@Test func wordCloudDrawsTheSamePictureForTheSameSeedAndFindsItsWords() {
    let words = ["agent", "goblin", "cloud", "branch", "keyboard", "history", "insight", "screen", "device", "word"]
        .enumerated().map { InsightWord(word: $1, count: 50 - $0) }
    let first = WordCloudLayout(words: words, columns: 180, seed: 42), second = WordCloudLayout(words: words, columns: 180, seed: 42)
    let boxes = { (layout: WordCloudLayout) in layout.words.map { [$0.x, $0.y, $0.width, $0.height] } }
    #expect(!first.words.isEmpty)
    #expect(boxes(first) == boxes(second))
    #expect(first.props.map { [$0.x, $0.y] } == second.props.map { [$0.x, $0.y] })
    #expect(first.image(dark: true).dataProvider?.data == second.image(dark: true).dataProvider?.data)
    for word in first.words {
        #expect(word.x >= 1 && word.y >= 1 && word.x + word.width <= first.columns - 1 && word.y + word.height <= first.rows - 1)
    }
    let top = first.words[0], cell = WordCloudLayout.cell
    #expect(first.word(at: CGPoint(x: (CGFloat(top.x) + CGFloat(top.width) / 2) * cell, y: (CGFloat(top.y) + CGFloat(top.height) / 2) * cell)) == 0)
    // Off the cloud, only a fingertip's slop reaches a word.
    #expect(first.word(at: CGPoint(x: -1, y: -1)) == nil)
    #expect(first.word(at: CGPoint(x: -1, y: -1), slop: 10_000) != nil)
}
