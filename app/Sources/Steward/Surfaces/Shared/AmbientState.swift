import AppKit
import StewardKit

/// The store, sliced for the ambient surfaces. The store swaps whole snapshots on every refetch; each
/// field here is assigned only when its value really changed, so a view re-renders for its own slice.
@MainActor @Observable
final class AmbientModel {
    var now: TaskItem?
    /// When the current task became the current task, for the running timer.
    var nowSince: Date?
    var next: [TaskItem] = []
    /// Sessions that need the user first, then working, then idle.
    var sessions: [CodeSession] = []
    var sessionStates: [SessionState] = []
    var meeting: Meeting?
    var meetingLive = false
    var approvals: [Approval] = []
    var questions: [BrainEvent.ChatQuestion] = []
    var agentBusy = false
    var agentActivity: String?
    var suggestionCount = 0
    var online = false
    var liveNote: Note?
    var projectTitles: [String: String] = [:]
    /// The most recent chats with the agent, newest first, for the notch tray.
    var chats: [ChatPeek] = []
    /// What the collapsed notch's right ear shows; kept current by the notch surface.
    var indicator = NotchIndicator.none

    static let nextCount = 4

    func bind(to store: AppStore) {
        watch { store.snapshot?.now } onChange: { [weak self] in self?.setNow($0) }
        watch { Array((store.snapshot?.top ?? []).filter { $0.id != store.snapshot?.now?.id }.prefix(Self.nextCount)) } onChange: { [weak self] in self?.next = $0 }
        watch { Self.ranked(store.sessions) } onChange: { [weak self] in
            self?.sessions = $0
            // Idle sessions say nothing at a glance; the dots are for what is moving or needs the user.
            let live: Set<SessionState> = [.blocked, .waiting, .working]
            let states: [SessionState] = $0.map(\.state).filter(live.contains)
            if states != self?.sessionStates { self?.sessionStates = states }
        }
        watch { store.snapshot?.currentMeeting ?? store.snapshot?.nextMeeting } onChange: { [weak self] in self?.meeting = $0 }
        watch { store.snapshot?.currentMeeting != nil } onChange: { [weak self] in self?.meetingLive = $0 }
        watch { store.approvals } onChange: { [weak self] in self?.approvals = $0 }
        watch { store.questions } onChange: { [weak self] in self?.questions = $0 }
        watch { store.agent.busy } onChange: { [weak self] in self?.agentBusy = $0 }
        watch { store.agent.activity } onChange: { [weak self] in self?.agentActivity = $0 }
        watch { store.suggestions.count } onChange: { [weak self] in self?.suggestionCount = $0 }
        watch { ChatPeek.recent(store) } onChange: { [weak self] in self?.chats = $0 }
        watch { store.connection.isOnline } onChange: { [weak self] in self?.online = $0 }
        watch { store.snapshot?.liveNote } onChange: { [weak self] in self?.liveNote = $0 }
        watch { Dictionary(store.tree.allProjects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) } onChange: { [weak self] in self?.projectTitles = $0 }
    }

    static func ranked(_ sessions: [CodeSession]) -> [CodeSession] {
        func rank(_ state: SessionState) -> Int {
            switch state {
            case .blocked: 0
            case .waiting: 1
            case .working: 2
            default: 3
            }
        }
        return sessions.sorted { (rank($0.state), $0.stateSince) < (rank($1.state), $1.stateSince) }
    }

    private func setNow(_ task: TaskItem?) {
        now = task
        nowSince = task.map { $0.startedAt ?? $0.updatedAt }
    }
}

/// One chat as the notch tray shows it.
struct ChatPeek: Identifiable, Equatable {
    enum State: Equatable { case answering, needsYou, idle }

    var id: String
    var title: String
    var updatedAt: Date
    var state: State

    static let count = 3

    @MainActor static func recent(_ store: AppStore) -> [ChatPeek] {
        store.threads.prefix(count).map { thread in
            let waiting = store.questions.contains { $0.threadId == thread.id } || store.approvals.contains { $0.threadId == thread.id }
            let state: State = waiting ? .needsYou : store.streamingThreads.contains(thread.id) ? .answering : .idle
            return ChatPeek(id: thread.id, title: thread.title.isEmpty ? "Untitled chat" : thread.title, updatedAt: thread.updatedAt, state: state)
        }
    }
}

/// What a tap in any ambient view can do. A value so the views render without an `AppContext`.
@MainActor
struct AmbientActions {
    var complete: (TaskItem) -> Void = { _ in }
    var start: (TaskItem) -> Void = { _ in }
    var snooze: (TaskItem, Date) -> Void = { _, _ in }
    /// Opens the task's place in the main window.
    var open: (TaskItem) -> Void = { _ in }
    var focus: (CodeSession) -> Void = { _ in }
    var join: (Meeting) -> Void = { _ in }
    var approve: (Approval) -> Void = { _ in }
    var deny: (Approval) -> Void = { _ in }
    var answer: (BrainEvent.ChatQuestion, String) -> Void = { _, _ in }
    var capture: (String, CaptureSource) -> Void = { _, _ in }
    /// Send to the agent and show the reply in the chat window.
    var ask: (String) -> Void = { _ in }
    var openChat: (String) -> Void = { _ in }
    var openMain: (Route?) -> Void = { _ in }

    init() {}

    init(app: AppContext, ambient: AmbientState) {
        let store = app.store
        complete = { store.complete($0) }
        start = { store.start($0) }
        snooze = { store.snooze($0, until: $1) }
        open = { app.open(view: Route.today.rawValue, path: "/tasks/\($0.id)") }
        focus = { app.focus($0) }
        join = { app.open($0.joinUrl) }
        approve = { store.approve($0) }
        deny = { store.deny($0) }
        answer = { store.answer($0, $1) }
        capture = { [weak ambient] text, source in
            store.capture(text, source: source, context: ambient?.captureContext(app) ?? app.captureContext)
        }
        ask = { [weak ambient] in ambient?.ask($0, false) }
        openChat = { [weak ambient] in ambient?.openChat($0) }
        openMain = { app.showMainWindow($0) }
    }
}

/// What the ambient surfaces share: the sliced model, the toast stack, voice state, and the few hooks
/// one surface offers the others.
@MainActor
final class AmbientState {
    let model = AmbientModel()
    let toasts = ToastCenter()
    let voice = VoiceModel()
    var actions = AmbientActions()

    /// Chat surface: send a question to the agent and show the streamed reply in the chat window. `spoken` = it was asked by voice.
    var ask: (_ text: String, _ spoken: Bool) -> Void = { _, _ in }
    /// Chat surface: bring the chat window up on a thread.
    var openChat: (_ threadId: String) -> Void = { _ in }
    /// Capture surface: the panel is up, so dictation goes into its field.
    var captureIsOpen: () -> Bool = { false }
    var dictateIntoCapture: (_ partial: String, _ final: Bool) -> Void = { _, _ in }
    /// Notch surface: a short message in the island ("Captured"), and the listening presentation.
    var notice: (_ icon: String, _ text: String) -> Void = { _, _ in }
    var presentVoice: (Bool) -> Void = { _ in }
    /// Voice surface: say this aloud (when the setting allows).
    var speak: (String) -> Void = { _ in }

    /// `app.captureContext` plus the coding session the front window belongs to, when one matches.
    func captureContext(_ app: AppContext) -> CaptureContext {
        var context = app.captureContext
        context.sessionId = Self.session(for: context.title, in: model.sessions)?.id
        return context
    }

    /// Editors and terminals put the folder in the window title; the longest folder name found there wins.
    static func session(for windowTitle: String?, in sessions: [CodeSession]) -> CodeSession? {
        guard let title = windowTitle?.lowercased(), !title.isEmpty else { return nil }
        return sessions
            .map { ($0, URL(fileURLWithPath: $0.cwd).lastPathComponent.lowercased()) }
            .filter { $0.1.count >= 3 && title.contains($0.1) }
            .max { $0.1.count < $1.1.count }?.0
    }
}
