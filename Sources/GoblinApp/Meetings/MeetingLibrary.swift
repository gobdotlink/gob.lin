import Foundation
import GoblinMeetings

/// One live line of a recording's transcript.
struct MeetingLine: Identifiable, Hashable, Sendable {
    let id: UUID
    let speaker: String
    let start: Double
    let text: String
}

/// The app's view of `MeetingStore`: every read of a meeting folder goes through the store.
struct MeetingLibrary: Sendable {
    let store: MeetingStore
    /// People known by voice, beside the meetings.
    let people: PeopleStore

    /// `modelDownload` hears the speaker model's one-time download, as `MeetingPostProcessOptions` describes;
    /// `transcribeLater` transcribes what the live transcript left for after the call; `rememberVoices` is read at each
    /// run, and `voiceModelDownload` hears the voice model's.
    init(root: URL, modelDownload: (@Sendable (Double?) -> Void)? = nil, transcribeLater: MeetingLateTranscriber? = nil,
         rememberVoices: @escaping @Sendable () -> Bool = { false }, voiceModelDownload: (@Sendable (Double?) -> Void)? = nil) {
        let people = PeopleStore(meetingsRoot: root)
        self.people = people
        var options = MeetingPostProcessOptions(modelDownload: modelDownload, transcribeLater: transcribeLater)
        options.voices = MeetingVoiceOptions(enabled: rememberVoices, embed: VoiceprintEmbedder.lazy(download: voiceModelDownload), people: people)
        store = MeetingStore(root: root, options: options)
    }

    func list() async -> [MeetingSummary] { await store.list() }
}
