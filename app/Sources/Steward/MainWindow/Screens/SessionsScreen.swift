import AppKit
import SwiftUI
import StewardKit

/// The radar at full size: one card per live coding session, or a large-type board for a second monitor.
struct SessionsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @AppStorage("sessions.mode") private var storedMode = "cards"
    @AppStorage("sessions.group") private var grouping = "state"
    @State private var selection: String?
    /// The session whose own page is open, instead of the radar.
    @State private var placeId: String?
    @State private var ended: [CodeSession] = []
    @State private var recaps: Set<String> = []
    @State private var linking: String?
    @State private var copied: String?

    private var mode: String { model.scenario["sessions.mode"] ?? storedMode }

    var body: some View {
        let sessions = store.sessions.sorted { SessionOrder.key($0) < SessionOrder.key($1) }
        let groups = SessionGroup.make(sessions, by: grouping)
        let ordered = groups.flatMap(\.sessions)
        Group {
            if let placeId {
                SessionPlaceView(sessionId: placeId) { withAnimation(Motion.snappy) { self.placeId = nil } }.id(placeId)
            } else if mode == "board" {
                SessionBoard(sessions: sessions, selection: selection, mode: modeBinding) { open($0.id) }
                    .screenKeys(model) { keys($0, sessions) }
            } else {
                cards(groups, total: sessions).screenKeys(model) { keys($0, ordered) }
            }
        }
        .task(id: store.changes[.sessions]) {
            if let all = try? await store.client.sessions(includeEnded: true) {
                ended = Array(all.filter { $0.state == .ended }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
            }
        }
        .onAppear {
            if let id = model.scenario["sessions.recap"] { recaps.insert(id); selection = id }
            if let id = model.scenario["sessions.link"] { linking = id }
            takeFocus()
        }
        .onChange(of: model.focusSessionId) { takeFocus() }
    }

    private func takeFocus() {
        guard let id = model.focusSessionId else { return }
        selection = id
        placeId = id
        model.focusSessionId = nil
    }

    /// A session's own page. Its editor window is one click further, on that page.
    private func open(_ id: String) {
        selection = id
        withAnimation(Motion.snappy) { placeId = id }
    }

    private var modeBinding: Binding<String> {
        Binding(get: { mode }, set: { storedMode = $0 })
    }

    // MARK: Cards

    private func cards(_ groups: [SessionGroup], total: [CodeSession]) -> some View {
        let waiting = total.filter(\.needsAttention).count
        return ScreenScaffold(title: "Sessions", subtitle: SessionsScreen.subtitle(total.count, waiting), scrolls: false) {
            MenuChip(title: "Group: \(grouping.capitalized)", icon: "rectangle.3.group") {
                Picker("Group by", selection: $grouping) {
                    Text("State").tag("state")
                    Text("Repo").tag("repo")
                }
                .pickerStyle(.inline)
            }
            Segmented([("cards", "Cards", "square.grid.2x2"), ("board", "Board", "rectangle.split.1x2")], selection: modeBinding)
        } content: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.l) {
                            if total.isEmpty {
                                EmptyState(icon: "terminal", title: "No sessions running",
                                           message: "Coding-agent sessions on this Mac show up here as soon as they start, with what they are doing and whether they need you.")
                                    .frame(height: 260)
                            }
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: Space.s) {
                                    SectionLabel(group.title, count: group.sessions.count).padding(.leading, 2)
                                    SessionMasonry {
                                        ForEach(group.sessions) { session in card(session).id(session.id) }
                                    }
                                }
                            }
                            if !ended.isEmpty { endedSection }
                        }
                        .padding(.horizontal, Space.xl)
                        .padding(.bottom, Space.xl)
                        .animation(Motion.settle, value: groups.map { $0.sessions.map(\.id) })
                    }
                    .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
                }
                KeyLegend([(["J", "K"], "move"), (["↩"], "open"), (["F"], "go to window"), (["R"], "recap"), (["L"], "link task"), (["C"], "copy resume"),
                           (["G"], "grouping"), (["B"], "board")])
            }
        }
    }

    static func subtitle(_ total: Int, _ waiting: Int) -> String {
        if total == 0 { return "Nothing running" }
        return waiting == 0 ? "\(total) running · none need you" : "\(total) running · \(waiting) need\(waiting == 1 ? "s" : "") you"
    }

    private func card(_ session: CodeSession) -> some View {
        SessionCard(session: session, task: model.library.task(session.taskId), selected: selection == session.id,
                    recap: recaps.contains(session.id), linking: linking == session.id, copied: copied == session.id,
                    onSelect: { open(session.id) },
                    onRecap: { toggleRecap(session.id) },
                    onLink: { withAnimation(Motion.snappy) { linking = linking == session.id ? nil : session.id } },
                    onCopy: { copy(session) })
    }

    private var endedSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("Ended recently", count: ended.count).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(ended) { session in
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) {
                            Circle().fill(Palette.textFaint).frame(width: 7, height: 7).frame(width: 12)
                            Text(session.displayName).font(Typo.bodyStrong).foregroundStyle(Palette.textDim).lineLimit(1)
                            if let ticket = session.ticket { Text(ticket).font(Typo.caption).foregroundStyle(Palette.info.opacity(0.8)) }
                            Text(session.title ?? session.branch ?? "").font(Typo.body).foregroundStyle(Palette.textDim).lineLimit(1)
                            Spacer(minLength: Space.s)
                            Text("ended \(Fmt.since(session.updatedAt)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize()
                            IconButton(icon: "text.alignleft", help: "Recap", tint: recaps.contains(session.id) ? Palette.accent : Palette.textDim) { toggleRecap(session.id) }
                            IconButton(icon: copied == session.id ? "checkmark" : "doc.on.doc", help: "Copy resume command",
                                       tint: copied == session.id ? Palette.ok : Palette.textDim) { copy(session) }
                        }
                        if recaps.contains(session.id) { SessionRecapView(sessionId: session.id).padding(.leading, 20) }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .rowSurface()
                    .onTapGesture { open(session.id) }
                    .help("Open this session's page")
                }
            }
            .padding(Space.xs)
            .cardSurface(radius: Radius.l)
        }
    }

    // MARK: Actions

    private func toggleRecap(_ id: String) {
        withAnimation(Motion.snappy) { if recaps.contains(id) { recaps.remove(id) } else { recaps.insert(id) } }
    }

    private func copy(_ session: CodeSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SessionsScreen.resumeHint(session), forType: .string)
        Haptics.tick()
        withAnimation(Motion.snappy) { copied = session.id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.snappy) { if copied == session.id { copied = nil } }
        }
    }

    static func resumeHint(_ session: CodeSession) -> String {
        "cd '\(session.cwd.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(session.id)"
    }

    private func keys(_ stroke: KeyStroke, _ ordered: [CodeSession]) -> Bool {
        if let next = moveSelection(stroke, in: ordered.map(\.id), from: selection) {
            selection = next
            return true
        }
        if stroke.plain("b") {
            withAnimation(Motion.resist) { storedMode = mode == "board" ? "cards" : "board" }
            return true
        }
        if stroke.plain("g") {
            withAnimation(Motion.settle) { grouping = grouping == "state" ? "repo" : "state" }
            return true
        }
        if stroke.plain(.escape), linking != nil {
            withAnimation(Motion.snappy) { linking = nil }
            return true
        }
        guard let session = ordered.first(where: { $0.id == selection }) else { return false }
        switch stroke.key {
        case .enter where stroke.mods.isEmpty, .char("o") where stroke.mods.isEmpty: open(session.id)
        case .char("f") where stroke.mods.isEmpty: app.focus(session)
        case .char("r") where stroke.mods.isEmpty: toggleRecap(session.id)
        case .char("l") where stroke.mods.isEmpty: withAnimation(Motion.snappy) { linking = linking == session.id ? nil : session.id }
        case .char("c") where stroke.mods.isEmpty: copy(session)
        default: return false
        }
        return true
    }
}

/// Columns of cards where each card goes under the shortest column, so one card opening its recap
/// does not leave a hole beside it. Not lazy: there are a handful of sessions, not hundreds.
private struct SessionMasonry: Layout {
    var minWidth: CGFloat = 360
    var spacing: CGFloat = Space.m

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, Int((width + spacing) / (minWidth + spacing)))
        let column = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        var heights = [CGFloat](repeating: 0, count: count)
        let frames = subviews.map { view -> CGRect in
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = view.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
            defer { heights[target] += height + spacing }
            return CGRect(x: CGFloat(target) * (column + spacing), y: heights[target], width: column, height: height)
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minWidth
        return CGSize(width: width, height: frames(width, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [CodeSession]

    /// `sessions` arrive sorted by need; groups keep that order inside and between them.
    static func make(_ sessions: [CodeSession], by grouping: String) -> [SessionGroup] {
        if grouping == "repo" {
            var order: [String] = []
            var byRepo: [String: [CodeSession]] = [:]
            for session in sessions {
                let repo = session.repo ?? session.displayName
                if byRepo[repo] == nil { order.append(repo) }
                byRepo[repo, default: []].append(session)
            }
            return order.map { SessionGroup(id: "repo:\($0)", title: $0, sessions: byRepo[$0] ?? []) }
        }
        let buckets: [(String, (CodeSession) -> Bool)] = [
            ("Needs you", { $0.needsAttention }), ("Working", { $0.state == .working }), ("Idle", { !$0.needsAttention && $0.state != .working }),
        ]
        return buckets.compactMap { title, test in
            let list = sessions.filter(test)
            return list.isEmpty ? nil : SessionGroup(id: "state:\(title)", title: title, sessions: list)
        }
    }
}

extension SessionState {
    var sessionLabel: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .blocked: "Needs an answer"
        case .idle: "Idle"
        case .ended: "Ended"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Card

private struct SessionCard: View {
    let session: CodeSession
    let task: TaskItem?
    let selected: Bool
    let recap: Bool
    let linking: Bool
    let copied: Bool
    let onSelect: () -> Void
    let onRecap: () -> Void
    let onLink: () -> Void
    let onCopy: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let color = Palette.session(session.state)
        VStack(alignment: .leading, spacing: Space.s + 2) {
            HStack(spacing: Space.s) {
                StateDot(session.state, size: 9).frame(width: 14, height: 14)
                Text(session.state.sessionLabel).font(Typo.bodyStrong).foregroundStyle(color)
                Spacer(minLength: Space.s)
                Live(every: 15) { now in
                    Text(Fmt.since(session.stateSince, now: now)).font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(session.needsAttention ? color : Palette.textDim)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(session.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").font(Typo.mono).foregroundStyle(Palette.textDim).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let title = session.title { Text(title).font(Typo.body).foregroundStyle(Palette.text.opacity(0.9)).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            if session.ticket != nil || session.pr != nil || task != nil {
                Flow(spacing: 5) {
                    if let ticket = session.ticket { Pill(ticket, icon: "ticket", color: Palette.info) }
                    if let pr = session.pr { SessionPRPill(pr: pr) { app.open(pr.url) } }
                    if let task {
                        Button { model.inspect(task) } label: { Pill(task.title, icon: "checklist", color: Palette.accent).frame(maxWidth: 220) }
                            .buttonStyle(.pressable(.bare)).help("Linked task. Click to open.")
                    }
                }
            }
            if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("You").font(Typo.label).kerning(0.4).foregroundStyle(Palette.textFaint)
                    Text(prompt).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reply = session.lastAssistantText, !reply.isEmpty {
                Text(MarkdownView.inline(reply)).font(Typo.body).foregroundStyle(Palette.text.opacity(0.85)).lineLimit(3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
            }
            if linking { SessionLinkPicker(session: session, onDone: onLink).transition(.opacity) }
            if recap { SessionRecapView(sessionId: session.id).transition(.opacity) }
            // The buttons never push the card wider than its column: when the labels do not fit, the icons stand alone.
            ViewThatFits(in: .horizontal) {
                actions(labels: 2)
                actions(labels: 1)
                actions(labels: 0)
            }
            .padding(.top, 2)
        }
        .padding(Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgRaised, in: .continuous(Radius.l))
        .background(alignment: .top) {
            if session.needsAttention {
                LinearGradient(colors: [color.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom).frame(height: 70).clipShape(.continuous(Radius.l))
            }
        }
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(
            selected ? Palette.accent.opacity(0.7) : session.needsAttention ? color.opacity(0.4) : hovered ? Palette.strokeStrong : Palette.stroke,
            lineWidth: selected ? 1.5 : 1))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .animation(Motion.snappy, value: hovered)
        .animation(Motion.snappy, value: selected)
        .contextMenu {
            Button("Open", systemImage: "sidebar.right", action: onSelect)
            Button("Go to window", systemImage: "macwindow") { app.focus(session) }
            Button("Copy resume command", systemImage: "doc.on.doc", action: onCopy)
            if task != nil { Button("Unlink task", systemImage: "link.badge.plus") { Task { try? await store.client.updateSession(session.id, ["taskId": .null]) } } }
            Button("Ask agent about this session", systemImage: "sparkles") {
                model.agentContext = [.init(kind: .session, id: session.id, title: session.displayName)]
                model.go(.agent)
            }
        }
    }
}

extension SessionCard {
    /// `labels`: 2 names every button, 1 only the first, 0 none.
    private func actions(labels level: Int) -> some View {
        let labels = level == 2
        return HStack(spacing: labels ? 6 : 4) {
            action("Go to window", "macwindow", level > 0, session.needsAttention ? .primary : .secondary,
                   help: "Bring its editor window forward. When no open window has this folder, its page opens here instead.") { app.focus(session) }
            action(task == nil ? "Link task" : "Relink", "link", labels, linking ? .secondary : .ghost, help: "Link this session to a task", action: onLink)
            action("Recap", "text.alignleft", labels, recap ? .secondary : .ghost, help: "What the session did: goal, done, open, next", action: onRecap)
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Label(copied ? "Copied" : "Resume hint", systemImage: copied ? "checkmark" : "doc.on.doc").foregroundStyle(copied ? Palette.ok : Palette.textDim)
                    .labelStyle(SessionActionLabel(labels: labels))
            }
            .buttonStyle(.pressable(.ghost)).fixedSize()
            .help(SessionsScreen.resumeHint(session))
        }
    }

    private func action(_ title: String, _ icon: String, _ labels: Bool, _ kind: PressableButtonStyle.Kind, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(SessionActionLabel(labels: labels)) }
            .buttonStyle(.pressable(kind)).fixedSize()
            .help(labels ? help : "\(title). \(help)")
            .accessibilityLabel(title)
    }
}

/// Title and icon, or the icon alone when the card is too narrow for words.
private struct SessionActionLabel: LabelStyle {
    let labels: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if labels { configuration.title }
        }
    }
}

/// PR number, review decision, checks and open review threads in one clickable capsule.
struct SessionPRPill: View {
    let pr: CodeSession.PullRequest
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .semibold))
                Text(verbatim: "#\(pr.number)").font(Typo.caption.weight(.medium))
                Text(review.text).font(Typo.caption).foregroundStyle(review.color)
                if let checks = pr.checks?.lowercased() {
                    let good = checks.hasPrefix("pass") || checks == "success"
                    let bad = checks.hasPrefix("fail") || checks == "failure"
                    Image(systemName: good ? "checkmark.circle.fill" : bad ? "xmark.circle.fill" : "clock")
                        .font(.system(size: 10)).foregroundStyle(good ? Palette.ok : bad ? Palette.danger : Palette.warn)
                        .help("Checks \(checks)")
                }
                if let unresolved = pr.unresolved, unresolved > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.left").font(.system(size: 9, weight: .medium))
                        Text(verbatim: "\(unresolved)").font(Typo.caption)
                    }
                    .foregroundStyle(Palette.warn)
                    .help("\(unresolved) unresolved review thread\(unresolved == 1 ? "" : "s")")
                }
                Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(Palette.violet)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Palette.violet.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.pressable(.bare))
        .help("Open the pull request")
    }

    private var review: (text: String, color: Color) {
        if pr.state.uppercased() == "MERGED" { return ("merged", Palette.ok) }
        if pr.state.uppercased() == "CLOSED" { return ("closed", Palette.textDim) }
        switch pr.reviewDecision?.uppercased() {
        case "APPROVED": return ("approved", Palette.ok)
        case "CHANGES_REQUESTED": return ("changes requested", Palette.danger)
        default: return (pr.state.lowercased(), Palette.violet)
        }
    }
}

/// Inline "link to task": search open tasks or make one from the session.
struct SessionLinkPicker: View {
    let session: CodeSession
    let onDone: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let matches = Array(Fuzzy.rank(model.visible(store.tasks), query: query) { $0.title }.prefix(5))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                TextField("Link to a task…", text: $query)
                    .textFieldStyle(.plain).font(Typo.body).foregroundStyle(Palette.text).focused($focused)
                    .onSubmit { if let first = matches.first { link(first.id) } }
                KeyHint("esc")
            }
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            ForEach(matches) { task in
                Button { link(task.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: task.status.icon).font(.system(size: 10)).foregroundStyle(Palette.priority(task.priority)).frame(width: 14)
                        Text(task.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if task.id == session.taskId { Text("linked").font(Typo.caption).foregroundStyle(Palette.accent) }
                    }
                    .padding(.horizontal, Space.s)
                    .frame(height: 26)
                    .rowSurface(radius: Radius.s)
                }
                .buttonStyle(.pressable(.bare, haptic: false))
            }
            Button(action: create) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 14)
                    Text("Create task “\(newTitle)”").font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s)
                .frame(height: 26)
                .rowSurface(radius: Radius.s)
            }
            .buttonStyle(.pressable(.bare, haptic: false))
        }
        .padding(Space.xs)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
        .onAppear { focused = true }
    }

    private var newTitle: String {
        query.trimmingCharacters(in: .whitespaces).nonEmpty ?? session.title ?? "Work in \(session.displayName)"
    }

    private func link(_ taskId: String) {
        Task { try? await store.client.updateSession(session.id, ["taskId": .string(taskId)]) }
        Haptics.tick()
        onDone()
    }

    private func create() {
        var fields: [String: JSONValue] = ["title": .string(newTitle), "status": "todo", "source": "claude", "sourceRef": .string(session.id)]
        if let pr = session.pr { fields["links"] = [["kind": "pr", "title": .string("\(session.displayName) #\(pr.number)"), "url": .string(pr.url)]] }
        let sessionId = session.id
        Task {
            guard let task = try? await store.client.createTask(.object(fields)) else { return }
            try? await store.client.updateSession(sessionId, ["taskId": .string(task.id)])
        }
        Haptics.success()
        onDone()
    }
}

/// The cached recap of what a session did, with refresh. Says so plainly when the agent is not running.
struct SessionRecapView: View {
    let sessionId: String
    @Environment(AppStore.self) private var store
    @State private var text: String?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                SectionLabel("Recap")
                if loading { ProgressView().controlSize(.mini) }
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Write a fresh recap", size: 20) { Task { await load(refresh: true) } }.disabled(loading)
            }
            if let text {
                MarkdownView(text: text)
            } else if let error {
                InlineNotice(text: error, icon: "moon.zzz", color: Palette.violet)
            } else {
                Text("Reading what the session did…").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
        }
        .padding(Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.violet.opacity(0.05), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.violet.opacity(0.2), lineWidth: 1))
        .task { await load(refresh: false) }
    }

    private func load(refresh: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let recap = try await store.client.sessionRecap(sessionId, refresh: refresh)
            withAnimation(Motion.snappy) { text = recap; error = nil }
        } catch {
            // A failed refresh keeps the recap already on screen.
            withAnimation(Motion.snappy) { self.error = text == nil ? error.brief : nil }
        }
    }
}

// MARK: - Board

/// Second-monitor mode: big type, no chrome, whoever needs the user on top.
private struct SessionBoard: View {
    let sessions: [CodeSession]
    let selection: String?
    @Binding var mode: String
    let onFocus: (CodeSession) -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        let waiting = sessions.filter(\.needsAttention).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Space.m) {
                Text(waiting == 0 ? "All clear" : "\(waiting) need\(waiting == 1 ? "s" : "") you")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(waiting == 0 ? Palette.ok : Palette.accent)
                    .contentTransition(.numericText())
                Text("\(sessions.filter { $0.state == .working }.count) working · \(sessions.filter { $0.state == .idle }.count) idle")
                    .font(.system(size: 15)).foregroundStyle(Palette.textDim)
                Spacer()
                Live(every: 30) { now in Text(Fmt.time(now)).font(.system(size: 15, design: .rounded).monospacedDigit()).foregroundStyle(Palette.textFaint) }
                Segmented([("cards", "", "square.grid.2x2"), ("board", "", "rectangle.split.1x2")], selection: $mode)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, 22)
            .padding(.bottom, Space.l)
            .frame(minHeight: 84, alignment: .bottom)
            OfflineBanner(connection: store.connection, note: store.brainNote) { store.refresh() }.padding(.horizontal, Space.xl)
            if sessions.isEmpty {
                EmptyState(icon: "terminal", title: "No sessions running", message: "Leave this open on a second screen: sessions appear here and float to the top when they need you.")
            }
            ScrollView {
                VStack(spacing: Space.s) {
                    ForEach(sessions) { session in
                        Button { onFocus(session) } label: { SessionBoardRow(session: session, selected: selection == session.id) }
                            .buttonStyle(.pressable(.bare))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xl)
                .animation(Motion.settle, value: sessions.map(\.id))
            }
        }
    }
}

private struct SessionBoardRow: View {
    let session: CodeSession
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        let color = Palette.session(session.state)
        HStack(spacing: Space.l) {
            RoundedRectangle.continuous(3).fill(color.opacity(session.state == .idle ? 0.5 : 1)).frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(session.displayName).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    if let ticket = session.ticket { Text(ticket).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.info) }
                    if let branch = session.branch { Text(branch).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.textFaint).lineLimit(1) }
                }
                Text(session.title ?? session.lastAssistantText ?? session.cwd).font(.system(size: 16)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: Space.l)
            VStack(alignment: .trailing, spacing: 0) {
                Live(every: 10) { now in
                    Text(Fmt.since(session.stateSince, now: now)).font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(session.needsAttention ? color : Palette.textDim)
                }
                HStack(spacing: 6) {
                    StateDot(session.state, size: 7)
                    Text(session.state.sessionLabel.uppercased()).font(Typo.label).kerning(0.6).foregroundStyle(color)
                }
            }
            .fixedSize()
        }
        .padding(.trailing, Space.l)
        .frame(height: 84)
        .background(session.needsAttention ? color.opacity(hovered ? 0.14 : 0.09) : hovered ? Palette.hover : Palette.bgRaised, in: .continuous(Radius.l))
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(selected ? Palette.accent.opacity(0.7) : session.needsAttention ? color.opacity(0.35) : Palette.stroke, lineWidth: selected ? 1.5 : 1))
        .clipShape(.continuous(Radius.l))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
        .help("Open this session's page")
    }
}
