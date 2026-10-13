import AppKit

// Simulate SwiftPM's aborting accessor when a relocated app has no separate resource bundle.
#if SWIFT_PACKAGE
extension Bundle {
    static var module: Bundle { fatalError("Packaged artwork must not depend on the SwiftPM resource bundle") }
}
#endif

// Offscreen production rendering only: no NSApplication, windows, permissions, or live services.
@main
struct IconCheck {
    static func pixels(_ image: NSImage, size: Int) -> Data {
        precondition(image.isValid, "Artwork must decode")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let bytes = Data(bytes: bitmap.bitmapData!, count: size * size * 4)
        precondition(stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count > size,
            "Artwork must have visible pixels")
        precondition(stride(from: 0, to: bytes.count, by: 4).contains {
            bytes[$0 + 1] > bytes[$0] && bytes[$0 + 1] > bytes[$0 + 2] && bytes[$0 + 3] > 0
        }, "Artwork must retain the green brand color")
        return bytes
    }

    static func checkMenuStates() {
        for scale in [1, 2] {
            let rendered = MascotState.allCases.map { state in
                let image = GoblinBrand.menuImage(state)
                precondition(image.size == NSSize(width: 22, height: 22) && !image.isTemplate)
                precondition(image.accessibilityDescription == "gob.lin " + state.rawValue)
                return pixels(image, size: 22 * scale)
            }
            precondition(Set(rendered).count == MascotState.allCases.count, "Menu states must be distinct")
        }
    }

    static func main() throws {
        precondition(Bundle.main.bundleURL.pathExtension == "app")
        let assets = GoblinBrand.assetDirectory!
        for path in CommandLine.arguments.dropFirst() {
            let app = Bundle(url: URL(fileURLWithPath: path))!
            precondition(app.bundleIdentifier == "app.goblin.dictation")
            precondition(app.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
                "The signed app must remain menu-bar-only")
            precondition(app.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Goblin")
            let iconURL = app.url(forResource: "Goblin", withExtension: "icns")!
            let packagedIcon = try Data(contentsOf: iconURL)
            let sourceIcon = try Data(contentsOf: URL(fileURLWithPath: "Resources/Goblin.icns"))
            precondition(packagedIcon == sourceIcon, "The app must package the current source icon")
            let icon = NSImage(contentsOf: iconURL)!
            precondition(icon.representations.contains { $0.pixelsWide == 16 })
            precondition(icon.representations.contains { $0.pixelsWide == 1024 })
            for size in [16, 32, 128, 256, 512, 1024] { _ = pixels(icon, size: size) }
            for name in ["goblin-shut", "goblin-yap", "hands"] {
                let packaged = app.resourceURL!.appendingPathComponent("Assets/" + name + ".png")
                let packagedBytes = try Data(contentsOf: packaged)
                let sourceBytes = try Data(contentsOf: assets.appendingPathComponent(name + ".png"))
                precondition(packagedBytes == sourceBytes,
                    "Both packaging paths must preserve the source sprites")
                _ = pixels(NSImage(contentsOf: packaged)!, size: 64)
            }
            print("PASS signed-bundle artwork: \(path)")
        }
        checkMenuStates()
        let shut = assets.appendingPathComponent("goblin-shut.png")
        let yap = assets.appendingPathComponent("goblin-yap.png")
        try FileManager.default.removeItem(at: shut)
        try Data("invalid PNG".utf8).write(to: yap)
        checkMenuStates()
        precondition(GoblinBrand.sprite("goblin-shut").accessibilityDescription == "gob.lin artwork unavailable")
        try FileManager.default.removeItem(at: assets)
        precondition(GoblinBrand.sprite("hands").accessibilityDescription == "gob.lin artwork unavailable")
        checkMenuStates()
        _ = pixels(GoblinBrand.sprite("hands"), size: 64)
        print("PASS production menu states at 1x/2x; visible fallback for missing/corrupt sprites and missing Assets")
    }
}
