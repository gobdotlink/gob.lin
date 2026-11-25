import Foundation

/// A call's microphone can hear more than the person at this Mac: colleagues round one laptop, a meeting room's
/// speakerphone. With Remember voices on, the microphone's voices are told apart like the call's, and their voiceprints
/// say which of them is you. Without voiceprints nothing can, so the microphone stays one voice, You.
public enum MicrophoneVoices {
    /// The least a voice must match your saved samples to be you, by the middle sample. Across twelve calls a person's
    /// own voice matched at 0.85–0.92, and round a table on a conference microphone at 0.77 and 0.83; the colleague
    /// beside them matched at 0.55, and the call coming back out of the loudspeakers at 0.35 at most.
    public static let yourVoiceFloor: Float = 0.65
    /// While a call records, the least: a voice's first few seconds, or two people the streaming model hasn't parted
    /// yet, matched your samples at 0.56–0.58 where the same voice reached 0.68 once more of it was heard. Your lines
    /// leaving You mid-call is the worse mistake, and nothing is learned from what's shown live.
    public static let liveYourVoiceFloor: Float = 0.45
    /// A microphone voice whose sound is this much the call's own (the loudspeakers, heard back) isn't someone here.
    static let callSoundShare = 0.6

    /// One voice heard on the microphone, by the speaker model's slot.
    public struct Voice: Sendable, Hashable {
        public var id: Int
        public var embedding: [Float]

        public init(id: Int, embedding: [Float]) {
            self.id = id
            self.embedding = embedding
        }
    }

    /// Which of a microphone's voices is the person at this Mac, and who else is there.
    public struct Sorted: Sendable, Equatable {
        /// The voices that are you: empty when several people were heard and none of them is known to be you.
        public var you: Set<Int> = []
        /// Everyone else, one group of voices per person, each in the order given.
        public var others: [[Int]] = []

        public init(you: Set<Int> = [], others: [[Int]] = []) {
            self.you = you
            self.others = others
        }

        /// More than you on the microphone.
        public var isShared: Bool { !others.isEmpty }
    }

    /// How alike `embedding` is to your saved samples: the middle one, so a few samples that were learned from a
    /// microphone you shared don't speak for you. Nil when there are none.
    public static func similarityToYou(_ embedding: [Float], samples: [[Float]]) -> Float? {
        let scores = samples.map { Voiceprint.similarity($0, embedding) }.sorted()
        guard !scores.isEmpty else { return nil }
        let middle = scores.count / 2
        return scores.count % 2 == 1 ? scores[middle] : (scores[middle - 1] + scores[middle]) / 2
    }

    /// Voices that sound alike within the call are one person the speaker model split. One person on the microphone is
    /// you, as it always was. With several, the one closest to your samples is you, when it's close enough; a voice
    /// that would be named as you on its own joins it. With none close enough, or before any sample of you exists,
    /// nobody is You until someone says so, as in a room. `live` asks less of the closest voice (`liveYourVoiceFloor`).
    public static func sort(_ voices: [Voice], yourSamples: [[Float]], live: Bool = false) -> Sorted {
        var groups: [[Voice]] = []
        for voice in voices {
            let alike = groups.indices.filter { index in
                groups[index].contains { Voiceprint.similarity($0.embedding, voice.embedding) >= VoiceMatching.sameVoiceThreshold }
            }
            guard let first = alike.first else {
                groups.append([voice])
                continue
            }
            groups[first].append(voice)
            // A voice like two groups joins them.
            for index in alike.dropFirst().reversed() { groups[first] += groups.remove(at: index) }
        }
        guard groups.count > 1 else { return Sorted(you: Set(voices.map(\.id))) }
        let scores = groups.map { group in
            group.compactMap { similarityToYou($0.embedding, samples: yourSamples) }.max() ?? -1
        }
        var you: Set<Int> = []
        if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= (live ? liveYourVoiceFloor : yourVoiceFloor) {
            for index in groups.indices where index == best || scores[index] >= VoiceMatching.nameThreshold {
                you.formUnion(groups[index].map(\.id))
            }
        }
        let others = groups.map { $0.map(\.id) }.filter { you.isDisjoint(with: $0) }
        return Sorted(you: you, others: others)
    }
}

extension MeetingPostProcessor {
    /// What a call's microphone voices are called before they're numbered with the call's own unnamed voices.
    static func microphoneVoiceLabel(_ voice: Int) -> String { "\u{1F}microphone \(voice)" }

    static func isMicrophoneVoiceLabel(_ label: String) -> Bool { label.hasPrefix("\u{1F}microphone ") }

    /// The voices on a call's microphone that are the call's own sound coming back out of the loudspeakers: most of
    /// what such a voice says, the call's track says at the same moment. `excluded` is left out of both: what was said
    /// while muted or dictated isn't in the transcript, and someone talking under the call while muted is still here.
    static func callSoundVoices(_ spans: [DiarizedSpan], system: [DiarizedSpan], excluded: [ClosedRange<Double>] = []) -> Set<Int> {
        let spans = excluded.isEmpty ? spans : outside(spans, joined(excluded))
        guard !system.isEmpty, !spans.isEmpty else { return [] }
        let talking = joined(system.map { $0.start...$0.end })
        var total: [Int: Double] = [:], shared: [Int: Double] = [:]
        // Both in time order, so the call's talking is walked once.
        var first = 0
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            total[span.speaker, default: 0] += span.end - span.start
            while first < talking.count, talking[first].upperBound <= span.start { first += 1 }
            var index = first
            while index < talking.count, talking[index].lowerBound < span.end {
                shared[span.speaker, default: 0] += max(0, min(talking[index].upperBound, span.end) - max(talking[index].lowerBound, span.start))
                index += 1
            }
        }
        return Set(total.filter { voice, seconds in (shared[voice] ?? 0) / seconds >= MicrophoneVoices.callSoundShare }.keys)
    }

    /// The speaker model's spans on a call's microphone without the voices that are the call's own sound.
    static func withoutCallSound(_ spans: [DiarizedSpan], system: [DiarizedSpan],
                                 excluded: [ClosedRange<Double>] = []) -> [DiarizedSpan] {
        let echoes = callSoundVoices(spans, system: system, excluded: excluded)
        return echoes.isEmpty ? spans : spans.filter { !echoes.contains($0.speaker) }
    }

    /// The parts of `spans` outside `ranges`, which are in time order and don't overlap.
    static func outside(_ spans: [DiarizedSpan], _ ranges: [ClosedRange<Double>]) -> [DiarizedSpan] {
        spans.flatMap { span -> [DiarizedSpan] in
            var pieces: [DiarizedSpan] = []
            var cursor = span.start
            for range in ranges where range.upperBound > cursor && range.lowerBound < span.end {
                if range.lowerBound > cursor { pieces.append(DiarizedSpan(speaker: span.speaker, start: cursor, end: range.lowerBound)) }
                cursor = max(cursor, range.upperBound)
            }
            if span.end > cursor { pieces.append(DiarizedSpan(speaker: span.speaker, start: cursor, end: span.end)) }
            return pieces
        }
    }

    /// Overlapping and touching ranges as one.
    static func joined(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// A call's microphone lines as turns, by who said them. `spans` are the speaker model's on the microphone. Each
    /// voice with enough clean speech gets a voiceprint; a voice without one is too slight to be a person, and its
    /// words go to whoever was talking around it. Returns the turns ("You", or a label `numberVoices` then numbers) and
    /// the spans they were made from, empty when the microphone was one voice.
    static func microphoneTurns(_ microphone: [TranscriptSegment], spans: [DiarizedSpan], system: [TranscriptTurn],
                                systemSpans: [DiarizedSpan], audio: [Float], excluded: [ClosedRange<Double>],
                                yourSamples: [[Float]], embed: VoiceprintEmbed,
                                log: @Sendable (String) -> Void) async throws -> (turns: [TranscriptTurn], spans: [DiarizedSpan]) {
        func you(_ segments: [TranscriptSegment]) -> [TranscriptTurn] {
            segments.map {
                TranscriptTurn(speaker: microphoneLabel, label: microphoneLabel, track: .microphone, start: $0.start, end: $0.end,
                               text: $0.text, words: $0.words)
            }
        }
        let heard = withoutCallSound(spans, system: systemSpans, excluded: excluded)
        guard Set(heard.map(\.speaker)).count > 1 else { return (you(microphone), []) }
        let provisional = turns(attributed(microphone, spans: heard), track: .microphone) { voice in
            voice.map(microphoneVoiceLabel) ?? microphoneLabel
        }
        let prints = try await VoiceStretches.voices(in: provisional + system, audio: [.microphone: audio], inPerson: false,
                                                     spans: [.microphone: heard], microphoneExcluded: excluded, embed: embed)
        var voices: [MicrophoneVoices.Voice] = []
        for slot in Set(heard.map(\.speaker)).sorted() {
            guard let print = prints.first(where: { $0.label == microphoneVoiceLabel(slot) && $0.track == .microphone }) else { continue }
            voices.append(.init(id: slot, embedding: print.embedding))
        }
        let sorted = MicrophoneVoices.sort(voices, yourSamples: yourSamples)
        log("microphone: \(Set(heard.map(\.speaker)).count) voices heard, \(voices.count) with enough speech; "
            + (sorted.isShared ? "\(sorted.others.count) besides \(sorted.you.isEmpty ? "nobody known to be you" : "you")" : "all you"))
        guard sorted.isShared else { return (you(microphone), []) }
        // One voice per person: each group under its first voice, you under one of yours.
        var person: [Int: Int] = [:]
        if let first = sorted.you.min() { for voice in sorted.you { person[voice] = first } }
        for group in sorted.others { for voice in group { person[voice] = group[0] } }
        let kept = heard.compactMap { span in person[span.speaker].map { DiarizedSpan(speaker: $0, start: span.start, end: span.end) } }
            .sorted { $0.start < $1.start }
        let yours = sorted.you.min()
        let result = turns(attributed(microphone, spans: kept), track: .microphone) { voice in
            guard let voice, voice != yours else { return microphoneLabel }
            return microphoneVoiceLabel(voice)
        }
        return (result, kept)
    }

    /// Numbers a shared microphone's other voices with the call's own unnamed voices, "Speaker N" in the order they
    /// first spoke, so no two voices of a meeting share a label. A call whose microphone was one voice is left as it is.
    static func numberVoices(_ turns: [TranscriptTurn]) -> [TranscriptTurn] {
        guard turns.contains(where: { isMicrophoneVoiceLabel($0.label ?? "") }) else { return turns }
        struct Key: Hashable { let track: MeetingTrack; let label: String }
        var numbers: [Key: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            guard let label = turn.label, isMicrophoneVoiceLabel(label) || MeetingTimeline.isUnnamed(label) else { continue }
            let key = Key(track: turn.track, label: label)
            if numbers[key] == nil { numbers[key] = "Speaker \(numbers.count + 1)" }
        }
        return turns.map { turn in
            guard let label = turn.label, let number = numbers[Key(track: turn.track, label: label)] else { return turn }
            var turn = turn
            turn.label = number
            turn.speaker = number
            return turn
        }
    }
}
