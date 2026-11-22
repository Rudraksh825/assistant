import Foundation

// Swift mirrors of the brain's data model. Timestamps are `Date` (epoch ms on the wire, see `BrainJSON`).

public enum TaskStatus: String, LenientEnum, CaseIterable { case inbox, todo, doing, waiting, done, dropped, unknown }
public enum LinkKind: String, LenientEnum { case ticket, pr, thread, doc, meeting, session, url, file, unknown }
public enum SourceKind: String, LenientEnum { case manual, capture, agent, claude, chat, meeting, ticket, doc, calendar, message, browser, git, unknown }
public enum WorkStatus: String, LenientEnum, CaseIterable { case active, paused, done, dropped, unknown }
public enum SuggestionStatus: String, LenientEnum { case pending, accepted, dismissed, unknown }
public enum SignalTriage: String, LenientEnum { case new, ignored, suggested, linked, unknown }
public enum SessionState: String, LenientEnum, CaseIterable { case working, waiting, blocked, idle, ended, unknown }
public enum NoteKind: String, LenientEnum, CaseIterable { case live, dump, meeting, journal, brief, unknown }
public enum ApprovalStatus: String, LenientEnum { case pending, approved, denied, executed, failed, expired, unknown }
public enum NudgeKind: String, LenientEnum { case session, meeting, task, brief, approval, question, insight, budget, system, unknown }
public enum ChatRole: String, LenientEnum { case user, assistant, tool, system, unknown }
public enum ToolStatus: String, LenientEnum { case running, ok, error, denied, unknown }
public enum PrepStatus: String, LenientEnum { case running, failed, unknown }
public enum RunStatus: String, LenientEnum { case running, ok, error, cancelled, unknown }
public enum RunTrigger: String, LenientEnum { case user, schedule, event, unknown }
public enum Billing: String, LenientEnum { case api, login, mixed, unknown }
public enum ConnectorHealth: String, LenientEnum { case ok, error, off, unknown }

public enum SuggestionKind: String, LenientEnum {
    case newTask = "new_task", updateTask = "update_task", completeTask = "complete_task"
    case followup, link, insight, question, unknown
}

public enum NudgeActionKind: String, LenientEnum {
    case openURL = "open_url", focusSession = "focus_session", openView = "open_view", api, dismiss, unknown
}

public struct TaskLink: Codable, Hashable, Sendable {
    public var kind: LinkKind
    public var title: String
    public var url: String
    public var ref: String?
}

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var status: TaskStatus
    /// 0 none, 1 low, 2 high, 3 urgent
    public var priority: Int
    public var projectId: String?
    public var parentId: String?
    public var dueAt: Date?
    public var scheduledFor: Date?
    public var snoozedUntil: Date?
    public var estimateMin: Int?
    public var pinned: Bool
    public var manualRank: Double?
    public var score: Double
    public var scoreReasons: [String]
    public var waitingOn: String?
    public var people: [String]
    public var tags: [String]
    public var links: [TaskLink]
    public var source: SourceKind
    public var sourceRef: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    /// When it last became `doing`; nil while it is anything else.
    public var startedAt: Date?

    public var isOpen: Bool { status != .done && status != .dropped }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var initiativeId: String?
    public var title: String
    public var notes: String
    public var status: WorkStatus
    public var color: String?
    public var weight: Double
    public var createdAt: Date
    public var updatedAt: Date
}

public struct Initiative: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var status: WorkStatus
    public var weight: Double
    public var horizon: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct ProjectNode: Decodable, Identifiable, Hashable, Sendable {
    public var project: Project
    public var openTasks: Int
    public var doneTasks: Int
    public var id: String { project.id }

    private enum Keys: String, CodingKey { case openTasks, doneTasks }
    public init(from decoder: Decoder) throws {
        project = try Project(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        openTasks = try c.decode(Int.self, forKey: .openTasks)
        doneTasks = try c.decode(Int.self, forKey: .doneTasks)
    }
}

public struct InitiativeNode: Decodable, Identifiable, Hashable, Sendable {
    public var initiative: Initiative
    public var projects: [ProjectNode]
    public var id: String { initiative.id }

    private enum Keys: String, CodingKey { case projects }
    public init(from decoder: Decoder) throws {
        initiative = try Initiative(from: decoder)
        projects = try decoder.container(keyedBy: Keys.self).decode([ProjectNode].self, forKey: .projects)
    }
}

public struct Tree: Decodable, Hashable, Sendable {
    public var initiatives: [InitiativeNode]
    public var looseProjects: [ProjectNode]
    public init() { initiatives = []; looseProjects = [] }
    public var allProjects: [Project] { (initiatives.flatMap(\.projects) + looseProjects).map(\.project) }
}

public struct Suggestion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: SuggestionKind
    public var title: String
    public var rationale: String
    public var payload: [String: JSONValue]
    public var source: SourceKind
    public var sourceRef: String?
    public var sourceUrl: String?
    public var confidence: Double
    public var status: SuggestionStatus
    public var createdAt: Date
    public var decidedAt: Date?
}

public struct Signal: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: SourceKind
    public var kind: String
    public var externalId: String
    public var title: String
    public var body: String
    public var url: String?
    public var actor: String?
    public var occurredAt: Date
    public var payload: [String: JSONValue]
    public var triage: SignalTriage
    public var processedAt: Date?
}

public struct CodeSession: Codable, Identifiable, Hashable, Sendable {
    public struct PullRequest: Codable, Hashable, Sendable {
        public var number: Int
        public var url: String
        public var state: String
        public var reviewDecision: String?
        public var checks: String?
        public var unresolved: Int?
    }

    public var id: String
    public var pid: Int?
    public var name: String?
    public var cwd: String
    public var repo: String?
    public var branch: String?
    public var ticket: String?
    public var state: SessionState
    public var stateSince: Date
    public var title: String?
    public var lastUserPrompt: String?
    public var lastAssistantText: String?
    public var pr: PullRequest?
    public var taskId: String?
    /// The owner's own notes on the session.
    public var notes: String
    public var startedAt: Date
    public var updatedAt: Date

    public var needsAttention: Bool { state == .waiting || state == .blocked }
    public var displayName: String {
        name ?? repo ?? URL(fileURLWithPath: cwd).lastPathComponent
    }
}

public struct Meeting: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: SourceKind
    public var externalId: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var attendees: [String]
    public var joinUrl: String?
    public var location: String?
    public var summary: String?
    public var actionItems: [String]
    public var recordingUrl: String?
    public var prepNote: String?
    /// The prep run for this meeting, while it runs or after it failed; nil otherwise.
    public var prepStatus: PrepStatus?
    public var prepError: String?
    /// False when the source gave a day but no time: `startAt` is then that day's midnight and is not shown as a time.
    public var startKnown: Bool?
    public var updatedAt: Date

    public var hasStartTime: Bool { startKnown ?? true }
}

public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var handles: [String: String]
    public var notes: String
    public var lastContactAt: Date?
}

public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: NoteKind
    public var title: String
    public var body: String
    public var taskId: String?
    public var meetingId: String?
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
}

public struct Approval: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var summary: String
    public var tool: String
    /// The literal payload that runs. `summary` and `target` are the agent's words about it; `note` is the brain's own reason for asking.
    public var input: [String: JSONValue]
    public var note: String?
    public var target: String?
    public var status: ApprovalStatus
    public var result: String?
    public var threadId: String?
    public var createdAt: Date
    public var decidedAt: Date?
}

public struct NudgeAction: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var kind: NudgeActionKind
    public var url: String?
    public var sessionId: String?
    public var view: String?
    public var method: String?
    public var path: String?
    public var body: JSONValue?
}

public struct Nudge: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: NudgeKind
    public var title: String
    public var body: String
    /// 0 passive (notch only), 1 toast, 2 toast + system notification
    public var priority: Int
    public var actions: [NudgeAction]
    public var dedupeKey: String?
    public var createdAt: Date
    public var expiresAt: Date?
    public var dismissedAt: Date?
}

public struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var agentSessionId: String?
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public struct ToolCall: Codable, Hashable, Sendable {
        public var name: String
        public var input: JSONValue?
        public var result: String?
        public var status: ToolStatus
    }

    public var id: String
    public var threadId: String
    public var role: ChatRole
    public var text: String
    public var tool: ToolCall?
    /// Assistant replies: what the turn cost.
    public var costUsd: Double?
    public var createdAt: Date

    public init(id: String, threadId: String, role: ChatRole, text: String, tool: ToolCall? = nil, costUsd: Double? = nil, createdAt: Date = Date()) {
        self.id = id; self.threadId = threadId; self.role = role; self.text = text; self.tool = tool; self.costUsd = costUsd; self.createdAt = createdAt
    }
}

public struct AgentRun: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var trigger: RunTrigger
    public var model: String
    public var status: RunStatus
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUsd: Double
    public var billing: Billing
    public var summary: String?
    public var startedAt: Date
    public var endedAt: Date?
}

public struct ActivitySpan: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var app: String
    public var bundleId: String?
    public var title: String?
    public var startAt: Date
    public var endAt: Date
    public var idle: Bool
    public var sessionId: String?
    public var taskId: String?
}

/// What the sensors post: an `ActivitySpan` before the brain assigns id/session/task.
public struct ActivitySpanInput: Codable, Hashable, Sendable {
    public var app: String
    public var bundleId: String?
    public var title: String?
    public var startAt: Date
    public var endAt: Date
    public var idle: Bool

    public init(app: String, bundleId: String?, title: String?, startAt: Date, endAt: Date, idle: Bool) {
        self.app = app; self.bundleId = bundleId; self.title = title
        self.startAt = startAt; self.endAt = endAt; self.idle = idle
    }
}

public struct StateSnapshot: Decodable, Hashable, Sendable {
    public struct Counts: Codable, Hashable, Sendable {
        public var inbox: Int, suggestions: Int, approvals: Int, waiting: Int, dueToday: Int, overdue: Int
    }
    public struct Budget: Codable, Hashable, Sendable {
        public var todayUsd: Double, dailyCapUsd: Double, monthUsd: Double
        public var billing: Billing
    }
    public struct AgentStatus: Codable, Hashable, Sendable {
        public var busy: Bool
        public var activity: String?
        /// Only in `/state`: false when the brain runs without an agent. `agent.activity` events do not carry it.
        public var available: Bool?
    }
    public struct Health: Codable, Hashable, Sendable {
        public var connectors: [String: ConnectorHealth]
        public var lastSyncAt: [String: Date]
    }

    public var now: TaskItem?
    public var top: [TaskItem]
    public var sessions: [CodeSession]
    public var nextMeeting: Meeting?
    public var currentMeeting: Meeting?
    public var counts: Counts
    public var nudges: [Nudge]
    public var liveNote: Note?
    public var budget: Budget
    public var agent: AgentStatus
    public var health: Health
    public var serverTime: Date

    private enum Keys: String, CodingKey {
        case now, top, sessions, nextMeeting, currentMeeting, counts, nudges, liveNote, budget, agent, health, serverTime
    }

    // Hand-written so a snapshot missing a whole section still renders the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        now = try? c.decodeIfPresent(TaskItem.self, forKey: .now)
        top = try c.decode([TaskItem].self, forKey: .top)
        sessions = try c.decode([CodeSession].self, forKey: .sessions)
        nextMeeting = try? c.decodeIfPresent(Meeting.self, forKey: .nextMeeting)
        currentMeeting = try? c.decodeIfPresent(Meeting.self, forKey: .currentMeeting)
        counts = (try? c.decodeIfPresent(Counts.self, forKey: .counts))
            ?? Counts(inbox: 0, suggestions: 0, approvals: 0, waiting: 0, dueToday: 0, overdue: 0)
        nudges = try c.decode([Nudge].self, forKey: .nudges)
        liveNote = try? c.decodeIfPresent(Note.self, forKey: .liveNote)
        budget = (try? c.decodeIfPresent(Budget.self, forKey: .budget))
            ?? Budget(todayUsd: 0, dailyCapUsd: 0, monthUsd: 0, billing: .unknown)
        agent = (try? c.decodeIfPresent(AgentStatus.self, forKey: .agent)) ?? AgentStatus(busy: false, activity: nil)
        health = (try? c.decodeIfPresent(Health.self, forKey: .health)) ?? Health(connectors: [:], lastSyncAt: [:])
        serverTime = (try? c.decodeIfPresent(Date.self, forKey: .serverTime)) ?? Date()
    }
}

// MARK: - Endpoint payloads

public struct ItemsResponse<T: Decodable>: Decodable { public var items: [T] }
public struct OkResponse: Decodable, Sendable { public var ok: Bool }
public struct HealthResponse: Decodable, Sendable { public var ok: Bool; public var version: String; public var uptimeMs: Double }
public struct AcceptResponse: Decodable, Sendable { public var suggestion: Suggestion?; public var task: TaskItem? }
public struct RecapResponse: Decodable, Sendable { public var text: String }
public struct RunRef: Decodable, Sendable { public var runId: String }
public struct CaptureResponse: Decodable, Sendable { public var noteId: String }
public struct SendResponse: Decodable, Sendable { public var messageId: String; public var runId: String }

public struct ActivitySummary: Decodable, Hashable, Sendable {
    public struct AppTime: Decodable, Hashable, Sendable { public var app: String; public var ms: Double }
    public struct TaskTime: Decodable, Hashable, Sendable { public var taskId: String; public var title: String; public var ms: Double }
    public var byApp: [AppTime]
    public var byTask: [TaskTime]
    public var focusMs: Double
    public var switches: Int
}

public struct CostReport: Decodable, Hashable, Sendable {
    public struct Day: Decodable, Hashable, Sendable { public var day: String; public var usd: Double }
    public struct Kind: Decodable, Hashable, Sendable { public var kind: String; public var usd: Double }
    public struct DayKind: Decodable, Hashable, Sendable { public var day: String; public var kind: String; public var usd: Double }
    public var today: Double
    public var month: Double
    public var byDay: [Day]
    public var byKind: [Kind]
    public var byDayKind: [DayKind]
}

public struct Job: Decodable, Identifiable, Hashable, Sendable {
    /// Every N minutes (`everyMin`), or daily at local "HH:MM" (`at`) on `days` (0 = Sunday; empty = every day).
    public struct Schedule: Codable, Hashable, Sendable {
        public var everyMin: Int?
        public var at: String?
        public var days: [Int]?
        public init(everyMin: Int) { self.everyMin = everyMin }
        public init(at: String, days: [Int]? = nil) { self.at = at; self.days = days }
    }

    public var name: String
    public var schedule: String
    public var lastRunAt: Date?
    public var lastStatus: String?
    public var nextRunAt: Date?
    public var enabled: Bool
    public var running: Bool
    public var scheduleSpec: Schedule?
    /// The user changed the schedule; false means the job's own default.
    public var customSchedule: Bool
    public var id: String { name }
}

public struct MemoryFile: Decodable, Identifiable, Hashable, Sendable {
    public var path: String
    public var size: Int
    public var updatedAt: Date
    public var id: String { path }
}

public struct RebuildResponse: Decodable, Sendable { public var ok: Bool; public var log: String }

public struct CaptureContext: Codable, Hashable, Sendable {
    public var app: String?
    public var title: String?
    public var url: String?
    public var sessionId: String?
    public init(app: String? = nil, title: String? = nil, url: String? = nil, sessionId: String? = nil) {
        self.app = app; self.title = title; self.url = url; self.sessionId = sessionId
    }
}

public enum CaptureSource: String, Codable, Sendable { case hotkey, voice, notch, hud }
