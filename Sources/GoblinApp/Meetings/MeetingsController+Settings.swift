import Foundation
import GoblinMeetings

/// The UserDefaults the review and settings surfaces share with the recording side. Kept apart from
/// `MeetingsController.swift` so the two can change independently.
extension MeetingsController {
    /// The one-time setup sheet has been through, so turning Meetings on again doesn't show it.
    static let setupFinishedKey = "meetings.setupFinished"

    typealias CallPolicy = AppPolicy

    /// One row of "When a call starts": a native call app, or every browser at once.
    struct CallAppRow: Identifiable, Hashable {
        let name: String
        let bundleIDs: [String]
        var detail: String?
        var id: String { name }
        /// The bundle to draw the icon from.
        var iconBundleID: String { bundleIDs[0] }
    }

    static var callAppRows: [CallAppRow] {
        let native = CallApp.known.filter { $0.kind == .native }.map { CallAppRow(name: $0.name, bundleIDs: $0.bundleIDs) }
        let browsers = CallApp.known.filter { $0.kind == .browser }.flatMap(\.bundleIDs)
        return native + [CallAppRow(name: "Meetings in a browser", bundleIDs: browsers,
                                    detail: "Chrome, Safari, Arc and others, when the tab looks like a meeting.")]
    }

    var setupFinished: Bool {
        get { defaults.bool(forKey: Self.setupFinishedKey) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.setupFinishedKey) }
    }

    /// A row's policy: its first bundle's, since Settings always sets a row's bundles together.
    func policy(for row: CallAppRow) -> CallPolicy { policy(for: row.bundleIDs[0]) }

    func setPolicy(_ policy: CallPolicy, for row: CallAppRow) {
        objectWillChange.send()
        for bundleID in row.bundleIDs { setPolicy(policy, for: bundleID) }
    }
}

extension MeetingsController.AppPolicy {
    var title: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

extension Notification.Name {
    /// A meeting's names, audio or existence changed from the Meetings page, so counts elsewhere refresh.
    static let meetingsEdited = Notification.Name("app.goblin.meetings.edited")
}
