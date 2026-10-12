import AppKit
import CoreText
import SwiftUI

enum MascotState: String, CaseIterable {
    case idle, recording, transcribing, warning
}

@MainActor
enum GoblinBrand {
    static let accent = Color(red: 87 / 255, green: 230 / 255, blue: 143 / 255)
    static let background = Color(red: 11 / 255, green: 13 / 255, blue: 16 / 255)
    static let surface = Color(red: 20 / 255, green: 24 / 255, blue: 29 / 255)

    static var assetDirectory: URL? {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Assets", isDirectory: true)
        if let directory, FileManager.default.fileExists(atPath: directory.path) { return directory }
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
              let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 64, height: 64)) }
        image.isTemplate = false
        return image
    }

    static func menuImage(_ state: MascotState) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { bounds in
            NSGraphicsContext.current?.imageInterpolation = .none
            let goblin = Self.sprite(state == .recording ? "goblin-yap" : "goblin-shut")
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
