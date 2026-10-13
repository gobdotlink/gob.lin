import AppKit
import SwiftUI

// Hidden production rendering: no recording, visible window, focus, or clipboard access.
@main
struct MascotCheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        GoblinBrand.registerFonts()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        do {
            let model = OverlayModel()
            model.phase = .listening
            model.audioLevel = 0.1
            let view = NSHostingView(rootView: DictationOverlay(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 456, height: 120),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.close() }
            func advance(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            func capture(scale: Int = 1) -> NSBitmapImageRep {
                view.setFrameSize(view.fittingSize)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                precondition(!window.isVisible && !window.isKeyWindow, "Fixture must stay offscreen")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: Int(view.bounds.width) * scale * 4, bitsPerPixel: 32)!
                bitmap.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }
            func pixels(_ bitmap: NSBitmapImageRep, _ rect: CGRect, scale: Int) -> Data {
                let crop = bitmap.cgImage!.cropping(to: CGRect(x: rect.minX * Double(scale),
                    y: rect.minY * Double(scale), width: rect.width * Double(scale), height: rect.height * Double(scale)))!
                let rep = NSBitmapImageRep(cgImage: crop)
                return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
            }
            let head = CGRect(x: 196, y: 8, width: 64, height: 42)
            let hands = CGRect(x: 209, y: 70, width: 38, height: 7)
            let waveform = CGRect(x: 24, y: 64, width: 44, height: 30)
            advance(0.2)
            for scale in [1, 2] {
                model.audioLevel = 0.1
                advance(0.2)
                let closed = capture(scale: scale)
                let closedHead = pixels(closed, head, scale: scale)
                let steadyHands = pixels(closed, hands, scale: scale)
                model.audioLevel = 0.6
                advance(0.2)
                let speaking = capture(scale: scale)
                let openHead = pixels(speaking, head, scale: scale)
                precondition(pixels(closed, waveform, scale: scale) != pixels(speaking, waveform, scale: scale),
                    "Waveform must still respond to microphone level")
                precondition(openHead != closedHead, "Mouth must respond to speech")
                for level in [0.1, 0.14, 0.6, 0.8, 0.15, 0.151, 0.149, 0.0] {
                    model.audioLevel = level
                    for _ in 0..<16 {
                        advance(0.008)
                        let frame = capture(scale: scale)
                        precondition(pixels(frame, head, scale: scale) == (level > 0.15 ? openHead : closedHead),
                            "Level updates must switch mouth pixels discretely without interpolating the head")
                        precondition(pixels(frame, hands, scale: scale) == steadyHands,
                            "Level updates must not animate the hands")
                    }
                }
                model.committedText = "A short synthetic sentence."
                model.textHeight = 44
                advance(0.1)
                let small = capture(scale: scale)
                model.tentativeText = " Another synthetic sentence makes the result area grow."
                model.textHeight = 130
                advance(0.1)
                let large = capture(scale: scale)
                precondition(large.pixelsHigh > small.pixelsHigh, "Fixture must exercise layout growth")
                precondition(pixels(large, head, scale: scale) == closedHead,
                    "Live text growth must preserve head pixels and position within the overlay")
                precondition(pixels(large, hands, scale: scale) == steadyHands,
                    "Live text growth must preserve hand pixels and position within the overlay")
                model.committedText = ""
                model.tentativeText = ""
                model.textHeight = 44
                model.audioLevel = 0.6
                advance(0.2)
                model.phase = .transcribing
                advance(0.02)
                precondition(pixels(capture(scale: scale), head, scale: scale) == closedHead,
                    "Mouth must close when listening ends")
                model.phase = .listening
                model.audioLevel = 0
                advance(0.2)
            }
            if let path = CommandLine.arguments.dropFirst().first {
                model.committedText = "A clear result, one sentence at a time."
                model.audioLevel = 0.6
                advance(0.2)
                try capture(scale: 2).representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: path))
            }
            print("PASS offscreen mascot: stable head/hands, discrete mouth, live layout growth, phase exit at 1x/2x; Reduce Motion=\(reduceMotion)")
        }
    }
}
