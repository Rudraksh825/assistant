import SwiftUI
import StewardKit

/// What is selected in the Projects tree.
enum ProjectPick: Hashable {
    case initiative(String), project(String), looseTasks

    var scrollId: String {
        switch self {
        case .initiative(let id): "i:\(id)"
        case .project(let id): "p:\(id)"
        case .looseTasks: "loose-tasks"
        }
    }
}

/// The tree as the screen shows it: ranked by weight, minus rows waiting on an undo, with progress per project.
struct ProjectOutline {
    struct Progress {
        var done = 0
        var total = 0
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    var initiatives: [InitiativeNode] = []
    var loose: [ProjectNode] = []
    var looseTasks: [TaskItem] = []
    var progress: [String: Progress] = [:]
    var tasks: [TaskItem] = []

    init(tree: Tree, hidden: Set<String>, tasks: [TaskItem]) {
        self.tasks = tasks.filter { !hidden.contains($0.id) }
        // Weight is the ranking: heavier first, title only breaks ties.
        func ranked(_ nodes: [ProjectNode]) -> [ProjectNode] {
            nodes.filter { !hidden.contains($0.id) }.sorted {
                ($0.project.weight, $1.project.title.lowercased()) > ($1.project.weight, $0.project.title.lowercased())
            }
        }
        initiatives = tree.initiatives.filter { !hidden.contains($0.id) }
            .map { node in
                var node = node
                node.projects = ranked(node.projects)
                return node
            }
            .sorted { ($0.initiative.weight, $1.initiative.title.lowercased()) > ($1.initiative.weight, $0.initiative.title.lowercased()) }
        loose = ranked(tree.looseProjects)
        for node in tree.initiatives.flatMap(\.projects) + tree.looseProjects {
            progress[node.id] = Progress(done: node.doneTasks, total: node.openTasks + node.doneTasks)
        }
        looseTasks = self.tasks.filter { $0.projectId == nil && $0.isOpen }
    }

    var isEmpty: Bool { initiatives.isEmpty && loose.isEmpty }
    var allProjects: [ProjectNode] { initiatives.flatMap(\.projects) + loose }

    /// Every selectable row, top to bottom.
    var picks: [ProjectPick] {
        initiatives.flatMap { [.initiative($0.id)] + $0.projects.map { .project($0.id) } } + loose.map { .project($0.id) } + [.looseTasks]
    }

    func progress(of node: InitiativeNode) -> Progress {
        node.projects.reduce(into: Progress()) { sum, project in
            sum.done += progress[project.id]?.done ?? 0
            sum.total += progress[project.id]?.total ?? 0
        }
    }

    func initiative(of pick: ProjectPick?) -> InitiativeNode? {
        switch pick {
        case .initiative(let id): initiatives.first { $0.id == id }
        case .project(let id): initiatives.first { $0.projects.contains { $0.id == id } }
        default: nil
        }
    }
}

/// Runs a write against the brain and keeps the last failure for display. The tree itself comes back through the store.
@MainActor @Observable
final class ProjectWrites {
    var error: String?

    func run(_ op: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await op()
                error = nil
            } catch {
                withAnimation(Motion.snappy) { self.error = error.brief }
            }
        }
    }
}

enum ProjectStyle {
    static func color(_ project: Project) -> Color { Color(hexString: project.color) ?? nameTint(project.title) }

    static func weightTitle(_ weight: Int) -> String {
        switch weight {
        case 3: "Top of the list"
        case 2: "Important"
        case 1: "Background"
        default: "Parked"
        }
    }

    static func title(_ status: WorkStatus) -> String { status == .unknown ? "Active" : status.rawValue.capitalized }
    static let statuses: [WorkStatus] = [.active, .paused, .done, .dropped]
}

/// Initiatives → projects, ranked by weight. Where the owner says which areas matter most.
struct ProjectsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var selection: ProjectPick?
    @State private var renaming: ProjectPick?
    @State private var dragging: String?
    @State private var dropTarget: String?
    @State private var projectToken = 0
    @State private var initiativeToken = 0
    @State private var taskToken = 0
    @State private var writes = ProjectWrites()

    var body: some View {
        let outline = ProjectOutline(tree: store.tree, hidden: model.hidden, tasks: model.library.loaded ? model.library.tasks : store.tasks)
        ScreenScaffold(title: "Projects", subtitle: subtitle(outline), scrolls: false) {
            VStack(spacing: 0) {
                if let error = writes.error {
                    InlineNotice(text: error, icon: "exclamationmark.triangle", color: Palette.danger)
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.m)
                }
                if outline.isEmpty {
                    empty
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        tree(outline).frame(width: 420)
                        Rectangle().fill(Palette.stroke).frame(width: 1)
                        ProjectDetailPane(pick: selection, outline: outline, writes: writes, addToken: taskToken) { pick in
                            withAnimation(Motion.snappy) { selection = pick }
                        } onDelete: { delete($0, outline) }
                    }
                }
                KeyLegend([(["J", "K"], "move"), (["0", "1", "2", "3"], "weight"), (["↩"], "rename"), (["N"], "new project"), (["⇧", "N"], "new initiative"), (["A"], "add task"), (["⌫"], "delete")])
            }
        }
        .animation(Motion.settle, value: outline.picks)
        .task(id: store.changes[.tasks]) { await model.library.refresh() }
        .screenKeys(model) { keys($0, outline) }
        .onAppear { focus(outline) }
        .onChange(of: model.focusProjectId) { focus(outline) }
    }

    private func subtitle(_ outline: ProjectOutline) -> String {
        outline.isEmpty ? "Nothing yet" : "\(outline.initiatives.count) initiatives · \(outline.allProjects.count) projects · ranked by weight"
    }

    private func focus(_ outline: ProjectOutline) {
        if let id = model.focusProjectId {
            selection = .project(id)
            model.focusProjectId = nil
        } else if let preset = model.scenario["projects.pick"], selection == nil {
            selection = preset == "loose" ? .looseTasks : .initiative(preset)
        } else if selection == nil {
            selection = outline.picks.first { if case .project = $0 { true } else { false } } ?? outline.picks.first
        }
    }

    private var empty: some View {
        VStack(spacing: Space.s) {
            EmptyState(icon: "square.stack.3d.up", title: "Create your first initiative",
                       message: "An initiative is an area you own. Give it projects, then weigh them 0–3: the weights feed the ranking on Today.")
                .frame(maxHeight: 220)
            ProjectAddField(placeholder: "Name an initiative…", icon: "flag", focusToken: initiativeToken, action: addInitiative).frame(width: 340)
            ProjectAddField(placeholder: "…or just a project", icon: "plus", focusToken: projectToken) { addProject($0, under: nil) }.frame(width: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tree

    private func tree(_ outline: ProjectOutline) -> some View {
        let parent = outline.initiative(of: selection)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ForEach(Array(outline.initiatives.enumerated()), id: \.element.id) { index, node in
                            initiativeCard(node, rank: index + 1, outline)
                        }
                        looseCard(outline)
                    }
                    .padding(.leading, Space.xl)
                    .padding(.trailing, Space.l)
                    .padding(.bottom, Space.l)
                }
                .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection.scrollId) } } }
            }
            VStack(spacing: Space.s) {
                ProjectAddField(placeholder: parent.map { "New project in \($0.initiative.title)…" } ?? "New loose project…", icon: "plus", hint: "N",
                                focusToken: projectToken) { addProject($0, under: parent?.id) }
                ProjectAddField(placeholder: "New initiative…", icon: "flag", hint: "⇧N", focusToken: initiativeToken, action: addInitiative)
            }
            .padding(.leading, Space.xl)
            .padding(.trailing, Space.l)
            .padding(.vertical, Space.m)
            .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
        }
    }

    private func initiativeCard(_ node: InitiativeNode, rank: Int, _ outline: ProjectOutline) -> some View {
        let pick = ProjectPick.initiative(node.id)
        return VStack(alignment: .leading, spacing: 1) {
            ProjectInitiativeRow(node: node, rank: rank, progress: outline.progress(of: node).fraction, selected: selection == pick, renaming: renaming == pick,
                                 onWeight: { setWeight(pick, $0, outline) }, onRename: { rename(pick, $0) })
                .id(pick.scrollId)
                .onTapGesture { select(pick) }
                .contextMenu { menu(pick, outline) }
            ForEach(Array(node.projects.enumerated()), id: \.element.id) { index, project in
                projectRow(project, rank: index + 1, outline)
            }
            if node.projects.isEmpty {
                Text("No projects yet. Drag one here, or press N.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                    .padding(.leading, 34).padding(.vertical, 6)
            }
        }
        .padding(Space.xs + 2)
        .cardSurface(radius: Radius.l)
        .overlay(dropRing(node.id))
        .opacity(node.initiative.status == .active || node.initiative.status == .unknown ? 1 : 0.6)
        .onDrop(of: [.text], isTargeted: targeted(node.id)) { _ in drop(onto: node.id) }
    }

    private func looseCard(_ outline: ProjectOutline) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                SectionLabel("Loose projects", count: outline.loose.count)
                Spacer()
                Text("no initiative").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, Space.s)
            .frame(height: 26)
            ForEach(Array(outline.loose.enumerated()), id: \.element.id) { index, project in
                projectRow(project, rank: index + 1, outline)
            }
            HStack(spacing: Space.s) {
                Image(systemName: "tray").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textDim).frame(width: 30, alignment: .trailing)
                Text("Loose tasks").font(Typo.body).foregroundStyle(Palette.text)
                Spacer()
                Text("\(outline.looseTasks.count) open").font(Typo.numeric).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, Space.s)
            .frame(height: 32)
            .rowSurface(selected: selection == .looseTasks)
            .id(ProjectPick.looseTasks.scrollId)
            .onTapGesture { select(.looseTasks) }
        }
        .padding(Space.xs + 2)
        .cardSurface(radius: Radius.l)
        .overlay(dropRing("loose"))
        .onDrop(of: [.text], isTargeted: targeted("loose")) { _ in drop(onto: nil) }
    }

    private func projectRow(_ node: ProjectNode, rank: Int, _ outline: ProjectOutline) -> some View {
        let pick = ProjectPick.project(node.id)
        return ProjectTreeRow(node: node, rank: rank, progress: outline.progress[node.id]?.fraction ?? 0, selected: selection == pick, renaming: renaming == pick,
                              onWeight: { setWeight(pick, $0, outline) }, onRename: { rename(pick, $0) })
            .id(pick.scrollId)
            .opacity(dragging == node.id ? 0.4 : 1)
            .onTapGesture { select(pick) }
            .contextMenu { menu(pick, outline) }
            .onDrag {
                dragging = node.id
                return NSItemProvider(object: node.id as NSString)
            }
    }

    private func dropRing(_ id: String) -> some View {
        RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.accent, lineWidth: 1.5)
            .opacity(dropTarget == id && dragging != nil ? 1 : 0)
            .animation(Motion.snappy, value: dropTarget)
            .allowsHitTesting(false)
    }

    private func targeted(_ id: String) -> Binding<Bool> {
        Binding(get: { dropTarget == id }, set: { inside in
            if inside { dropTarget = id } else if dropTarget == id { dropTarget = nil }
        })
    }

    @ViewBuilder private func menu(_ pick: ProjectPick, _ outline: ProjectOutline) -> some View {
        Button("Rename", systemImage: "pencil") { renaming = pick }
        Menu("Weight") {
            ForEach((0...3).reversed(), id: \.self) { weight in
                Button("\(weight) · \(ProjectStyle.weightTitle(weight))") { setWeight(pick, weight, outline) }
            }
        }
        Menu("Status") {
            ForEach(ProjectStyle.statuses, id: \.self) { status in
                Button(ProjectStyle.title(status)) { patch(pick, ["status": .string(status.rawValue)]) }
            }
        }
        if case .project(let id) = pick {
            Menu("Move to") {
                Button("No initiative") { patch(pick, ["initiativeId": .null]) }
                ForEach(outline.initiatives) { node in
                    Button(node.initiative.title) { patch(.project(id), ["initiativeId": .string(node.id)]) }
                }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(pick, outline) }
    }

    // MARK: Actions

    private func select(_ pick: ProjectPick) {
        withAnimation(Motion.snappy) { selection = pick }
    }

    private func patch(_ pick: ProjectPick, _ fields: JSONValue) {
        let client = store.client
        switch pick {
        case .initiative(let id): writes.run { _ = try await client.updateInitiative(id, fields) }
        case .project(let id): writes.run { _ = try await client.updateProject(id, fields) }
        case .looseTasks: break
        }
    }

    private func setWeight(_ pick: ProjectPick, _ weight: Int, _ outline: ProjectOutline) {
        guard pick != .looseTasks else { return }
        Haptics.tick()
        patch(pick, ["weight": .number(Double(min(3, max(0, weight))))])
    }

    private func rename(_ pick: ProjectPick, _ title: String?) {
        renaming = nil
        if let title { patch(pick, ["title": .string(title)]) }
    }

    private func addProject(_ title: String, under initiative: String?) {
        let client = store.client
        writes.run {
            let project = try await client.createProject(["title": .string(title), "initiativeId": initiative.map(JSONValue.string) ?? .null, "weight": 1])
            selection = .project(project.id)
        }
    }

    private func addInitiative(_ title: String) {
        let client = store.client
        writes.run {
            let initiative = try await client.createInitiative(["title": .string(title), "weight": 1])
            selection = .initiative(initiative.id)
        }
    }

    private func drop(onto initiative: String?) -> Bool {
        guard let id = dragging else { return false }
        dragging = nil
        dropTarget = nil
        Haptics.thunk()
        patch(.project(id), ["initiativeId": initiative.map(JSONValue.string) ?? .null])
        return true
    }

    private func delete(_ pick: ProjectPick, _ outline: ProjectOutline) {
        let client = store.client, writes = writes
        let picks = outline.picks
        let next = picks.firstIndex(of: pick).flatMap { index in picks.indices.contains(index + 1) ? picks[index + 1] : picks.dropLast().last }
        switch pick {
        case .initiative(let id):
            guard let node = outline.initiatives.first(where: { $0.id == id }) else { return }
            model.deferred("Deleted “\(node.initiative.title)”", hiding: [id]) { writes.run { try await client.deleteInitiative(id) } }
        case .project(let id):
            guard let node = outline.allProjects.first(where: { $0.id == id }) else { return }
            model.deferred("Deleted “\(node.project.title)”", hiding: [id]) { writes.run { try await client.deleteProject(id) } }
        case .looseTasks:
            return
        }
        selection = next
    }

    private func isInitiative(_ pick: ProjectPick?) -> Bool {
        if case .initiative = pick { true } else { false }
    }

    private func keys(_ stroke: KeyStroke, _ outline: ProjectOutline) -> Bool {
        if let next = moveSelection(stroke, in: outline.picks, from: selection) {
            selection = next
            return true
        }
        if stroke.plain("n") { projectToken += 1; return true }
        if stroke.shift("n") { initiativeToken += 1; return true }
        if stroke.plain("a"), selection != nil, !isInitiative(selection) { taskToken += 1; return true }
        guard let selection, selection != .looseTasks, stroke.mods.isEmpty else { return false }
        switch stroke.key {
        case .char(let ch) where "0123".contains(ch): setWeight(selection, Int(String(ch))!, outline)
        case .enter: renaming = selection
        case .delete: delete(selection, outline)
        default: return false
        }
        return true
    }
}

// MARK: - Tree rows

private struct ProjectInitiativeRow: View {
    let node: InitiativeNode
    let rank: Int
    let progress: Double
    let selected: Bool
    let renaming: Bool
    let onWeight: (Int) -> Void
    let onRename: (String?) -> Void

    var body: some View {
        let initiative = node.initiative
        let open = node.projects.reduce(0) { $0 + $1.openTasks }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Space.s) {
                Text("\(rank)").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.accent.opacity(0.9)).frame(width: 18, alignment: .trailing)
                if renaming {
                    ProjectRenameField(title: initiative.title, font: Typo.heading, onDone: onRename)
                } else {
                    Text(initiative.title).font(Typo.heading).foregroundStyle(Palette.text).lineLimit(1)
                }
                if let horizon = initiative.horizon, !horizon.isEmpty, !renaming { Pill(horizon, icon: "flag") }
                if initiative.status != .active, initiative.status != .unknown { Pill(ProjectStyle.title(initiative.status)) }
                Spacer(minLength: Space.s)
                Text("\(open) open").font(Typo.numeric).foregroundStyle(Palette.textFaint).fixedSize()
                WeightControl(weight: Int(initiative.weight), onChange: onWeight)
            }
            Meter(fraction: progress, color: Palette.accent.opacity(0.75), height: 3).padding(.leading, 26)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.s)
        .rowSurface(selected: selected)
    }
}

private struct ProjectTreeRow: View {
    let node: ProjectNode
    let rank: Int
    let progress: Double
    let selected: Bool
    let renaming: Bool
    let onWeight: (Int) -> Void
    let onRename: (String?) -> Void

    var body: some View {
        let project = node.project
        let color = ProjectStyle.color(project)
        let live = project.status == .active || project.status == .unknown
        HStack(spacing: Space.s) {
            Text("\(rank)").font(Typo.numeric).foregroundStyle(Palette.textFaint).frame(width: 18, alignment: .trailing)
            Circle().fill(color).frame(width: 8, height: 8)
            if renaming {
                ProjectRenameField(title: project.title, font: Typo.body, onDone: onRename)
            } else {
                Text(project.title).font(Typo.body).foregroundStyle(live ? Palette.text : Palette.textDim).lineLimit(1)
            }
            if !live { Pill(ProjectStyle.title(project.status)) }
            Spacer(minLength: Space.s)
            Text("\(node.openTasks)").font(Typo.numeric).foregroundStyle(node.openTasks > 0 ? Palette.textDim : Palette.textFaint).help("\(node.openTasks) open tasks")
            Meter(fraction: progress, color: color.opacity(0.85), height: 3).frame(width: 34)
            WeightControl(weight: Int(project.weight), color: color, onChange: onWeight)
        }
        .padding(.horizontal, Space.s)
        .frame(height: 32)
        .rowSurface(selected: selected)
    }
}

/// Title field for renaming in place: focused when it appears, Return commits, leaving it cancels.
private struct ProjectRenameField: View {
    let title: String
    let font: Font
    let onDone: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Palette.text)
            .focused($focused)
            .onAppear {
                text = title
                // Focus does not take inside the same update that inserts the field.
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit {
                let value = text.trimmingCharacters(in: .whitespaces)
                onDone(value.isEmpty || value == title ? nil : value)
            }
            .onChange(of: focused) { if !focused { onDone(nil) } }
    }
}

/// One-line create field that a key can focus.
private struct ProjectAddField: View {
    let placeholder: String
    let icon: String
    var hint = ""
    let focusToken: Int
    let action: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(focused ? Palette.accent : Palette.textFaint).frame(width: 16)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .onSubmit {
                    let value = text.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    text = ""
                    Haptics.tick()
                    action(value)
                }
            if !text.isEmpty { KeyHint("↩") } else if !focused, !hint.isEmpty { KeyHint(hint) }
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: 30)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
        .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: focused)
        .onChange(of: focusToken) { focused = true }
    }
}

// MARK: - Detail

/// Right column: the selected project, initiative, or the tasks that belong to no project.
private struct ProjectDetailPane: View {
    let pick: ProjectPick?
    let outline: ProjectOutline
    let writes: ProjectWrites
    let addToken: Int
    let onSelect: (ProjectPick) -> Void
    let onDelete: (ProjectPick) -> Void

    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var showDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                switch pick {
                case .project(let id):
                    if let node = outline.allProjects.first(where: { $0.id == id }) { project(node) } else { nothing }
                case .initiative(let id):
                    if let node = outline.initiatives.first(where: { $0.id == id }) { initiative(node) } else { nothing }
                case .looseTasks:
                    looseTasks
                case nil:
                    nothing
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nothing: some View {
        EmptyState(icon: "square.stack.3d.up", title: "Pick a project", message: "Its tasks, notes and progress show here.").frame(height: 300)
    }

    // MARK: Project

    @ViewBuilder private func project(_ node: ProjectNode) -> some View {
        let project = node.project
        let color = ProjectStyle.color(project)
        let tasks = outline.tasks.filter { $0.projectId == project.id }
        let progress = outline.progress[project.id] ?? .init()
        let client = store.client
        let save: (JSONValue) -> Void = { fields in writes.run { _ = try await client.updateProject(project.id, fields) } }

        HStack(spacing: Space.s) {
            Circle().fill(color).frame(width: 10, height: 10)
            CommitField(placeholder: "Project title", value: project.title, font: .system(size: 19, weight: .semibold)) { if !$0.isEmpty { save(["title": .string($0)]) } }
            Spacer(minLength: Space.s)
            IconButton(icon: "trash", help: "Delete project (⌫)") { onDelete(.project(project.id)) }
        }
        Flow(spacing: 6) {
            statusChip(project.status, save)
            MenuChip(title: outline.initiative(of: .project(project.id))?.initiative.title ?? "No initiative", icon: "flag",
                     active: project.initiativeId != nil) {
                Button("No initiative") { save(["initiativeId": .null]) }
                Divider()
                ForEach(outline.initiatives) { node in
                    Button(node.initiative.title) { save(["initiativeId": .string(node.id)]) }
                }
            }
            weightChip(Int(project.weight), color) { save(["weight": .number(Double($0))]) }
        }
        progressCard(progress, open: tasks.filter(\.isOpen).count, color: color)
        NotesEditor(text: project.notes, minHeight: 56) { save(["notes": .string($0)]) }.id(project.id)
        taskLists(tasks, projectId: project.id)
    }

    // MARK: Initiative

    @ViewBuilder private func initiative(_ node: InitiativeNode) -> some View {
        let initiative = node.initiative
        let client = store.client
        let save: (JSONValue) -> Void = { fields in writes.run { _ = try await client.updateInitiative(initiative.id, fields) } }
        let open = node.projects.reduce(0) { $0 + $1.openTasks }

        HStack(spacing: Space.s) {
            Image(systemName: "flag.fill").font(.system(size: 12)).foregroundStyle(Palette.accent)
            CommitField(placeholder: "Initiative title", value: initiative.title, font: .system(size: 19, weight: .semibold)) { if !$0.isEmpty { save(["title": .string($0)]) } }
            Spacer(minLength: Space.s)
            IconButton(icon: "trash", help: "Delete initiative (⌫)") { onDelete(.initiative(initiative.id)) }
        }
        Flow(spacing: 6) {
            statusChip(initiative.status, save)
            weightChip(Int(initiative.weight), Palette.accent) { save(["weight": .number(Double($0))]) }
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textDim)
                CommitField(placeholder: "Horizon (Q4, ongoing…)", value: initiative.horizon ?? "", font: Typo.caption) {
                    save(["horizon": $0.isEmpty ? .null : .string($0)])
                }
                .frame(width: 120)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Palette.hover, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        }
        progressCard(outline.progress(of: node), open: open, color: Palette.accent)
        NotesEditor(text: initiative.notes, minHeight: 56) { save(["notes": .string($0)]) }.id(initiative.id)
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Projects", count: node.projects.count).padding(.horizontal, Space.s)
            if node.projects.isEmpty {
                Text("No projects under this initiative yet. Press N to add one, or drag one onto it.")
                    .font(Typo.caption).foregroundStyle(Palette.textFaint).padding(.horizontal, Space.s)
            }
            ForEach(node.projects) { child in
                let progress = outline.progress[child.id] ?? .init()
                HStack(spacing: Space.s) {
                    Circle().fill(ProjectStyle.color(child.project)).frame(width: 8, height: 8)
                    Text(child.project.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text("\(progress.done) of \(progress.total) done").font(Typo.caption).foregroundStyle(Palette.textFaint)
                    Meter(fraction: progress.fraction, color: ProjectStyle.color(child.project), height: 3).frame(width: 80)
                    Text("\(child.openTasks) open").font(Typo.numeric).foregroundStyle(Palette.textDim).frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, Space.s)
                .frame(height: 32)
                .rowSurface()
                .onTapGesture { onSelect(.project(child.id)) }
            }
        }
    }

    // MARK: Loose tasks

    @ViewBuilder private var looseTasks: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "tray").font(.system(size: 14)).foregroundStyle(Palette.textDim)
            Text("Loose tasks").font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.text)
        }
        Text("Open tasks that belong to no project. Give them one from the right-click menu, or type #project when adding.")
            .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
        taskLists(outline.tasks.filter { $0.projectId == nil }, projectId: nil)
    }

    // MARK: Shared pieces

    private func statusChip(_ status: WorkStatus, _ save: @escaping (JSONValue) -> Void) -> some View {
        MenuChip(title: ProjectStyle.title(status), icon: "circle.dashed", active: status != .active && status != .unknown) {
            ForEach(ProjectStyle.statuses, id: \.self) { option in
                Button(ProjectStyle.title(option)) { save(["status": .string(option.rawValue)]) }
            }
        }
    }

    private func weightChip(_ weight: Int, _ color: Color, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            WeightControl(weight: weight, color: color) {
                Haptics.tick()
                onChange($0)
            }
            Text("Weight \(weight) · \(ProjectStyle.weightTitle(weight))").font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Palette.hover, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
    }

    private func progressCard(_ progress: ProjectOutline.Progress, open: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("\(Int((progress.fraction * 100).rounded()))%").font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Palette.text)
                Text(progress.total == 0 ? "No tasks yet" : "\(progress.done) of \(progress.total) done").font(Typo.body).foregroundStyle(Palette.textDim)
                Spacer()
                Text("\(open) open").font(Typo.numeric).foregroundStyle(Palette.textDim)
            }
            Meter(fraction: progress.fraction, color: color, height: 6)
        }
        .padding(Space.m)
        .cardSurface(radius: Radius.l)
    }

    @ViewBuilder private func taskLists(_ tasks: [TaskItem], projectId: String?) -> some View {
        let open = tasks.filter(\.isOpen)
        let done = tasks.filter { $0.status == .done }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: Space.xs) {
            QuickAddField(placeholder: projectId == nil ? "Add a task…   !priority  #project  @person" : "Add a task to this project…   !priority  @person",
                          focusToken: addToken, hint: "A") { draft in
                var fields = draft.fields(projects: store.tree.allProjects)
                if let projectId, fields["projectId"].isNull { fields = fields.setting("projectId", to: .string(projectId)) }
                store.addTask(draft.title, fields: fields)
            }
            .padding(.bottom, Space.xs)
            SectionLabel("Open", count: open.count).padding(.horizontal, Space.s + 2).padding(.top, Space.xs)
            if open.isEmpty {
                Text(done.isEmpty ? "Nothing here yet." : "Everything here is done.").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(.horizontal, Space.s + 2).padding(.vertical, Space.xs)
            }
            ForEach(open) { task in line(task) }
            if !done.isEmpty {
                Button {
                    withAnimation(Motion.snappy) { showDone.toggle() }
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.textFaint).rotationEffect(.degrees(showDone ? 90 : 0))
                        SectionLabel("Done", count: done.count)
                        Spacer()
                    }
                    .padding(.horizontal, Space.s + 2)
                    .frame(height: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(.bare, haptic: false))
                .padding(.top, Space.s)
                if showDone { ForEach(done) { task in line(task) } }
            }
        }
    }

    private func line(_ task: TaskItem) -> some View {
        TaskLine(task: task, selected: model.inspectedTaskId == task.id, showReasons: task.isOpen, showScore: true,
                 onComplete: { model.complete(task) }, onOpen: { model.inspect(task) }, onStart: { store.start(task) })
            .equatable()
            .taskMenu(task)
    }
}
