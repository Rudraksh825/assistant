import AppKit
import SwiftUI
import StewardKit

/// Whether an editor that is running already has a window on a folder. Asking never opens anything.
@MainActor
enum WindowProbe {
    static func holds(_ directory: String) -> Bool {
        let path = (directory as NSString).standardizingPath
        return NSWorkspace.shared.runningApplications.contains { WindowFocuser.openFolder(containing: path, in: $0) != nil }
    }
}

/// One session's page: what it is doing and for how long, where it lives, what was said, and what can be done
/// about it from here. Going to its editor window is one of the buttons, and only when that window exists.
struct SessionPlaceView: View {
    let sessionId: String
    let onBack: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var place: SessionPlace?
    @State private var turns = SessionTurns()
    @State private var limit = 30
    @State private var missing = false
    @State private var unfolded: Set<Int> = []
    @State private var unfoldAll = false
    @State private var linking = false
    @State private var copied = false
    @State private var windowOpen = false
    @State private var nudgeNotice = 0
    @State private var recap: SessionPlace.Recap?
    @State private var recapBusy = false
    @State private var recapError: String?
    @State private var notesFocus = 0

    /// Live from the store while the session runs; the fetched copy once it has ended.
    private var session: CodeSession? { store.sessions.first { $0.id == sessionId } ?? place?.session }
    private var task: TaskItem? { session?.taskId.flatMap { model.library.task($0) } ?? (place?.task?.id == session?.taskId ? place?.task : nil) }

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                header(session)
                actions(session)
                GeometryReader { geo in
                    if geo.size.width >= 880 {
                        HStack(alignment: .top, spacing: 0) {
                            conversation(session).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            ScrollView { rail(session).padding(.trailing, Space.xl).padding(.bottom, Space.xl) }.frame(width: 348)
                        }
                    } else {
                        ScrollView {
                            // One column: what was said comes first, the cards after it.
                            VStack(alignment: .leading, spacing: Space.l) {
                                turnList(session)
                                rail(session)
                            }
                            .padding(.horizontal, Space.xl).padding(.bottom, Space.xl)
                        }
                    }
                }
                KeyLegend([(["esc"], "back"), (["G"], "window"), (["C"], "copy"), (["A"], "ask"), (["R"], "recap"), (["L"], "link"),
                           (["N"], "notes"), (["E"], "unfold"), (["M"], "earlier"), (["P"], "PR"), (["T"], "ticket")])
            } else if missing {
                EmptyState(icon: "terminal", title: "Session not found", message: "Steward has no record of this session.", actionTitle: "Back to sessions", action: onBack)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenKeys(model, keys)
        .task(id: reloadKey) { await load() }
        .task(id: session?.cwd) {
            // Windows open and close while the page is up; the probe is a small file read.
            while !Task.isCancelled, let cwd = session?.cwd {
                windowOpen = model.scenario["session.window"] == "1" || WindowProbe.holds(cwd)
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .task { await model.library.refresh() }
    }

    private var reloadKey: String {
        let live = store.sessions.first { $0.id == sessionId }
        return "\(sessionId)|\(limit)|\(live?.updatedAt.timeIntervalSince1970 ?? 0)|\(store.changes[.sessions] ?? 0)|\(store.changes[.tasks] ?? 0)"
    }

    private func load() async {
        do {
            let fetched = try await store.client.sessionPlace(sessionId)
            place = fetched
            if !recapBusy { recap = fetched.recap ?? recap }
        } catch {
            missing = session == nil
        }
        if let fetched = try? await store.client.sessionTurns(sessionId, limit: limit) { turns = fetched }
    }

    // MARK: Header

    private func header(_ session: CodeSession) -> some View {
        let color = Palette.session(session.state)
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Text("Sessions").font(Typo.caption)
                    KeyHint("esc")
                }
                .foregroundStyle(Palette.textDim)
            }
            .buttonStyle(.pressable(.bare)).fixedSize()
            HStack(alignment: .top, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title ?? session.displayName).font(Typo.title).foregroundStyle(Palette.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        StateDot(session.state, size: 8).frame(width: 12, height: 12)
                        Live(every: 15) { now in
                            Text(session.state == .ended ? "Ended \(Fmt.since(session.updatedAt, now: now)) ago" : "\(session.state.sessionLabel) for \(Fmt.since(session.stateSince, now: now))")
                                .font(Typo.bodyStrong).foregroundStyle(color)
                        }
                        Text(session.displayName).font(Typo.body).foregroundStyle(Palette.textDim).lineLimit(1)
                        if let branch = session.branch {
                            Label(branch, systemImage: "arrow.triangle.branch").font(Typo.mono).foregroundStyle(Palette.textDim).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: Space.m)
                HStack(spacing: 5) {
                    if let ticket = session.ticket { Pill(ticket, icon: "ticket", color: Palette.info) }
                    if let pr = session.pr { SessionPRPill(pr: pr) { app.open(pr.url) } }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, 20)
        .padding(.bottom, Space.m)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .bottomLeading)
    }

    // MARK: Actions

    private func actions(_ session: CodeSession) -> some View {
        let live = session.state != .ended
        return HStack(spacing: 6) {
            if live {
                Button { goToWindow(session) } label: { keyed("Go to window", "macwindow", "G") }
                    .buttonStyle(.pressable(session.needsAttention && windowOpen ? .primary : .secondary)).fixedSize()
                    .disabled(!windowOpen)
                    .help(windowOpen ? "Bring the editor window that has this folder to the front" : "No open window has this folder")
            }
            Button { copyResume(session) } label: { keyed(copied ? "Copied" : "Copy resume command", copied ? "checkmark" : "doc.on.doc", "C") }
                .buttonStyle(.pressable(.secondary)).fixedSize()
                .help(SessionsScreen.resumeHint(session))
            Button { ask(session) } label: { keyed("Ask the agent", "sparkles", "A") }.buttonStyle(.pressable(.secondary)).fixedSize()
                .help("Open the chat with this session attached")
            if let pr = session.pr {
                Button { app.open(pr.url) } label: { keyed("Open pull request", "arrow.up.right", "P") }.buttonStyle(.pressable(.ghost)).fixedSize()
            }
            if let url = place?.ticketUrl {
                Button { app.open(url) } label: { keyed("Open ticket", "arrow.up.right", "T") }.buttonStyle(.pressable(.ghost)).fixedSize()
            }
            if live, !windowOpen {
                Label("No open window has this folder", systemImage: "macwindow.badge.plus")
                    .font(Typo.caption).foregroundStyle(nudgeNotice > 0 ? Palette.warn : Palette.textFaint).lineLimit(1)
                    .padding(.leading, Space.xs)
                    .animation(Motion.snappy, value: nudgeNotice)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.m)
    }

    private func keyed(_ title: String, _ icon: String, _ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title)
            KeyHint(key)
        }
    }

    private func goToWindow(_ session: CodeSession) {
        guard windowOpen else {
            // Say why nothing happened instead of opening a window nobody asked for.
            Haptics.thunk()
            nudgeNotice += 1
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                nudgeNotice = 0
            }
            return
        }
        app.focuser.focus(directory: session.cwd)
    }

    private func copyResume(_ session: CodeSession) {
        copyToPasteboard(SessionsScreen.resumeHint(session))
        withAnimation(Motion.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.snappy) { copied = false }
        }
    }

    private func ask(_ session: CodeSession) {
        model.agentContext = [.init(kind: .session, id: session.id, title: session.displayName)]
        model.go(.agent)
    }

    // MARK: Conversation

    /// The heading stays put while the turns scroll under it, newest at the bottom, the way a conversation is read.
    private func conversation(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            turnHeader.padding(.leading, Space.xl).padding(.trailing, Space.l).padding(.bottom, Space.s)
            ScrollView {
                turnItems(session).padding(.leading, Space.xl).padding(.trailing, Space.l).padding(.bottom, Space.xl)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func turnList(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            turnHeader
            turnItems(session)
        }
    }

    private var turnHeader: some View {
        HStack(spacing: Space.s) {
            SectionLabel("Conversation", count: turns.items.filter { $0.role != .tools }.count)
            Text(turns.from == "transcript" ? "the latest, from the transcript on this Mac" : turns.from == "summary" ? "only the last exchange was kept; the transcript is gone" : "")
                .font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
            Spacer(minLength: 0)
            if turns.truncated, turns.from == "transcript" {
                Button { limit += 30 } label: {
                    HStack(spacing: 5) { Text("Earlier"); KeyHint("M") }
                }
                .buttonStyle(.pressable(.ghost)).fixedSize()
            }
        }
        .frame(minHeight: 24)
    }

    private func turnItems(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if turns.items.isEmpty {
                Text(turns.from == "none" ? "Nothing has been said in this session yet." : "Reading the transcript…").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            ForEach(Array(turns.items.enumerated()), id: \.offset) { index, turn in
                // Counted from the end, so loading earlier turns does not shuffle which ones are unfolded.
                let key = turns.items.count - index
                SessionTurnView(turn: turn, unfolded: unfoldAll || unfolded.contains(key)) {
                    withAnimation(Motion.snappy) { if unfolded.contains(key) { unfolded.remove(key) } else { unfolded.insert(key) } }
                }
            }
            if session.state == .blocked, let question = session.lastAssistantText, !question.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Waiting for your answer", systemImage: "questionmark.bubble.fill").font(Typo.bodyStrong).foregroundStyle(Palette.danger)
                    // Usually the question is the reply just above; it is only spelled out again when it is something else (a permission prompt).
                    if turns.items.last(where: { $0.role == .assistant })?.text != question {
                        Text(MarkdownView.inline(question)).font(Typo.body).foregroundStyle(Palette.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Text(windowOpen ? "Answer it in its window: G." : "Answer it in the terminal it runs in; no open editor window has this folder.")
                        .font(Typo.caption).foregroundStyle(Palette.textDim)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.danger.opacity(0.07), in: .continuous(Radius.m))
                .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.danger.opacity(0.35), lineWidth: 1))
            }
        }
    }

    // MARK: Rail

    private func rail(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Card(title: "Task") {
                if task != nil {
                    Button { withAnimation(Motion.snappy) { linking.toggle() } } label: { Text(linking ? "Cancel" : "Change").font(Typo.caption).foregroundStyle(Palette.textFaint) }
                        .buttonStyle(.pressable(.bare))
                }
            } content: {
                if let task {
                    HStack(spacing: Space.s) {
                        Button { model.inspect(task) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: task.status.icon).font(.system(size: 11)).foregroundStyle(task.status.color).frame(width: 14)
                                Text(task.title).font(Typo.body).foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.pressable(.bare, haptic: false))
                        .help("Open the task (O)")
                        IconButton(icon: "link.badge.plus", help: "Unlink (U)", size: 22) { unlink() }
                    }
                } else if !linking {
                    Button { withAnimation(Motion.snappy) { linking = true } } label: {
                        HStack(spacing: 6) { Image(systemName: "link").font(.system(size: 10, weight: .semibold)); Text("Link or create a task"); KeyHint("L") }
                    }
                    .buttonStyle(.pressable()).fixedSize()
                }
                if linking { SessionLinkPicker(session: session) { withAnimation(Motion.snappy) { linking = false } } }
            }
            Card(title: "Recap") {
                HStack(spacing: 4) {
                    if recapBusy { ProgressView().controlSize(.mini) }
                    if recap != nil { IconButton(icon: "arrow.clockwise", help: "Write a fresh recap (R)", size: 20) { writeRecap() }.disabled(recapBusy) }
                }
            } content: {
                if let recap {
                    MarkdownView(text: recap.text)
                    Text("Written \(Fmt.since(recap.at)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint)
                } else if !recapBusy {
                    Button { writeRecap() } label: {
                        HStack(spacing: 6) { Image(systemName: "text.alignleft").font(.system(size: 10, weight: .semibold)); Text("Write a recap"); KeyHint("R") }
                    }
                    .buttonStyle(.pressable()).fixedSize()
                    .help("Goal, done, open, next: one quick agent run over the transcript, kept until the session moves on")
                } else {
                    Text("Reading what the session did…").font(Typo.caption).foregroundStyle(Palette.textFaint)
                }
                if let recapError { InlineNotice(text: recapError, icon: "moon.zzz", color: Palette.violet) }
            }
            Card("Your notes") {
                NotesEditor(text: session.notes, minHeight: 64, placeholder: "Notes for yourself about this session…", focusToken: notesFocus) { text in
                    Task { try? await store.client.updateSession(session.id, ["notes": .string(text)]) }
                }
            }
            Card("Details") {
                VStack(alignment: .leading, spacing: 5) {
                    detail("Folder", (session.cwd as NSString).abbreviatingWithTildeInPath, mono: true)
                    if let repo = session.repo { detail("Repo", repo) }
                    if let branch = session.branch { detail("Branch", branch, mono: true) }
                    detail("Started", "\(Fmt.day(session.startedAt)) \(Fmt.time(session.startedAt))")
                    if let pr = session.pr { detail("Pull request", SessionPlaceView.describe(pr)) }
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).font(Typo.caption).foregroundStyle(Palette.textFaint).frame(width: 78, alignment: .leading)
            Text(value).font(mono ? Typo.mono : Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// "#1836 open · changes requested · checks failing · 3 unresolved threads"
    static func describe(_ pr: CodeSession.PullRequest) -> String {
        var parts = ["#\(pr.number) \(pr.state.lowercased())"]
        if let review = pr.reviewDecision, !review.isEmpty { parts.append(review.lowercased().replacingOccurrences(of: "_", with: " ")) }
        if let checks = pr.checks, !checks.isEmpty { parts.append("checks \(checks.lowercased())") }
        if let unresolved = pr.unresolved, unresolved > 0 { parts.append("\(unresolved) unresolved thread\(unresolved == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func unlink() {
        Task { try? await store.client.updateSession(sessionId, ["taskId": .null]) }
    }

    private func writeRecap() {
        guard !recapBusy else { return }
        recapBusy = true
        recapError = nil
        Task {
            defer { recapBusy = false }
            do {
                let text = try await store.client.sessionRecap(sessionId, refresh: true)
                withAnimation(Motion.snappy) { recap = .init(text: text, at: Date()) }
            } catch {
                withAnimation(Motion.snappy) { recapError = error.brief }
            }
        }
    }

    // MARK: Keys

    private func keys(_ stroke: KeyStroke) -> Bool {
        if stroke.plain(.escape) {
            if linking { withAnimation(Motion.snappy) { linking = false } } else { onBack() }
            return true
        }
        guard let session, stroke.mods.isEmpty else { return false }
        switch stroke.key {
        case .char("g"), .enter: if session.state != .ended { goToWindow(session) }
        case .char("c"): copyResume(session)
        case .char("a"): ask(session)
        case .char("r"): writeRecap()
        case .char("l"): withAnimation(Motion.snappy) { linking.toggle() }
        case .char("u"): if session.taskId != nil { unlink() }
        case .char("o"): if let task { model.inspect(task) }
        case .char("n"): notesFocus += 1
        case .char("e"): withAnimation(Motion.snappy) { unfoldAll.toggle(); unfolded = [] }
        case .char("m"): if turns.truncated, turns.from == "transcript" { limit += 30 }
        case .char("p"): if let pr = session.pr { app.open(pr.url) }
        case .char("t"): if let url = place?.ticketUrl { app.open(url) }
        default: return false
        }
        return true
    }
}

/// One entry of the conversation: a prompt, a reply, or the quiet line a run of tool calls collapses to.
private struct SessionTurnView: View {
    let turn: SessionTurn
    let unfolded: Bool
    let toggle: () -> Void

    /// Wide enough for the longer of the two names in the label face.
    static let gutter: CGFloat = 62

    var body: some View {
        if turn.role == .tools {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 9))
                Text(turn.text).font(Typo.mono).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Palette.textFaint)
            .padding(.leading, SessionTurnView.gutter + Space.m)
            .help("Tool calls between two replies: \(turn.text)")
        } else {
            let mine = turn.role == .user
            let preview = TurnFold.preview(turn.text)
            HStack(alignment: .top, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(mine ? "YOU" : "CLAUDE").font(Typo.label).kerning(0.5).foregroundStyle(mine ? Palette.accent : Palette.violet)
                    if let at = turn.at {
                        Text(Fmt.time(at)).font(Typo.caption).foregroundStyle(Palette.textFaint).help("\(Fmt.day(at)) \(Fmt.time(at))")
                    }
                }
                .frame(width: SessionTurnView.gutter, alignment: .leading)
                .padding(.top, mine ? Space.s : 1)
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if mine {
                            Text(unfolded ? turn.text : preview.text).font(Typo.body).foregroundStyle(Palette.text).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            MarkdownView(text: unfolded ? turn.text : preview.text)
                        }
                    }
                    .textSelection(.enabled)
                    if preview.folded {
                        Button(action: toggle) {
                            Text(unfolded ? "Show less" : "Show all \(turn.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                                .font(Typo.caption).foregroundStyle(Palette.info)
                        }
                        .buttonStyle(.pressable(.bare)).fixedSize()
                    }
                }
                .padding(mine ? Space.s + 2 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(mine ? Palette.accent.opacity(0.07) : .clear, in: .continuous(Radius.m))
            }
        }
    }
}
