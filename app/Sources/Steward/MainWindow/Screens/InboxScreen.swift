import SwiftUI
import StewardKit

/// Triage: approvals first (they block the agent), then suggestions grouped by where they came from.
/// Everything is reachable from the keyboard; the last accept or dismiss can be undone.
struct InboxScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var selection: String?
    /// Row id being edited before accepting; its changes live in `edits`.
    @State private var editing: String?
    /// Approvals whose long payload has been opened in full.
    @State private var expanded: Set<String> = []
    @State private var edits: [String: JSONValue] = [:]
    /// How each row should leave: true slides out as accepted, false collapses as dismissed.
    @State private var exits: [String: Bool] = [:]
    /// Where the selected suggestion came from and what was fetched about it, by suggestion id.
    @State private var places: [String: SuggestionPlace] = [:]
    @State private var refusals: [String: String] = [:]

    private static let confident = 0.8

    private enum Row: Identifiable {
        case approval(Approval), suggestion(Suggestion)

        var id: String {
            switch self {
            case .approval(let a): "approval:\(a.id)"
            case .suggestion(let s): s.id
            }
        }
    }

    var body: some View {
        let suggestions = store.suggestions.filter { !model.hidden.contains($0.id) }
        let groups = Self.grouped(suggestions)
        let rows = store.approvals.map(Row.approval) + groups.flatMap { $0.items.map(Row.suggestion) }
        let current = rows.first { $0.id == selection } ?? rows.first
        let sure = suggestions.filter { $0.confidence >= Self.confident && $0.kind != .question }
        let unsorted = model.visible(store.tasks).filter { $0.status == .inbox }

        ScreenScaffold(title: "Inbox", subtitle: subtitle(suggestions.count), scrolls: false) {
            if !sure.isEmpty {
                Button { acceptAll(sure) } label: {
                    HStack(spacing: 6) {
                        Text("Accept \(sure.count) confident")
                        KeyHint("⇧", "A")
                    }
                }
                .buttonStyle(.pressable()).fixedSize()
                .help("Accept every suggestion at \(Int(Self.confident * 100))% confidence or more")
            }
        } content: {
            VStack(spacing: 0) {
                if rows.isEmpty && unsorted.isEmpty {
                    EmptyState(icon: "tray", title: "Inbox zero",
                               message: store.connection.isOnline ? "Suggestions from your sessions, chat, meetings and tickets land here, along with anything the agent needs you to approve."
                                   : "Suggestions will show up once the brain is back.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: Space.s) {
                                if !store.approvals.isEmpty {
                                    header("Waiting for your approval", icon: "hand.raised.fill", count: store.approvals.count, color: Palette.danger)
                                    ForEach(store.approvals) { approval in
                                        let id = "approval:\(approval.id)"
                                        ApprovalReviewCard(approval: approval, selected: current?.id == id, editing: Binding(get: { editing == id }, set: { editing = $0 ? id : nil }),
                                                           expanded: Binding(get: { expanded.contains(approval.id) }, set: { if $0 { expanded.insert(approval.id) } else { expanded.remove(approval.id) } }))
                                            .id(id)
                                            .onTapGesture { selection = id }
                                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                                    }
                                }
                                ForEach(groups, id: \.id) { group in
                                    header(group.title, icon: group.icon, count: group.items.count, color: group.color)
                                    ForEach(group.items) { suggestion in
                                        card(suggestion, selected: current?.id == suggestion.id)
                                    }
                                }
                                if !unsorted.isEmpty {
                                    header("Unsorted tasks", icon: "tray", count: unsorted.count, color: Palette.textDim)
                                    ForEach(unsorted) { task in
                                        HStack(spacing: Space.s) {
                                            TaskLine(task: task, project: store.tree.allProjects.first { $0.id == task.projectId }, showReasons: false,
                                                     onComplete: { model.complete(task) }, onOpen: { model.inspect(task) }).equatable()
                                            Button("Keep") { store.update(task, ["status": "todo"]) }.buttonStyle(.pressable()).fixedSize()
                                                .help("Move to To do")
                                        }
                                        .taskMenu(task)
                                    }
                                }
                            }
                            .padding(.horizontal, Space.xl)
                            .padding(.bottom, Space.xl)
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
                    }
                }
                KeyLegend([(["J", "K"], "move"), (["A"], "accept"), (["E"], "edit, then accept"), (["X"], "dismiss"), (["M"], "see more"), (["O"], "open source"),
                           (["⇧", "A"], "accept confident"), (["⌘", "↩"], "approve"), (["⌘", "Z"], "undo")])
            }
        }
        .animation(Motion.snappy, value: rows.map(\.id))
        .animation(Motion.snappy, value: editing)
        .screenKeys(model) { keys($0, rows: rows, current: current, confident: sure) }
        .task(id: store.changes[.tasks]) { await model.library.refresh() }
        .task(id: "\(current?.id ?? "")|\(store.changes[.places] ?? 0)") {
            guard case .suggestion(let suggestion)? = current else { return }
            // Moving down the list with J should not fetch for every row passed on the way.
            if places[suggestion.id] == nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let fetched = try? await store.client.suggestionPlace(suggestion.id) else { return }
            withAnimation(Motion.snappy) { places[suggestion.id] = fetched }
        }
        .onAppear {
            if let preset = model.scenario["inbox.editing"] {
                selection = preset
                editing = preset
            }
            if let preset = model.scenario["inbox.selected"] { selection = preset }
            takeFocus()
        }
        .onChange(of: model.focusSuggestionId) { takeFocus() }
        // Approvals are the first rows, so a fresh Inbox already starts on them; this covers one that is open further down.
        .onChange(of: model.focusApprovals) { selection = store.approvals.first.map { "approval:\($0.id)" } }
    }

    private func subtitle(_ suggestions: Int) -> String {
        let approvals = store.approvals.count
        if suggestions == 0 && approvals == 0 { return "Nothing to review" }
        return [approvals > 0 ? "\(approvals) approval\(approvals == 1 ? "" : "s")" : nil,
                suggestions > 0 ? "\(suggestions) suggestion\(suggestions == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func takeFocus() {
        guard let id = model.focusSuggestionId else { return }
        selection = id
        model.focusSuggestionId = nil
    }

    private struct Group {
        let id: String
        let title: String
        let icon: String
        let color: Color
        var items: [Suggestion]
    }

    /// What the user themselves promised comes first, under its own heading; the rest by source, in the order each
    /// source first appears (the list arrives newest first).
    private static func grouped(_ suggestions: [Suggestion]) -> [Group] {
        let promised = suggestions.filter { $0.commitment != nil }
        var groups = promised.isEmpty ? [] : [Group(id: "commitments", title: "You said you would", icon: "text.quote", color: Palette.accent, items: promised)]
        for suggestion in suggestions where suggestion.commitment == nil {
            let id = "source:\(suggestion.source.rawValue)"
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].items.append(suggestion)
            } else {
                groups.append(Group(id: id, title: suggestion.source.title, icon: suggestion.source.icon, color: Palette.textDim, items: [suggestion]))
            }
        }
        return groups
    }

    private func seeMore(_ suggestion: Suggestion, refresh: Bool) {
        guard let place = places[suggestion.id], place.seeMoreVia != nil, place.context?.status != .running else { return }
        refusals[suggestion.id] = nil
        Task {
            do {
                let context = try await store.client.seeMore(suggestion: suggestion.id, refresh: refresh)
                withAnimation(Motion.snappy) { places[suggestion.id]?.context = context }
            } catch {
                withAnimation(Motion.snappy) { refusals[suggestion.id] = error.brief }
            }
        }
    }

    private func header(_ title: String, icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            SectionLabel(title, count: count)
        }
        .padding(.top, Space.m)
        .padding(.leading, 2)
    }

    private func card(_ suggestion: Suggestion, selected: Bool) -> some View {
        let target = suggestion.payload["taskId"]?.string.flatMap { model.library.task($0) }
        return InboxSuggestionCard(
            suggestion: suggestion, selected: selected, editing: editing == suggestion.id, edits: $edits,
            projects: store.tree.allProjects, target: target,
            place: selected ? places[suggestion.id] : nil, refusal: refusals[suggestion.id],
            onSeeMore: { seeMore(suggestion, refresh: $0) },
            onAccept: { accept(suggestion) },
            onDismiss: { dismiss(suggestion) },
            onEdit: { toggleEdit(suggestion, $0) },
            onAnswer: { accept(suggestion, with: ["answer": .string($0)]) },
            onSource: { app.open(suggestion.sourceUrl) })
            .id(suggestion.id)
            .onTapGesture { selection = suggestion.id }
            .transition(.asymmetric(
                insertion: .opacity,
                removal: exits[suggestion.id] == true ? .move(edge: .trailing).combined(with: .opacity) : .scale(scale: 0.94, anchor: .top).combined(with: .opacity)))
    }

    // MARK: Actions

    private func toggleEdit(_ suggestion: Suggestion, _ on: Bool) {
        edits = [:]
        selection = suggestion.id
        editing = on && InboxSuggestionCard.editable(suggestion.kind) ? suggestion.id : nil
    }

    private func accept(_ suggestion: Suggestion, with answer: [String: JSONValue]? = nil) {
        let changes = answer ?? (editing == suggestion.id ? edits : [:])
        editing = nil
        edits = [:]
        Haptics.success()
        leave(suggestion, accepted: true, label: "Accepted “\(suggestion.title)”") {
            store.accept(suggestion, edits: changes.isEmpty ? nil : .object(changes))
        }
    }

    private func dismiss(_ suggestion: Suggestion) {
        if editing == suggestion.id { editing = nil }
        Haptics.tick()
        leave(suggestion, accepted: false, label: "Dismissed “\(suggestion.title)”") { store.dismiss(suggestion) }
    }

    private func acceptAll(_ list: [Suggestion]) {
        guard !list.isEmpty else { return }
        Haptics.success()
        for suggestion in list { exits[suggestion.id] = true }
        DispatchQueue.main.async {
            model.deferred("Accepted \(list.count) suggestions", hiding: list.map(\.id)) { store.acceptAll(list) }
        }
    }

    /// Hides the row now; the brain hears about it once the undo window has passed.
    private func leave(_ suggestion: Suggestion, accepted: Bool, label: String, commit: @escaping () -> Void) {
        let visible = store.suggestions.filter { !model.hidden.contains($0.id) }
        let ordered = Self.grouped(visible).flatMap(\.items)
        if let index = ordered.firstIndex(of: suggestion) {
            selection = (ordered.indices.contains(index + 1) ? ordered[index + 1] : ordered[..<index].last)?.id
        }
        exits[suggestion.id] = accepted
        // Next tick, so the row has picked up its exit transition before it is removed.
        DispatchQueue.main.async { model.deferred(label, hiding: [suggestion.id], commit: commit) }
    }

    // MARK: Keys

    private func keys(_ stroke: KeyStroke, rows: [Row], current: Row?, confident: [Suggestion]) -> Bool {
        if editing != nil, stroke.plain(.escape) {
            editing = nil
            edits = [:]
            return true
        }
        if let next = moveSelection(stroke, in: rows.map(\.id), from: current?.id) {
            if editing != nil { editing = nil; edits = [:] }
            selection = next
            return true
        }
        if stroke.shift("a") {
            acceptAll(confident)
            return true
        }
        switch current {
        case .approval(let approval)?:
            // Approving is deliberate: ⌘↩ only, never the plain accept key that triage repeats.
            // A payload cut short is opened first and approved on the next press; an open editor is approved from its own button.
            if stroke.command(.enter) {
                if editing == "approval:\(approval.id)" { return false }
                if ApprovalReviewCard.canApprove(approval, expanded: expanded.contains(approval.id)) { store.approve(approval) } else { expanded.insert(approval.id) }
            } else if stroke.plain("e") { if approval.kind != "self_modify" { editing = "approval:\(approval.id)" } }
            else if stroke.plain("x") { store.deny(approval) }
            else { return false }
            return true
        case .suggestion(let suggestion)?:
            let options = suggestion.payload["options"]?.array?.compactMap(\.string) ?? []
            if case .char(let ch) = stroke.key, stroke.mods.isEmpty, let n = Int(String(ch)), options.indices.contains(n - 1) {
                accept(suggestion, with: ["answer": .string(options[n - 1])])
            } else if stroke.plain("a") || stroke.plain(.enter) || stroke.command(.enter) {
                // A question is answered with one of its options, not a blanket yes.
                if options.isEmpty { accept(suggestion) }
            } else if stroke.plain("e") { toggleEdit(suggestion, editing != suggestion.id) }
            else if stroke.plain("x") || stroke.plain(.delete) { dismiss(suggestion) }
            else if stroke.plain("o") { app.open(suggestion.sourceUrl) }
            else if stroke.plain("m") { seeMore(suggestion, refresh: places[suggestion.id]?.context?.body.isEmpty == false) }
            else { return false }
            return true
        case nil:
            return false
        }
    }
}

/// One suggestion: what was noticed, why, and what accepting will do.
struct InboxSuggestionCard: View {
    let suggestion: Suggestion
    let selected: Bool
    let editing: Bool
    @Binding var edits: [String: JSONValue]
    let projects: [Project]
    /// The task an update / complete / link suggestion points at, when it is known.
    let target: TaskItem?
    /// Where it came from and what was fetched about it; given for the selected card only.
    var place: SuggestionPlace?
    var refusal: String?
    var onSeeMore: (_ refresh: Bool) -> Void = { _ in }
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onEdit: (Bool) -> Void
    let onAnswer: (String) -> Void
    let onSource: () -> Void

    static func editable(_ kind: SuggestionKind) -> Bool { kind == .newTask || kind == .followup || kind == .updateTask }

    private var kind: (title: String, icon: String, color: Color, accept: String) {
        switch suggestion.kind {
        case .newTask: ("New task", "plus", Palette.accent, "Add task")
        case .followup where suggestion.commitment != nil: ("You said", "text.quote", Palette.accent, "Add task")
        case .followup: ("Follow up", "arrowshape.turn.up.left", Palette.violet, "Add follow-up")
        case .updateTask: ("Update", "pencil", Palette.info, "Apply")
        case .completeTask: ("Looks done", "checkmark", Palette.ok, "Mark done")
        case .link: ("Link", "link", Palette.info, "Link")
        case .insight: ("Insight", "lightbulb", Palette.warn, "Got it")
        case .question: ("Question", "questionmark", Palette.violet, "Answer")
        case .unknown: ("Suggestion", "sparkle", Palette.textDim, "Accept")
        }
    }

    /// The proposed fields: the payload itself for a new task, its `patch` for an update.
    private var base: [String: JSONValue] {
        suggestion.kind == .updateTask ? suggestion.payload["patch"]?.object ?? [:] : suggestion.payload
    }

    private func value(_ key: String) -> JSONValue { edits[key] ?? base[key] ?? .null }

    var body: some View {
        let options = suggestion.payload["options"]?.array?.compactMap(\.string) ?? []
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: kind.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(kind.color)
                    .frame(width: 20, height: 20).background(kind.color.opacity(0.14), in: Circle())
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                    if !suggestion.rationale.isEmpty {
                        Text(suggestion.rationale).font(Typo.caption).foregroundStyle(Palette.textDim).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.s)
                confidence
            }
            if let said = suggestion.commitment, !said.quote.isEmpty, place?.origins.isEmpty ?? true {
                // The same words the source panel shows once the card is selected; until then the quote stands in for it.
                Text("“\(said.quote)”" + (said.to.map { "  to \($0)" } ?? "") + (said.madeAt.map { ", \(Fmt.since($0)) ago" } ?? ""))
                    .font(Typo.caption).italic().foregroundStyle(Palette.textDim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            if let place, !place.origins.isEmpty || place.seeMoreVia != nil {
                SourcePanel(origins: place.origins, context: place.context, via: place.seeMoreVia, refusal: refusal, keyHint: ["M"], onFetch: onSeeMore)
                    .padding(.leading, 28)
                    .transition(.opacity)
            }
            Group {
                if editing { form } else { effect(options) }
            }
            .padding(.leading, 28)
            if options.isEmpty || editing { actions.padding(.leading, 28) }
        }
        .padding(Space.m)
        .cardSurface(radius: Radius.l)
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.accent.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
        .contentShape(.rect)
    }

    private var confidence: some View {
        HStack(spacing: 6) {
            Text(kind.title).font(Typo.caption).foregroundStyle(kind.color)
            Meter(fraction: suggestion.confidence, color: suggestion.confidence >= 0.8 ? Palette.ok : Palette.textDim, height: 3).frame(width: 26)
            Text("\(Int((suggestion.confidence * 100).rounded()))%").font(Typo.numeric).foregroundStyle(Palette.textFaint).frame(width: 30, alignment: .trailing)
        }
        .help("How sure Steward is. \(Fmt.since(suggestion.createdAt)) ago.")
    }

    private var actions: some View {
        HStack(spacing: Space.s) {
            Button(action: onAccept) {
                HStack(spacing: 6) {
                    Text(editing ? "\(kind.accept) with changes" : kind.accept)
                    if selected { KeyHint(editing ? "↩" : "A") }
                }
            }
            .buttonStyle(.pressable(selected ? .primary : .secondary)).fixedSize()
            if Self.editable(suggestion.kind) {
                Button { onEdit(!editing) } label: {
                    HStack(spacing: 6) { Text(editing ? "Cancel" : "Edit"); if selected { KeyHint(editing ? "esc" : "E") } }
                }
                .buttonStyle(.pressable(.ghost)).fixedSize()
            }
            Button(action: onDismiss) {
                HStack(spacing: 6) { Text("Dismiss"); if selected { KeyHint("X") } }
            }
            .buttonStyle(.pressable(.ghost)).fixedSize()
            Spacer(minLength: 0)
            // Once the source panel is showing, its own "Open in …" is the way out.
            if suggestion.sourceUrl != nil, place?.origins.contains(where: { $0.url != nil }) != true {
                Button(action: onSource) {
                    HStack(spacing: 4) {
                        Text("Open in \(suggestion.source.title.lowercased())").font(Typo.caption)
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        if selected { KeyHint("O") }
                    }
                    .foregroundStyle(Palette.info)
                }
                .buttonStyle(.pressable(.bare)).fixedSize()
            }
        }
    }

    // MARK: What accepting does

    @ViewBuilder private func effect(_ options: [String]) -> some View {
        switch suggestion.kind {
        case .newTask, .followup:
            box {
                Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Palette.priority(value("priority").int ?? 0))
                Text(value("title").string ?? suggestion.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                chips
                Spacer(minLength: 0)
                Text(value("waitingOn").string != nil ? "new waiting task" : "new task").font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize()
            }
        case .updateTask:
            VStack(alignment: .leading, spacing: 6) {
                Label(target?.title ?? "A task", systemImage: "pencil").font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
                ForEach(base.keys.sorted(), id: \.self) { key in
                    HStack(spacing: Space.s) {
                        Text(Self.label(key)).font(Typo.caption).foregroundStyle(Palette.textFaint).frame(width: 64, alignment: .leading)
                        Text(target.map { format(key, Self.current(key, of: $0)) } ?? "…").font(Typo.body).foregroundStyle(Palette.textDim).strikethrough(color: Palette.textFaint)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint)
                        Text(format(key, value(key))).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                    }
                }
            }
            .padding(Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
        case .completeTask:
            box {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.ok)
                Text(target?.title ?? "The task").font(Typo.body).foregroundStyle(Palette.textDim).strikethrough(color: Palette.textFaint).lineLimit(1)
                Spacer(minLength: 0)
                Text("marks it done").font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize()
            }
        case .link:
            box {
                Image(systemName: "link").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.info)
                Text(suggestion.payload["link"]?["title"].string ?? suggestion.payload["link"]?["url"].string ?? "Link").font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint)
                Text(target?.title ?? "a task").font(Typo.body).foregroundStyle(Palette.textDim).lineLimit(1)
                Spacer(minLength: 0)
            }
        case .question:
            Flow(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { onAnswer(option) } label: {
                        HStack(spacing: 6) { Text(option); if selected { KeyHint("\(index + 1)") } }
                    }
                    .buttonStyle(.pressable()).fixedSize()
                }
                Button(action: onDismiss) {
                    HStack(spacing: 6) { Text("Skip"); if selected { KeyHint("X") } }
                }
                .buttonStyle(.pressable(.ghost)).fixedSize()
            }
        case .insight, .unknown:
            EmptyView()
        }
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: Space.s) { content() }
            .padding(.horizontal, Space.s + 2)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
    }

    @ViewBuilder private var chips: some View {
        if let priority = value("priority").int, priority > 0 { Pill(Priority.title(priority), color: Palette.priority(priority), style: .outline) }
        if let project = projects.first(where: { $0.id == value("projectId").string }) {
            Pill(project.title, icon: "square.stack.3d.up", color: Color(hexString: project.color) ?? Palette.textDim)
        }
        if let due = value("dueAt").double { Pill(Fmt.due(Date(timeIntervalSince1970: due / 1000)).text, icon: "calendar") }
        if let waiting = value("waitingOn").string { Pill("Waiting on \(waiting)", icon: "hourglass", color: Palette.info) }
        ForEach(value("people").array?.compactMap(\.string) ?? [], id: \.self) { Pill($0, icon: "person") }
    }

    // MARK: Edit before accepting

    private var form: some View {
        let keys = suggestion.kind == .updateTask ? base.keys.sorted() : ["title", "priority", "projectId", "dueAt"] + (suggestion.kind == .followup || base["waitingOn"] != nil ? ["waitingOn"] : [])
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
            ForEach(keys, id: \.self) { key in
                GridRow {
                    Text(Self.label(key)).font(Typo.caption).foregroundStyle(Palette.textFaint).frame(width: 64, alignment: .leading)
                    field(key).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Space.s + 2)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
        .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private func field(_ key: String) -> some View {
        switch key {
        case "title", "waitingOn":
            TextField(key == "title" ? "Title" : "Nobody", text: Binding(
                get: { value(key).string ?? (key == "title" && suggestion.kind != .updateTask ? suggestion.title : "") },
                set: { edits[key] = $0.isEmpty && key == "waitingOn" ? .null : .string($0) }))
                .textFieldStyle(.plain).font(Typo.body).foregroundStyle(Palette.text)
                .onSubmit(onAccept)
        case "priority":
            Segmented(Priority.all.map { ($0.value, $0.title, nil) }, selection: Binding(get: { value(key).int ?? 0 }, set: { edits[key] = .number(Double($0)) }))
        case "projectId":
            let project = projects.first { $0.id == value(key).string }
            MenuChip(title: project?.title ?? "None", icon: "square.stack.3d.up", active: project != nil) {
                Button("None") { edits[key] = .null }
                Divider()
                ForEach(projects) { project in Button(project.title) { edits[key] = .string(project.id) } }
            }
        case "dueAt", "scheduledFor", "snoozedUntil":
            DateChip(title: Self.label(key), icon: "calendar", date: value(key).double.map { Date(timeIntervalSince1970: $0 / 1000) }, withTime: true) { edits[key] = .ms($0) }
        case "status":
            MenuChip(title: TaskStatus(rawValue: value(key).string ?? "")?.title ?? "Status", icon: "circle.dashed") {
                ForEach([TaskStatus.inbox, .todo, .doing, .waiting, .done, .dropped], id: \.self) { status in
                    Button(status.title) { edits[key] = .string(status.rawValue) }
                }
            }
        default:
            Text(format(key, value(key))).font(Typo.body).foregroundStyle(Palette.textDim)
        }
    }

    // MARK: Formatting

    static func label(_ key: String) -> String {
        switch key {
        case "projectId": "Project"
        case "dueAt": "Due"
        case "scheduledFor": "Scheduled"
        case "snoozedUntil": "Snooze"
        case "waitingOn": "Waiting on"
        case "estimateMin": "Estimate"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    static func current(_ key: String, of task: TaskItem) -> JSONValue {
        switch key {
        case "title": .string(task.title)
        case "notes": .string(task.notes)
        case "status": .string(task.status.rawValue)
        case "priority": .number(Double(task.priority))
        case "projectId": task.projectId.map(JSONValue.string) ?? .null
        case "dueAt": .ms(task.dueAt)
        case "scheduledFor": .ms(task.scheduledFor)
        case "snoozedUntil": .ms(task.snoozedUntil)
        case "waitingOn": task.waitingOn.map(JSONValue.string) ?? .null
        case "estimateMin": task.estimateMin.map { .number(Double($0)) } ?? .null
        case "pinned": .bool(task.pinned)
        default: .null
        }
    }

    private func format(_ key: String, _ value: JSONValue) -> String {
        if value.isNull { return "none" }
        switch key {
        case "priority": return Priority.title(value.int ?? 0)
        case "dueAt", "scheduledFor", "snoozedUntil": return value.double.map { Fmt.due(Date(timeIntervalSince1970: $0 / 1000)).text } ?? "none"
        case "status": return TaskStatus(rawValue: value.string ?? "")?.title ?? value.string ?? ""
        case "projectId": return projects.first { $0.id == value.string }?.title ?? "Unknown project"
        case "estimateMin": return value.double.map { Fmt.span($0 * 60) } ?? "none"
        case "pinned": return value.bool == true ? "pinned" : "not pinned"
        default: return value.string ?? value.text()
        }
    }
}
