import SwiftUI

/// Round checkbox that fills, draws its tick and pops before reporting completion.
public struct TaskCheckbox: View {
    let color: Color
    let size: CGFloat
    let onComplete: () -> Void
    @State private var done = false
    @State private var hovered = false

    public init(color: Color = Palette.textFaint, size: CGFloat = 16, onComplete: @escaping () -> Void) {
        self.color = color
        self.size = size
        self.onComplete = onComplete
    }

    public var body: some View {
        Button {
            guard !done else { return }
            Haptics.success()
            withAnimation(Motion.bounce) { done = true }
            // Let the tick land before the row leaves the list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: onComplete)
        } label: {
            ZStack {
                Circle().strokeBorder(done ? Palette.ok : color.opacity(hovered ? 1 : 0.75), lineWidth: 1.5)
                Circle().fill(Palette.ok).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
                CheckShape()
                    .trim(from: 0, to: done || hovered ? 1 : 0)
                    .stroke(done ? Palette.bg : color.opacity(0.7), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.27)
            }
            .frame(width: size, height: size)
            .scaleEffect(done ? 1.12 : 1)
            .animation(Motion.snappy, value: hovered)
            .contentShape(.rect.inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Complete task")
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
            return p
        }
    }
}

/// One task line. Score reasons replace the metadata on hover.
public struct TaskRow: View {
    let task: TaskItem
    let project: String?
    let compact: Bool
    let onComplete: () -> Void
    let onOpen: (() -> Void)?
    @State private var hovered = false
    @State private var completing = false

    public init(task: TaskItem, project: String? = nil, compact: Bool = false, onComplete: @escaping () -> Void, onOpen: (() -> Void)? = nil) {
        self.task = task
        self.project = project
        self.compact = compact
        self.onComplete = onComplete
        self.onOpen = onOpen
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s + 2) {
            TaskCheckbox(color: Palette.priority(task.priority)) {
                onComplete()
            }
            .simultaneousGesture(TapGesture().onEnded { withAnimation(Motion.settle) { completing = true } })
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    if task.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.accent) }
                    Text(task.title)
                        .font(Typo.body)
                        .foregroundStyle(completing ? Palette.textFaint : Palette.text)
                        .strikethrough(completing, color: Palette.textFaint)
                        .lineLimit(compact ? 1 : 2)
                }
                if !compact || hovered { meta }
            }
            Spacer(minLength: Space.s)
            if task.status == .doing { Pill("Now", icon: "play.fill", color: Palette.accent) }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, compact ? 5 : 7)
        .background(hovered ? Palette.hover : .clear, in: .continuous(Radius.s + 2))
        .contentShape(.rect)
        .onTapGesture { onOpen?() }
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
    }

    @ViewBuilder private var meta: some View {
        if hovered, !task.scoreReasons.isEmpty {
            HStack(spacing: Space.xs) {
                Text("\(Int(task.score))").font(Typo.numeric).foregroundStyle(Palette.accent)
                Text(task.scoreReasons.joined(separator: " · ")).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .transition(.opacity)
        } else {
            let chips = metaChips
            if !chips.isEmpty {
                HStack(spacing: Space.xs) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in chip }
                }
                .transition(.opacity)
            }
        }
    }

    private var metaChips: [Pill] {
        var chips: [Pill] = []
        if let project { chips.append(Pill(project, icon: "square.stack.3d.up", color: Palette.textDim)) }
        if let dueAt = task.dueAt {
            let due = Fmt.due(dueAt)
            chips.append(Pill(due.text, icon: "calendar", color: due.overdue ? Palette.danger : Palette.textDim))
        }
        if task.status == .waiting { chips.append(Pill(task.waitingOn.map { "Waiting on \($0)" } ?? "Waiting", icon: "hourglass", color: Palette.info)) }
        if task.priority >= 2 { chips.append(Pill(task.priority == 3 ? "Urgent" : "High", color: Palette.priority(task.priority), style: .outline)) }
        if let minutes = task.estimateMin { chips.append(Pill(Fmt.span(Double(minutes) * 60), icon: "timer")) }
        return chips
    }
}
