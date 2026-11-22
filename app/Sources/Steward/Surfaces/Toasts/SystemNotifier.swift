import Foundation
import UserNotifications
import StewardKit

/// System notifications for priority-2 nudges. A nudge's actions become the notification's buttons;
/// clicking the banner opens the view the nudge is about.
@MainActor
enum SystemNotifier {
    /// `UNUserNotificationCenter.current()` raises outside an app bundle (`swift run`), so check first.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    private static let delegate = Delegate()
    private static var categories: [String: UNNotificationCategory] = [:]

    /// - Parameters:
    ///   - onOpen: the banner itself was clicked.
    ///   - onAction: one of the nudge's action buttons was clicked.
    static func start(onOpen: @escaping @MainActor (_ nudgeId: String, _ kind: NudgeKind) -> Void,
                      onAction: @escaping @MainActor (_ nudgeId: String, _ actionId: String) -> Void) {
        guard available else { return }
        delegate.onOpen = onOpen
        delegate.onAction = onAction
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func post(_ nudge: Nudge) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = nudge.body
        content.userInfo = ["nudgeId": nudge.id, "kind": nudge.kind.rawValue]
        content.interruptionLevel = .active

        let actions = nudge.actions.filter { $0.kind != .dismiss }.prefix(3)
        if !actions.isEmpty {
            // A category is a fixed set of buttons, so each distinct set of actions gets its own.
            let id = "steward." + actions.map { "\($0.id)=\($0.label)" }.joined(separator: "|")
            if categories[id] == nil {
                categories[id] = UNNotificationCategory(
                    identifier: id,
                    actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.label, options: $0.kind == .api ? [] : [.foreground]) },
                    intentIdentifiers: [])
                UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
            }
            content.categoryIdentifier = id
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier(nudge.id), content: content, trigger: nil))
    }

    /// The nudge was dealt with in the app; the banner in Notification Centre is stale.
    static func withdraw(nudgeId: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(nudgeId)])
    }

    private static func identifier(_ nudgeId: String) -> String { "nudge.\(nudgeId)" }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        var onOpen: (@MainActor (String, NudgeKind) -> Void)?
        var onAction: (@MainActor (String, String) -> Void)?

        // Without this a notification posted while Steward is frontmost is silently dropped.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let info = response.notification.request.content.userInfo
            guard let nudgeId = info["nudgeId"] as? String else { return }
            let kind = NudgeKind(rawValue: info["kind"] as? String ?? "") ?? .unknown
            let action = response.actionIdentifier
            await MainActor.run {
                switch action {
                case UNNotificationDefaultActionIdentifier: self.onOpen?(nudgeId, kind)
                case UNNotificationDismissActionIdentifier: break
                default: self.onAction?(nudgeId, action)
                }
            }
        }
    }
}
