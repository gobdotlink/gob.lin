import Foundation

/// Where the popover goblin looks: straight ahead, or toward the pointer at one of eight compass points.
public enum Gaze: String, CaseIterable, Sendable {
    case ahead, n, ne, e, se, s, sw, w, nw

    /// Clockwise from east, in screen coordinates where y grows downward.
    private static let compass: [Gaze] = [.e, .se, .s, .sw, .w, .nw, .n, .ne]

    /// The gaze for a pointer `dx`, `dy` art pixels from the eyes, so the face's rim grows with the
    /// sprite. Near a sector's edge or that rim the eyes keep `current`, so a resting pointer never
    /// makes them flicker.
    public static func toward(dx: Double, dy: Double, from current: Gaze) -> Gaze {
        if (dx * dx + dy * dy).squareRoot() < (current == .ahead ? 44 : 36) { return .ahead }
        let sector = atan2(dy, dx) / (.pi / 4)
        if let index = compass.firstIndex(of: current), abs(remainder(sector - Double(index), 8)) < 0.65 {
            return current
        }
        return compass[(Int(sector.rounded()) + 8) % 8]
    }
}
