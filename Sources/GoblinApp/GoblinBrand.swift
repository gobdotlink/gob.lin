import AppKit
import CoreText
import os
import SwiftUI

enum MascotState: String, CaseIterable {
    case idle, recording, transcribing, warning
}

/// Tokens from DESIGN.md › Colour. Moss does every interactive job; neon is for marks only.
enum GoblinBrand {
    static let moss = Color(nsColor: .dynamic(light: 0x2B7D4F, dark: 0x34965F))
    /// Moss for text and glyphs, lifted in dark mode so it stays readable.
    static let mossText = Color(nsColor: .dynamic(light: 0x2B7D4F, dark: 0x62C78A))
    static let neon = Color(nsColor: NSColor(hex: 0x57E68F))
    static let candle = Color(nsColor: .dynamic(light: 0xB26B0F, dark: 0xF2A93B))
    /// Window background for Settings and History.
    static let caseBackground = Color(nsColor: .dynamic(light: 0xEDECE9, dark: 0x1E1F21))
    static let plate = Color(nsColor: .dynamic(light: 0xFBFAF8, dark: 0x2A2B2E))
    /// The overlay, in both appearances.
    static let bubble = Color(nsColor: NSColor(hex: 0x181A1C, alpha: 0.92))
    static let wordmark = Color(nsColor: .dynamic(light: 0x2B7D4F, dark: 0x57E68F))

    /// Inset for pages that cannot be grouped Forms, so every page shares Form margins.
    static let pagePadding: CGFloat = 20

    static var assetDirectory: URL? {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Assets", isDirectory: true)
        if let directory, FileManager.default.fileExists(atPath: directory.path) { return directory }
        // Packaged apps may not ship SwiftPM's separate resource bundle; its accessor can abort.
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "Assets", withExtension: nil)
        #else
        return nil
        #endif
    }

    static func registerFonts() {
        for name in ["Workbench", "VT323"] {
            guard let url = assetDirectory?.appendingPathComponent(name + ".ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func sprite(_ name: String) -> NSImage {
        guard let url = assetDirectory?.appendingPathComponent(name + ".png"),
              let image = NSImage(contentsOf: url), image.isValid else {
            Logger(subsystem: "app.goblin.dictation.brand", category: "resources")
                .error("Bundled artwork \(name, privacy: .public).png is missing or invalid; showing gob.lin fallback.")
            let fallback = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
                NSColor(red: 87 / 255, green: 230 / 255, blue: 143 / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
                ("g" as NSString).draw(at: NSPoint(x: 16, y: 7), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 48, weight: .bold),
                    .foregroundColor: NSColor.black,
                ])
                return true
            }
            fallback.isTemplate = false
            fallback.accessibilityDescription = "gob.lin artwork unavailable"
            return fallback
        }
        image.isTemplate = false
        return image
    }

    static func menuArtwork() -> NSImage {
        guard let assets = assetDirectory,
              let data = try? Data(contentsOf: assets.appendingPathComponent("goblin-menu.png")),
              let normal = NSBitmapImageRep(data: data) else {
            return sprite("goblin-menu")
        }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        normal.size = size
        image.addRepresentation(normal)
        if let data = try? Data(contentsOf: assets.appendingPathComponent("goblin-menu@2x.png")),
           let retina = NSBitmapImageRep(data: data) {
            retina.size = size
            image.addRepresentation(retina)
        }
        image.isTemplate = false
        return image
    }

    static func menuImage(_ state: MascotState) -> NSImage {
        let goblin = menuArtwork()
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { bounds in
            NSGraphicsContext.current?.imageInterpolation = .none
            goblin.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            if state != .idle {
                let color: NSColor = switch state {
                case .recording: .systemRed
                case .transcribing: .systemOrange
                case .warning: .systemYellow
                case .idle: .clear
                }
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 0, width: 8, height: 8)).fill()
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 1, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "gob.lin " + state.rawValue
        return image
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
}

/// Every goblin frame and prop, decoded once. DESIGN.md › Pixel art says when each one appears.
enum Sprite: String, CaseIterable {
    case shut = "goblin-shut", yap = "goblin-yap", look = "goblin-look", squint = "goblin-squint"
    case side = "goblin-side", closed = "goblin-closed", sheepish = "goblin-sheepish", cackle = "goblin-cackle"
    case gripHand = "hand-grip", palm = "hand-palm", quill = "hand-quill"
    case zz = "prop-zz", drop = "prop-drop", candle = "prop-candle", spark = "prop-spark", coin = "prop-coin"

    @MainActor private static var cache: [Sprite: NSImage] = [:]

    @MainActor var image: NSImage {
        if let image = Self.cache[self] { return image }
        let image = GoblinBrand.sprite(rawValue)
        Self.cache[self] = image
        return image
    }
}

/// A sprite at a whole-number scale (points per art pixel), never resampled or announced.
struct PixelSprite: View {
    let sprite: Sprite
    var scale: CGFloat = 1
    var mirrored = false

    var body: some View {
        let image = sprite.image
        Image(nsImage: image).resizable().interpolation(.none)
            .frame(width: image.size.width * scale, height: image.size.height * scale)
            .scaleEffect(x: mirrored ? -1 : 1)
            .accessibilityHidden(true)
    }
}

/// The goblin gripping an edge: put the view's bottom on the edge. The whole head shows above it,
/// the knuckles sit on it and the two claw rows hang over it.
struct PeekingGoblin: View {
    var sprite: Sprite = .shut
    var scale: CGFloat = 2

    var body: some View {
        PixelSprite(sprite: sprite, scale: scale)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 28 * scale) {
                    PixelSprite(sprite: .gripHand, scale: scale)
                    PixelSprite(sprite: .gripHand, scale: scale, mirrored: true)
                }
                .padding(.leading, 5 * scale).offset(y: 3 * scale)
            }
    }
}

struct GoblinWordmark: View {
    /// Workbench sits on an 8-cell grid; multiples of 4pt keep its scanlines crisp.
    var size: CGFloat = 48

    var body: some View {
        Text("gob.lin").font(.custom("Workbench-Regular", size: size, relativeTo: .largeTitle))
            .foregroundStyle(GoblinBrand.wordmark)
            .accessibilityLabel("gob.lin")
    }
}

/// `$ sudo autism --unmuted`. Only on About and the last first-run step.
struct GoblinTagline: View {
    var size: CGFloat = 22
    var cursor = false
    /// A terminal reply after the prompt, like "ok".
    var reply = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = !cursor || reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Text("""
                \(Text("$ ").foregroundStyle(GoblinBrand.neon))\
                \(Text("sudo ").foregroundStyle(.secondary))\
                \(Text("autism ").foregroundStyle(GoblinBrand.neon))\
                \(Text("--unmuted").foregroundStyle(.secondary))\
                \(Text(reply.isEmpty ? "" : "  " + reply).foregroundStyle(GoblinBrand.neon))\
                \(Text(cursor ? " █" : "").foregroundStyle(GoblinBrand.neon.opacity(on ? 1 : 0)))
                """)
                .font(.custom("VT323-Regular", size: size, relativeTo: .body))
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("sudo autism --unmuted")
    }
}
