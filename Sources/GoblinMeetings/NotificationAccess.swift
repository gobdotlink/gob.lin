import Foundation
import UserNotifications

/// What Allow does for Notifications, from what macOS last said about gob.lin.
public enum NotificationAccess {
    public enum Step: Equatable, Sendable {
        /// macOS hasn't asked yet: ask, then read the answer.
        case request
        /// Turned off before, so asking again shows nothing: open gob.lin's row in System Settings › Notifications.
        case openSettings
        /// Already allowed.
        case none
    }

    public static func step(for status: UNAuthorizationStatus?) -> Step {
        switch status {
        case .authorized, .provisional, .ephemeral: .none
        case .denied: .openSettings
        default: .request
        }
    }

    /// System Settings › Notifications, at this app's entry when `bundleID` is known.
    public static func settingsURL(bundleID: String?) -> URL {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleID, let id = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return URL(string: base)! }
        return URL(string: base + "?id=" + id)!
    }
}
