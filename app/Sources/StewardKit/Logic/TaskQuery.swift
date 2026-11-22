import Foundation

public struct TaskGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var tasks: [TaskItem]
}

/// Filter, sort and group for the Tasks screen. Pure, so it can run on every keystroke and be tested.
public struct TaskQuery: Equatable, Sendable {
    public enum Grouping: String, CaseIterable, Sendable { case none, project, status, due }
    public enum Sort: String, CaseIterable, Sendable { case rank, due, priority, updated, created, title }
    public enum ProjectFilter: Equatable, Sendable { case any, none, id(String) }

    public var search = ""
    /// Empty means every status.
    public var statuses: Set<TaskStatus> = [.inbox, .todo, .doing, .waiting]
    public var project: ProjectFilter = .any
    public var priorities: Set<Int> = []
    public var sources: Set<SourceKind> = []
    public var person: String?
    public var hasSession = false
    public var waitingOnly = false
    public var grouping: Grouping = .none
    public var sort: Sort = .rank

    public init() {}

    /// Filters beyond the default open-status set, for the "3 filters" badge and Clear.
    public var activeFilterCount: Int {
        (statuses == TaskQuery().statuses ? 0 : 1) + (project == .any ? 0 : 1) + (priorities.isEmpty ? 0 : 1)
            + (sources.isEmpty ? 0 : 1) + (person == nil ? 0 : 1) + (hasSession ? 1 : 0) + (waitingOnly ? 1 : 0)
    }

    public func matches(_ task: TaskItem, sessionTaskIds: Set<String> = []) -> Bool {
        if !statuses.isEmpty, !statuses.contains(task.status) { return false }
        switch project {
        case .any: break
        case .none: if task.projectId != nil { return false }
        case .id(let id): if task.projectId != id { return false }
        }
        if !priorities.isEmpty, !priorities.contains(task.priority) { return false }
        if !sources.isEmpty, !sources.contains(task.source) { return false }
        if let person, !Self.involves(task, person) { return false }
        if hasSession, !sessionTaskIds.contains(task.id), !task.links.contains(where: { $0.kind == .session }) { return false }
        if waitingOnly, task.status != .waiting, (task.waitingOn ?? "").isEmpty { return false }
        let words = search.lowercased().split(separator: " ")
        if !words.isEmpty {
            let hay = ([task.title, task.notes, task.waitingOn ?? ""] + task.tags + task.people).joined(separator: "\n").lowercased()
            if !words.allSatisfy({ hay.contains($0) }) { return false }
        }
        return true
    }

    /// True when the task waits on or involves `person` (case-insensitive, full name or first name).
    public static func involves(_ task: TaskItem, _ person: String) -> Bool {
        waitsOn(task, person) || task.people.contains { same($0, person) }
    }

    public static func waitsOn(_ task: TaskItem, _ person: String) -> Bool {
        task.waitingOn.map { same($0, person) } ?? false
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        let first = { (s: String) in s.split(separator: " ").first.map(String.init) ?? s }
        return a == first(b) || first(a) == b
    }

    public func apply(_ tasks: [TaskItem], projects: [String: String] = [:], sessionTaskIds: Set<String> = [], now: Date = Date(), calendar: Calendar = .current) -> [TaskGroup] {
        let filtered = tasks.filter { matches($0, sessionTaskIds: sessionTaskIds) }.sorted(by: order)
        switch grouping {
        case .none:
            return filtered.isEmpty ? [] : [TaskGroup(id: "all", title: "", tasks: filtered)]
        case .project:
            let groups = Dictionary(grouping: filtered) { $0.projectId ?? "" }
            return groups.map { TaskGroup(id: "project:\($0.key)", title: $0.key.isEmpty ? "No project" : projects[$0.key] ?? "Unknown project", tasks: $0.value) }
                .sorted { ($0.id == "project:" ? 1 : 0, $0.title.lowercased()) < ($1.id == "project:" ? 1 : 0, $1.title.lowercased()) }
        case .status:
            let order: [TaskStatus] = [.doing, .todo, .inbox, .waiting, .done, .dropped, .unknown]
            let groups = Dictionary(grouping: filtered, by: \.status)
            return order.compactMap { status in groups[status].map { TaskGroup(id: "status:\(status.rawValue)", title: Self.title(status), tasks: $0) } }
        case .due:
            let groups = Dictionary(grouping: filtered) { DueBucket($0.dueAt, now: now, calendar: calendar) }
            return DueBucket.allCases.compactMap { bucket in groups[bucket].map { TaskGroup(id: "due:\(bucket.rawValue)", title: bucket.title, tasks: $0) } }
        }
    }

    public static func title(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "Inbox"
        case .todo: "To do"
        case .doing: "Doing"
        case .waiting: "Waiting"
        case .done: "Done"
        case .dropped: "Dropped"
        case .unknown: "Other"
        }
    }

    private func order(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch sort {
        // Closed tasks keep whatever score they had; they belong under the open ones.
        case .rank: if a.isOpen != b.isOpen { return a.isOpen }
        case .due: if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
        case .priority: if a.priority != b.priority { return a.priority > b.priority }
        case .updated: if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        case .created: if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        case .title:
            let order = a.title.localizedCaseInsensitiveCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
        }
        // The brain's order: manually ranked first, then score.
        if a.manualRank != b.manualRank { return (a.manualRank ?? .infinity) < (b.manualRank ?? .infinity) }
        if a.score != b.score { return a.score > b.score }
        return a.createdAt < b.createdAt
    }
}

public enum DueBucket: String, CaseIterable, Sendable {
    case overdue, today, tomorrow, week, later, none

    public init(_ due: Date?, now: Date = Date(), calendar: Calendar = .current) {
        guard let due else { self = .none; return }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
        self = due < today ? .overdue : days == 0 ? .today : days == 1 ? .tomorrow : days < 7 ? .week : .later
    }

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .week: "Next 7 days"
        case .later: "Later"
        case .none: "No date"
        }
    }
}
