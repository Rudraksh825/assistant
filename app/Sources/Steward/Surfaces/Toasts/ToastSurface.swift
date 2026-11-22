import AppKit
import StewardKit

/// Turns brain events into toasts under the notch and, for priority 2, system notifications. The stack
/// itself is drawn by the notch panels (`ToastStack`); this decides what goes on it and when.
@MainActor
final class ToastSurface: Surface {
    private let ambient: AmbientState
    private var handler: UUID?
    private weak var store: AppStore?

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        let store = app.store, center = ambient.toasts
        self.store = store

        center.onArrive = { [weak center] item in
            // One gentle tick for the things that need the user; lesser toasts arrive silently.
            if item.priority >= 2 { Haptics.tick() }
            Log.info("toasts: showing \(item.id) (priority \(item.priority)) on display \(center?.displayID.map(String.init) ?? "none")")
        }
        center.onUnseen = { item in
            if case .nudge(let nudge) = item.kind { SystemNotifier.post(nudge) }
        }
        center.onUserDismiss = { store.dismiss($0) }

        SystemNotifier.start(
            onOpen: { _, kind in app.showMainWindow(Self.route(for: kind)) },
            onAction: { nudgeId, actionId in
                guard let nudge = store.nudges.first(where: { $0.id == nudgeId }), let action = nudge.actions.first(where: { $0.id == actionId }) else {
                    app.showMainWindow()
                    return
                }
                store.act(on: nudge, action)
            })

        handler = store.onEvent { [weak self] event in self?.handle(event, store: store) }

        // Decided somewhere else (main window, another toast): the toast has nothing left to ask.
        watch { Set(store.approvals.map(\.id)) } onChange: { center.prune(prefix: "approval:", keeping: $0) }
        watch { Set(store.questions.map(\.id)) } onChange: { center.prune(prefix: "question:", keeping: $0) }
        // shortcut: "do not disturb" is a live meeting only. Screen sharing has no cheap public signal;
        // macOS already holds system banners back while the display is shared or mirrored.
        watch { store.snapshot?.currentMeeting != nil } onChange: { center.setQuiet($0) }
        Log.info("toasts: started (system notifications \(SystemNotifier.available ? "available" : "unavailable: no bundle"))")
    }

    func stop() {
        if let handler { store?.removeHandler(handler) }
        handler = nil
    }

    private func handle(_ event: BrainEvent, store: AppStore) {
        let center = ambient.toasts
        switch event {
        case .nudge(let nudge):
            guard nudge.dismissedAt == nil else {
                center.dismiss("nudge:\(nudge.id)")
                return
            }
            let quiet = store.snapshot?.currentMeeting != nil
            let plan = ToastDelivery.plan(priority: nudge.priority, userActive: Self.userIsActive, quiet: quiet)
            // An approval or question arrives twice: as itself (with its own richer toast) and as a nudge.
            let covered = (nudge.kind == .approval && !store.approvals.isEmpty) || (nudge.kind == .question && !store.questions.isEmpty)
            if plan.toast && !covered {
                center.show(.nudge(nudge), lifetime: ToastDelivery.lifetime(priority: nudge.priority), expiresAt: nudge.expiresAt, followUpIfUnseen: plan.notifyIfUnseen)
            }
            if plan.notifyNow || (covered && nudge.priority >= 2 && !Self.userIsActive) { SystemNotifier.post(nudge) }
        case .nudgeDismissed(let id):
            center.dismiss("nudge:\(id)")
            SystemNotifier.withdraw(nudgeId: id)
        case .chatQuestion(let question):
            center.dismissNudges(of: .question)
            center.show(.question(question), lifetime: ToastDelivery.lifetime(priority: 2, needsDecision: true))
        case .approvalRequested(let approval):
            center.dismissNudges(of: .approval)
            center.show(.approval(approval), lifetime: ToastDelivery.lifetime(priority: 2, needsDecision: true))
        case .uiCommand(let command) where command.command == .toast:
            let args = command.args ?? .null
            guard let text = args["text"].string ?? args["title"].string, !text.isEmpty else { return }
            let item = ToastItem(id: "message:\(UUID().uuidString)", kind: .message, title: text, body: args["body"].string ?? "",
                                 priority: args["priority"].int ?? 1)
            center.show(item, lifetime: ToastDelivery.lifetime(priority: item.priority))
        default:
            break
        }
    }

    /// At the machine: input in the last 90 s and the screen not locked.
    static var userIsActive: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return idle < 90 && !locked
    }

    static func route(for kind: NudgeKind) -> Route {
        switch kind {
        case .session: .sessions
        case .meeting: .meetings
        case .approval, .insight: .inbox
        case .question: .agent
        case .brief: .notes
        case .budget, .system: .settings
        case .task, .unknown: .today
        }
    }
}

extension ToastActions {
    init(app: AppContext) {
        let store = app.store
        act = { store.act(on: $0, $1) }
        approve = { store.approve($0) }
        deny = { store.deny($0) }
        answer = { store.answer($0, $1) }
        open = { item in
            switch item.kind {
            case .nudge(let nudge): app.showMainWindow(ToastSurface.route(for: nudge.kind))
            case .approval: app.showMainWindow(.inbox)
            case .question: app.showMainWindow(.agent)
            case .message: break
            }
        }
    }
}
