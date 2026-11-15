#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation

/// What you talked about, packed as a pixel word cloud on a grid of 2 pt cells. Each word is drawn in Press Start 2P
/// at its native 8 pt and scaled by whole numbers, like the sprites, then packed outward from the middle. The side-eye
/// goblin grips the top edge of the biggest word; smaller goblins and sparks sit only in gaps that fit them.
///
/// The app registers Press Start 2P; words it can't draw, or every word without it, come from a 16 pt system font.
/// Pure and deterministic, so it can run off the main thread.
public struct WordCloudLayout: Sendable {
    public static let cell: CGFloat = 2
    public static let height: CGFloat = 300

    public struct Word: Sendable, Identifiable {
        public let id: Int
        public let text: String
        public let count: Int
        /// In cells.
        public let x, y, width, height: Int
    }

    public struct Prop: Sendable, Identifiable {
        /// The sprite's file name.
        public enum Sprite: String, Sendable {
            case side = "goblin-side", cackle = "goblin-cackle", yap = "goblin-yap", spark = "prop-spark"
        }

        public let id: Int
        public let sprite: Sprite
        /// In points.
        public let x, y: CGFloat
        /// Points per sprite pixel.
        public var scale: CGFloat = 1
        public var mirrored = false
        /// The goblin grips the edge under it with both hands, at scale 1.
        public var peeking = false
    }

    public let columns: Int
    public let rows: Int
    public private(set) var words: [Word] = []
    public private(set) var props: [Prop] = []
    /// Per cell: 0 is empty, otherwise the palette slot of the word drawn there.
    private var ink: [UInt8]
    /// Per cell: the index of the word drawn there, or −1.
    private var owner: [Int16]
    /// Cells taken by a word, a goblin or a spark, plus the gap kept around each.
    private var taken: [Bool]

    /// Neon for the biggest word, moss for the next two, then ink and muted greens and greys.
    private static let dark: [UInt32] = [0x57E68FFF, 0x62C78AFF, 0xECECEEFF, 0x3E9C68FF, 0x8A8B90FF, 0xC4C5C8FF, 0x5FAF82FF]
    private static let light: [UInt32] = [0x2B7D4FFF, 0x3E9466FF, 0x2E2F31FF, 0x6FA585FF, 0x8C8C8FFF, 0x4D4E52FF, 0x9DBFAAFF]
    /// The same roles with every word at 4.5:1 or more against a plate, for Increase Contrast.
    private static let darkContrast: [UInt32] = [0x57E68FFF, 0x62C78AFF, 0xECECEEFF, 0x6DBF8FFF, 0xA9AAAFFF, 0xC4C5C8FF, 0x86CDA4FF]
    private static let lightContrast: [UInt32] = [0x2B7D4FFF, 0x2D7650FF, 0x2E2F31FF, 0x3D6B50FF, 0x5E5E62FF, 0x4D4E52FF, 0x46705AFF]
    private static let gap = 3
    private static let goblinCells = 32

    public init(words input: [InsightWord], columns: Int, seed: UInt64) {
        self.columns = columns
        rows = Int(Self.height / Self.cell)
        ink = Array(repeating: 0, count: columns * rows)
        owner = Array(repeating: -1, count: columns * rows)
        taken = Array(repeating: false, count: columns * rows)
        var random = SplitMix(seed: seed)
        for (rank, word) in input.prefix(28).enumerated() {
            let text = word.word.uppercased()
            let (base, doubled) = Self.bitmap(text)
            guard base.width > 0 else { continue }
            let tier = [5, 4, 4, 3, 3, 3, 3][safe: rank] ?? (rank < 15 ? 2 : 1)
            // Words the pixel font can't draw come from a 16 pt system font, so they start at half the scale.
            var scale = doubled ? max(1, tier / 2) : tier
            let vertical = rank >= 3 && random.next() < 0.3
            var placed: (mask: Mask, x: Int, y: Int)?
            while placed == nil, scale >= 1 {
                var mask = base.scaled(scale)
                if vertical { mask = mask.rotated() }
                if rank == 0 {
                    // Just below the middle, leaving room above for the goblin hanging off its top edge.
                    let x = (columns - mask.width) / 2, y = (rows - mask.height) / 2 + 14
                    if fits(mask, x, y) { placed = (mask, x, y) }
                } else if let spot = spiral(mask, columns / 2, rows / 2 + 6) {
                    placed = (mask, spot.x, spot.y)
                }
                if placed == nil { scale -= 1 }
            }
            guard let placed else { continue }
            let slot = UInt8(rank == 0 ? 1 : rank < 3 ? 2 : rank < 8 ? 3 : 4 + rank % 4)
            claim(placed.mask, placed.x, placed.y, ink: slot, word: words.count)
            words.append(Word(id: words.count, text: word.word, count: word.count,
                              x: placed.x, y: placed.y, width: placed.mask.width, height: placed.mask.height))
            if rank == 0 { hangGoblin(over: placed.mask, x: placed.x, y: placed.y) }
            if rank == 6 { tuckGoblin(.cackle, nearX: columns / 2 - 60, mirrored: false) }
            if rank == 16 { tuckGoblin(.yap, nearX: columns / 2 + 60, mirrored: true) }
        }
        var sparks = 0
        for _ in 0..<400 where sparks < 7 {
            let spark = Mask(filled: 9, 9)
            let x = Int(random.next() * Double(columns - 10)), y = Int(random.next() * Double(rows - 10))
            guard fits(spark, x, y) else { continue }
            claim(spark, x, y, gap: 3)
            props.append(Prop(id: props.count, sprite: .spark, x: CGFloat(x + 1) * Self.cell, y: CGFloat(y + 1) * Self.cell, scale: 2))
            sparks += 1
        }
    }

    /// One picture per day and period, so the cloud doesn't reshuffle on every visit.
    public static func seed(for period: InsightPeriod, on date: Date = Date(), calendar: Calendar = .current) -> UInt64 {
        UInt64(calendar.ordinality(of: .day, in: .era, for: date) ?? 0) &* 3 + UInt64(period.rawValue)
    }

    /// One pixel per cell. The highlighted word is drawn in full ink: white on dark, near-black on light.
    public func image(dark: Bool, highlight: Int? = nil, increasedContrast: Bool = false) -> CGImage {
        let palette = increasedContrast ? (dark ? Self.darkContrast : Self.lightContrast) : (dark ? Self.dark : Self.light)
        let lit: UInt32 = dark ? 0xFFFFFFFF : 0x111213FF
        var pixels = [UInt32](repeating: 0, count: ink.count)
        for index in ink.indices where ink[index] > 0 {
            pixels[index] = (highlight.map { Int(owner[index]) == $0 } == true ? lit : palette[Int(ink[index]) - 1]).bigEndian
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The word under a point in the cloud, in points: the one inked there, else the smallest box around it, so the
    /// gaps inside a letter still count. Past every box, the nearest word within `slop` points, for a fingertip.
    public func word(at point: CGPoint, slop: CGFloat = 0) -> Int? {
        let x = Int(point.x / Self.cell), y = Int(point.y / Self.cell)
        if x >= 0, y >= 0, x < columns, y < rows {
            if owner[y * columns + x] >= 0 { return Int(owner[y * columns + x]) }
            if let boxed = words.filter({ x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height })
                .min(by: { $0.width * $0.height < $1.width * $1.height }) {
                return boxed.id
            }
        }
        guard slop > 0 else { return nil }
        let px = point.x / Self.cell, py = point.y / Self.cell
        func distance(_ word: Word) -> CGFloat {
            let dx = max(CGFloat(word.x) - px, 0, px - CGFloat(word.x + word.width))
            let dy = max(CGFloat(word.y) - py, 0, py - CGFloat(word.y + word.height))
            return (dx * dx + dy * dy).squareRoot() * Self.cell
        }
        return words.map { ($0.id, distance($0)) }.filter { $0.1 <= slop }.min { $0.1 < $1.1 }?.0
    }

    // MARK: Goblins

    /// The side-eye goblin grips the biggest word's top edge, the way a goblin grips a card.
    private mutating func hangGoblin(over mask: Mask, x: Int, y: Int) {
        let size = CGFloat(Self.goblinCells) * Self.cell
        let left = min(max(0, (CGFloat(x) + CGFloat(mask.width) * 0.74) * Self.cell - size / 2), CGFloat(columns) * Self.cell - size)
        let top = CGFloat(y) * Self.cell - size
        guard top >= 0 else { return }
        claim(Mask(filled: Self.goblinCells, Self.goblinCells - 1), Int(left / Self.cell), Int(top / Self.cell), gap: 2)
        props.append(Prop(id: props.count, sprite: .side, x: left, y: top, peeking: true))
    }

    private mutating func tuckGoblin(_ sprite: Prop.Sprite, nearX x: Int, mirrored: Bool) {
        let mask = Mask(filled: Self.goblinCells, Self.goblinCells)
        guard let spot = spiral(mask, x, rows / 2) else { return }
        claim(mask, spot.x, spot.y, gap: 2)
        props.append(Prop(id: props.count, sprite: sprite, x: CGFloat(spot.x) * Self.cell, y: CGFloat(spot.y) * Self.cell, mirrored: mirrored))
    }

    // MARK: Packing

    private func fits(_ mask: Mask, _ x: Int, _ y: Int) -> Bool {
        guard x >= 1, y >= 1, x + mask.width <= columns - 1, y + mask.height <= rows - 1 else { return false }
        for row in 0..<mask.height {
            let maskRow = row * mask.width, gridRow = (y + row) * columns + x
            for column in 0..<mask.width where mask.bits[maskRow + column] && taken[gridRow + column] { return false }
        }
        return true
    }

    private mutating func claim(_ mask: Mask, _ x: Int, _ y: Int, ink slot: UInt8 = 0, word: Int = -1, gap: Int = gap) {
        for row in 0..<mask.height {
            for column in 0..<mask.width where mask.bits[row * mask.width + column] {
                if slot > 0 {
                    ink[(y + row) * columns + x + column] = slot
                    owner[(y + row) * columns + x + column] = Int16(word)
                }
                for dy in -gap...gap {
                    let gridY = y + row + dy
                    guard gridY >= 0, gridY < rows else { continue }
                    for dx in -gap...gap {
                        let gridX = x + column + dx
                        if gridX >= 0, gridX < columns { taken[gridY * columns + gridX] = true }
                    }
                }
            }
        }
    }

    /// The first free spot on an Archimedean spiral from the centre, stretched to the cloud's shape.
    private func spiral(_ mask: Mask, _ centerX: Int, _ centerY: Int) -> (x: Int, y: Int)? {
        let stretch = Double(columns) / Double(rows) * 0.8
        var angle = 0.0, radius = 0.0
        while radius < Double(max(columns, rows)) {
            let x = Int((Double(centerX) + radius * cos(angle) * stretch - Double(mask.width) / 2).rounded())
            let y = Int((Double(centerY) + radius * sin(angle) - Double(mask.height) / 2).rounded())
            if fits(mask, x, y) { return (x, y) }
            angle += 1.2 / max(radius, 1.5)
            radius = 0.9 * angle
        }
        return nil
    }

    // MARK: Glyphs

    /// The word as solid pixels at 1×. Press Start 2P draws on an 8 pt grid, so at 8 pt with antialiasing
    /// off every glyph pixel lands on one bitmap pixel.
    private static func bitmap(_ text: String) -> (Mask, doubled: Bool) {
        let pixel = CTFontCreateWithName("PressStart2P-Regular" as CFString, 8, nil)
        let covered = CTFontCopyPostScriptName(pixel) as String == "PressStart2P-Regular" && covers(pixel, text)
        let font = covered ? pixel : CTFontCreateUIFontForLanguage(.emphasizedSystem, 16, nil) ?? pixel
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let width = Int(advance.rounded(.up)) + 4, height = Int((ascent + descent).rounded(.up)) + 4
        guard width > 4, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return (Mask(filled: 0, 0), !covered) }
        context.setShouldAntialias(false)
        context.setAllowsFontSmoothing(false)
        context.textPosition = CGPoint(x: 2, y: 2 + descent.rounded(.up))
        CTLineDraw(line, context)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var bits = [Bool](repeating: false, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > 127 {
                bits[y * width + x] = true
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (Mask(filled: 0, 0), !covered) }
        return (Mask(cropping: bits, width: width, x: minX, y: minY, toWidth: maxX - minX + 1, height: maxY - minY + 1), !covered)
    }

    private static func covers(_ font: CTFont, _ text: String) -> Bool {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}

private struct Mask {
    var width: Int
    var height: Int
    var bits: [Bool]

    init(filled width: Int, _ height: Int) {
        self.width = width; self.height = height
        bits = Array(repeating: true, count: width * height)
    }

    init(width: Int, height: Int, bits: [Bool]) { self.width = width; self.height = height; self.bits = bits }

    init(cropping source: [Bool], width sourceWidth: Int, x: Int, y: Int, toWidth width: Int, height: Int) {
        self.width = width; self.height = height
        // A plain loop: the equivalent flatMap over slices exceeds the type checker's time limit in release builds.
        var bits: [Bool] = []
        bits.reserveCapacity(width * height)
        for row in 0..<height {
            let start: Int = (y + row) * sourceWidth + x
            bits.append(contentsOf: source[start..<(start + width)])
        }
        self.bits = bits
    }

    /// Every pixel becomes a k × k block.
    func scaled(_ k: Int) -> Mask {
        guard k > 1 else { return self }
        var out = [Bool](repeating: false, count: width * k * height * k)
        for y in 0..<height * k {
            for x in 0..<width * k { out[y * width * k + x] = bits[(y / k) * width + x / k] }
        }
        return Mask(width: width * k, height: height * k, bits: out)
    }

    /// A quarter turn anticlockwise, so vertical words read bottom to top.
    func rotated() -> Mask {
        var out = [Bool](repeating: false, count: bits.count)
        for y in 0..<width {
            for x in 0..<height { out[y * height + x] = bits[x * width + (width - 1 - y)] }
        }
        return Mask(width: height, height: width, bits: out)
    }
}

/// A tiny seeded generator, so one seed always draws the same cloud.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((value ^ (value >> 31)) >> 11) / Double(1 << 53)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
