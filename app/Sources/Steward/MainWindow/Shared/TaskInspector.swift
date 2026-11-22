import SwiftUI
import StewardKit

/// The task's place: everything about one task, editable in place, with where it came from, what was fetched
/// about it, what it touches and what can be done about it from here. Slides in on the right of any screen
/// (`model.inspect(task)`).
struct TaskInspector: View {
    let taskId: String

    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var task: TaskItem?
    @State private var children: [TaskItem] = []
    @State private var parent: TaskItem?
    @State private var missing = false
    @State private var spentMs: Double?
    @State private var newLink = ""
    @State private var place: TaskPlace?
    /// Why "See more" or "Draft a reply" could not start (agent off, budget spent, nothing to read).
    @State private var contextRefusal: String?
    @State private var draftRefusal: String?
    /// Set when the draft was asked for from this inspector, so its arrival can go to the clipboard.
    @State private var awaitingDraft = false
    @State private var draftCopied = false

    var body: some View {
        VStack(spacing: 0) {
            if let task {
                header(task)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        CommitField(placeholder: "Title", value: task.title, font: .system(size: 17, weight: .semibold), axis: .vertical) {
                            if !$0.isEmpty { patch(["title": .string($0)]) }
                        }
                        .lineLimit(1...4)
                        if !task.scoreReasons.isEmpty {
                            Flow(spacing: 5) {
                                Text("\(Int(task.score))").font(Typo.numeric).foregroundStyle(Palette.accent)
                                ForEach(task.scoreReasons, id: \.self) { ReasonChip(text: $0) }
                            }
                        }
                        source(task)
                        act(task)
                        properties(task)
                        block("Notes") { NotesEditor(text: task.notes) { patch(["notes": .string($0)]) } }
                        subtasks(task)
                        sessions(task)
                        links(task)
                        related
                        footer(task)
                    }
                    .padding(Space.l)
                }
                keyStrip
            } else if missing {
                EmptyState(icon: "questionmark.circle", title: "Task not found", message: "It may have been deleted.", actionTitle: "Close") { model.inspect(nil) }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.bg)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.stroke).frame(width: 1) }
        .task(id: store.changes[.tasks]) {
            if task == nil { task = model.library.task(taskId) }
            do { task = try await store.client.task(taskId) } catch { missing = task == nil }
            if let list = try? await store.client.tasks(parentId: taskId) { children = list }
            if let parentId = task?.parentId { parent = try? await store.client.task(parentId) } else { parent = nil }
        }
        .task {
            let summary = try? await store.client.activitySummary(from: Date().addingTimeInterval(-30 * 86_400), to: Date())
            spentMs = summary?.byTask.first { $0.taskId == taskId }?.ms
        }
        .task(id: placeKey) {
            if let fetched = try? await store.client.taskPlace(taskId) { withAnimation(Motion.snappy) { place = fetched } }
        }
        .onChange(of: place?.context?.draftAt) { draftArrived() }
        .onAppear { model.inspectorKeys = (taskId, keys) }
        .onDisappear { if model.inspectorKeys?.taskId == taskId { model.inspectorKeys = nil } }
    }

    /// Everything the place is built from: a change to any of these can change what it shows.
    private var placeKey: String {
        [BrainEvent.Entity.places, .tasks, .sessions, .suggestions, .approvals, .meetings].map { String(store.changes[$0] ?? 0) }.joined(separator: ".")
    }

    private func patch(_ fields: JSONValue) {
        Task {
            guard let updated = try? await store.client.updateTask(taskId, fields) else { return }
            withAnimation(Motion.snappy) { task = updated }
            model.library.apply(updated)
        }
    }

    // MARK: Place: source, context, actions

    @ViewBuilder private func source(_ task: TaskItem) -> some View {
        if let place, !place.origins.isEmpty || place.seeMoreVia != nil || place.context?.body.isEmpty == false {
            block("Where this came from") {
                SourcePanel(origins: place.origins, context: place.context, via: place.seeMoreVia, refusal: contextRefusal, keyHint: ["⌥", "M"]) { seeMore(refresh: $0) }
            }
        }
    }

    private func seeMore(refresh: Bool) {
        guard place?.seeMoreVia != nil, place?.context?.status != .running else { return }
        contextRefusal = nil
        Task {
            do {
                let context = try await store.client.seeMore(task: taskId, refresh: refresh)
                withAnimation(Motion.snappy) { place?.context = context }
            } catch {
                withAnimation(Motion.snappy) { contextRefusal = error.brief }
            }
        }
    }

    @ViewBuilder private func act(_ task: TaskItem) -> some View {
        let context = place?.context
        let drafting = context?.draftStatus == .running
        block("Act") {
            Flow(spacing: 6) {
                if place?.replyVia != nil {
                    Button { draftReply() } label: {
                        HStack(spacing: 6) {
                            if drafting { ProgressView().controlSize(.mini) } else { Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10, weight: .semibold)) }
                            Text(drafting ? "Drafting…" : context?.draft == nil ? "Draft a reply" : "Draft again")
                            KeyHint("⌥", "R")
                        }
                    }
                    .buttonStyle(.pressable()).fixedSize().disabled(drafting)
                    .help("The agent writes a reply in your voice and files it for your approval. Nothing is sent until you approve it.")
                }
                Button { askAgent(task) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                        Text("Ask the agent")
                        KeyHint("⌥", "A")
                    }
                }
                .buttonStyle(.pressable()).fixedSize()
                .help("Open the chat with this task attached")
            }
            if let draft = context?.draft, !drafting { draftCard(draft, context) }
            if let problem = draftRefusal ?? (context?.draftStatus == .failed ? context?.draftNote ?? "The draft failed." : nil) {
                InlineNotice(text: problem, icon: "exclamationmark.triangle", color: Palette.warn)
            }
        }
    }

    private func draftCard(_ draft: String, _ context: ItemContext?) -> some View {
        let waiting = store.approvals.contains { $0.id == context?.draftApprovalId }
        return VStack(alignment: .leading, spacing: 6) {
            Text(draft).font(Typo.body).foregroundStyle(Palette.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: Space.s) {
                Image(systemName: waiting ? "hand.raised.fill" : "doc.on.clipboard").font(.system(size: 10)).foregroundStyle(waiting ? Palette.danger : Palette.textDim)
                Text(waiting ? "Waiting in Approvals. Nothing is sent until you approve it." : draftCopied ? "Copied to the clipboard. \(context?.draftNote ?? "")" : context?.draftApprovalId != nil ? "Already decided in Approvals." : context?.draftNote ?? "")
                    .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if waiting {
                    Button("Review and approve") { app.open(view: "approvals") }.buttonStyle(.pressable(.primary)).fixedSize()
                }
                Button(draftCopied ? "Copied" : "Copy") {
                    copyToPasteboard(draft)
                    withAnimation(Motion.snappy) { draftCopied = true }
                }
                .buttonStyle(.pressable(.ghost)).fixedSize()
            }
        }
        .padding(Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.violet.opacity(0.06), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.violet.opacity(0.25), lineWidth: 1))
    }

    private func draftReply() {
        guard place?.replyVia != nil, place?.context?.draftStatus != .running else { return }
        draftRefusal = nil
        draftCopied = false
        awaitingDraft = true
        Task {
            do {
                let context = try await store.client.draftReply(task: taskId)
                withAnimation(Motion.snappy) { place?.context = context }
            } catch {
                awaitingDraft = false
                withAnimation(Motion.snappy) { draftRefusal = error.brief }
            }
        }
    }

    /// A draft that could not be queued for approval has nowhere else to go: it is put on the clipboard, and the note says so.
    private func draftArrived() {
        guard awaitingDraft, let context = place?.context, context.draftStatus != .running else { return }
        awaitingDraft = false
        if context.draftStatus == .ok, context.draftApprovalId == nil, let draft = context.draft {
            copyToPasteboard(draft)
            withAnimation(Motion.snappy) { draftCopied = true }
        }
    }

    private func askAgent(_ task: TaskItem) {
        model.agentContext = [.init(kind: .task, id: task.id, title: task.title)]
        model.go(.agent)
    }

    @ViewBuilder private var related: some View {
        if let related = place?.related, !related.isEmpty {
            block("Related", count: related.count) {
                VStack(spacing: 1) {
                    ForEach(related.tasks, id: \.task.id) { item in
                        relatedRow(item.task.status.icon, item.task.status.color, item.task.title, item.why) { model.inspect(item.task) }
                    }
                    ForEach(related.suggestions, id: \.suggestion.id) { item in
                        relatedRow("tray", Palette.accent, item.suggestion.title, "suggested · \(item.why)") { app.open(view: Route.inbox.rawValue, path: "/suggestions/\(item.suggestion.id)") }
                    }
                    ForEach(related.sessions, id: \.session.id) { item in
                        relatedRow("terminal", Palette.session(item.session.state), item.session.title ?? item.session.displayName, "\(item.session.state.rawValue) · \(item.why)") { model.openSession(item.session.id) }
                    }
                    ForEach(related.meetings, id: \.meeting.id) { item in
                        relatedRow("calendar", Palette.info, item.meeting.title, "\(Fmt.day(item.meeting.startAt)) · \(item.why)") { app.open(view: Route.meetings.rawValue, path: "/meetings/\(item.meeting.id)") }
                    }
                }
            }
        }
    }

    private func relatedRow(_ icon: String, _ tint: Color, _ title: String, _ why: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                    Text(why).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, 4)
            .rowSurface()
        }
        .buttonStyle(.pressable(.bare, haptic: false))
    }

    private var keyStrip: some View {
        HStack(spacing: Space.s + 2) {
            ForEach(Array([("M", "more"), ("R", "reply"), ("A", "ask"), ("O", "source")].enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 4) {
                    HStack(spacing: 2) { KeyHint("⌥"); KeyHint(entry.0) }
                    Text(entry.1).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    private func keys(_ stroke: KeyStroke) -> Bool {
        guard stroke.mods == .option, case .char(let ch) = stroke.key, let task else { return false }
        switch ch {
        case "m": seeMore(refresh: place?.context?.body.isEmpty == false)
        case "r": draftReply()
        case "a": askAgent(task)
        case "o": app.open(place?.origins.compactMap(\.url).first ?? task.links.first?.url)
        default: return false
        }
        return true
    }

    // MARK: Header

    private func header(_ task: TaskItem) -> some View {
        HStack(spacing: Space.s) {
            MenuChip(title: task.status.title, icon: task.status.icon, active: task.status == .doing) {
                ForEach([TaskStatus.inbox, .todo, .doing, .waiting, .done, .dropped], id: \.self) { status in
                    Button(status.title, systemImage: status.icon) { patch(["status": .string(status.rawValue)]) }
                }
            }
            if task.isOpen {
                if task.status != .doing {
                    Button("Start", systemImage: "play.fill") { store.start(task) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon)
                }
                Button("Complete", systemImage: "checkmark") { model.complete(task) }.buttonStyle(.pressable(.primary)).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            IconButton(icon: task.pinned ? "pin.fill" : "pin", help: task.pinned ? "Unpin" : "Pin", tint: task.pinned ? Palette.accent : Palette.textDim) {
                patch(["pinned": .bool(!task.pinned)])
            }
            IconButton(icon: "xmark", help: "Close (esc)") { model.inspect(nil) }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, 22)
        .padding(.bottom, Space.m)
        .frame(minHeight: 72, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    // MARK: Properties

    private func properties(_ task: TaskItem) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: Space.s + 2) {
            row("Priority") {
                Segmented(Priority.all.map { ($0.value, $0.title, nil) }, selection: Binding(get: { task.priority }, set: { patch(["priority": .number(Double($0))]) }))
            }
            row("Project") {
                let project = store.tree.allProjects.first { $0.id == task.projectId }
                MenuChip(title: project?.title ?? "None", icon: "square.stack.3d.up", active: project != nil) {
                    Button("None") { patch(["projectId": .null]) }
                    Divider()
                    ForEach(store.tree.allProjects) { project in
                        Button(project.title) { patch(["projectId": .string(project.id)]) }
                    }
                }
            }
            row("Dates") {
                Flow(spacing: 5) {
                    DateChip(title: "Due", icon: "calendar", date: task.dueAt, withTime: true) { patch(["dueAt": .ms($0)]) }
                    DateChip(title: "Scheduled", icon: "calendar.badge.clock", date: task.scheduledFor) { patch(["scheduledFor": .ms($0)]) }
                    DateChip(title: "Snooze", icon: "moon.zzz", date: task.snoozedUntil.flatMap { $0 > Date() ? $0 : nil }, withTime: true,
                             presets: Snooze.options().prefix(3).map { ($0.title, $0.date) }) { patch(["snoozedUntil": .ms($0)]) }
                }
            }
            row("Estimate") {
                HStack(spacing: Space.s) {
                    MenuChip(title: task.estimateMin.map { Fmt.span(Double($0) * 60) } ?? "None", icon: "timer", active: task.estimateMin != nil) {
                        ForEach([15, 30, 60, 90, 120, 240], id: \.self) { minutes in
                            Button(Fmt.span(Double(minutes) * 60)) { patch(["estimateMin": .number(Double(minutes))]) }
                        }
                        Divider()
                        Button("None") { patch(["estimateMin": .null]) }
                    }
                    if let spentMs, spentMs > 0 {
                        Label("\(Fmt.span(spentMs / 1000)) spent", systemImage: "clock").font(Typo.caption).foregroundStyle(Palette.textDim)
                            .help("Time with this task in progress over the last 30 days")
                    }
                }
            }
            row("Waiting on") {
                CommitField(placeholder: "Nobody", value: task.waitingOn ?? "") { patch(["waitingOn": $0.isEmpty ? .null : .string($0)]) }
            }
            row("People") { tokens(task.people, placeholder: "Add person", icon: "person") { patch(["people": .array($0.map(JSONValue.string))]) } }
            row("Tags") { tokens(task.tags, placeholder: "Add tag", icon: "number") { patch(["tags": .array($0.map(JSONValue.string))]) } }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        GridRow {
            Text(label).font(Typo.caption).foregroundStyle(Palette.textFaint).frame(width: 66, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tokens(_ values: [String], placeholder: String, icon: String, onChange: @escaping ([String]) -> Void) -> some View {
        Flow(spacing: 5) {
            ForEach(values, id: \.self) { value in
                Button { onChange(values.filter { $0 != value }) } label: {
                    HStack(spacing: 3) {
                        Text(value).font(Typo.caption)
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(0.6)
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Palette.hover, in: Capsule())
                }
                .buttonStyle(.pressable(.bare))
                .help("Remove \(value)")
            }
            TokenField(placeholder: placeholder) { new in
                if !values.contains(new) { onChange(values + [new]) }
            }
        }
    }

    // MARK: Sections

    private func block<C: View>(_ title: String, count: Int? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title, count: count)
            content()
        }
    }

    @ViewBuilder private func subtasks(_ task: TaskItem) -> some View {
        let children = model.visible(children)
        block("Subtasks", count: children.count) {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    TaskLine(task: child, showReasons: false, onComplete: { model.complete(child) }, onOpen: { model.inspect(child) }).equatable().taskMenu(child)
                }
            }
            CaptureField("Add a subtask…") { title in
                var fields: [String: JSONValue] = ["parentId": .string(task.id)]
                if let projectId = task.projectId { fields["projectId"] = .string(projectId) }
                store.addTask(title, fields: .object(fields))
            }
        }
        if let parent, parent.id == task.parentId {
            Button { model.inspect(parent) } label: {
                Label("Part of “\(parent.title)”", systemImage: "arrow.turn.left.up").font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .buttonStyle(.pressable(.bare))
        }
    }

    /// Linked sessions with their state. A row opens the session's page; going to its window is the button on it.
    @ViewBuilder private func sessions(_ task: TaskItem) -> some View {
        let live = store.sessions.filter { $0.taskId == task.id }
        // Ended sessions come with the place; a live one is taken from the store so its state is current.
        let linked = live + (place?.sessions ?? []).filter { session in session.taskId == task.id && !live.contains { $0.id == session.id } }
        let free = store.sessions.filter { $0.taskId == nil }
        if !linked.isEmpty || !free.isEmpty {
            block("Sessions", count: linked.count) {
                ForEach(linked) { session in
                    HStack(spacing: Space.s) {
                        Button { model.openSession(session.id) } label: {
                            HStack(spacing: Space.s) {
                                StateDot(session.state, size: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.title ?? session.displayName).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                                    Text((session.state == .ended ? "ended \(Fmt.since(session.updatedAt)) ago" : "\(session.state.rawValue) \(Fmt.since(session.stateSince))") + " · \(session.displayName)" + (session.branch.map { " · \($0)" } ?? ""))
                                        .font(Typo.caption).foregroundStyle(Palette.session(session.state)).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.pressable(.bare, haptic: false))
                        .help("Open this session's page")
                        if session.state != .ended { IconButton(icon: "macwindow", help: "Go to its window") { app.focus(session) } }
                        IconButton(icon: "link.badge.plus", help: "Unlink") { link(session, to: nil) }
                    }
                    .padding(Space.s)
                    .cardSurface()
                }
                if !free.isEmpty {
                    MenuChip(title: "Link a session", icon: "terminal") {
                        ForEach(free) { session in
                            Button("\(session.displayName): \(session.title ?? session.branch ?? "")") { link(session, to: task.id) }
                        }
                    }
                }
            }
        }
    }

    private func link(_ session: CodeSession, to taskId: String?) {
        Task { try? await store.client.updateSession(session.id, ["taskId": taskId.map(JSONValue.string) ?? .null]) }
    }

    private func links(_ task: TaskItem) -> some View {
        block("Links", count: task.links.count) {
            ForEach(task.links, id: \.url) { link in
                HStack(spacing: Space.s) {
                    Image(systemName: Self.icon(link.kind)).font(.system(size: 11)).foregroundStyle(Palette.info).frame(width: 16)
                    Button { app.open(link.url) } label: {
                        Text(link.title.nonEmpty ?? link.url).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                    }
                    .buttonStyle(.pressable(.bare))
                    .help(link.url)
                    Spacer(minLength: 0)
                    IconButton(icon: "xmark", help: "Remove link", size: 20) { setLinks(task.links.filter { $0 != link }.map(Self.json)) }
                }
                .padding(.horizontal, Space.s)
                .frame(height: 28)
                .rowSurface()
            }
            CaptureField("Paste a link…", icon: "link") { url in
                setLinks(task.links.map(Self.json) + [["kind": "url", "title": .string(URL(string: url)?.host ?? url), "url": .string(url)]])
            }
        }
    }

    private func setLinks(_ links: [JSONValue]) {
        patch(["links": .array(links)])
    }

    private static func json(_ link: TaskLink) -> JSONValue {
        ["kind": .string(link.kind.rawValue), "title": .string(link.title), "url": .string(link.url)]
    }

    private func footer(_ task: TaskItem) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task.source.title) · created \(Fmt.day(task.createdAt))").font(Typo.caption).foregroundStyle(Palette.textFaint)
                if let done = task.completedAt { Text("Completed \(Fmt.day(done)) \(Fmt.time(done))").font(Typo.caption).foregroundStyle(Palette.textFaint) }
            }
            Spacer()
            Button("Delete", systemImage: "trash") { model.delete([task]) }.buttonStyle(.pressable(.danger)).labelStyle(.titleAndIcon)
        }
        .padding(.top, Space.s)
    }

    static func icon(_ kind: LinkKind) -> String {
        switch kind {
        case .ticket: "ticket"
        case .pr: "arrow.triangle.pull"
        case .thread: "bubble.left"
        case .doc: "doc.text"
        case .meeting: "calendar"
        case .session: "terminal"
        case .file: "doc"
        case .url, .unknown: "link"
        }
    }
}

/// Small "+ add" field that turns into a chip on Return.
private struct TokenField: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typo.caption)
            .foregroundStyle(Palette.text)
            .frame(width: 84, height: 22)
            .onSubmit {
                let value = text.trimmingCharacters(in: .whitespaces)
                text = ""
                if !value.isEmpty { onAdd(value) }
            }
    }
}

/// Plain-text notes that save a moment after typing stops, and when the editor goes away.
struct NotesEditor: View {
    let text: String
    var minHeight: CGFloat = 90
    var placeholder = "Add notes…"
    /// Bump to put the cursor in the editor (a screen's "notes" key).
    var focusToken = 0
    let onSave: (String) -> Void
    @State private var draft = ""
    @State private var saved = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        // TextEditor has no intrinsic height; the hidden copy of the text gives the stack one, so the field grows with it.
        ZStack(alignment: .topLeading) {
            Text(draft + "\n").font(Typo.body).padding(.horizontal, 5).frame(maxWidth: .infinity, alignment: .leading).hidden()
            TextEditor(text: $draft)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($focused)
        }
            .frame(minHeight: minHeight)
            .padding(Space.s)
            .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.m))
            .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder).font(Typo.body).foregroundStyle(Palette.textFaint).padding(.horizontal, Space.s + 5).padding(.vertical, Space.s).allowsHitTesting(false)
                }
            }
            .onAppear { draft = text; saved = text }
            .onChange(of: focusToken) { focused = true }
            .onChange(of: text) { if !focused { draft = text; saved = text } }
            .onChange(of: draft) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { flush() }
                }
            }
            .onDisappear {
                pending?.cancel()
                flush()
            }
            .animation(Motion.snappy, value: focused)
    }

    private func flush() {
        guard draft != saved else { return }
        saved = draft
        onSave(draft)
    }
}
