import Foundation

// A "place" is the one page for one tracked thing. These mirror the brain's place, context and loose-end types.

public enum TurnRole: String, LenientEnum { case user, assistant, tools, unknown }
public enum RunState: String, LenientEnum { case running, ok, failed, unknown }
public enum LooseEndKind: String, LenientEnum { case commitment, session, waiting, pr, page, unknown }

/// One entry of a session's conversation tail. `tools` is a burst of tool calls folded into one line.
public struct SessionTurn: Codable, Hashable, Sendable {
    public var role: TurnRole
    public var at: Date?
    public var text: String
}

public struct SessionTurns: Decodable, Hashable, Sendable {
    public var items: [SessionTurn]
    /// "transcript", "summary" (only the last exchange the collector kept) or "none".
    public var from: String
    public var truncated: Bool
    public init() { items = []; from = "none"; truncated = false }
}

public struct SessionPlace: Decodable, Hashable, Sendable {
    public struct Recap: Decodable, Hashable, Sendable {
        public var text: String
        public var at: Date
        public init(text: String, at: Date) { self.text = text; self.at = at }
    }
    public var session: CodeSession
    public var task: TaskItem?
    public var ticketUrl: String?
    public var recap: Recap?
}

/// Where a task or suggestion came from, as the brain has it stored.
public struct Origin: Codable, Hashable, Sendable {
    public var source: SourceKind
    public var kind: String
    public var title: String
    public var body: String
    public var actor: String?
    public var at: Date?
    public var url: String?
    public var signalId: String?
    public var sessionId: String?
    public var meetingId: String?
    public var noteId: String?
}

/// What "See more" fetched around an item's source, and the reply drafted for it.
public struct ItemContext: Codable, Hashable, Sendable {
    public var id: String
    public var subject: String
    public var status: RunState?
    public var body: String
    public var error: String?
    public var fetchedAt: Date?
    public var costUsd: Double
    public var draftStatus: RunState?
    public var draft: String?
    public var draftApprovalId: String?
    public var draftNote: String?
    public var draftAt: Date?
}

public struct RelatedItems: Decodable, Hashable, Sendable {
    public struct RelatedTask: Decodable, Hashable, Sendable { public var task: TaskItem; public var why: String }
    public struct RelatedSuggestion: Decodable, Hashable, Sendable { public var suggestion: Suggestion; public var why: String }
    public struct RelatedSession: Decodable, Hashable, Sendable { public var session: CodeSession; public var why: String }
    public struct RelatedMeeting: Decodable, Hashable, Sendable { public var meeting: Meeting; public var why: String }
    public var tasks: [RelatedTask]
    public var suggestions: [RelatedSuggestion]
    public var sessions: [RelatedSession]
    public var meetings: [RelatedMeeting]

    public var isEmpty: Bool { tasks.isEmpty && suggestions.isEmpty && sessions.isEmpty && meetings.isEmpty }
    public var count: Int { tasks.count + suggestions.count + sessions.count + meetings.count }
}

public struct TaskPlace: Decodable, Hashable, Sendable {
    public var task: TaskItem
    public var origins: [Origin]
    public var context: ItemContext?
    public var related: RelatedItems
    /// Linked sessions, ended ones included.
    public var sessions: [CodeSession]
    /// The connector family "See more" would read; nil when there is nothing remote behind the task.
    public var seeMoreVia: String?
    /// The connector family a reply would go through; nil when there is no thread to reply in.
    public var replyVia: String?
}

public struct SuggestionPlace: Decodable, Hashable, Sendable {
    public var suggestion: Suggestion
    public var origins: [Origin]
    public var context: ItemContext?
    public var seeMoreVia: String?
}

/// Something promised or started and then left.
public struct LooseEnd: Codable, Identifiable, Hashable, Sendable {
    public struct Place: Codable, Hashable, Sendable { public var view: String; public var path: String }
    public var id: String
    public var kind: LooseEndKind
    public var title: String
    public var reason: String
    public var since: Date
    /// Where it opens inside Steward; nil for a page or pull request nothing tracks yet.
    public var place: Place?
    public var url: String?
}

public struct LooseEnds: Decodable, Hashable, Sendable {
    public struct Group: Decodable, Identifiable, Hashable, Sendable {
        public var kind: LooseEndKind
        public var title: String
        public var items: [LooseEnd]
        public var id: String { kind.rawValue }
    }
    public var groups: [Group]
    public var count: Int
    public init() { groups = []; count = 0 }

    public var all: [LooseEnd] { groups.flatMap(\.items) }

    /// The few to show first: one from each group before a second from any, so a pile of page visits cannot hide the one promise.
    public func top(_ count: Int) -> [LooseEnd] {
        var out: [LooseEnd] = []
        var depth = 0
        while out.count < count, groups.contains(where: { $0.items.count > depth }) {
            for group in groups where group.items.count > depth && out.count < count { out.append(group.items[depth]) }
            depth += 1
        }
        return out
    }
}

/// What the owner said they would do, carried by a `followup` suggestion.
public struct Commitment: Hashable, Sendable {
    public var quote: String
    public var to: String?
    public var madeAt: Date?
}

extension Suggestion {
    public var commitment: Commitment? {
        guard let c = payload["commitment"]?.object else { return nil }
        return Commitment(quote: c["quote"]?.string ?? "", to: c["to"]?.string, madeAt: c["madeAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
    }
}
