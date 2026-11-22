import AppKit
import SwiftUI
import StewardKit

/// UI state shared by the main window's screens: inspector, palette, undo, key routing, and the
/// all-tasks cache. One per window; in the environment as `MainWindowModel`.
@MainActor @Observable
final class MainWindowModel {
    enum PaletteMode: Equatable { case commands, addTask, askAgent, startTask, completeTask, looseEnds }

    struct UndoEntry: Identifiable {
        let id = UUID()
        let label: String
        let hidden: Set<String>
        let undo: () -> Void
        let commit: () -> Void
    }

    /// What the agent composer attaches to the next message.
    struct ContextChip: Identifiable, Hashable {
        enum Kind: String { case task, session, meeting }
        let kind: Kind
        let id: String
        let title: String
    }

    /// The live window's model, for teardown paths that have no environment (see `ScreenKeys`).
    @ObservationIgnored static weak var current: MainWindowModel?

    @ObservationIgnored let app: AppContext
    var store: AppStore { app.store }
    let library: TaskLibrary

    var inspectedTaskId: String?
    var palette: PaletteMode?
    /// Bumped by ⌘F; a screen with a search field focuses it when this changes.
    var searchToken = 0
    @ObservationIgnored var screenHasSearch = false

    /// Set by the palette and by deep links (`AppContext.open(view:path:)`); the screen that owns the item selects it
    /// when it appears or this changes, then clears it.
    var focusProjectId: String?
    var focusPersonId: String?
    var focusNoteId: String?
    var focusMeetingId: String?
    /// A session to open on its own page (its "place"), set by deep links, the palette and anything that points at a session.
    var focusSessionId: String?
    var focusSuggestionId: String?
    /// Bumped when something asks for the approvals: an Inbox that is already open goes back to the first one.
    var focusApprovals = 0

    /// Tasks the snooze panel is asking about; nil when it is closed.
    var snoozing: [TaskItem]?

    /// Prep requests the brain refused outright (agent off, already running), by meeting id. A run that starts
    /// reports through `Meeting.prepStatus` instead.
    var prepRefused: [String: String] = [:]

    var threadId: String? { didSet { UserDefaults.standard.set(threadId, forKey: "main.thread") } }
    var agentContext: [ContextChip] = []

    private(set) var undoEntry: UndoEntry?
    /// Ids removed from view while their destructive action can still be undone.
    private(set) var hidden: Set<String> = []
    @ObservationIgnored private var undoTimer: Task<Void, Never>?

    @ObservationIgnored var screenKeys: (owner: ObjectIdentifier, handle: (KeyStroke) -> Bool)?
    @ObservationIgnored var paletteKeys: ((KeyStroke) -> Bool)?
    /// The open task place's own keys (⌥-letters, so they never collide with the screen under it).
    @ObservationIgnored var inspectorKeys: (taskId: String, handle: (KeyStroke) -> Bool)?
    /// Set while Settings records a hotkey: the next key press goes here instead of anywhere else.
    @ObservationIgnored var recorder: ((KeyStroke) -> Void)?

    /// Snapshot scenarios preset screen state through this ("sessions.mode": "board"). Empty in normal runs.
    @ObservationIgnored var scenario: [String: String] = [:]

    init(app: AppContext) {
        self.app = app
        library = TaskLibrary(store: app.store)
        threadId = UserDefaults.standard.string(forKey: "main.thread")
        MainWindowModel.current = self
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitUndo() }
        }
    }

    // MARK: Navigation

    func go(_ route: Route) {
        withAnimation(Motion.snappy) { app.route = route }
    }

    func inspect(_ task: TaskItem?) {
        withAnimation(Motion.snappy) { inspectedTaskId = task?.id }
    }

    /// Opens a session's page inside Steward. Going to its editor window is a button there, never this.
    func openSession(_ id: String) {
        focusSessionId = id
        go(.sessions)
    }

    /// Opens a loose end's place. One that nothing tracks yet (a page, a pull request) gets a task first, and that task's place opens.
    func open(_ end: LooseEnd) {
        if let place = end.place {
            app.open(view: place.view, path: place.path)
            return
        }
        Task {
            do {
                let task = try await store.client.trackLooseEnd(end.id)
                library.apply(task)
                inspect(task)
            } catch {
                store.report(error)
            }
        }
    }

    func openPalette(_ mode: PaletteMode = .commands) {
        withAnimation(Motion.snappy) { palette = mode }
    }

    func closePalette() {
        withAnimation(Motion.snappy) { palette = nil }
    }

    /// Opens the Agent screen on a fresh thread and sends `prompt`.
    func ask(_ prompt: String, context: [ContextChip] = []) {
        go(.agent)
        Task {
            if let id = await store.send(prompt, to: nil, context: Self.contextJSON(context)) { threadId = id }
        }
    }

    static func contextJSON(_ chips: [ContextChip]) -> JSONValue? {
        guard !chips.isEmpty else { return nil }
        var out: [String: JSONValue] = [:]
        for chip in chips { out["\(chip.kind.rawValue)Id"] = .string(chip.id) }
        return .object(out)
    }

    // MARK: Undo

    /// Runs `action` now and offers Undo for a few seconds.
    func undoable(_ label: String, undo: @escaping () -> Void, action: () -> Void) {
        commitUndo()
        action()
        show(UndoEntry(label: label, hidden: [], undo: undo, commit: {}))
    }

    /// Hides `ids` now and only runs `commit` once the Undo window has passed: nothing is lost if the user undoes.
    func deferred(_ label: String, hiding ids: [String], commit: @escaping () -> Void) {
        commitUndo()
        withAnimation(Motion.snappy) { hidden.formUnion(ids) }
        show(UndoEntry(label: label, hidden: Set(ids), undo: {}, commit: commit))
    }

    private func show(_ entry: UndoEntry) {
        withAnimation(Motion.bounce) { undoEntry = entry }
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.commitUndo() }
        }
    }

    func performUndo() {
        guard let entry = undoEntry else { return }
        undoTimer?.cancel()
        entry.undo()
        withAnimation(Motion.snappy) {
            hidden.subtract(entry.hidden)
            undoEntry = nil
        }
        Haptics.tick()
    }

    func commitUndo() {
        guard let entry = undoEntry else { return }
        undoTimer?.cancel()
        entry.commit()
        withAnimation(Motion.snappy) { undoEntry = nil }
        // Keep the ids hidden until the store has dropped them, or they would flash back in.
        let ids = entry.hidden
        if !ids.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.hidden.subtract(ids)
            }
        }
    }

    // MARK: Task actions (the ones with undo)

    func complete(_ task: TaskItem) {
        let previous = task.status
        undoable("Completed “\(task.title)”", undo: { [store] in store.update(task, ["status": .string(previous.rawValue)]) }) {
            store.complete(task)
        }
        if inspectedTaskId == task.id { inspect(nil) }
    }

    func complete(_ tasks: [TaskItem]) {
        guard tasks.count != 1 else { return complete(tasks[0]) }
        undoable("Completed \(tasks.count) tasks", undo: { [store] in tasks.forEach { store.update($0, ["status": .string($0.status.rawValue)]) } }) {
            tasks.forEach(store.complete)
        }
    }

    func snooze(_ task: TaskItem, until: Date) {
        undoable("Snoozed until \(Fmt.due(until).text)", undo: { [store] in store.update(task, ["snoozedUntil": .null]) }) {
            store.snooze(task, until: until)
        }
    }

    func delete(_ tasks: [TaskItem]) {
        guard !tasks.isEmpty else { return }
        if let id = inspectedTaskId, tasks.contains(where: { $0.id == id }) { inspect(nil) }
        deferred(tasks.count == 1 ? "Deleted “\(tasks[0].title)”" : "Deleted \(tasks.count) tasks", hiding: tasks.map(\.id)) { [store] in
            tasks.forEach(store.delete)
        }
    }

    func snooze(_ tasks: [TaskItem], until: Date) {
        guard tasks.count != 1 else { return snooze(tasks[0], until: until) }
        undoable("Snoozed \(tasks.count) tasks", undo: { [store] in tasks.forEach { store.update($0, ["snoozedUntil": .null]) } }) {
            tasks.forEach { store.snooze($0, until: until) }
        }
    }

    func askSnooze(_ tasks: [TaskItem]) {
        guard !tasks.isEmpty else { return }
        withAnimation(Motion.snappy) { snoozing = tasks }
    }

    /// Asks the agent to write a prep note; the note arrives later with the meeting.
    func prepare(_ meeting: Meeting) {
        prepRefused[meeting.id] = nil
        Task {
            do {
                _ = try await store.client.prepMeeting(meeting.id)
            } catch {
                withAnimation(Motion.snappy) { prepRefused[meeting.id] = error.brief }
            }
        }
    }

    /// Why this meeting has no prep note, when a run failed or could not start.
    func prepFailure(_ meeting: Meeting) -> String? {
        meeting.prepStatus == .failed ? meeting.prepError ?? "The prep run failed." : prepRefused[meeting.id]
    }

    func visible(_ tasks: [TaskItem]) -> [TaskItem] {
        hidden.isEmpty ? tasks : tasks.filter { !hidden.contains($0.id) }
    }

    // MARK: Keys

    /// The window's key-down path. True when the key was used.
    func handle(_ stroke: KeyStroke, editingText: Bool, resignText: () -> Void) -> Bool {
        if let recorder {
            recorder(stroke)
            return true
        }
        if app.showOnboarding { return false }
        if let tasks = snoozing {
            let options = Snooze.options()
            if case .char(let ch) = stroke.key, stroke.mods.isEmpty, let n = Int(String(ch)), (1...options.count).contains(n) {
                snooze(tasks, until: options[n - 1].date)
            }
            // Modal: any other key closes it without snoozing.
            withAnimation(Motion.snappy) { snoozing = nil }
            return true
        }
        if palette != nil {
            if stroke.command("k") || stroke.plain(.escape) {
                closePalette()
                return true
            }
            return paletteKeys?(stroke) ?? false
        }
        if stroke.mods == .command, case .char(let ch) = stroke.key {
            switch ch {
            case "k": openPalette(); return true
            case "n": openPalette(.addTask); return true
            case "f":
                if screenHasSearch { searchToken += 1 } else { openPalette() }
                return true
            case "z" where !editingText && undoEntry != nil: performUndo(); return true
            case ",": go(.settings); return true
            case "/": go(.guide); return true
            case "0": go(.activity); return true
            case "1"..."9":
                go(Route.allCases[Int(String(ch))! - 1])
                return true
            default: break
            }
        }
        if editingText {
            guard stroke.plain(.escape) else { return false }
            resignText()
            return true
        }
        if let keys = inspectorKeys, keys.taskId == inspectedTaskId, keys.handle(stroke) { return true }
        if screenKeys?.handle(stroke) == true { return true }
        if stroke.plain(.escape), inspectedTaskId != nil {
            inspect(nil)
            return true
        }
        return false
    }
}

/// Every task (open and closed), for the Tasks screen, project progress, subtasks and the palette.
/// Loaded on first use and refetched when the brain says tasks changed.
@MainActor @Observable
final class TaskLibrary {
    private(set) var tasks: [TaskItem] = []
    private(set) var loaded = false
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var loadedVersion = -1
    @ObservationIgnored private var loading = false

    init(store: AppStore) { self.store = store }

    /// Call from `.task(id: store.changes[.tasks])`.
    func refresh() async {
        let version = store.changes[.tasks] ?? 0
        guard !loading, version != loadedVersion || !loaded else { return }
        loading = true
        defer { loading = false }
        // 5000: the brain's default page is 500, and "everything" has to mean it.
        guard let all = try? await store.client.tasks(limit: 5000) else { return }
        tasks = all
        loaded = true
        loadedVersion = version
    }

    /// Applies a local edit at once; the refetch that follows confirms it.
    func apply(_ task: TaskItem) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task } else { tasks.append(task) }
    }

    func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id } ?? store.task(id)
    }
}
