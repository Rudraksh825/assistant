import AppKit
import StewardKit

/// Sleep/wake, lock/unlock, display changes and meeting apps starting, posted to `/sensors/event`.
@MainActor
final class SystemEventSensor {
    private let client: BrainClient
    private let activity: ActivitySensor
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "com.hnc.Discord",
    ]

    init(client: BrainClient, activity: ActivitySensor) {
        self.client = client
        self.activity = activity
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        on(workspace, NSWorkspace.willSleepNotification) { s, _ in s.post("sleep", pausing: true) }
        on(workspace, NSWorkspace.didWakeNotification) { s, _ in s.post("wake") }
        on(distributed, .init("com.apple.screenIsLocked")) { s, _ in s.post("lock", pausing: true) }
        on(distributed, .init("com.apple.screenIsUnlocked")) { s, _ in s.post("unlock") }
        on(.default, NSApplication.didChangeScreenParametersNotification) { s, _ in
            s.post("display_change", data: ["screens": .number(Double(NSScreen.screens.count))])
        }
        on(workspace, NSWorkspace.didLaunchApplicationNotification) { s, note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, Self.meetingApps.contains(id) else { return }
            s.post("meeting_app_started", data: ["bundleId": .string(id), "app": .string(app.localizedName ?? id)])
        }
    }

    private func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (SystemEventSensor, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let self { handler(self, note) }
            }
        }
        tokens.append((center, token))
    }

    private func post(_ kind: String, pausing: Bool = false, data: JSONValue? = nil) {
        if pausing { activity.pause() }
        Log.info("sensor event: \(kind)")
        Task { try? await client.postSensorEvent(kind, data: data) }
    }
}
