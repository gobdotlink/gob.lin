import Foundation

/// What became of inserted text while it was watched in the target app.
public enum EditOutcome: String, Codable, Sendable, Equatable {
    case kept, edited, rewritten, rejected, unobservable
}

/// Pure text logic for watching a pasted span: locate it inside the field's
/// current value, measure how far it drifted, and classify the result.
/// The pasted span is described by the text that surrounded it in the
/// expected post-insertion value, so edits to the span move it but
/// unrelated replacements lose the anchor instead of being misread.
public enum EditObservation {
    /// Fields longer than this are never sampled; whole-value reads stop being cheap.
    public static let maximumFieldCharacters = 20_000
    /// Levenshtein cell budget, mirroring the TextDiff guard.
    static let maximumDistanceCells = 1_000_000

    public enum Sample: Equatable, Sendable {
        /// The span was located; `distance` is grapheme edits from the inserted text.
        case region(text: String, distance: Int)
        /// The span was located and its contents are gone.
        case deleted
        /// The surrounding text no longer matches, so the span cannot be located.
        case anchorLost
        /// The field or the changed stretch is too large to measure honestly.
        case tooLong
    }

    /// The largest final distance still counted as an edit of the dictation
    /// rather than a rewrite. The absolute floor keeps short dictations sane:
    /// "yes" → "no" is a complete ratio change but a real edit.
    public static func editCap(insertedCount: Int) -> Int {
        max(10, insertedCount / 2)
    }

    /// Locate the inserted span in `current` and measure its drift.
    /// `prefix`/`suffix` are the expected value's text before/after the span.
    public static func evaluate(prefix: String, inserted: String, suffix: String, current: String) -> Sample {
        guard current.count <= maximumFieldCharacters else { return .tooLong }
        if current == prefix + inserted + suffix { return .region(text: inserted, distance: 0) }
        guard current.count >= prefix.count + suffix.count,
              current.hasPrefix(prefix), current.hasSuffix(suffix) else { return .anchorLost }
        let region = String(current.dropFirst(prefix.count).dropLast(suffix.count))
        if region.isEmpty, !inserted.isEmpty { return .deleted }
        guard let distance = graphemeDistance(inserted, region) else { return .tooLong }
        return .region(text: region, distance: distance)
    }

    /// Classify a finished observation. `fresh` says the last successful
    /// sample is recent enough to speak for the end of the session; without
    /// it, only an already-seen edit is evidence — silence never reads as kept.
    public static func classify(finalDistance: Int?, maximumDistance: Int?, insertedCount: Int,
                                 regionDeleted: Bool, fresh: Bool) -> EditOutcome {
        if regionDeleted { return .rejected }
        guard let distance = finalDistance, fresh || (maximumDistance ?? 0) > 0 else { return .unobservable }
        if distance == 0 { return .kept }
        return distance <= editCap(insertedCount: insertedCount) ? .edited : .rewritten
    }

    /// Levenshtein distance over grapheme clusters, common ends trimmed first.
    /// Returns nil when the changed stretch exceeds the cell budget.
    public static func graphemeDistance(_ a: String, _ b: String) -> Int? {
        let a = Array(a), b = Array(b)
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let midA = Array(a[start..<endA]), midB = Array(b[start..<endB])
        if midA.isEmpty { return midB.count }
        if midB.isEmpty { return midA.count }
        guard midA.count * midB.count <= maximumDistanceCells else { return nil }
        // Two-row dynamic programming; the strings are dictation-sized after trimming.
        var previous = Array(0...midB.count)
        var current = Array(repeating: 0, count: midB.count + 1)
        for i in 1...midA.count {
            current[0] = i
            for j in 1...midB.count {
                current[j] = midA[i - 1] == midB[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[midB.count]
    }
}
