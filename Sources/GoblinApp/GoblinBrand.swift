import AppKit
import CoreText
import os
import SwiftUI

enum MascotState: String, CaseIterable {
    case idle, recording, transcribing, warning
}

enum GoblinBrand {
    /// Neon brand green for marks, meters and the cursor. Too bright to carry white text.
    static let accent = Color(red: 87 / 255, green: 230 / 255, blue: 143 / 255)
    /// Control tint: white button labels and switch knobs stay readable on it.
    static let tint = Color(red: 31 / 255, green: 138 / 255, blue: 76 / 255)
    static let background = Color(red: 11 / 255, green: 13 / 255, blue: 16 / 255)
    static let surface = Color(red: 20 / 255, green: 24 / 255, blue: 29 / 255)

    // Terminal theme for the tagline. Elsewhere color only carries meaning: warnings and levels.
    static let prompt = Color(red: 82 / 255, green: 99 / 255, blue: 112 / 255)
    static let blue = Color(red: 82 / 255, green: 179 / 255, blue: 242 / 255)
    static let purple = Color(red: 191 / 255, green: 133 / 255, blue: 252 / 255)
    static let yellow = Color(red: 230 / 255, green: 210 / 255, blue: 87 / 255)
    static let red = Color(red: 242 / 255, green: 112 / 255, blue: 90 / 255)

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

struct GoblinWordmark: View {
    /// Workbench sits on an 8-cell grid; multiples of 4pt keep its scanlines crisp.
    var size: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.14) {
            Text("gob.lin").font(.custom("Workbench-Regular", size: size, relativeTo: .largeTitle))
                .foregroundStyle(GoblinBrand.accent)
            Text("""
                \(Text("$ ").foregroundStyle(GoblinBrand.prompt))\
                \(Text("sudo ").foregroundStyle(GoblinBrand.blue))\
                \(Text("autism ").foregroundStyle(.primary))\
                \(Text("--unmuted ").foregroundStyle(GoblinBrand.purple))\
                \(Text("█").foregroundStyle(GoblinBrand.accent))
                """)
                .font(.custom("VT323-Regular", size: (size * 0.45).rounded(), relativeTo: .body))
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("gob.lin. sudo autism --unmuted")
    }
}

/// Top of every page: a title and a one-line code comment.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let comment: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.weight(.semibold))
                Text("// " + comment).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, GoblinBrand.pagePadding).padding(.top, 12).padding(.bottom, 4)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, comment: String) {
        self.init(title: title, comment: comment) { EmptyView() }
    }
}

/// A shortcut drawn as physical keys: "⌥⇧Space" becomes ⌥ ⇧ Space.
struct KeyCombo: View {
    let label: String

    var body: some View {
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = label.dropFirst(modifiers.count)
        HStack(spacing: 4) {
            ForEach(Array(modifiers.enumerated()), id: \.offset) { KeyCap(String($0.element)) }
            if !key.isEmpty { KeyCap(String(key)) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .monospaced).weight(.medium))
            .padding(.horizontal, 7).frame(minWidth: 26, minHeight: 24)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.6)).offset(y: 1.5))
    }
}
