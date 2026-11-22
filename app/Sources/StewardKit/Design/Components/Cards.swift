import SwiftUI

public struct MeetingRow: View {
    let meeting: Meeting
    let onJoin: (() -> Void)?

    public init(meeting: Meeting, onJoin: (() -> Void)? = nil) {
        self.meeting = meeting
        self.onJoin = onJoin
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let live = meeting.startAt <= now && now < meeting.endAt
            let soon = !live && meeting.startAt > now && meeting.startAt.timeIntervalSince(now) < 15 * 60
            HStack(spacing: Space.s + 2) {
                RoundedRectangle.continuous(2).fill(live ? Palette.accent : Palette.info.opacity(0.7)).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                    HStack(spacing: Space.xs) {
                        Text("\(Fmt.time(meeting.startAt)) – \(Fmt.time(meeting.endAt))").font(Typo.numeric).foregroundStyle(Palette.textDim)
                            .lineLimit(1).fixedSize()
                        if !meeting.attendees.isEmpty {
                            Text("· \(meeting.attendees.count) people").font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: Space.s)
                if live { Pill("Now", color: Palette.accent) }
                if soon { Pill("in \(Fmt.span(meeting.startAt.timeIntervalSince(now)))", icon: "clock", color: Palette.warn) }
                if let onJoin, meeting.joinUrl != nil, live || soon {
                    Button("Join", action: onJoin).buttonStyle(.pressable(.primary))
                }
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, 6)
        }
    }
}

public struct SuggestionCard: View {
    let suggestion: Suggestion
    let selected: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void

    public init(suggestion: Suggestion, selected: Bool = false, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.suggestion = suggestion
        self.selected = selected
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Pill(kindText, icon: kindIcon, color: Palette.accent)
                Pill(suggestion.source.rawValue, color: Palette.textDim)
                Spacer()
                Text("\(Int(suggestion.confidence * 100))%").font(Typo.numeric).foregroundStyle(Palette.textFaint).help("Confidence")
            }
            Text(suggestion.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            if !suggestion.rationale.isEmpty {
                Text(suggestion.rationale).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                Button("Accept", action: onAccept).buttonStyle(.pressable(.primary))
                Button("Dismiss", action: onDismiss).buttonStyle(.pressable(.ghost))
                Spacer()
                if selected {
                    KeyHint("↩")
                    KeyHint("⌫")
                }
            }
        }
        .padding(Space.m)
        .cardSurface()
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.accent.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
    }

    private var kindText: String {
        switch suggestion.kind {
        case .newTask: "New task"
        case .updateTask: "Update"
        case .completeTask: "Looks done"
        case .followup: "Follow up"
        case .link: "Link"
        case .insight: "Insight"
        case .question: "Question"
        case .unknown: "Suggestion"
        }
    }

    private var kindIcon: String {
        switch suggestion.kind {
        case .newTask: "plus"
        case .updateTask: "pencil"
        case .completeTask: "checkmark"
        case .followup: "arrowshape.turn.up.left"
        case .link: "link"
        case .insight: "lightbulb"
        case .question: "questionmark"
        case .unknown: "sparkle"
        }
    }
}

public struct NudgeView: View {
    let nudge: Nudge
    let onAction: (NudgeAction) -> Void
    let onDismiss: () -> Void

    public init(nudge: Nudge, onAction: @escaping (NudgeAction) -> Void, onDismiss: @escaping () -> Void) {
        self.nudge = nudge
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.s + 2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.nudge(nudge.kind))
                .frame(width: 22, height: 22)
                .background(Palette.nudge(nudge.kind).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(nudge.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(2)
                if !nudge.body.isEmpty {
                    Text(nudge.body).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(3)
                }
                let actions = nudge.actions.filter { $0.kind != .dismiss }
                if !actions.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            Button(action.label) { onAction(action) }.buttonStyle(.pressable(index == 0 ? .primary : .secondary))
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint).frame(width: 18, height: 18)
            }
            .buttonStyle(.pressable(.bare))
            .accessibilityLabel("Dismiss")
        }
        .padding(Space.m)
    }

    private var icon: String {
        switch nudge.kind {
        case .session: "terminal"
        case .meeting: "calendar"
        case .task: "checklist"
        case .brief: "text.alignleft"
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble"
        case .insight: "lightbulb"
        case .budget: "dollarsign.circle"
        case .system, .unknown: "bell"
        }
    }
}
