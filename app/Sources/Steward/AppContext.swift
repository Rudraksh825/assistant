import AppKit
import StewardKit

/// What every surface and screen gets: the store plus the app-level services and actions.
/// In SwiftUI: `@Environment(AppContext.self) private var app`.
@MainActor @Observable
final class AppContext {
    let store: AppStore
    let supervisor: BrainSupervisor
    let hotkeys = HotkeyCenter()
    let activity: ActivitySensor
    let systemEvents: SystemEventSensor
    let focuser = WindowFocuser()

    /// The main window's current screen. Set it (or call `showMainWindow`) to navigate.
    var route: Route = .today
    var showOnboarding = false

    @ObservationIgnored private lazy var mainWindow = MainWindowController(app: self)

    init(client: BrainClient = BrainClient()) {
        store = AppStore(client: client)
        supervisor = BrainSupervisor(store: store)
        activity = ActivitySensor(client: client)
        systemEvents = SystemEventSensor(client: client, activity: activity)
    }

    /// Brings the main window forward. Only call from a user action (click, hotkey, Dock).
    func showMainWindow(_ route: Route? = nil, activate: Bool = true) {
        if let route { self.route = route }
        mainWindow.show(activate: activate)
    }

    /// Opens a screen by its route name and, when `path` is one record's API path ("/notes/<id>"), that record.
    func open(view: String, path: String? = nil) {
        // Approvals have no screen of their own: they sit at the top of the Inbox.
        guard let route = view == "approvals" ? .inbox : Route(rawValue: view) else { return }
        let parts = path?.split(separator: "/") ?? []
        let id = parts.count == 2 ? String(parts[1]) : nil
        let model = mainWindow.model
        switch route {
        case .notes: model.focusNoteId = id
        case .meetings: model.focusMeetingId = id
        case .sessions: model.focusSessionId = id
        case .people: model.focusPersonId = id
        case .projects: model.focusProjectId = id
        case .today, .tasks: if let id { model.inspectedTaskId = id }
        case .inbox: if view == "approvals" { model.focusApprovals += 1 } else if parts.first == "suggestions" { model.focusSuggestionId = id }
        case .agent, .activity, .settings, .guide: break
        }
        showMainWindow(route)
    }

    /// Jumps to the window a session lives in. When no open window holds it, nothing is launched: the
    /// session's own page in Steward opens instead.
    /// The main window's UI state; the chat window shares its context chips and hands its thread over.
    var windowModel: MainWindowModel { mainWindow.model }

    func focus(_ session: CodeSession) {
        let result = focuser.focus(directory: session.cwd)
        Log.info("focus session \(session.id): \(result)")
        if result == .notFound { open(view: Route.sessions.rawValue, path: "/sessions/\(session.id)") }
    }

    /// Web links only (and the app's own links into System Settings). These strings come from the agent and from
    /// synced data, and other schemes do things rather than show them: file: runs scripts, shortcuts: runs shortcuts,
    /// mailto: and sms: compose messages.
    static let openable: Set<String> = ["https", "http", "x-apple.systempreferences"]

    func open(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), Self.openable.contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the user is looking at right now, attached to captures.
    var captureContext: CaptureContext {
        CaptureContext(app: activity.frontmost?.app, title: activity.frontmost?.title)
    }

    /// The commands the foundation owns. `show_note`, `speak` and `toast` belong to surfaces, which
    /// listen on `store.onEvent` themselves.
    func handle(_ command: BrainEvent.UICommand) {
        let args = command.args ?? .null
        switch command.command {
        case .openView:
            open(view: args["view"].string ?? "", path: args["path"].string)
        case .focusSession:
            if let session = store.sessions.first(where: { $0.id == args["sessionId"].string }) { focus(session) }
        case .openURL:
            open(args["url"].string)
        case .showNote, .speak, .toast, .unknown:
            break
        }
    }
}
