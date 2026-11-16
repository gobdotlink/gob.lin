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

    /// `modelDownload` hears the speaker model's one-time download, as `MeetingPostProcessOptions` describes;
    /// `transcribeLater` transcribes what the live transcript left for after the call.
    init(root: URL, modelDownload: (@Sendable (Double?) -> Void)? = nil, transcribeLater: MeetingLateTranscriber? = nil) {
        store = MeetingStore(root: root, options: MeetingPostProcessOptions(modelDownload: modelDownload, transcribeLater: transcribeLater))
    }

    func list() async -> [MeetingSummary] { await store.list() }
}
