import Foundation
import UserNotifications

/// "Record this call?" as a notification, with Record and Not Now, routed back to the controller.
/// Only used inside a bundled app: the notification center needs a bundle identifier.
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Record and Not Now are the buttons; `show` is a click on the notification itself, which asks again in the
    /// overlay rather than recording.
    enum Response { case record(bundleID: String), notNow(bundleID: String), show(bundleID: String) }

    var onResponse: (@MainActor (Response) -> Void)?
    private static let category = "meeting-offer"
    private static let prefix = "meeting-offer-"

    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func register() {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "record", title: "Record", options: [])
        let notNow = UNNotificationAction(identifier: "not-now", title: "Not Now", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [record, notNow],
                                                                 intentIdentifiers: [], options: [.customDismissAction])])
    }

    /// Asks once; macOS remembers the answer.
    func requestAuthorization() async -> Bool {
        guard Self.available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard Self.available else { return nil }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func offer(appName: String, bundleID: String, title: String?) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Record this call?"
        content.body = title.map { "\(appName) · \($0). Let people know you're recording." }
            ?? "\(appName) is using your mic. Let people know you're recording."
        content.categoryIdentifier = Self.category
        content.userInfo = ["bundle": bundleID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.prefix + bundleID, content: content, trigger: nil))
    }

    /// A recording sleep or the lid cut short, said when nobody was looking and the call has ended.
    func interrupted(_ sentence: String) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = "gob.lin"
        content.body = sentence
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "meeting-interrupted-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func withdraw(bundleID: String) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + bundleID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + bundleID])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.notification.request.content.categoryIdentifier == Self.category,
              let bundle = response.notification.request.content.userInfo["bundle"] as? String else { return }
        let answer: Response
        switch response.actionIdentifier {
        case "record": answer = .record(bundleID: bundle)
        case UNNotificationDefaultActionIdentifier: answer = .show(bundleID: bundle)
        default: answer = .notNow(bundleID: bundle)
        }
        Task { @MainActor in self.onResponse?(answer) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // gob.lin is a menu-bar app and usually "frontmost" only while a window is open; show it anyway.
        completionHandler([.banner, .sound])
    }
}
