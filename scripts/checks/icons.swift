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
        let containsGreen = stride(from: 0, to: bytes.count, by: 4).contains { index -> Bool in
            let red = bytes[index], green = bytes[index + 1], blue = bytes[index + 2], alpha = bytes[index + 3]
            return green > red && green > blue && alpha > 0
        }
        precondition(containsGreen, "Artwork must retain the green brand color")
        return bytes
    }

    static func checkMenuStates() {
        for scale in [1, 2] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    let rendered = MascotState.allCases.map { state in
                        let image = GoblinBrand.menuImage(state)
                        precondition(image.size == NSSize(width: 22, height: 22) && !image.isTemplate)
                        precondition(image.accessibilityDescription == "gob.lin " + state.rawValue)
                        return pixels(image, size: 22 * scale)
                    }
                    precondition(Set(rendered).count == MascotState.allCases.count, "Menu states must be distinct")
                }
            }
        }
    }

    /// The menu bar keeps one image per state, so that same image must redraw when the bar turns dark.
    static func checkMenuAppearance() {
        let idle = GoblinBrand.menuImage(.idle)
        var light = Data(), dark = Data()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = pixels(idle, size: 44) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = pixels(idle, size: 44) }
        precondition(light != dark, "A dark menu bar must redraw the cached icon with its deep green edge")
        // At 44 px: an ear-tip edge pixel of the map, and a pixel inside the state dot's ring, rows from the top.
        var recording = (light: Data(), dark: Data())
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { recording.light = pixels(GoblinBrand.menuImage(.recording), size: 44) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { recording.dark = pixels(GoblinBrand.menuImage(.recording), size: 44) }
        for (bytes, x, y, expected, what) in [(light, 6, 2, 0x08110F, "light edge"), (dark, 6, 2, 0x153C23, "dark edge"),
                                              (recording.light, 36, 42, 0x000000, "light dot ring"),
                                              (recording.dark, 36, 42, 0x153C23, "dark dot ring")] {
            let index = (y * 44 + x) * 4
            let channels = [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
            let target = [expected >> 16 & 0xFF, expected >> 8 & 0xFF, expected & 0xFF]
            precondition(bytes[index + 3] == 255 && zip(channels, target).allSatisfy { abs($0 - $1) <= 8 },
                "The \(what) must be #\(String(expected, radix: 16)), found \(channels)")
        }
    }

    static func writePreview(to path: String) throws {
        let size = NSSize(width: 660, height: 180)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 360,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 1320 * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        ("gob.lin · 22 × 22 pt menu icon · Retina rendering" as NSString).draw(at: NSPoint(x: 18, y: 152),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.black])
        for (column, state) in MascotState.allCases.enumerated() {
            let x = CGFloat(18 + column * 162)
            (state.rawValue.capitalized as NSString).draw(at: NSPoint(x: x, y: 123),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
            for (row, dark) in [false, true].enumerated() {
                let y = CGFloat(72 - row * 46)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 146, height: 36), xRadius: 5, yRadius: 5).fill()
                (dark ? "Dark" : "Light" as NSString).draw(at: NSPoint(x: x + 10, y: y + 11),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.white : NSColor.darkGray])
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    GoblinBrand.menuImage(state).draw(in: NSRect(x: x + 111, y: y + 7, width: 22, height: 22))
                }
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
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
            for name in ["goblin-shut", "goblin-yap", "goblin-look", "hand-grip", "goblin-menu", "goblin-menu@2x",
                         "goblin-menu-dark", "goblin-menu-dark@2x"] {
                let packaged = app.resourceURL!.appendingPathComponent("Assets/" + name + ".png")
                let packagedBytes = try Data(contentsOf: packaged)
                let sourceBytes = try Data(contentsOf: assets.appendingPathComponent(name + ".png"))
                precondition(packagedBytes == sourceBytes,
                    "Both packaging paths must preserve the source sprites")
                _ = pixels(NSImage(contentsOf: packaged)!, size: 64)
                if name.hasPrefix("goblin-menu") {
                    let bitmap = NSBitmapImageRep(data: packagedBytes)!
                    let dimension = name.hasSuffix("@2x") ? 44 : 22
                    precondition(bitmap.pixelsWide == dimension && bitmap.pixelsHigh == dimension && bitmap.hasAlpha,
                        "Menu artwork must ship transparent 22×22 and 44×44 representations")
                }
            }
            print("PASS signed-bundle artwork: \(path)")
        }
        for artwork in [GoblinBrand.menuArtwork(), GoblinBrand.menuArtwork(dark: true)] {
            precondition(artwork.size == NSSize(width: 22, height: 22))
            for dimension in [22, 44] {
                precondition(artwork.representations.contains { $0.pixelsWide == dimension && $0.pixelsHigh == dimension },
                    "Load both menu artwork scales at the same 22-point logical size")
            }
        }
        let originalMenu = pixels(GoblinBrand.menuImage(.idle), size: 44)
        checkMenuStates()
        checkMenuAppearance()
        if let path = ProcessInfo.processInfo.environment["GOBLIN_ICON_PREVIEW"] { try writePreview(to: path) }
        let shut = assets.appendingPathComponent("goblin-shut.png")
        let yap = assets.appendingPathComponent("goblin-yap.png")
        try FileManager.default.removeItem(at: shut)
        try Data("invalid PNG".utf8).write(to: yap)
        checkMenuStates()
        precondition(pixels(GoblinBrand.menuImage(.idle), size: 44) == originalMenu,
            "The menu must use its dedicated artwork independently of overlay sprites")
        precondition(GoblinBrand.sprite("goblin-shut").accessibilityDescription == "gob.lin artwork unavailable")
        let menu = assets.appendingPathComponent("goblin-menu.png")
        let retina = assets.appendingPathComponent("goblin-menu@2x.png")
        try Data("invalid PNG".utf8).write(to: retina)
        checkMenuStates()
        precondition(GoblinBrand.menuArtwork().representations.count == 1, "A bad Retina asset must fall back to the standard asset")
        try Data("invalid PNG".utf8).write(to: menu)
        checkMenuStates()
        precondition(GoblinBrand.menuArtwork().accessibilityDescription == "gob.lin artwork unavailable")
        try FileManager.default.removeItem(at: menu)
        checkMenuStates()
        try FileManager.default.removeItem(at: assets)
        precondition(GoblinBrand.sprite("hand-grip").accessibilityDescription == "gob.lin artwork unavailable")
        checkMenuStates()
        _ = pixels(GoblinBrand.sprite("hand-grip"), size: 64)
        print("PASS production menu states at 1x/2x; visible fallback for missing/corrupt sprites and missing Assets")
    }
}
