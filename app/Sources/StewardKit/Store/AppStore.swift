import Foundation
import Observation

/// The one observable store every surface and screen reads. Owns the SSE connection, keeps slices
/// fresh, and exposes intents. UI never talks to `BrainClient` for the slices held here.
@MainActor @Observable
public final class AppStore {
    public enum Connection: Equatable, Sendable {
        case connecting
        case online
        case offline(String)

        public var isOnline: Bool { self == .online }
    }

    /// `notes`, `people` and `looseEnds` are fetched lazily: call `need(_:)` from the screen that shows them.
    public enum Slice: Hashable, Sendable {
        case tasks, suggestions, sessions, meetings, approvals, nudges, threads, settings, tree, notes, people, looseEnds
    }

    public let client: BrainClient

    public private(set) var connection: Connection = .connecting
    /// Why the brain is not running, when the supervisor knows ("node not found", "restarting in 4s").
    public var brainNote: String?
    public private(set) var brainVersion: String?

    public private(set) var snapshot: StateSnapshot?
    /// Open tasks (inbox, todo, doing, waiting), ranked by the brain.
    public private(set) var tasks: [TaskItem] = []
    public private(set) var suggestions: [Suggestion] = []
    public private(set) var sessions: [CodeSession] = []
    /// Yesterday through the next seven days.
    public private(set) var meetings: [Meeting] = []
    public private(set) var approvals: [Approval] = []
    public private(set) var nudges: [Nudge] = []
    public private(set) var agent = StateSnapshot.AgentStatus(busy: false, activity: nil)
    /// Why the agent cannot work right now, when the brain knows (no runtime, or the Claude login is broken and there is no key); nil when it can.
    public var agentIssue: String? {
        guard connection.isOnline, let snapshot else { return nil }
        if snapshot.agent.available == false { return "The agent is switched off in this brain. Tasks, capture and the session radar work; chat, briefs and syncs do not." }
        let health = snapshot.health.connectors
        if health["agent:login"] == .error, health["agent:api"] != .ok {
            return "The Claude login on this Mac is not working. Run claude in a terminal and sign in, or add an API key in Settings."
        }
        return nil
    }
    public private(set) var settings: JSONValue = .object([:])

    public private(set) var tree = Tree()
    public private(set) var notes: [Note] = []
    public private(set) var people: [Person] = []
    /// Things promised or started and then left; computed by the brain on request.
    public private(set) var looseEnds = LooseEnds()

    public private(set) var threads: [ChatThread] = []
    /// Messages per thread, including the in-flight assistant message while a reply streams.
    public private(set) var messages: [String: [ChatMessage]] = [:]
    public private(set) var streamingThreads: Set<String> = []
    public private(set) var questions: [BrainEvent.ChatQuestion] = []

    /// Bumped per entity on every `state.changed`; use as a `.task(id:)` key for data a screen fetches itself.
    public private(set) var changes: [BrainEvent.Entity: Int] = [:]
    /// Last failed intent, for a transient error display. Cleared by the next success.
    public private(set) var lastError: String?

    @ObservationIgnored private var needed: Set<Slice> = [.tasks, .suggestions, .sessions, .meetings, .approvals, .nudges, .threads, .settings, .tree]
    @ObservationIgnored private var dirty: Set<Slice> = []
    @ObservationIgnored private var flush: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var handlers: [UUID: @MainActor (BrainEvent) -> Void] = [:]
    /// Captures made while the brain was unreachable, kept across launches and sent on the next connection:
    /// a thought typed into a hotkey panel must not be lost to a restart.
    @ObservationIgnored private var outbox: [PendingCapture] = PendingCapture.load()

    public init(client: BrainClient = BrainClient()) {
        self.client = client
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, client] in
            for await signal in client.events() {
                guard let self else { return }
                switch signal {
                case .connected:
                    self.connection = .online
                    // Whatever failed while the brain was still starting is no longer true.
                    self.lastError = nil
                    self.refresh()
                    // Questions only arrive as events; the ones asked while this client was away are fetched once per connection.
                    self.run { self.questions = try await self.client.chatQuestions() }
                    self.sendOutbox()
                case .event(let event):
                    self.apply(event)
                case .disconnected(let why):
                    self.connection = .offline(why)
                    self.streamingThreads = []
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Refetch everything in use.
    public func refresh() {
        dirty.formUnion(needed)
        scheduleFlush(delay: 0)
    }

    /// Declare that a screen shows these slices; they load now and stay fresh from then on.
    public func need(_ slices: Slice...) {
        let new = Set(slices).subtracting(needed)
        guard !new.isEmpty else { return }
        needed.formUnion(new)
        dirty.formUnion(new)
        scheduleFlush(delay: 0)
    }

    // MARK: Events

    /// Every event, after the store has applied it. Client-side nudge actions arrive here as `.uiCommand`.
    @discardableResult
    public func onEvent(_ handler: @escaping @MainActor (BrainEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func removeHandler(_ id: UUID) {
        handlers[id] = nil
    }

    /// Same as `onEvent`, as a stream. Ends when the consumer stops iterating.
    public func events() -> AsyncStream<BrainEvent> {
        AsyncStream { continuation in
            let id = onEvent { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeHandler(id) }
            }
        }
    }

    private func emit(_ event: BrainEvent) {
        for handler in handlers.values { handler(event) }
    }

    func apply(_ event: BrainEvent) {
        switch event {
        case .hello(let version):
            brainVersion = version
        case .stateChanged(let entities):
            for entity in entities {
                changes[entity, default: 0] += 1
                switch entity {
                case .tasks: dirty.formUnion([.tasks, .looseEnds])
                case .projects, .initiatives: dirty.insert(.tree)
                case .suggestions: dirty.formUnion([.suggestions, .looseEnds])
                case .sessions: dirty.formUnion([.sessions, .looseEnds])
                case .places: dirty.insert(.looseEnds)
                case .meetings: dirty.insert(.meetings)
                case .notes: dirty.insert(.notes)
                case .approvals: dirty.insert(.approvals)
                case .nudges: dirty.insert(.nudges)
                case .settings: dirty.insert(.settings)
                case .people: dirty.insert(.people)
                case .budget, .jobs, .unknown: break
                }
            }
            scheduleFlush(delay: 0.08)
        case .sessionUpdated(let session):
            upsert(session, into: &sessions, keep: session.state != .ended)
            if snapshot != nil { upsert(session, into: &snapshot!.sessions, keep: session.state != .ended) }
        case .nudge(let nudge):
            upsert(nudge, into: &nudges)
            if snapshot != nil { upsert(nudge, into: &snapshot!.nudges) }
        case .nudgeDismissed(let id):
            nudges.removeAll { $0.id == id }
            snapshot?.nudges.removeAll { $0.id == id }
        case .chatStarted(let ref):
            streamingThreads.insert(ref.threadId)
            messages[ref.threadId, default: []].append(ChatMessage(id: Self.streamId(ref.runId), threadId: ref.threadId, role: .assistant, text: ""))
        case .chatDelta(let delta):
            streamingThreads.insert(delta.threadId)
            var list = messages[delta.threadId] ?? []
            // A tool call splits the reply: text after it goes into a fresh bubble below the tool row.
            if let last = list.indices.last, list[last].id.hasPrefix(Self.streamId(delta.runId)) {
                list[last].text += delta.text
            } else {
                list.append(ChatMessage(id: "\(Self.streamId(delta.runId)):\(list.count)", threadId: delta.threadId, role: .assistant, text: delta.text))
            }
            messages[delta.threadId] = list
        case .chatTool(let tool):
            let message = ChatMessage(
                id: "call:\(tool.callId)", threadId: tool.threadId, role: .tool, text: "",
                tool: .init(name: tool.name, input: tool.input, result: tool.result, status: tool.status))
            upsert(message, into: &messages[tool.threadId, default: []])
        case .chatQuestion(let question):
            upsert(question, into: &questions)
        case .chatDone(let done):
            streamingThreads.remove(done.threadId)
            reloadMessages(done.threadId)
            dirty.insert(.threads)
            scheduleFlush(delay: 0.08)
        case .chatError(let error):
            streamingThreads.remove(error.threadId)
            messages[error.threadId, default: []].append(ChatMessage(id: "error:\(error.runId)", threadId: error.threadId, role: .system, text: error.message))
        case .agentActivity(let status):
            agent.busy = status.busy
            agent.activity = status.activity
            snapshot?.agent = agent
        case .approvalRequested(let approval):
            upsert(approval, into: &approvals)
        case .uiCommand, .appRelaunch, .ping:
            break
        }
        emit(event)
    }

    private static func streamId(_ runId: String) -> String { "run:\(runId)" }

    private func upsert<T: Identifiable>(_ item: T, into list: inout [T], keep: Bool = true) {
        if let i = list.firstIndex(where: { $0.id == item.id }) {
            if keep { list[i] = item } else { list.remove(at: i) }
        } else if keep {
            list.append(item)
        }
    }

    // MARK: Fetching

    private func scheduleFlush(delay: TimeInterval) {
        flush?.cancel()
        flush = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            let slices = self.dirty.intersection(self.needed)
            self.dirty = []
            await self.fetch(slices)
        }
    }

    private func fetch(_ slices: Set<Slice>) async {
        var jobs = [Task { await self.load { self.setSnapshot(try await self.client.state()) } }]
        for slice in slices {
            jobs.append(Task { await self.load { try await self.fetch(slice) } })
        }
        for job in jobs { await job.value }
    }

    private func fetch(_ slice: Slice) async throws {
        switch slice {
        case .tasks: tasks = try await client.tasks(status: [.inbox, .todo, .doing, .waiting])
        case .suggestions: suggestions = try await client.suggestions()
        case .sessions: sessions = try await client.sessions()
        case .meetings:
            let day: TimeInterval = 86_400
            meetings = try await client.meetings(from: Date().addingTimeInterval(-day), to: Date().addingTimeInterval(7 * day))
                .sorted { $0.startAt < $1.startAt }
        case .approvals: approvals = try await client.approvals()
        case .nudges: nudges = try await client.nudges()
        case .threads: threads = try await client.chatThreads().sorted { $0.updatedAt > $1.updatedAt }
        case .settings:
            settings = try await client.settings()
            Haptics.enabled = settings["ui"]["haptics"].bool ?? true
        case .tree: tree = try await client.tree()
        case .notes: notes = try await client.notes()
        case .people: people = try await client.people()
        case .looseEnds:
            // An app newer than its brain asks a route that is not there yet; that is an empty list, not an error on every screen.
            do { looseEnds = try await client.looseEnds() } catch BrainError.http(status: 404, _, _) { looseEnds = LooseEnds() }
        }
    }

    private func setSnapshot(_ new: StateSnapshot) {
        snapshot = new
        agent = new.agent
    }

    /// Runs a fetch; a failure is recorded but never thrown, so one bad slice cannot stall the rest.
    private func load(_ op: () async throws -> Void) async {
        do { try await op() } catch { lastError = BrainError.describe(error) }
    }

    /// Shows a failure from an action a screen ran itself, the same way a failed intent shows.
    public func report(_ error: Error) {
        lastError = BrainError.describe(error)
    }

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await op()
                self.lastError = nil
            } catch {
                self.lastError = BrainError.describe(error)
                self.refresh()
            }
        }
    }

    // MARK: Task intents

    public func complete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        snapshot?.top.removeAll { $0.id == task.id }
        if snapshot?.now?.id == task.id { snapshot?.now = nil }
        run { _ = try await self.client.completeTask(task.id) }
    }

    public func start(_ task: TaskItem, exclusive: Bool = true) {
        run { _ = try await self.client.startTask(task.id, exclusive: exclusive) }
    }

    public func snooze(_ task: TaskItem, until: Date) {
        tasks.removeAll { $0.id == task.id }
        snapshot?.top.removeAll { $0.id == task.id }
        run { _ = try await self.client.snoozeTask(task.id, until: until) }
    }

    /// `fields` is a `Partial<Task>` object, e.g. `["priority": 2, "projectId": "…"]`.
    public func addTask(_ title: String, fields: JSONValue = [:]) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        run { _ = try await self.client.createTask(fields.setting("title", to: .string(title))) }
    }

    public func update(_ task: TaskItem, _ patch: JSONValue) {
        run { _ = try await self.client.updateTask(task.id, patch) }
    }

    public func delete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        snapshot?.top.removeAll { $0.id == task.id }
        run { try await self.client.deleteTask(task.id) }
    }

    public func reorder(_ ids: [String]) {
        run { try await self.client.reorderTasks(ids) }
    }

    public func capture(_ text: String, source: CaptureSource? = nil, context: CaptureContext? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await self.client.capture(text, source: source, context: context)
                self.lastError = nil
            } catch BrainError.offline {
                self.outbox.append(PendingCapture(text: text, source: source, context: context))
                PendingCapture.save(self.outbox)
            } catch {
                self.lastError = BrainError.describe(error)
            }
        }
    }

    private func sendOutbox() {
        guard !outbox.isEmpty else { return }
        let pending = outbox
        outbox = []
        Task {
            for (index, item) in pending.enumerated() {
                do { try await self.client.capture(item.text, source: item.source, context: item.context) } catch {
                    self.outbox = Array(pending[index...]) + self.outbox
                    break
                }
            }
            PendingCapture.save(self.outbox)
        }
    }

    // MARK: Suggestion, approval, nudge intents

    public func accept(_ suggestion: Suggestion, edits: JSONValue? = nil) {
        suggestions.removeAll { $0.id == suggestion.id }
        run { _ = try await self.client.acceptSuggestion(suggestion.id, edits: edits) }
    }

    public func dismiss(_ suggestion: Suggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        run { try await self.client.dismissSuggestion(suggestion.id) }
    }

    public func acceptAll(_ list: [Suggestion]) {
        let ids = Set(list.map(\.id))
        suggestions.removeAll { ids.contains($0.id) }
        run { try await self.client.acceptAllSuggestions(Array(ids)) }
    }

    /// Approves exactly this payload (or the edited one). Only ever called from an explicit user action.
    public func approve(_ approval: Approval, edits: JSONValue? = nil) {
        approvals.removeAll { $0.id == approval.id }
        run { _ = try await self.client.approve(approval.id, edits: edits) }
    }

    public func deny(_ approval: Approval, reason: String? = nil) {
        approvals.removeAll { $0.id == approval.id }
        run { try await self.client.deny(approval.id, reason: reason) }
    }

    public func dismiss(_ nudge: Nudge) {
        nudges.removeAll { $0.id == nudge.id }
        snapshot?.nudges.removeAll { $0.id == nudge.id }
        run { try await self.client.dismissNudge(nudge.id) }
    }

    /// Reports the action to the brain (which runs `api` actions itself) and re-emits the client-side
    /// kinds as `.uiCommand`, so the app has one place that opens URLs, views and session windows.
    public func act(on nudge: Nudge, _ action: NudgeAction) {
        switch action.kind {
        case .dismiss:
            dismiss(nudge)
            return
        case .openURL:
            emit(.uiCommand(.init(command: .openURL, args: ["url": action.url.map(JSONValue.string) ?? .null])))
        case .focusSession:
            emit(.uiCommand(.init(command: .focusSession, args: ["sessionId": action.sessionId.map(JSONValue.string) ?? .null])))
        case .openView:
            emit(.uiCommand(.init(command: .openView, args: ["view": action.view.map(JSONValue.string) ?? .null, "path": action.path.map(JSONValue.string) ?? .null])))
        case .api, .unknown:
            break
        }
        run { try await self.client.actOnNudge(nudge.id, actionId: action.id) }
    }

    public func dismiss(_ end: LooseEnd) {
        for i in looseEnds.groups.indices { looseEnds.groups[i].items.removeAll { $0.id == end.id } }
        looseEnds.groups.removeAll { $0.items.isEmpty }
        looseEnds.count = looseEnds.all.count
        run { try await self.client.dismissLooseEnd(end.id) }
    }

    // MARK: Chat intents

    public func openThread(_ id: String) {
        guard messages[id] == nil else { return }
        reloadMessages(id)
    }

    private func reloadMessages(_ threadId: String) {
        run { self.messages[threadId] = try await self.client.chatMessages(threadId) }
    }

    /// Sends to `threadId`, or to a new thread when nil. Returns the thread id once known.
    @discardableResult
    public func send(_ text: String, to threadId: String? = nil, context: JSONValue? = nil) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return threadId }
        var id = threadId
        do {
            if id == nil {
                let thread = try await client.createChatThread()
                threads.insert(thread, at: 0)
                id = thread.id
            }
            guard let id else { return nil }
            messages[id, default: []].append(ChatMessage(id: "local:\(UUID().uuidString)", threadId: id, role: .user, text: text))
            streamingThreads.insert(id)
            _ = try await client.sendChat(id, text: text, context: context)
            lastError = nil
            return id
        } catch {
            // Also for a thread created just above: it must not look like it is still replying.
            if let id { streamingThreads.remove(id) }
            lastError = BrainError.describe(error)
            return id
        }
    }

    public func renameThread(_ id: String, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].title = title }
        run { _ = try await self.client.renameChatThread(id, title: title) }
    }

    public func deleteThread(_ id: String) {
        threads.removeAll { $0.id == id }
        messages[id] = nil
        streamingThreads.remove(id)
        questions.removeAll { $0.threadId == id }
        run { try await self.client.deleteChatThread(id) }
    }

    public func interrupt(_ threadId: String) {
        run { try await self.client.interruptChat(threadId) }
    }

    public func answer(_ question: BrainEvent.ChatQuestion, _ answer: String) {
        questions.removeAll { $0.id == question.id }
        run { try await self.client.answerQuestion(question.questionId, answer: answer) }
    }

    // MARK: Settings

    /// Sets one value by dotted path ("ui.haptics"). The brain deep-merges, so only that path is sent.
    public func setSetting(_ path: String, _ value: JSONValue) {
        settings = settings.setting(path, to: value)
        Haptics.enabled = settings["ui"]["haptics"].bool ?? true
        run { try await self.client.putSettings(JSONValue.object([:]).setting(path, to: value)) }
    }

    // MARK: Lookups

    public func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id } ?? snapshot?.top.first { $0.id == id }
    }

    public func projectTitle(_ id: String?) -> String? {
        guard let id else { return nil }
        return tree.allProjects.first { $0.id == id }?.title
    }
}

private struct PendingCapture: Codable {
    var text: String
    var source: CaptureSource?
    var context: CaptureContext?

    private static let key = "capture.outbox"

    static func load() -> [PendingCapture] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([PendingCapture].self, from: $0) } ?? []
    }

    static func save(_ items: [PendingCapture]) {
        if items.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key) }
    }
}
