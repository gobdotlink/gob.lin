import Foundation
import GoblinCore
import os

/// Where meetings live on disk and what each meeting folder holds. One folder per recording,
/// named "<yyyy-MM-dd HHmmss> <title>"; the folder name is the meeting's ID.
public enum MeetingStorage {
    private static let configuredRoot = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// `~/Library/Application Support/gob.lin/Meetings`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/Meetings", isDirectory: true)
    }

    /// The folder new meetings are written to. Set it once at launch to move meetings elsewhere;
    /// readers and writers on any thread see the same value.
    public static var root: URL {
        get { configuredRoot.withLock { $0 } ?? defaultRoot }
        set { configuredRoot.withLock { $0 = newValue.standardizedFileURL } }
    }

    /// Hidden defaults key (`defaults write app.goblin.dictation meetingsDebugAccessibilityLog -bool YES`) that keeps the
    /// raw logs test captures need: each meeting's accessibility.jsonl and the detector's detection.jsonl. Off by default,
    /// since they hold call-window text and every app's mic use.
    public static let debugLogKey = "meetingsDebugAccessibilityLog"
    public static var debugLogging: Bool { UserDefaults.standard.bool(forKey: debugLogKey) }

    // File names inside a meeting folder.
    public static let sessionFile = "session.json"
    public static let segmentsFile = "segments.jsonl"
    public static let eventsFile = "events.log"
    /// The call window's raw text, written only with `debugLogging` on.
    public static let accessibilityFile = "accessibility.jsonl"
    public static let muteFile = "mute.jsonl"
    /// Turns attributed to their diarized label (or "You"), before speakers.json names are applied.
    public static let attributedFile = "attributed.json"
    public static let transcriptFile = "transcript.json"
    public static let transcriptMarkdownFile = "transcript.md"
    public static let reportFile = "postprocess.json"
    public static let diarizationFile = "diarization.json"
    /// Diarized label → the name a person gave that speaker.
    public static let speakersFile = "speakers.json"
    /// A rerun's new attribution and the names carried onto it, as one file, while they replace attributed.json and
    /// speakers.json; one left behind is finished first by the next run or render.
    public static let relabelFile = "relabel.json"
    /// Participant names read from the call window while recording.
    public static let participantsFile = "participants.json"
    /// Dictation spans in meeting seconds; when present the post-processor reads them instead of
    /// the dictation history, so an exported fixture replays the same way on another machine.
    public static let dictationsFile = "dictations.json"
    /// Written by `MeetingSession` during a recording, one take per line.
    public static let liveDictationsFile = "dictations.jsonl"
    /// Moments marked during the call, one per line: `{"t": <seconds from session start>, "label": "<optional>"}`.
    /// Written by the app while recording (see `MeetingMarks`), read by the meeting's review.
    public static let marksFile = "marks.jsonl"
    /// Speech the live transcript didn't get to (it fell behind, or the speech model couldn't run), one chunk per
    /// line: `{"track": "system", "startSample": 0, "sampleCount": 16000}`. Processing transcribes them from the audio.
    public static let deferredFile = "deferred.jsonl"
    /// What the person changed after recording: title, star, and what the app learned (interrupted, failure).
    public static let metadataFile = "meeting.json"

    public static func audioFile(_ track: MeetingTrack) -> String { "\(track.fileStem).wav" }
    public static func timingFile(_ track: MeetingTrack) -> String { "\(track.fileStem).timing.jsonl" }

    static let folderDateFormat = "yyyy-MM-dd HHmmss"

    static func newDirectory(title: String, date: Date) throws -> URL {
        try newDirectory(title: title, date: date, in: root)
    }

    /// Creates a fresh folder, never reusing one: a second meeting with the same title in the same
    /// second gets " 2" appended.
    static func newDirectory(title: String, date: Date, in root: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = folderDateFormat
        let base = "\(formatter.string(from: date)) \(safeName(title))"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var name = base
        var suffix = 2
        while true {
            let url = root.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                name = "\(base) \(suffix)"
                suffix += 1
            }
        }
    }

    /// A title made safe as one path component.
    static func safeName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.drop { $0 == "." }.prefix(80))
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    /// The start date encoded in a folder name, for folders whose session.json never got written.
    static func date(fromFolderName name: String) -> Date? {
        guard name.count >= 17 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = folderDateFormat
        return formatter.date(from: String(name.prefix(17)))
    }

    /// The title encoded in a folder name.
    static func title(fromFolderName name: String) -> String {
        name.count > 18 && date(fromFolderName: name) != nil ? String(name.dropFirst(18)) : name
    }

    /// The developer flag that keeps meeting audio past the retention window, for benchmarking:
    /// the Boolean `meetingsKeepAudio` in gob.lin's defaults domain (`app.goblin.dictation`), set with
    /// `defaults write app.goblin.dictation meetingsKeepAudio -bool true`. Deliberately not in Settings.
    public static let keepAudioDefaultsKey = "meetingsKeepAudio"

    public static var keepAudioFlag: Bool {
        // Inside the app its own domain is `.standard`; a suite named after the app's own bundle ID does not work.
        let defaults = Bundle.main.bundleIdentifier == GoblinMetadata.bundleIdentifier
            ? .standard : (UserDefaults(suiteName: GoblinMetadata.bundleIdentifier) ?? .standard)
        return defaults.bool(forKey: keepAudioDefaultsKey)
    }
}
