import SwiftUI
import StewardKit

/// Every task, open or closed: filter, search, group, sort, multi-select with bulk actions.
struct TasksScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var query = TaskQuery()
    /// Keyboard cursor.
    @State private var selection: String?
    /// Multi-selection; bulk actions apply to it.
    @State private var checked: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var addToken = 0
    @AppStorage("tasks.grouping") private var grouping = TaskQuery.Grouping.none.rawValue
    @AppStorage("tasks.sort") private var sort = TaskQuery.Sort.rank.rawValue

    var body: some View {
        let projects = Dictionary(store.tree.allProjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions = Dictionary(grouping: store.sessions.filter { $0.taskId != nil }, by: { $0.taskId! })
        let source = model.library.loaded ? model.library.tasks : store.tasks
        let groups = effectiveQuery.apply(model.visible(source), projects: projects.mapValues(\.title), sessionTaskIds: Set(sessions.keys))
        let visible = groups.flatMap { collapsed.contains($0.id) ? [] : $0.tasks }
        let total = groups.reduce(0) { $0 + $1.tasks.count }

        ScreenScaffold(title: "Tasks", subtitle: subtitle(total, of: source.count), scrolls: false) {
            SearchField(text: $query.search, placeholder: "Search tasks", focusToken: model.searchToken)
        } content: {
            VStack(spacing: 0) {
                filters(projects: store.tree.allProjects, source: source)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                            QuickAddField(focusToken: addToken) { draft in
                                var fields = draft.fields(projects: store.tree.allProjects)
                                if case .id(let id) = query.project, fields["projectId"].isNull { fields = fields.setting("projectId", to: .string(id)) }
                                store.addTask(draft.title, fields: fields)
                            }
                            .padding(.bottom, Space.s)
                            if groups.isEmpty { empty(source.isEmpty) }
                            ForEach(groups) { group in
                                Section {
                                    if !collapsed.contains(group.id) {
                                        ForEach(group.tasks) { task in
                                            row(task, project: effectiveQuery.grouping == .project ? nil : projects[task.projectId ?? ""], sessions: sessions[task.id], visible: visible)
                                        }
                                    }
                                } header: {
                                    if !group.title.isEmpty { header(group) }
                                }
                            }
                        }
                        .padding(.horizontal, Space.xl)
                        .padding(.bottom, checked.isEmpty ? Space.xl : 72)
                    }
                    .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
                }
                KeyLegend([(["J", "K"], "move"), (["X"], "select"), (["␣"], "complete"), (["↩"], "open"), (["S"], "snooze"), (["P"], "pin"),
                           (["1", "2", "3"], "priority"), (["⌫"], "delete"), (["⌘", "A"], "all")])
            }
            .overlay(alignment: .bottom) {
                if !checked.isEmpty {
                    BulkBar(tasks: visible.filter { checked.contains($0.id) }) { withAnimation(Motion.snappy) { checked = [] } }
                        .padding(.bottom, 42)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.snappy, value: checked.isEmpty)
        .animation(Motion.settle, value: visible.map(\.id))
        .task(id: store.changes[.tasks]) { await model.library.refresh() }
        .screenKeys(model) { keys($0, visible) }
        .onAppear {
            model.screenHasSearch = true
            store.need(.people)
            applyScenario()
        }
        .onDisappear { model.screenHasSearch = false }
    }

    private var effectiveQuery: TaskQuery {
        var q = query
        q.grouping = TaskQuery.Grouping(rawValue: grouping) ?? .none
        q.sort = TaskQuery.Sort(rawValue: sort) ?? .rank
        return q
    }

    private func subtitle(_ shown: Int, of all: Int) -> String {
        shown == all ? "\(all) tasks" : "\(shown) of \(all) tasks"
    }

    private func applyScenario() {
        if let group = model.scenario["tasks.group"] { grouping = group }
        if model.scenario["tasks.statuses"] == "all" { query.statuses = [] }
        if let ids = model.scenario["tasks.selected"] { checked = Set(ids.split(separator: ",").map(String.init)) }
    }

    // MARK: Rows

    private func row(_ task: TaskItem, project: Project?, sessions: [CodeSession]?, visible: [TaskItem]) -> some View {
        TaskLine(task: task, project: project, selected: selection == task.id, checked: checked.isEmpty ? nil : checked.contains(task.id),
                 showReasons: task.isOpen, showScore: effectiveQuery.sort == .rank, sessionStates: sessions?.map(\.state) ?? [],
                 onComplete: { model.complete(task) },
                 onOpen: { open(task, visible) },
                 onStart: { store.start(task) },
                 onCheck: { toggle(task.id) })
            .equatable()
            .taskMenu(task)
            .id(task.id)
    }

    private func open(_ task: TaskItem, _ visible: [TaskItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggle(task.id)
        } else if flags.contains(.shift), let anchor = selection, let a = visible.firstIndex(where: { $0.id == anchor }), let b = visible.firstIndex(of: task) {
            checked.formUnion(visible[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = task.id
            model.inspect(task)
        }
    }

    private func toggle(_ id: String) {
        withAnimation(Motion.snappy) { if checked.contains(id) { checked.remove(id) } else { checked.insert(id) } }
        Haptics.tick()
    }

    private func header(_ group: TaskGroup) -> some View {
        let open = !collapsed.contains(group.id)
        return Button {
            withAnimation(Motion.snappy) { if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) } }
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.textFaint).rotationEffect(.degrees(open ? 90 : 0))
                Text(group.title).font(Typo.heading).foregroundStyle(group.id == "due:overdue" ? Palette.danger : Palette.text)
                Text("\(group.tasks.count)").font(Typo.numeric).foregroundStyle(Palette.textFaint)
                Spacer()
            }
            .padding(.horizontal, Space.s)
            .frame(height: 30)
            .background(Palette.bg)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(.bare, haptic: false))
        .padding(.top, Space.s)
    }

    @ViewBuilder private func empty(_ nothingAtAll: Bool) -> some View {
        if nothingAtAll {
            EmptyState(icon: "checklist", title: "No tasks yet", message: "Add one above. `!` sets priority, `#` picks a project, `@` adds a person.")
                .frame(height: 260)
        } else {
            EmptyState(icon: "line.3.horizontal.decrease.circle", title: "Nothing matches", message: "No task fits this search and these filters.",
                       actionTitle: "Clear filters") { withAnimation(Motion.snappy) { query = TaskQuery() } }
                .frame(height: 260)
        }
    }

    // MARK: Filters

    private func filters(projects: [Project], source: [TaskItem]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Flow(spacing: 6) {
                MenuChip(title: statusTitle, icon: "circle.dashed", active: query.statuses != TaskQuery().statuses) {
                    Button("Open") { query.statuses = TaskQuery().statuses }
                    Button("Everything") { query.statuses = [] }
                    Button("Closed") { query.statuses = [.done, .dropped] }
                    Divider()
                    ForEach([TaskStatus.inbox, .todo, .doing, .waiting, .done, .dropped], id: \.self) { status in
                        Toggle(status.title, isOn: member(status, in: \.statuses))
                    }
                }
                MenuChip(title: projectTitle(projects), icon: "square.stack.3d.up", active: query.project != .any) {
                    Button("Any project") { query.project = .any }
                    Button("No project") { query.project = .none }
                    Divider()
                    ForEach(projects) { project in Button(project.title) { query.project = .id(project.id) } }
                }
                MenuChip(title: query.priorities.isEmpty ? "Priority" : query.priorities.sorted(by: >).map(Priority.title).joined(separator: ", "), icon: "flag", active: !query.priorities.isEmpty) {
                    ForEach(Priority.all.reversed(), id: \.value) { option in Toggle(option.title, isOn: member(option.value, in: \.priorities)) }
                    Divider()
                    Button("Any priority") { query.priorities = [] }
                }
                MenuChip(title: query.sources.isEmpty ? "Source" : query.sources.map(\.title).sorted().joined(separator: ", "), icon: "arrow.down.right.circle", active: !query.sources.isEmpty) {
                    ForEach(Set(source.map(\.source)).sorted { $0.title < $1.title }, id: \.self) { kind in
                        Toggle(kind.title, isOn: member(kind, in: \.sources))
                    }
                    Divider()
                    Button("Any source") { query.sources = [] }
                }
                MenuChip(title: query.person ?? "Person", icon: "person", active: query.person != nil) {
                    Button("Anyone") { query.person = nil }
                    Divider()
                    ForEach(people(source), id: \.self) { name in Button(name) { query.person = name } }
                }
                ToggleChip(title: "Has session", icon: "terminal", isOn: $query.hasSession)
                ToggleChip(title: "Waiting on", icon: "hourglass", isOn: $query.waitingOnly)
                if query.activeFilterCount > 0 {
                    Button("Clear") { withAnimation(Motion.snappy) { query = TaskQuery() } }
                        .buttonStyle(.pressable(.bare)).font(Typo.caption).foregroundStyle(Palette.textDim).padding(.horizontal, 4).frame(height: 24)
                }
            }
            MenuChip(title: "Group: \(grouping.capitalized)", icon: "rectangle.3.group") {
                Picker("Group by", selection: $grouping) {
                    ForEach(TaskQuery.Grouping.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            MenuChip(title: "Sort: \(sort.capitalized)", icon: "arrow.up.arrow.down") {
                Picker("Sort by", selection: $sort) {
                    ForEach(TaskQuery.Sort.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.m)
    }

    private var statusTitle: String {
        if query.statuses.isEmpty { return "Everything" }
        if query.statuses == TaskQuery().statuses { return "Open" }
        return TaskStatus.allCases.filter(query.statuses.contains).map(\.title).joined(separator: ", ")
    }

    private func projectTitle(_ projects: [Project]) -> String {
        switch query.project {
        case .any: "Project"
        case .none: "No project"
        case .id(let id): projects.first { $0.id == id }?.title ?? "Project"
        }
    }

    private func people(_ tasks: [TaskItem]) -> [String] {
        Array(Set(store.people.map(\.name) + tasks.flatMap(\.people) + tasks.compactMap(\.waitingOn))).sorted()
    }

    private func member<T: Hashable>(_ value: T, in path: WritableKeyPath<TaskQuery, Set<T>>) -> Binding<Bool> {
        Binding(get: { query[keyPath: path].contains(value) },
                set: { on in if on { query[keyPath: path].insert(value) } else { query[keyPath: path].remove(value) } })
    }

    // MARK: Keys

    private func keys(_ stroke: KeyStroke, _ visible: [TaskItem]) -> Bool {
        let ids = visible.map(\.id)
        if let next = moveSelection(stroke, in: ids, from: selection) {
            selection = next
            return true
        }
        // ⇧J / ⇧K extend the selection while moving.
        if stroke.shift("j") || stroke.shift("k") || (stroke.mods == .shift && (stroke.key == .down || stroke.key == .up)) {
            let down = stroke.shift("j") || stroke.key == .down
            if let next = moveSelection(KeyStroke(down ? .down : .up), in: ids, from: selection) {
                if let selection { checked.insert(selection) }
                checked.insert(next)
                selection = next
            }
            return true
        }
        if stroke.plain("n") { addToken += 1; return true }
        if stroke.plain("/") { model.searchToken += 1; return true }
        if stroke.command("a") { checked = Set(ids); return true }
        if stroke.plain(.escape), !checked.isEmpty {
            withAnimation(Motion.snappy) { checked = [] }
            return true
        }
        // Actions apply to the multi-selection when there is one, else to the cursor row.
        let targets = checked.isEmpty ? visible.filter { $0.id == selection } : visible.filter { checked.contains($0.id) }
        guard !targets.isEmpty else { return false }
        switch stroke.key {
        case .char("x") where stroke.mods.isEmpty:
            if let selection { toggle(selection) }
        case .space where stroke.mods.isEmpty:
            Haptics.success()
            advance(past: targets, in: visible)
            model.complete(targets.filter(\.isOpen))
            checked = []
        case .enter where stroke.mods.isEmpty:
            if let task = visible.first(where: { $0.id == selection }) { model.inspect(task) }
        case .enter where stroke.mods == .command:
            if let task = visible.first(where: { $0.id == selection }) { store.start(task) }
        case .delete where stroke.mods.isEmpty:
            advance(past: targets, in: visible)
            model.delete(targets)
            checked = []
        case .char("s") where stroke.mods.isEmpty: model.askSnooze(targets)
        case .char("p") where stroke.mods.isEmpty: targets.forEach { store.update($0, ["pinned": .bool(!$0.pinned)]) }
        case .char(let ch) where stroke.mods.isEmpty && "0123".contains(ch):
            targets.forEach { store.update($0, ["priority": .number(Double(String(ch))!)]) }
        default: return false
        }
        return true
    }

    /// Moves the cursor to the row after the ones about to leave the list.
    private func advance(past targets: [TaskItem], in visible: [TaskItem]) {
        let leaving = Set(targets.map(\.id))
        guard let selection, leaving.contains(selection), let index = visible.firstIndex(where: { $0.id == selection }) else { return }
        self.selection = (visible[index...].first { !leaving.contains($0.id) } ?? visible[..<index].last { !leaving.contains($0.id) })?.id
    }
}

/// Floating bar for the multi-selection.
private struct BulkBar: View {
    let tasks: [TaskItem]
    let onClear: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s) {
            Text("\(tasks.count) selected").font(Typo.bodyStrong).foregroundStyle(Palette.text).contentTransition(.numericText()).fixedSize().padding(.trailing, Space.xs)
            Button("Complete", systemImage: "checkmark") {
                model.complete(tasks.filter(\.isOpen))
                onClear()
            }
            .buttonStyle(.pressable(.primary)).labelStyle(.titleAndIcon).fixedSize()
            MenuChip(title: "Priority", icon: "flag") {
                ForEach(Priority.all.reversed(), id: \.value) { option in
                    Button(option.title) { each(["priority": .number(Double(option.value))]) }
                }
            }
            MenuChip(title: "Project", icon: "square.stack.3d.up") {
                Button("None") { each(["projectId": .null]) }
                ForEach(store.tree.allProjects) { project in Button(project.title) { each(["projectId": .string(project.id)]) } }
            }
            MenuChip(title: "Status", icon: "circle.dashed") {
                ForEach([TaskStatus.inbox, .todo, .waiting, .dropped], id: \.self) { status in
                    Button(status.title) { each(["status": .string(status.rawValue)]) }
                }
            }
            Button("Snooze", systemImage: "moon.zzz") { model.askSnooze(tasks) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
            Button("Delete", systemImage: "trash") {
                model.delete(tasks)
                onClear()
            }
            .buttonStyle(.pressable(.danger)).labelStyle(.titleAndIcon).fixedSize()
            IconButton(icon: "xmark", help: "Clear selection (esc)", action: onClear)
        }
        .padding(.leading, Space.l)
        .padding(.trailing, Space.s)
        .frame(height: 44)
        .background(Palette.bgRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.strokeStrong, lineWidth: 1))
        .elevation(3)
    }

    private func each(_ patch: JSONValue) {
        tasks.forEach { store.update($0, patch) }
    }
}
