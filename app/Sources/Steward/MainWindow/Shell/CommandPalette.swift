import SwiftUI
import StewardKit

/// ⌘K: one field over routes, tasks, projects, sessions, people and actions. Also the global
/// "add task" (⌘N) and "ask agent" entry, and the task picker behind "Start…" / "Complete…".
struct CommandPalette: View {
    let mode: MainWindowModel.PaletteMode

    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let kind: String
        let icon: String
        var tint: Color = Palette.textDim
        let title: String
        var subtitle = ""
        var hint = ""
        var boost = 0
        /// Stays open after running (mode switches).
        var keepsOpen = false
        let run: (_ alternate: Bool) -> Void
    }

    static let prompts: [(slash: String, title: String, prompt: String)] = [
        ("/brief", "Brief me", "Give me a brief: what changed since I last looked, what needs me now, and what can wait."),
        ("/plan my day", "Plan my day", "Plan my day around my meetings, due dates and waiting sessions. Propose an order and say what to drop."),
        ("/what's waiting on me", "What's waiting on me", "What is waiting on me right now across sessions, chat, reviews and tickets? Most urgent first."),
        ("/recap sessions", "Recap sessions", "Recap my coding sessions: what each one did, where it stopped and what it needs from me."),
        ("/loose ends", "Loose ends", "Go through my loose ends: read them with the loose_ends tool, then tell me which to finish, which to hand back and which to drop, oldest promise first."),
    ]

    var body: some View {
        let items = results()
        let _ = install(items)
        ZStack(alignment: .top) {
            Color.black.opacity(0.42).contentShape(.rect).onTapGesture { model.closePalette() }
            VStack(spacing: 0) {
                HStack(spacing: Space.s + 2) {
                    Image(systemName: modeIcon).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 20)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.text)
                        .focused($focused)
                    if mode != .commands { Pill(modeTitle, color: Palette.accent) }
                    KeyHint("esc")
                }
                .padding(.horizontal, Space.l)
                .frame(height: 52)

                if mode == .addTask, !query.isEmpty { addPreview }

                if !items.isEmpty {
                    Rectangle().fill(Palette.stroke).frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    row(item, selected: index == selection)
                                        .id(item.id)
                                        .onTapGesture { run(item, alternate: false) }
                                }
                            }
                            .padding(Space.s)
                        }
                        .frame(maxHeight: 372)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: selection) { if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) } }
                    }
                }
                Rectangle().fill(Palette.stroke).frame(height: 1)
                HStack(spacing: Space.m) {
                    hint(["↑", "↓"], "move")
                    hint(["↩"], footerPrimary)
                    if mode == .commands { hint(["⌘", "↩"], "start task") }
                    if mode == .looseEnds { hint(["⌘", "↩"], "not a loose end") }
                    Spacer()
                    if mode == .addTask || mode == .commands { Text("!priority  #project  @person").font(Typo.mono).foregroundStyle(Palette.textFaint) }
                }
                .padding(.horizontal, Space.l)
                .frame(height: 32)
                .background(Palette.bgSunken.opacity(0.6))
            }
            .frame(width: 640)
            .background(Palette.bgRaised, in: .continuous(Radius.l))
            .clipShape(.continuous(Radius.l))
            .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.strokeStrong, lineWidth: 1))
            .elevation(4)
            .padding(.top, 96)
            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }
        .onAppear {
            focused = true
            if let preset = model.scenario["palette.query"] { query = preset }
            if mode == .commands { store.need(.people) }
            if mode == .commands || mode == .looseEnds { store.need(.looseEnds) }
        }
        .onChange(of: query) { selection = 0 }
        .onDisappear { model.paletteKeys = nil }
    }

    // MARK: Rows

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: Space.s + 2) {
            Image(systemName: item.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Palette.accent : item.tint).frame(width: 20)
            Text(item.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1) }
            Spacer(minLength: Space.s)
            if !item.hint.isEmpty { Text(item.hint).font(Typo.caption).foregroundStyle(Palette.textFaint) }
            Text(kindTitle(item.kind)).font(Typo.label).kerning(0.4).foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: 32)
        .background(selected ? Palette.accent.opacity(0.13) : .clear, in: .continuous(Radius.s + 1))
        .contentShape(.rect)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) { ForEach(keys, id: \.self) { KeyHint($0) } }
            Text(label).font(Typo.caption).foregroundStyle(Palette.textFaint)
        }
    }

    private var addPreview: some View {
        let draft = QuickAdd.parse(query)
        let project = draft.project(in: store.tree.allProjects)
        return HStack(spacing: Space.xs) {
            Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(Palette.priority(draft.priority ?? 0))
            Text(draft.title.isEmpty ? "Untitled" : draft.title).font(Typo.bodyStrong).foregroundStyle(draft.title.isEmpty ? Palette.textFaint : Palette.text).lineLimit(1)
            if let priority = draft.priority { Pill(Priority.title(priority), color: Palette.priority(priority), style: .outline) }
            if let project { Pill(project.title, icon: "square.stack.3d.up", color: Color(hexString: project.color) ?? Palette.textDim) }
            ForEach(draft.people, id: \.self) { Pill($0, icon: "person") }
            Spacer()
        }
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.m)
    }

    private var placeholder: String {
        switch mode {
        case .commands: "Search tasks, projects, sessions, people, or run a command"
        case .addTask: "New task…"
        case .askAgent: "Ask Steward…"
        case .startTask: "Start which task?"
        case .completeTask: "Complete which task?"
        case .looseEnds: "Promised or started, then left"
        }
    }

    private var modeIcon: String {
        switch mode {
        case .commands: "magnifyingglass"
        case .addTask: "plus"
        case .askAgent: "sparkles"
        case .startTask: "play"
        case .completeTask: "checkmark"
        case .looseEnds: "point.3.connected.trianglepath.dotted"
        }
    }

    private var modeTitle: String {
        switch mode {
        case .commands: ""
        case .addTask: "Add task"
        case .askAgent: "Ask agent"
        case .startTask: "Start"
        case .completeTask: "Complete"
        case .looseEnds: "Loose ends"
        }
    }

    private var footerPrimary: String {
        switch mode {
        case .commands: "open"
        case .addTask: "add"
        case .askAgent: "send"
        case .startTask: "start"
        case .completeTask: "complete"
        case .looseEnds: "open its place"
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "route": "GO TO"
        case "prompt": "AGENT"
        case "loose": "LOOSE END"
        default: kind.uppercased()
        }
    }

    // MARK: Results

    private func results() -> [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .addTask:
            return []
        case .askAgent:
            let prompts = promptItems()
            return text.isEmpty ? prompts : prompts.filter { Fuzzy.score(text, in: $0.title + " " + $0.subtitle) != nil }
        case .startTask, .completeTask:
            let pool = taskItems(action: mode)
            return ranked(pool, text, perKind: 30, showAllWhenEmpty: true)
        case .looseEnds:
            return ranked(looseEndItems(), text, perKind: 60, showAllWhenEmpty: true)
        case .commands:
            var out = ranked(actionItems() + taskItems(action: nil) + projectItems() + sessionItems() + looseEndItems() + personItems() + promptItems() + routeItems(), text, perKind: 6, showAllWhenEmpty: false)
            if !text.isEmpty {
                out.append(Item(id: "fallback:add", kind: "action", icon: "plus", title: "Add task “\(text)”") { _ in add(text) })
                out.append(Item(id: "fallback:ask", kind: "action", icon: "sparkles", title: "Ask agent “\(text)”") { _ in model.ask(text) })
            }
            return out
        }
    }

    private func ranked(_ items: [Item], _ text: String, perKind: Int, showAllWhenEmpty: Bool) -> [Item] {
        if text.isEmpty, showAllWhenEmpty { return Array(items.prefix(60)) }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = items.map { PaletteCandidate(id: $0.id, kind: $0.kind, title: $0.title, subtitle: $0.subtitle, boost: $0.boost) }
        return PaletteRanker.results(candidates, query: text, perKind: perKind).compactMap { byId[$0.id] }
    }

    private func actionItems() -> [Item] {
        var items = [
            Item(id: "a:add", kind: "action", icon: "plus", title: "Add task…", hint: "⌘N", boost: 9, keepsOpen: true) { _ in switchTo(.addTask) },
            Item(id: "a:ask", kind: "action", icon: "sparkles", title: "Ask agent…", boost: 8, keepsOpen: true) { _ in switchTo(.askAgent) },
            Item(id: "a:start", kind: "action", icon: "play", title: "Start task…", boost: 7, keepsOpen: true) { _ in switchTo(.startTask) },
            Item(id: "a:complete", kind: "action", icon: "checkmark", title: "Complete task…", boost: 6, keepsOpen: true) { _ in switchTo(.completeTask) },
            Item(id: "a:loose", kind: "action", icon: "point.3.connected.trianglepath.dotted", title: "Loose ends…", subtitle: store.looseEnds.count > 0 ? "\(store.looseEnds.count)" : "",
                 boost: 4, keepsOpen: true) { _ in switchTo(.looseEnds) },
        ]
        if let now = store.snapshot?.now {
            items.append(Item(id: "a:done-now", kind: "action", icon: "checkmark.circle", tint: Palette.ok, title: "Complete current task", subtitle: now.title, boost: 12) { _ in model.complete(now) })
            items.append(Item(id: "a:pause-now", kind: "action", icon: "pause", title: "Pause current task", subtitle: now.title, boost: 5) { _ in store.update(now, ["status": "todo"]) })
        }
        items += [
            Item(id: "a:rerank", kind: "action", icon: "arrow.up.arrow.down", title: "Rerank tasks now") { _ in Task { try? await store.client.rerankTasks() } },
            Item(id: "a:refresh", kind: "action", icon: "arrow.clockwise", title: "Refresh everything") { _ in store.refresh() },
            Item(id: "a:data", kind: "action", icon: "folder", title: "Reveal data folder in Finder") { _ in NSWorkspace.shared.activateFileViewerSelecting([store.client.dataDir.url]) },
        ]
        if model.undoEntry != nil {
            items.append(Item(id: "a:undo", kind: "action", icon: "arrow.uturn.backward", title: "Undo last action", hint: "⌘Z", boost: 11) { _ in model.performUndo() })
        }
        return items
    }

    private func taskItems(action: MainWindowModel.PaletteMode?) -> [Item] {
        model.visible(store.tasks).map { task in
            Item(id: "t:\(task.id)", kind: "task", icon: task.status.icon, tint: Palette.priority(task.priority), title: task.title,
                 subtitle: store.projectTitle(task.projectId) ?? "", boost: task.status == .doing ? 3 : 0) { alternate in
                switch action {
                case .startTask: store.start(task)
                case .completeTask: model.complete(task)
                default: if alternate { store.start(task) } else { model.inspect(task) }
                }
            }
        }
    }

    private func projectItems() -> [Item] {
        store.tree.allProjects.map { project in
            Item(id: "p:\(project.id)", kind: "project", icon: "square.stack.3d.up", tint: Color(hexString: project.color) ?? Palette.textDim, title: project.title) { _ in
                model.focusProjectId = project.id
                model.go(.projects)
            }
        }
    }

    private func sessionItems() -> [Item] {
        store.sessions.map { session in
            Item(id: "s:\(session.id)", kind: "session", icon: "terminal", tint: Palette.session(session.state), title: session.displayName,
                 subtitle: session.title ?? session.branch ?? "", hint: session.needsAttention ? "\(session.state.rawValue) \(Fmt.since(session.stateSince))" : "",
                 boost: session.state == .blocked ? 10 : session.state == .waiting ? 9 : 0) { alternate in
                // ↩ opens the session's page; ⌘↩ goes to its window when one is open.
                if alternate { app.focus(session) } else { model.openSession(session.id) }
            }
        }
    }

    private func looseEndItems() -> [Item] {
        store.looseEnds.all.map { end in
            Item(id: "l:\(end.id)", kind: "loose", icon: end.kind.icon, tint: end.kind.color, title: end.title, subtitle: end.reason, hint: Fmt.since(end.since)) { alternate in
                if alternate { store.dismiss(end) } else { model.open(end) }
            }
        }
    }

    private func personItems() -> [Item] {
        store.people.map { person in
            Item(id: "h:\(person.id)", kind: "person", icon: "person", title: person.name) { _ in
                model.focusPersonId = person.id
                model.go(.people)
            }
        }
    }

    private func promptItems() -> [Item] {
        Self.prompts.map { prompt in
            Item(id: "q:\(prompt.slash)", kind: "prompt", icon: "sparkles", tint: Palette.violet, title: prompt.title, subtitle: prompt.slash) { _ in model.ask(prompt.prompt) }
        }
    }

    private func routeItems() -> [Item] {
        Route.allCases.map { route in
            Item(id: "r:\(route.rawValue)", kind: "route", icon: route.icon, title: route.title, hint: route.shortcut, boost: route == app.route ? 0 : 1) { _ in model.go(route) }
        }
    }

    // MARK: Actions

    private func switchTo(_ next: MainWindowModel.PaletteMode) {
        query = ""
        model.openPalette(next)
    }

    private func add(_ text: String) {
        let draft = QuickAdd.parse(text)
        guard !draft.title.isEmpty else { return }
        store.addTask(draft.title, fields: draft.fields(projects: store.tree.allProjects))
        Haptics.success()
    }

    private func run(_ item: Item, alternate: Bool) {
        item.run(alternate)
        if !item.keepsOpen { model.closePalette() }
    }

    private func submit(_ items: [Item], alternate: Bool) {
        let text = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .addTask:
            guard !text.isEmpty else { return }
            add(text)
            model.closePalette()
        case .askAgent where !text.isEmpty && (items.isEmpty || !text.hasPrefix("/")):
            model.ask(text)
            model.closePalette()
        default:
            if items.indices.contains(selection) { run(items[selection], alternate: alternate) }
        }
    }

    /// The window's key monitor sends navigation keys here while the palette is open; typing reaches the field.
    private func install(_ items: [Item]) {
        model.paletteKeys = { stroke in
            switch stroke.key {
            case .down:
                if !items.isEmpty { selection = (selection + 1) % items.count }
                return true
            case .up:
                if !items.isEmpty { selection = (selection - 1 + items.count) % items.count }
                return true
            case .enter:
                submit(items, alternate: stroke.mods.contains(.command))
                return true
            case .delete where query.isEmpty && mode != .commands:
                switchTo(.commands)
                return true
            default:
                return false
            }
        }
    }
}
