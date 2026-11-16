import AVFoundation
import Foundation
import GoblinMeetings

/// Plays a meeting from its WAV files: a stretch or clip from its own track, or the whole meeting with both
/// tracks together from the playhead. In-person meetings have only the microphone.
@MainActor final class MeetingPlayer: ObservableObject {
    /// Seconds into the meeting.
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = false
    /// What's playing when it's a stretch or a clip, so its row and block can show it.
    @Published private(set) var playingRange: ClosedRange<Double>?

    private var files: [MeetingTrack: URL] = [:]
    private var players: [AVAudioPlayer] = []
    private var stopAt: Double?
    private var timer: Timer?

    var hasAudio: Bool { !files.isEmpty }

    func load(microphone: URL?, system: URL?) {
        stop()
        time = 0
        files = [:]
        if let microphone { files[.microphone] = microphone }
        if let system { files[.system] = system }
    }

    /// Plays `range` from one track, or every track when `track` is nil.
    func play(_ range: ClosedRange<Double>, track: MeetingTrack? = nil) {
        start(at: range.lowerBound, until: range.upperBound, tracks: track.map { [$0] } ?? Array(files.keys))
        playingRange = range
    }

    /// Play or pause from the playhead, with both tracks.
    func toggle() {
        if playing { pause() } else { start(at: time, until: nil, tracks: Array(files.keys)) }
    }

    func seek(_ seconds: Double) {
        let wasPlaying = playing && playingRange == nil
        stop()
        time = max(0, seconds)
        if wasPlaying { toggle() }
    }

    func pause() {
        players.forEach { $0.pause() }
        finish()
    }

    func stop() {
        players.forEach { $0.stop() }
        finish()
    }

    private func start(at seconds: Double, until end: Double?, tracks: [MeetingTrack]) {
        stop()
        let opened = tracks.compactMap { files[$0] }.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard !opened.isEmpty else { return }
        // Start every track on the same device tick so call and mic stay together.
        let at = (opened.first?.deviceCurrentTime ?? 0) + 0.05
        for player in opened {
            player.prepareToPlay()
            player.currentTime = min(seconds, player.duration)
            player.play(atTime: at)
        }
        players = opened
        time = seconds
        stopAt = end
        playing = true
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let lead = players.max(by: { $0.duration < $1.duration }) else { return }
        if lead.isPlaying { time = lead.currentTime }
        // A track that reached its end stops playing on its own.
        if let stopAt, time >= stopAt { stop() } else if !players.contains(where: \.isPlaying) { stop() }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        players = []
        playing = false
        stopAt = nil
        playingRange = nil
    }
}
