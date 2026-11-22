import Foundation

/// Which toasts are on screen, which wait, and when each leaves. Pure state: the caller owns the clock
/// (every method takes `now`) and schedules one wake-up for `nextDeadline`.
public struct ToastQueue<ID: Hashable & Sendable>: Sendable {
    public struct Entry: Sendable {
        public var id: ID
        public var priority: Int
        /// Seconds on screen before it leaves by itself.
        public var lifetime: TimeInterval
        /// When the underlying nudge stops being relevant; a waiting entry past this is dropped unseen.
        public var expiresAt: Date?
        /// nil while waiting or held under the pointer.
        public var deadline: Date?
        var remaining: TimeInterval?
        /// The user hovered it. A toast that leaves unseen may deserve a system notification.
        public var seen = false
    }

    public static var maxVisible: Int { 3 }
    /// After the pointer leaves a held toast it stays at least this long.
    public static var graceAfterHold: TimeInterval { 2.5 }

    /// Newest first: the newest toast sits nearest the notch.
    public private(set) var visible: [Entry] = []
    public private(set) var waiting: [Entry] = []
    /// While true nothing new is shown; arrivals wait.
    public private(set) var quiet = false

    public init() {}

    public var nextDeadline: Date? { visible.compactMap(\.deadline).min() }

    public mutating func push(_ id: ID, priority: Int, lifetime: TimeInterval, expiresAt: Date? = nil, now: Date) {
        if let i = visible.firstIndex(where: { $0.id == id }) {
            visible[i].priority = priority
            visible[i].expiresAt = expiresAt
            return
        }
        waiting.removeAll { $0.id == id }
        waiting.append(Entry(id: id, priority: priority, lifetime: lifetime, expiresAt: expiresAt))
        promote(now: now)
    }

    /// Dismissed, acted on, or gone upstream.
    public mutating func remove(_ id: ID, now: Date) {
        visible.removeAll { $0.id == id }
        waiting.removeAll { $0.id == id }
        promote(now: now)
    }

    public mutating func hold(_ id: ID, now: Date) {
        guard let i = visible.firstIndex(where: { $0.id == id }), let deadline = visible[i].deadline else { return }
        visible[i].remaining = deadline.timeIntervalSince(now)
        visible[i].deadline = nil
        visible[i].seen = true
    }

    public mutating func release(_ id: ID, now: Date) {
        guard let i = visible.firstIndex(where: { $0.id == id }), visible[i].deadline == nil else { return }
        visible[i].deadline = now.addingTimeInterval(max(visible[i].remaining ?? 0, Self.graceAfterHold))
        visible[i].remaining = nil
    }

    /// Removes toasts whose time is up and returns them, so the caller can follow up on unseen ones.
    public mutating func expire(now: Date) -> [Entry] {
        let gone = visible.filter { ($0.deadline ?? .distantFuture) <= now }
        guard !gone.isEmpty else { return [] }
        visible.removeAll { ($0.deadline ?? .distantFuture) <= now }
        promote(now: now)
        return gone
    }

    public mutating func setQuiet(_ quiet: Bool, now: Date) {
        self.quiet = quiet
        promote(now: now)
    }

    private mutating func promote(now: Date) {
        waiting.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
        guard !quiet else { return }
        while visible.count < Self.maxVisible, !waiting.isEmpty {
            // Highest priority first; among equals, the one that has waited longest.
            let index = waiting.indices.max { waiting[$0].priority < waiting[$1].priority || (waiting[$0].priority == waiting[$1].priority && $0 > $1) }!
            var entry = waiting.remove(at: index)
            entry.deadline = now.addingTimeInterval(entry.lifetime)
            visible.insert(entry, at: 0)
        }
    }
}

/// How a nudge reaches the user, given its priority and what the user is doing.
public struct ToastDelivery: Equatable, Sendable {
    public var toast: Bool
    /// Post the system notification immediately.
    public var notifyNow: Bool
    /// Post it later, only if the toast times out without the user touching it.
    public var notifyIfUnseen: Bool

    public static func plan(priority: Int, userActive: Bool, quiet: Bool) -> ToastDelivery {
        guard priority >= 1 else { return ToastDelivery(toast: false, notifyNow: false, notifyIfUnseen: false) }
        guard priority >= 2 else { return ToastDelivery(toast: true, notifyNow: false, notifyIfUnseen: false) }
        // Away or in a meeting: the toast cannot be relied on, so the system keeps the record. At the
        // machine: the toast is the alert, and the notification only follows if it went unseen.
        let reachable = userActive && !quiet
        return ToastDelivery(toast: true, notifyNow: !reachable, notifyIfUnseen: reachable)
    }

    public static func lifetime(priority: Int, needsDecision: Bool = false) -> TimeInterval {
        if needsDecision { return 30 }
        return priority >= 2 ? 11 : 6
    }
}
