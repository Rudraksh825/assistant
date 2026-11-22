import SwiftUI
import StewardKit

/// The main window's task row: checkbox, title, a quiet line of facts (project, due, why it ranks here),
/// and actions that appear on hover. Equatable on its data so big lists skip rows that did not change.
struct TaskLine: View, Equatable {
    let task: TaskItem
    var project: Project?
    var selected = false
    /// nil hides the multi-select box; otherwise its state.
    var checked: Bool?
    var showReasons = true
    var showScore = false
    var handle = false
    var sessionStates: [SessionState] = []
    var onComplete: () -> Void = {}
    var onOpen: () -> Void = {}
    var onStart: (() -> Void)?
    var onCheck: (() -> Void)?

    @State private var hovered = false
    @State private var completing = false

    nonisolated static func == (a: TaskLine, b: TaskLine) -> Bool {
        a.task == b.task && a.project == b.project && a.selected == b.selected && a.checked == b.checked
            && a.showReasons == b.showReasons && a.showScore == b.showScore && a.handle == b.handle && a.sessionStates == b.sessionStates
    }

    private var closed: Bool { !task.isOpen }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            if handle {
                Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    .frame(width: 10, height: 18).opacity(hovered ? 1 : 0)
            }
            if let checked {
                Button { onCheck?() } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 13))
                        .foregroundStyle(checked ? Palette.accent : Palette.textFaint).frame(width: 16, height: 18)
                }
                .buttonStyle(.plain)
            }
            if closed {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "xmark.circle").font(.system(size: 15))
                    .foregroundStyle(task.status == .done ? Palette.ok.opacity(0.7) : Palette.textFaint).frame(width: 16, height: 18)
            } else {
                TaskCheckbox(color: Palette.priority(task.priority)) { onComplete() }
                    .simultaneousGesture(TapGesture().onEnded { withAnimation(Motion.settle) { completing = true } })
                    .frame(height: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if task.pinned { Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(Palette.accent) }
                    Text(task.title)
                        .font(Typo.body)
                        .foregroundStyle(completing || closed ? Palette.textFaint : Palette.text)
                        .strikethrough(completing || task.status == .done, color: Palette.textFaint)
                        .lineLimit(1)
                    ForEach(Array(sessionStates.enumerated()), id: \.offset) { _, state in StateDot(state, size: 6) }
                }
                .frame(minHeight: 18)
                let facts = facts
                if !facts.isEmpty || (showReasons && !reasons.isEmpty) {
                    HStack(spacing: 6) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in fact }
                        if showReasons {
                            ForEach(reasons, id: \.self) { ReasonChip(text: $0) }
                        }
                    }
                    .lineLimit(1)
                    // Keep each fact whole and let the row cut the tail off, rather than squeezing every one into "Invoi…".
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
            }
            Spacer(minLength: Space.s)
            if hovered, !closed {
                HStack(spacing: 0) {
                    if let onStart, task.status != .doing { IconButton(icon: "play.fill", help: "Start (⌘↩)", action: onStart) }
                    IconButton(icon: "sidebar.right", help: "Open (↩)", action: onOpen)
                }
                .transition(.opacity)
            } else if task.status == .doing {
                Pill("Now", icon: "play.fill", color: Palette.accent)
            } else if showScore, task.score > 0, !closed {
                Text("\(Int(task.score))").font(Typo.numeric).foregroundStyle(Palette.textFaint).frame(height: 18).help("Rank score")
            }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, 6)
        .rowSurface(selected: selected)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { onStart?() }
        .onTapGesture(perform: onOpen)
        .animation(Motion.snappy, value: hovered)
    }

    /// The reasons worth a chip: at most three, minus any that only repeat the due label next to them.
    private var reasons: [String] {
        let due = task.dueAt.map { Fmt.due($0).text.lowercased() }
        return Array(task.scoreReasons.filter { $0.lowercased() != due }.prefix(3))
    }

    private var facts: [AnyView] {
        var out: [AnyView] = []
        if let project {
            out.append(AnyView(HStack(spacing: 4) {
                Circle().fill(Color(hexString: project.color) ?? nameTint(project.title)).frame(width: 6, height: 6)
                Text(project.title).font(Typo.caption).foregroundStyle(Palette.textDim)
            }))
        }
        if let dueAt = task.dueAt, !closed {
            let due = Fmt.due(dueAt)
            out.append(AnyView(Label(due.text, systemImage: "calendar").labelStyle(Fact()).foregroundStyle(due.overdue ? Palette.danger : Palette.textDim)))
        }
        if task.status == .waiting || !(task.waitingOn ?? "").isEmpty {
            out.append(AnyView(Label(task.waitingOn.map { "Waiting on \($0)" } ?? "Waiting", systemImage: "hourglass").labelStyle(Fact()).foregroundStyle(Palette.info)))
        }
        if let until = task.snoozedUntil, until > Date() {
            out.append(AnyView(Label("Snoozed to \(Fmt.due(until).text)", systemImage: "moon.zzz").labelStyle(Fact()).foregroundStyle(Palette.violet)))
        }
        if let minutes = task.estimateMin {
            out.append(AnyView(Label(Fmt.span(Double(minutes) * 60), systemImage: "timer").labelStyle(Fact()).foregroundStyle(Palette.textFaint)))
        }
        if let done = task.completedAt, closed {
            out.append(AnyView(Text("Done \(Fmt.since(done)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint)))
        }
        return out
    }
}

private struct Fact: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .medium))
            configuration.title.font(Typo.caption)
        }
    }
}

/// One score reason ("due today", "session waiting 12m"), tinted only when it signals pressure.
struct ReasonChip: View {
    let text: String

    var body: some View {
        let color = Self.color(text)
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color ?? Palette.textFaint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background((color ?? Color.white).opacity(color == nil ? 0.045 : 0.10), in: Capsule())
            .fixedSize()
    }

    static func color(_ reason: String) -> Color? {
        let r = reason.lowercased()
        if r.contains("overdue") || r.contains("urgent") || r.contains("blocked") { return Palette.danger }
        if r.contains("waiting") && r.contains("session") { return Palette.accent }
        if r.contains("due today") || r.contains("meeting") { return Palette.warn }
        return nil
    }
}

/// Add field with the capture shortcuts: `!` priority, `#project`, `@person`. Shows what it understood as you type.
struct QuickAddField: View {
    var placeholder = "Add a task…   !priority  #project  @person"
    var focusToken = 0
    /// The key that focuses this field on its screen; shown while it is empty and unfocused.
    var hint = "N"
    let onAdd: (QuickAdd) -> Void

    @Environment(AppStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let draft = QuickAdd.parse(text)
        HStack(spacing: Space.s) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(focused ? Palette.accent : Palette.textFaint).frame(width: 16)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .onSubmit(submit)
            if !text.isEmpty {
                if let priority = draft.priority { Pill(Priority.title(priority), color: Palette.priority(priority), style: .outline) }
                if let project = draft.project(in: store.tree.allProjects) {
                    Pill(project.title, icon: "square.stack.3d.up", color: Color(hexString: project.color) ?? Palette.textDim)
                }
                ForEach(draft.people, id: \.self) { Pill($0, icon: "person") }
                KeyHint("↩")
            } else if !focused, !hint.isEmpty {
                KeyHint(hint)
            }
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: 34)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: focused)
        .animation(Motion.snappy, value: draft.priority)
        .onChange(of: focusToken) { focused = true }
    }

    private func submit() {
        let draft = QuickAdd.parse(text)
        guard !draft.title.isEmpty else { return }
        onAdd(draft)
        text = ""
        Haptics.tick()
    }
}
