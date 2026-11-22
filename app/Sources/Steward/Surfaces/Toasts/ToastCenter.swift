import AppKit
import SwiftUI
import StewardKit

struct ToastItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case nudge(Nudge)
        case question(BrainEvent.ChatQuestion)
        case approval(Approval)
        /// A plain line from the agent (`ui.command toast`) or from Steward itself.
        case message
    }

    var id: String
    var kind: Kind
    var title: String
    var body = ""
    var priority = 1

    var icon: String {
        switch kind {
        case .nudge(let nudge): nudgeIcon(nudge.kind)
        case .question: nudgeIcon(.question)
        case .approval: nudgeIcon(.approval)
        case .message: "sparkle"
        }
    }

    var tint: Color {
        switch kind {
        case .nudge(let nudge): Palette.nudge(nudge.kind)
        case .question: Palette.nudge(.question)
        case .approval: Palette.nudge(.approval)
        case .message: Palette.violet
        }
    }

    static func nudge(_ nudge: Nudge) -> ToastItem {
        ToastItem(id: "nudge:\(nudge.id)", kind: .nudge(nudge), title: nudge.title, body: nudge.body, priority: nudge.priority)
    }

    static func question(_ question: BrainEvent.ChatQuestion) -> ToastItem {
        ToastItem(id: "question:\(question.id)", kind: .question(question), title: question.question, priority: 2)
    }

    static func approval(_ approval: Approval) -> ToastItem {
        ToastItem(id: "approval:\(approval.id)", kind: .approval(approval), title: "Agent: \(ApprovalPayload.label(approval.summary, max: 140))", priority: 2)
    }
}

/// The toast stack every notch panel can show. Owns the clock for `ToastQueue`: one sleeping task until
/// the next deadline, nothing while the stack is empty.
@MainActor @Observable
final class ToastCenter {
    /// On screen, newest first.
    private(set) var items: [ToastItem] = []
    /// The display whose notch the stack hangs from, chosen when the first toast of a run arrives.
    private(set) var displayID: CGDirectDisplayID?
    /// A toast being swiped, and how far.
    var swipe: (id: String, dx: CGFloat)?
    /// The toast under the pointer: the target of a two-finger swipe.
    @ObservationIgnored var hoveredID: String?

    @ObservationIgnored var chooseDisplay: () -> CGDirectDisplayID? = { nil }
    /// A toast came on screen (haptic, island reaction).
    @ObservationIgnored var onArrive: (ToastItem) -> Void = { _ in }
    /// A toast that asked for a follow-up timed out without the user touching it.
    @ObservationIgnored var onUnseen: (ToastItem) -> Void = { _ in }

    /// The user swiped or closed a nudge toast: the nudge itself is done with.
    @ObservationIgnored var onUserDismiss: (Nudge) -> Void = { _ in }

    @ObservationIgnored private var queue = ToastQueue<String>()
    @ObservationIgnored private var known: [String: ToastItem] = [:]
    @ObservationIgnored private var followUp: Set<String> = []
    @ObservationIgnored private var wake: Task<Void, Never>?

    func show(_ item: ToastItem, lifetime: TimeInterval, expiresAt: Date? = nil, followUpIfUnseen: Bool = false) {
        known[item.id] = item
        if followUpIfUnseen { followUp.insert(item.id) }
        queue.push(item.id, priority: item.priority, lifetime: lifetime, expiresAt: expiresAt, now: Date())
        sync()
    }

    func dismiss(_ id: String) {
        known[id] = nil
        followUp.remove(id)
        queue.remove(id, now: Date())
        sync()
    }

    func userDismiss(_ id: String) {
        if case .nudge(let nudge)? = known[id]?.kind { onUserDismiss(nudge) }
        if swipe?.id == id { swipe = nil }
        dismiss(id)
    }

    /// An approval or question toast supersedes the plain nudge announcing the same thing.
    func dismissNudges(of kind: NudgeKind) {
        for (id, item) in known {
            if case .nudge(let nudge) = item.kind, nudge.kind == kind { dismiss(id) }
        }
    }

    func hold(_ id: String) {
        queue.hold(id, now: Date())
        sync()
    }

    func release(_ id: String) {
        queue.release(id, now: Date())
        sync()
    }

    func setQuiet(_ quiet: Bool) {
        guard quiet != queue.quiet else { return }
        queue.setQuiet(quiet, now: Date())
        sync()
    }

    /// Drops toasts of one family whose subject is gone (approved elsewhere, answered in the main window).
    func prune(prefix: String, keeping ids: Set<String>) {
        for id in known.keys where id.hasPrefix(prefix) && !ids.contains(String(id.dropFirst(prefix.count))) { dismiss(id) }
    }

    private func sync() {
        let before = Set(items.map(\.id))
        let visible = queue.visible.compactMap { known[$0.id] }
        if visible != items {
            if items.isEmpty { displayID = chooseDisplay() }
            withAnimation(Motion.resist) { items = visible }
            visible.filter { !before.contains($0.id) }.forEach(onArrive)
        }
        known = known.filter { id, _ in queue.visible.contains { $0.id == id } || queue.waiting.contains { $0.id == id } }
        followUp.formIntersection(known.keys)

        wake?.cancel()
        guard let deadline = queue.nextDeadline else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            for entry in self.queue.expire(now: Date()) where !entry.seen && self.followUp.contains(entry.id) {
                if let item = self.known[entry.id] { self.onUnseen(item) }
            }
            self.sync()
        }
    }
}
