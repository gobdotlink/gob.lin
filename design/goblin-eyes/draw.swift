// The popover goblin looking around. Edit SLITS, then run: swift design/goblin-eyes/draw.swift
//
// Each frame is goblin-shut with a slit pupil in each eye and the glow redrawn around it. Looking
// down starts from goblin-look, so the upper lid drops too. Writes goblin-eyes-ahead.png and
// goblin-eyes-<n|ne|e|se|s|sw|w|nw>.png into Sources/GoblinApp/Assets.
import AppKit

let assets = URL(fileURLWithPath: #filePath).absoluteURL.deletingLastPathComponent()
    .appendingPathComponent("../../Sources/GoblinApp/Assets").standardized

/// The slit's top pixel in the eye on the viewer's left; the slit is three pixels tall. The other
/// eye mirrors the opposite direction, so both slits travel the same way across the face.
let SLITS: [String: (x: Int, y: Int)] = [
    "ahead": (22, 30), "n": (21, 29), "ne": (23, 30), "e": (24, 32), "se": (23, 32),
    "s": (22, 31), "sw": (21, 31), "w": (20, 29), "nw": (21, 29),
]
let MIRROR = ["ahead": "ahead", "n": "n", "ne": "nw", "e": "w", "se": "sw", "s": "s", "sw": "se", "w": "e", "nw": "ne"]

// Sampled from goblin-shut's eyes, hottest first, then the slit's ink.
let GLOW = [[255, 230, 92], [255, 170, 19], [232, 108, 8], [164, 72, 9]]
let INK = [12, 9, 14]

func load(_ name: String) -> NSBitmapImageRep {
    NSBitmapImageRep(data: try! Data(contentsOf: assets.appendingPathComponent(name + ".png")))!
}

func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    var pixel = [Int](repeating: 0, count: 4)
    image.getPixel(&pixel, atX: x, y: y)
    return pixel
}

func isEye(_ pixel: [Int]) -> Bool { pixel[3] > 0 && pixel[0] > 150 && pixel[2] < 100 && pixel[0] > pixel[1] }

for (direction, slit) in SLITS {
    let down = direction.hasPrefix("s")
    let image = load(down ? "goblin-look" : "goblin-shut")
    // Under goblin-look's lid, row 30 is shadow; the open eye starts at row 31.
    let eye = (24..<38).flatMap { y in (10..<32).map { (x: $0, y: y) } }
        .filter { isEye(color(image, $0.x, $0.y)) && (!down || $0.y > 30) }
    precondition(eye.count == (down ? 19 : 30), "The \(direction) eye has \(eye.count) pixels; did the art change?")
    precondition(eye.allSatisfy { isEye(color(image, 63 - $0.x, $0.y)) }, "The eyes must mirror each other")

    for (spot, flip) in [(slit, false), (SLITS[MIRROR[direction]!]!, true)] {
        let pupil = (0..<3).map { (x: spot.x, y: spot.y + $0) }
        precondition(pupil.allSatisfy { cell in eye.contains { $0 == cell } }, "The \(direction) slit must sit inside the eye")
        for (x, y) in eye {
            let distance = hypot(Double(x - spot.x), Double(y - spot.y - 1))
            var pixel = pupil.contains { $0 == (x, y) } ? INK
                : GLOW[distance < 1.5 ? 0 : distance < 2.3 ? 1 : distance < 3.1 ? 2 : 3]
            pixel.append(255)
            image.setPixel(&pixel, atX: flip ? 63 - x : x, y: y)
        }
    }
    try! image.representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent("goblin-eyes-\(direction).png"))
}
