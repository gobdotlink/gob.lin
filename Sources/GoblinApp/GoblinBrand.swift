import AppKit
import CoreText
import os
import SwiftUI

enum MascotState: String, CaseIterable {
    case idle, recording, transcribing, warning
}

enum GoblinBrand {
    static let accent = Color(red: 87 / 255, green: 230 / 255, blue: 143 / 255)
    static let background = Color(red: 11 / 255, green: 13 / 255, blue: 16 / 255)
    static let surface = Color(red: 20 / 255, green: 24 / 255, blue: 29 / 255)

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

    static func menuImage(_ state: MascotState) -> NSImage {
        let goblin = Self.sprite(state == .recording ? "goblin-yap" : "goblin-shut")
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { bounds in
            NSGraphicsContext.current?.imageInterpolation = .none
            goblin.draw(in: bounds.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: 1)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("gob.lin").font(.custom("Workbench-Regular", size: 42, relativeTo: .largeTitle))
                .foregroundStyle(GoblinBrand.accent)
            Text("$ sudo autism --unmuted").font(.custom("VT323-Regular", size: 19, relativeTo: .body))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
