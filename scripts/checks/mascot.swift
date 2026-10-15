import AppKit
import SwiftUI

// Hidden production rendering: no recording, visible window, focus, or clipboard access.
@main
struct MascotCheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        GoblinBrand.registerFonts()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let model = OverlayModel()
        model.presented = true
        model.phase = .listening
        let size = DictationOverlay.panelSize
        let view = NSHostingView(rootView: DictationOverlay(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.close() }
        func advance(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func capture(scale: Int) -> NSBitmapImageRep {
            view.setFrameSize(size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            precondition(!window.isVisible && !window.isKeyWindow, "Fixture must stay offscreen")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width) * scale * 4, bitsPerPixel: 32)!
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func pixels(_ bitmap: NSBitmapImageRep, _ rect: CGRect, scale: Int) -> Data {
            let crop = bitmap.cgImage!.cropping(to: CGRect(x: rect.minX * Double(scale), y: rect.minY * Double(scale),
                width: rect.width * Double(scale), height: rect.height * Double(scale)))!
            let rep = NSBitmapImageRep(cgImage: crop)
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        /// Same sprite where the reference is opaque; the transparent corners may show the bubble's shadow.
        func sameSprite(_ reference: Data, _ other: Data) -> Bool {
            guard reference.count == other.count else { return false }
            return stride(from: 0, to: reference.count, by: 4).allSatisfy { index in
                reference[index + 3] != 255 || reference[index..<index + 4] == other[index..<index + 4]
            }
        }
        // The goblin sits in the content's bottom-right corner; the bubble fills the column to its left.
        let margin = DictationOverlay.margin, content = DictationOverlay.contentSize
        let head = CGRect(x: margin + content.width - 128, y: margin + content.height - 128, width: 128, height: 128)
        let bubble = CGRect(x: margin, y: margin, width: content.width - 128 - 12, height: content.height)
        model.committedText = "A short synthetic sentence."
        advance(0.2)
        for scale in [1, 2] {
            model.audioLevel = 0.05
            advance(0.2)
            let closed = capture(scale: scale)
            let closedHead = pixels(closed, head, scale: scale)
            model.audioLevel = 0.6
            advance(0.2)
            let speaking = capture(scale: scale)
            let openHead = pixels(speaking, head, scale: scale)
            precondition(openHead != closedHead, "Mouth must respond to speech")
            precondition(pixels(closed, bubble, scale: scale) != pixels(speaking, bubble, scale: scale), "The meter must respond to level")
            // Between the thresholds the mouth keeps its current frame, so it never flaps.
            model.audioLevel = 0.15
            advance(0.2)
            precondition(pixels(capture(scale: scale), head, scale: scale) == openHead, "Hysteresis must hold an open mouth at mid level")
            for level in [0.1, 0.15, 0.6, 0.8, 0.15, 0.05] {
                model.audioLevel = level
                for _ in 0..<12 {
                    advance(0.008)
                    let frame = pixels(capture(scale: scale), head, scale: scale)
                    precondition(frame == openHead || frame == closedHead, "Mouth changes must swap frames, never interpolate")
                }
                advance(0.1)
            }
            model.audioLevel = 0.05
            advance(0.2)
            model.tentativeText = " Another synthetic sentence makes the bubble grow by a line or two, then more."
            advance(0.2)
            precondition(sameSprite(closedHead, pixels(capture(scale: scale), head, scale: scale)), "Text growth must not move or redraw the goblin")
            model.phase = .transcribing
            advance(0.2)
            let looking = pixels(capture(scale: scale), head, scale: scale)
            precondition(looking != closedHead && looking != openHead, "Transcribing must show its own face")
            model.tentativeText = ""
            model.phase = .listening
            advance(0.2)
        }
        if let path = CommandLine.arguments.dropFirst().first {
            model.audioLevel = 0.6
            advance(0.2)
            try capture(scale: 2).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        print("PASS offscreen mascot: discrete mouth with hysteresis, responsive meter, stable goblin during text growth, transcribing face at 1x/2x; Reduce Motion=\(reduceMotion)")
    }
}
