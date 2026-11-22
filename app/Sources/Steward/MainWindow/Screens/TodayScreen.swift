import SwiftUI
import StewardKit

/// Home: what is in progress, what is next and why, and everything with a clock on it.
struct TodayScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var selection: String?
    /// Row order while a drag is in flight; nil means the brain's order.
    @State private var dragOrder: [String]?
    @State private var dragging: String?
    @State private var limit = 12
    @State private var addToken = 0

    var body: some View {
        let now = model.hidden.contains(store.snapshot?.now?.id ?? "") ? nil : store.snapshot?.now
        let ranked = ranked(excluding: now)
        let rows = Array(ordered(ranked).prefix(limit))
        VStack(spacing: 0) {
            TodayHeader(now: now)
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.m) {
                            NowCard(task: now)
                            QuickAddField(focusToken: addToken) { draft in
                                store.addTask(draft.title, fields: draft.fields(projects: store.tree.allProjects))
                            }
                            list(rows, total: ranked.count)
                        }
                        .padding(.leading, Space.xl)
                        .padding(.trailing, Space.l)
                        .padding(.bottom, Space.xl)
                    }
                    .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
                }
                ScrollView {
                    TodayRail().padding(.trailing, Space.xl).padding(.bottom, Space.xl)
                }
                .frame(width: 340)
            }
            KeyLegend([(["J", "K"], "move"), (["␣"], "complete"), (["↩"], "open"), (["⌘", "↩"], "start"), (["S"], "snooze"), (["P"], "pin"),
                       (["1", "2", "3"], "priority"), (["⌘", "↑↓"], "reorder"), (["N"], "add"), (["L"], "loose ends")])
        }
        .animation(Motion.settle, value: rows.map(\.id))
        .screenKeys(model) { keys($0, rows) }
        .onAppear { if let preset = model.scenario["today.selected"] { selection = preset } }
    }

    private func ranked(excluding now: TaskItem?) -> [TaskItem] {
        let date = Date()
        return model.visible(store.tasks).filter { $0.id != now?.id && $0.parentId == nil && ($0.snoozedUntil ?? .distantPast) <= date }
    }

    private func ordered(_ tasks: [TaskItem]) -> [TaskItem] {
        guard let dragOrder else { return tasks }
        let rank = Dictionary(uniqueKeysWithValues: dragOrder.enumerated().map { ($1, $0) })
        return tasks.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    // MARK: List

    @ViewBuilder private func list(_ rows: [TaskItem], total: Int) -> some View {
        let projects = Dictionary(store.tree.allProjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions = Dictionary(grouping: store.sessions.filter { $0.taskId != nil }, by: { $0.taskId! })
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                SectionLabel("Next up", count: total)
                Spacer()
                if rows.contains(where: { $0.manualRank != nil }) {
                    Button("Back to ranked order") {
                        rows.filter { $0.manualRank != nil }.forEach { store.update($0, ["manualRank": .null]) }
                    }
                    .buttonStyle(.pressable(.bare)).font(Typo.caption).foregroundStyle(Palette.textDim)
                    .help("You reordered these by hand. Clear that and rank by score again.")
                }
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.top, Space.xs)

            if rows.isEmpty {
                TodayEmpty()
            }
            ForEach(rows) { task in
                TaskLine(task: task, project: projects[task.projectId ?? ""], selected: selection == task.id, showScore: true, handle: true,
                         sessionStates: sessions[task.id]?.map(\.state) ?? [],
                         onComplete: { model.complete(task) },
                         onOpen: { selection = task.id; model.inspect(task) },
                         onStart: { store.start(task) })
                    .equatable()
                    .taskMenu(task)
                    .id(task.id)
                    .opacity(dragging == task.id ? 0.4 : 1)
                    .onDrag {
                        dragging = task.id
                        dragOrder = rows.map(\.id)
                        return NSItemProvider(object: task.id as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDrop(target: task.id, order: $dragOrder, dragging: $dragging) { store.reorder($0) })
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
            if total > rows.count {
                Button("Show \(min(12, total - rows.count)) more of \(total)") { withAnimation(Motion.settle) { limit += 12 } }
                    .buttonStyle(.pressable(.ghost)).padding(.leading, Space.xs)
            }
        }
    }

    // MARK: Keys

    private func keys(_ stroke: KeyStroke, _ rows: [TaskItem]) -> Bool {
        if let next = moveSelection(stroke, in: rows.map(\.id), from: selection) {
            selection = next
            return true
        }
        if stroke.plain("n") {
            addToken += 1
            return true
        }
        if stroke.plain("l") {
            model.openPalette(.looseEnds)
            return true
        }
        guard let task = rows.first(where: { $0.id == selection }), let index = rows.firstIndex(of: task) else { return false }
        switch stroke.key {
        case .space where stroke.mods.isEmpty:
            Haptics.success()
            selection = rows.indices.contains(index + 1) ? rows[index + 1].id : rows.dropLast().last?.id
            model.complete(task)
        case .enter where stroke.mods == .command: store.start(task)
        case .enter where stroke.mods.isEmpty: model.inspect(task)
        case .delete where stroke.mods.isEmpty:
            selection = rows.indices.contains(index + 1) ? rows[index + 1].id : nil
            model.delete([task])
        case .up where stroke.mods == .command: move(task, by: -1, in: rows)
        case .down where stroke.mods == .command: move(task, by: 1, in: rows)
        case .char("s") where stroke.mods.isEmpty: model.askSnooze([task])
        case .char("p") where stroke.mods.isEmpty: store.update(task, ["pinned": .bool(!task.pinned)])
        case .char(let ch) where stroke.mods.isEmpty && "0123".contains(ch):
            store.update(task, ["priority": .number(Double(String(ch))!)])
        default: return false
        }
        return true
    }

    private func move(_ task: TaskItem, by delta: Int, in rows: [TaskItem]) {
        var ids = rows.map(\.id)
        guard let from = ids.firstIndex(of: task.id), ids.indices.contains(from + delta) else { return }
        ids.swapAt(from, from + delta)
        Haptics.tick()
        store.reorder(ids)
    }
}

/// Live reordering: rows make room as the dragged one passes over them; the drop commits the order.
private struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var order: [String]?
    @Binding var dragging: String?
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, var ids = order, let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        Haptics.tick()
        withAnimation(Motion.snappy) { order = ids }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let order { commit(order) }
        dragging = nil
        // Hold the dragged order until the brain's reordered list arrives, or the rows would jump back for a frame.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            order = nil
        }
        return true
    }
}

private struct TodayHeader: View {
    let now: TaskItem?
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(Date().formatted(.dateTime.weekday(.wide))).font(Typo.display).foregroundStyle(Palette.text)
                    Text(Date().formatted(.dateTime.day().month(.wide))).font(.system(size: 17, design: .rounded)).foregroundStyle(Palette.textFaint)
                }
                Live(every: 60) { date in stateLine(date) }
            }
            Spacer(minLength: Space.m)
            if let now {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    Text("Focus").font(Typo.caption).foregroundStyle(Palette.textDim)
                    FocusTimer(since: now.startedAt ?? now.updatedAt, font: Typo.numeric)
                }
                .padding(.horizontal, Space.s + 2)
                .frame(height: 26)
                .background(Palette.accent.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1))
                .help("Time since “\(now.title)” was last started or edited")
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, 22)
        .padding(.bottom, Space.l)
        .frame(minHeight: 84, alignment: .bottom)
        OfflineBanner(connection: store.connection, note: store.brainNote) { store.refresh() }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, store.connection.isOnline ? 0 : Space.m)
    }

    private func stateLine(_ date: Date) -> some View {
        let left = store.meetings.filter { Calendar.current.isDate($0.startAt, inSameDayAs: date) && $0.endAt > date }.count
        let counts = store.snapshot?.counts
        let waiting = store.sessions.filter(\.needsAttention).count
        var parts: [(String, Color)] = []
        parts.append((left == 0 ? "No meetings left" : "\(left) meeting\(left == 1 ? "" : "s") left", Palette.textDim))
        if let overdue = counts?.overdue, overdue > 0 { parts.append(("\(overdue) overdue", Palette.danger)) }
        parts.append(("\(counts?.dueToday ?? 0) due today", Palette.textDim))
        if waiting > 0 { parts.append(("\(waiting) session\(waiting == 1 ? "" : "s") waiting", Palette.accent)) }
        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").foregroundStyle(Palette.textFaint) }
                Text(part.0).foregroundStyle(part.1)
            }
        }
        .font(Typo.body)
    }
}

/// Counts up from `since`; ticks once a second without touching anything else.
struct FocusTimer: View {
    let since: Date
    var font: Font = Typo.numeric

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = max(0, Int(context.date.timeIntervalSince(since)))
            Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
                .font(font).foregroundStyle(Palette.text).contentTransition(.numericText())
        }
    }
}

private struct NowCard: View {
    let task: TaskItem?
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        Group {
            if let task { active(task) } else { idle }
        }
        .animation(Motion.resist, value: task?.id)
    }

    private var idle: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "play.circle").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing in progress").font(Typo.heading).foregroundStyle(Palette.textDim)
                Text("Pick a task below and press ⌘↩, or double-click it.").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            Spacer()
            Button("Pick a task…") { model.openPalette(.startTask) }.buttonStyle(.pressable())
        }
        .padding(Space.l)
        .cardSurface(radius: Radius.l)
        .transition(.opacity)
    }

    private func active(_ task: TaskItem) -> some View {
        let project = store.tree.allProjects.first { $0.id == task.projectId }
        let sessions = store.sessions.filter { $0.taskId == task.id }
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Space.s) {
                        Text("NOW").font(Typo.label).kerning(0.8).foregroundStyle(Palette.accent)
                        if let project {
                            HStack(spacing: 4) {
                                Circle().fill(Color(hexString: project.color) ?? Palette.textDim).frame(width: 6, height: 6)
                                Text(project.title).font(Typo.caption).foregroundStyle(Palette.textDim)
                            }
                        }
                    }
                    Text(task.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Flow(spacing: 5) {
                        if let dueAt = task.dueAt {
                            let due = Fmt.due(dueAt)
                            Pill(due.text, icon: "calendar", color: due.overdue ? Palette.danger : Palette.textDim)
                        }
                        ForEach(task.scoreReasons, id: \.self) { ReasonChip(text: $0) }
                    }
                }
                Spacer(minLength: Space.s)
                VStack(alignment: .trailing, spacing: 4) {
                    FocusTimer(since: task.startedAt ?? task.updatedAt, font: .system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    if let minutes = task.estimateMin {
                        Live(every: 20) { date in
                            let fraction = date.timeIntervalSince(task.startedAt ?? task.updatedAt) / (Double(minutes) * 60)
                            VStack(alignment: .trailing, spacing: 4) {
                                Meter(fraction: fraction, color: fraction > 1 ? Palette.danger : Palette.accent, height: 3).frame(width: 96)
                                Text("of \(Fmt.span(Double(minutes) * 60)) planned").font(Typo.caption).foregroundStyle(Palette.textFaint)
                            }
                        }
                    }
                }
            }
            HStack(spacing: Space.s) {
                Button {
                    Haptics.success()
                    model.complete(task)
                } label: { Label("Complete", systemImage: "checkmark") }
                    .buttonStyle(.pressable(.primary)).labelStyle(.titleAndIcon).fixedSize()
                Button("Pause", systemImage: "pause.fill") { store.update(task, ["status": "todo"]) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                    .help("Put it back in the list")
                Button("Switch…", systemImage: "arrow.left.arrow.right") { model.openPalette(.startTask) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                Spacer(minLength: Space.s)
                ForEach(sessions) { session in SessionChip(session: session) { app.focus(session) } }
                IconButton(icon: "sidebar.right", help: "Open") { model.inspect(task) }
            }
        }
        .padding(Space.l)
        .background(
            LinearGradient(colors: [Palette.accent.opacity(0.13), Palette.accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .continuous(Radius.l))
        .background(Palette.bgRaised, in: .continuous(Radius.l))
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.accent.opacity(0.28), lineWidth: 1))
        .taskMenu(task)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

// MARK: - Right rail

private struct TodayRail: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            timeline
            sessions
            looseEnds
            approvals
            brief
        }
        .onAppear { store.need(.notes, .looseEnds) }
    }

    /// Things promised or started and then left: the count, the oldest few, each opening its place.
    @ViewBuilder private var looseEnds: some View {
        let all = store.looseEnds.all
        if !all.isEmpty {
            Card(title: "Loose ends", count: all.count) {
                Button { model.openPalette(.looseEnds) } label: {
                    HStack(spacing: 4) { Text(all.count > 4 ? "All \(all.count)" : "All"); KeyHint("L") }.font(Typo.caption).foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.pressable(.bare))
            } content: {
                VStack(spacing: 1) {
                    ForEach(store.looseEnds.top(4)) { end in LooseEndLine(end: end) }
                }
                .animation(Motion.settle, value: all.map(\.id))
            }
        }
    }

    private enum Entry: Identifiable {
        case meeting(Meeting), task(TaskItem), marker(Date)

        var id: String {
            switch self {
            case .meeting(let m): "m:\(m.id)"
            case .task(let t): "t:\(t.id)"
            case .marker: "now"
            }
        }

        var time: Date {
            switch self {
            case .meeting(let m): m.startAt
            case .task(let t): t.dueAt ?? .distantFuture
            case .marker(let d): d
            }
        }
    }

    private var timeline: some View {
        Live(every: 60) { now in
            let cal = Calendar.current
            let meetings = store.meetings.filter { cal.isDate($0.startAt, inSameDayAs: now) }
            let due = model.visible(store.tasks).filter { $0.dueAt.map { cal.isDate($0, inSameDayAs: now) } ?? false }
            let entries = (meetings.map(Entry.meeting) + due.map(Entry.task) + [.marker(now)]).sorted { $0.time < $1.time }
            Card("Today's timeline") {
                if meetings.isEmpty && due.isEmpty {
                    Text("No meetings and nothing due today.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .meeting(let meeting): MeetingLine(meeting: meeting, now: now)
                        case .task(let task): dueLine(task, now: now)
                        case .marker(let date): if !(meetings.isEmpty && due.isEmpty) { nowLine(date) }
                        }
                    }
                }
            }
        }
    }

    private func nowLine(_ date: Date) -> some View {
        HStack(spacing: 6) {
            Text(Fmt.time(date)).font(Typo.numeric).foregroundStyle(Palette.accent).frame(width: 62, alignment: .leading)
            Circle().fill(Palette.accent).frame(width: 5, height: 5)
            Rectangle().fill(Palette.accent.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 3)
    }

    private func dueLine(_ task: TaskItem, now: Date) -> some View {
        Button { model.inspect(task) } label: {
            HStack(spacing: 6) {
                Text(Fmt.time(task.dueAt ?? now)).font(Typo.numeric).foregroundStyle((task.dueAt ?? now) < now ? Palette.danger : Palette.textDim).frame(width: 62, alignment: .leading)
                Image(systemName: "circle").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.priority(task.priority))
                Text(task.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                Text("due").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .rowSurface(radius: Radius.s)
        }
        .buttonStyle(.pressable(.bare, haptic: false))
    }

    @ViewBuilder private var sessions: some View {
        let list = store.sessions.sorted { SessionOrder.key($0) < SessionOrder.key($1) }
        Card(title: "Sessions", count: list.filter(\.needsAttention).count) {
            Button("All") { model.go(.sessions) }.buttonStyle(.pressable(.bare)).font(Typo.caption).foregroundStyle(Palette.textFaint)
        } content: {
            if list.isEmpty {
                Text("No coding sessions running.").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            VStack(spacing: 1) {
                ForEach(list) { session in
                    Button { app.focus(session) } label: { RadarLine(session: session) }
                        .buttonStyle(.pressable(.bare))
                        .help("Bring this session's window to the front")
                }
            }
            .animation(Motion.settle, value: list.map(\.id))
        }
    }

    @ViewBuilder private var approvals: some View {
        if !store.approvals.isEmpty {
            Card(title: "Needs your approval", count: store.approvals.count) {
                Button("Review") { model.go(.inbox) }.buttonStyle(.pressable(.bare)).font(Typo.caption).foregroundStyle(Palette.accent)
            } content: {
                ForEach(store.approvals) { approval in
                    Button { model.go(.inbox) } label: {
                        HStack(alignment: .top, spacing: Space.s) {
                            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Palette.danger).frame(width: 14, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(approval.summary).font(Typo.body).foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
                                if let target = approval.target { Text(target).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(.bare, haptic: false))
                }
            }
        }
    }

    @ViewBuilder private var brief: some View {
        if let note = store.notes.filter({ $0.kind == .brief }).max(by: { $0.updatedAt < $1.updatedAt }) {
            Card(title: "Latest brief") {
                Text("\(Fmt.since(note.updatedAt)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint)
            } content: {
                Button {
                    model.focusNoteId = note.id
                    model.go(.notes)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                        Text(Self.excerpt(note.body)).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(5).lineSpacing(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(.bare, haptic: false))
            }
        }
    }

    /// The brief's first few lines of prose, without markdown syntax.
    static func excerpt(_ markdown: String) -> String {
        Markdown.blocks(markdown).compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .quote(let text): text
            case .list(let items): items.prefix(4).map { "• \($0.text)" }.joined(separator: "\n")
            default: nil
            }
        }
        .prefix(3).joined(separator: "\n")
        .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

/// One loose end: what it is, why it counts as left, and how long. The row opens its place; the way out to another
/// app and "not a loose end" are the two small buttons that appear under the pointer.
struct LooseEndLine: View {
    let end: LooseEnd
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Button { model.open(end) } label: {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: end.kind.icon).font(.system(size: 10, weight: .medium)).foregroundStyle(end.kind.color).frame(width: 12, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(end.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                        Text(end.reason).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: Space.xs)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.pressable(.bare, haptic: false))
            .help(end.place == nil ? "Nothing tracks this yet: make it a task and open it" : "Open it in Steward")
            // Fixed width whether or not the buttons show, so the text does not reflow under the pointer.
            ZStack(alignment: .trailing) {
                Text(Fmt.since(end.since)).font(Typo.numeric).foregroundStyle(Palette.textFaint).opacity(hovered ? 0 : 1)
                HStack(spacing: 0) {
                    if let url = end.url, AppContext.canOpen(url) { IconButton(icon: "arrow.up.right", help: "Open in its own app", size: 20) { app.open(url) } }
                    IconButton(icon: "xmark", help: "Not a loose end", size: 20) { store.dismiss(end) }
                }
                .opacity(hovered ? 1 : 0)
            }
            .frame(width: 44, height: 20, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .rowSurface(radius: Radius.s)
        .onHover { hovered = $0 }
    }
}

/// Sort key that floats sessions needing the user to the top: blocked, then waiting (longest first), working, idle.
enum SessionOrder {
    static func key(_ session: CodeSession) -> (Int, Date) {
        switch session.state {
        case .blocked: (0, session.stateSince)
        case .waiting: (1, session.stateSince)
        case .working: (2, session.stateSince)
        case .idle: (3, session.stateSince)
        case .ended, .unknown: (4, session.stateSince)
        }
    }
}

/// One session on the radar: state, where, what, and how long it has been that way.
struct RadarLine: View {
    let session: CodeSession

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            StateDot(session.state, size: 7).frame(width: 12, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.displayName).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                    if let ticket = session.ticket { Text(ticket).font(Typo.caption).foregroundStyle(Palette.info).lineLimit(1) }
                }
                Text(session.title ?? session.branch ?? session.cwd).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            Live(every: 30) { now in
                Text(Fmt.since(session.stateSince, now: now)).font(Typo.numeric)
                    .foregroundStyle(session.needsAttention ? Palette.session(session.state) : Palette.textFaint)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .rowSurface(radius: Radius.s)
    }
}

/// A meeting on the timeline: time, title, Join when it is close, and whether prep exists.
private struct MeetingLine: View {
    let meeting: Meeting
    let now: Date
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        let live = meeting.startAt <= now && now < meeting.endAt
        let past = meeting.endAt <= now
        let soon = !live && !past && meeting.startAt.timeIntervalSince(now) < 15 * 60
        HStack(alignment: .top, spacing: 6) {
            Text(Fmt.time(meeting.startAt)).font(Typo.numeric).foregroundStyle(live ? Palette.accent : Palette.textDim).frame(width: 62, alignment: .leading).frame(height: 16)
            RoundedRectangle.continuous(1.5).fill(live ? Palette.accent : Palette.info.opacity(past ? 0.3 : 0.8)).frame(width: 3).padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.span(meeting.endAt.timeIntervalSince(meeting.startAt))).font(Typo.caption).foregroundStyle(Palette.textFaint)
                    if !meeting.attendees.isEmpty { Text(meeting.attendees.count == 1 ? meeting.attendees[0] : "\(meeting.attendees.count) people").font(Typo.caption).foregroundStyle(Palette.textFaint) }
                    if !past { prep }
                }
            }
            Spacer(minLength: Space.xs)
            if live { Pill("Now", color: Palette.accent) } else if soon { Pill("in \(Fmt.span(meeting.startAt.timeIntervalSince(now)))", color: Palette.warn) }
            if meeting.joinUrl != nil, live || soon {
                Button("Join") { app.open(meeting.joinUrl) }.buttonStyle(.pressable(.primary))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .opacity(past ? 0.5 : 1)
        .rowSurface(radius: Radius.s)
        .onTapGesture { model.go(.meetings) }
    }

    @ViewBuilder private var prep: some View {
        if meeting.prepNote != nil {
            Label("Prep ready", systemImage: "checkmark.circle.fill").font(Typo.caption).foregroundStyle(Palette.ok).labelStyle(.titleAndIcon)
        } else if meeting.prepStatus == .running {
            Text("Preparing…").font(Typo.caption).foregroundStyle(Palette.violet)
        } else {
            Button("Prepare") { model.prepare(meeting) }.buttonStyle(.pressable(.bare)).font(Typo.caption).foregroundStyle(Palette.violet)
        }
    }
}

/// An empty list says how to fill it: the capture hotkey, the add key, and (until projects exist) the one-off scan.
private struct TodayEmpty: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app

    var body: some View {
        let capture = store.setting("hotkeys.capture").string?.nonEmpty
        let fresh = store.tree.initiatives.isEmpty && store.tree.looseProjects.isEmpty
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "checkmark.circle").font(.system(size: 18, weight: .light)).foregroundStyle(Palette.textFaint)
                Text(fresh ? "Nothing on your list yet" : "Nothing waiting").font(Typo.heading).foregroundStyle(Palette.textDim)
            }
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                if let capture {
                    GridRow {
                        KeyHint(HotkeyCombo.display(capture)).gridColumnAlignment(.trailing)
                        Text("Capture a thought from any app. Steward files it as tasks: “send Sam the numbers tomorrow !!”").font(Typo.caption).foregroundStyle(Palette.textDim)
                    }
                }
                GridRow {
                    KeyHint("N").gridColumnAlignment(.trailing)
                    Text("Add a task here. ! sets priority, # a project, @ a person.").font(Typo.caption).foregroundStyle(Palette.textDim)
                }
            }
            if fresh {
                HStack(spacing: Space.m) {
                    Button("Learn about my work…", systemImage: "sparkle.magnifyingglass") { withAnimation(Motion.snappy) { app.showOnboarding = true } }
                        .buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                    Text("One scan proposes your projects, people and first tasks. About $1–2.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.l)
    }
}
