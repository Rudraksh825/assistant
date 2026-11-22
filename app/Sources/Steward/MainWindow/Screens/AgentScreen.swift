import SwiftUI
import StewardKit

/// Chat with the assistant: threads on the left, the conversation, and a composer that takes context.
struct AgentScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var draft = ""
    @State private var focusToken = 0

    var body: some View {
        let threadId = model.threadId
        let streaming = threadId.map(store.streamingThreads.contains) ?? false
        HStack(spacing: 0) {
            AgentThreadList { focusToken += 1 }
                .frame(width: 228)
            VStack(spacing: 0) {
                header(threadId)
                OfflineBanner(connection: store.connection, note: store.brainNote) { store.refresh() }
                    .padding(.horizontal, Space.xl)
                if let issue = store.agentIssue {
                    InlineNotice(text: issue, icon: "exclamationmark.triangle", color: Palette.warn).padding(.horizontal, Space.xl).padding(.top, Space.s)
                }
                AgentConversation(threadId: threadId, streaming: streaming) { send($0) }
                AgentComposer(draft: $draft, streaming: streaming, focusToken: focusToken, onSend: { send(draft) }, onStop: stop)
                    .disabled(!store.connection.isOnline)
            }
        }
        .task(id: threadId) { if let threadId { store.openThread(threadId) } }
        .screenKeys(model) { stroke in
            if stroke.plain(.escape), streaming {
                stop()
                return true
            }
            if stroke.plain("/") || stroke.plain("i") || stroke.plain(.enter) {
                if stroke.plain("/"), draft.isEmpty { draft = "/" }
                focusToken += 1
                return true
            }
            let ids = store.threads.map(\.id)
            if let next = moveSelection(stroke, in: ids, from: threadId) {
                model.threadId = next
                return true
            }
            return false
        }
        .onAppear { if let preset = model.scenario["agent.draft"] { draft = preset } }
    }

    private func header(_ threadId: String?) -> some View {
        let thread = store.threads.first { $0.id == threadId }
        let spent = (threadId.flatMap { store.messages[$0] } ?? []).compactMap(\.costUsd).reduce(0, +)
        return HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread?.title.nonEmpty ?? "New chat").font(Typo.title).foregroundStyle(Palette.text).lineLimit(1)
                Text("Reads everything it is connected to. Anything other people would see waits for your approval.")
                    .font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: Space.m)
            if spent > 0 {
                Text("\(Fmt.usd(spent)) this chat").font(Typo.numeric).foregroundStyle(Palette.textFaint).help("What the replies in this chat cost")
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, 22)
        .padding(.bottom, Space.m)
        .frame(minHeight: 72, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // "/plan my day" and friends expand to their full prompt; the first match wins, as in the list above the field.
        let prompt = trimmed.hasPrefix("/") ? AgentComposer.matches(trimmed).first?.prompt ?? trimmed : trimmed
        let context = MainWindowModel.contextJSON(model.agentContext)
        let target = model.threadId
        draft = ""
        model.agentContext = []
        Haptics.tick()
        Task {
            if let id = await store.send(prompt, to: target, context: context) { model.threadId = id }
        }
    }

    private func stop() {
        if let threadId = model.threadId { store.interrupt(threadId) }
    }
}

private struct AgentThreadList: View {
    let onNew: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var renaming: String?
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.threadId = nil
                onNew()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .medium))
                    Text("New chat").font(Typo.bodyStrong)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(model.threadId == nil ? Palette.accent : Palette.text)
                .padding(.horizontal, Space.s + 2)
                .frame(height: 30)
                .background(Palette.hover, in: .continuous(Radius.s + 1))
                .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(model.threadId == nil ? Palette.accent.opacity(0.4) : Palette.stroke, lineWidth: 1))
                .contentShape(.rect)
            }
            .buttonStyle(.pressable(.bare))
            .padding(.horizontal, Space.m)
            .padding(.top, 24)
            .padding(.bottom, Space.m)

            if store.threads.isEmpty {
                Text("Earlier chats will be listed here.").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(.horizontal, Space.l)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.threads) { thread in
                        Button { model.threadId = thread.id } label: {
                            HStack(spacing: Space.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if renaming == thread.id {
                                        TextField("Title", text: $title)
                                            .textFieldStyle(.plain).font(Typo.body).foregroundStyle(Palette.text)
                                            .focused($titleFocused)
                                            .onAppear { titleFocused = true }
                                            .onSubmit {
                                                store.renameThread(thread.id, title: title)
                                                renaming = nil
                                            }
                                            .onExitCommand { renaming = nil }
                                            .onChange(of: titleFocused) { if !titleFocused { renaming = nil } }
                                    } else {
                                        Text(thread.title.nonEmpty ?? "Untitled chat").font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                                    }
                                    Text(Fmt.day(thread.updatedAt) == "Today" ? Fmt.time(thread.updatedAt) : Fmt.day(thread.updatedAt))
                                        .font(Typo.caption).foregroundStyle(Palette.textFaint)
                                }
                                Spacer(minLength: 0)
                                if store.streamingThreads.contains(thread.id) { ProgressView().controlSize(.mini) }
                                else if store.approvals.contains(where: { $0.threadId == thread.id }) {
                                    Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(Palette.danger).help("Waiting for your approval")
                                }
                            }
                            .padding(.horizontal, Space.s + 2)
                            .padding(.vertical, 6)
                            .rowSurface(selected: model.threadId == thread.id)
                        }
                        .buttonStyle(.pressable(.bare, haptic: false))
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                title = thread.title
                                renaming = thread.id
                            }
                            Button("Delete chat", systemImage: "trash", role: .destructive) {
                                if model.threadId == thread.id { model.threadId = nil }
                                store.deleteThread(thread.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.s)
                .padding(.bottom, Space.m)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.bgSunken.opacity(0.55))
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.stroke).frame(width: 1) }
    }
}

/// Multi-line field: Return adds a line, ⌘↩ sends (or, with `returnSends`, Return sends and ⇧Return adds
/// a line). Context chips and slash prompts sit above it.
struct AgentComposer: View {
    @Binding var draft: String
    let streaming: Bool
    let focusToken: Int
    var returnSends = false
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @FocusState private var focused: Bool

    static func matches(_ text: String) -> [(slash: String, title: String, prompt: String)] {
        let typed = text.lowercased()
        return CommandPalette.prompts.filter { $0.slash.hasPrefix(typed) || Fuzzy.score(String(typed.dropFirst()), in: $0.title) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let error = store.lastError, store.connection.isOnline {
                InlineNotice(text: error, icon: "exclamationmark.circle", color: Palette.warn)
            }
            if draft.hasPrefix("/"), !draft.contains("\n") { slashList }
            VStack(alignment: .leading, spacing: Space.s) {
                ZStack(alignment: .topLeading) {
                    // Invisible twin that gives the editor its height; TextEditor has no intrinsic one.
                    Text(draft.isEmpty ? " " : draft + " ").font(.system(size: 14)).lineSpacing(2).padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading).opacity(0)
                    if draft.isEmpty {
                        Text("Ask anything, or type / for a quick prompt").font(.system(size: 14)).foregroundStyle(Palette.textFaint).padding(.horizontal, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.text)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            guard returnSends, !press.modifiers.contains(.shift), !streaming else { return .ignored }
                            onSend()
                            return .handled
                        }
                }
                .frame(minHeight: 22, maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach(model.agentContext) { chip in
                        Button { model.agentContext.removeAll { $0 == chip } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: Self.icon(chip.kind)).font(.system(size: 9, weight: .medium))
                                Text(chip.title).font(Typo.caption).lineLimit(1).frame(maxWidth: 180)
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(0.6)
                            }
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Palette.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.pressable(.bare)).fixedSize()
                        .help("Attached to your next message. Click to remove.")
                    }
                    contextMenu
                    Spacer(minLength: Space.s)
                    if streaming {
                        Button(action: onStop) {
                            HStack(spacing: 6) { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon); KeyHint("esc") }
                        }
                        .buttonStyle(.pressable()).fixedSize()
                    } else {
                        Text(returnSends ? "⇧↩ new line" : "↩ new line").font(Typo.caption).foregroundStyle(Palette.textFaint)
                        Button(action: onSend) {
                            HStack(spacing: 6) {
                                Text("Send")
                                Text(returnSends ? "↩" : "⌘↩").font(.system(size: 10.5, weight: .semibold, design: .rounded)).opacity(0.7)
                            }
                        }
                        .buttonStyle(.pressable(.primary)).fixedSize()
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(Space.m)
            .background(Palette.bgRaised, in: .continuous(Radius.l))
            .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
            .animation(Motion.snappy, value: focused)
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
        .padding(.top, Space.s)
        .frame(maxWidth: 760 + Space.xl * 2)
        .frame(maxWidth: .infinity)
        .onChange(of: focusToken) { focused = true }
        .animation(Motion.snappy, value: draft.hasPrefix("/"))
    }

    private var slashList: some View {
        let matches = Self.matches(draft)
        return VStack(alignment: .leading, spacing: 1) {
            if matches.isEmpty {
                Text("No quick prompt matches. ⌘↩ sends it as written.").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.s)
            }
            ForEach(Array(matches.enumerated()), id: \.element.slash) { index, match in
                Button {
                    draft = match.slash
                    onSend()
                } label: {
                    HStack(spacing: Space.s) {
                        Text(match.slash).font(Typo.mono).foregroundStyle(Palette.violet)
                        Text(match.prompt).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
                        Spacer(minLength: 0)
                        if index == 0 { KeyHint("⌘", "↩") }
                    }
                    .padding(.horizontal, Space.s + 2)
                    .frame(height: 28)
                    .rowSurface(selected: index == 0)
                }
                .buttonStyle(.pressable(.bare, haptic: false))
            }
        }
        .padding(Space.xs)
        .background(Palette.bgRaised, in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.stroke, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var contextMenu: some View {
        MenuChip(title: "Context", icon: "plus") {
            if let now = store.snapshot?.now {
                Button("Current task: \(now.title)", systemImage: "play.circle") { attach(.task, now.id, now.title) }
            }
            if !store.sessions.isEmpty {
                Menu("Session") {
                    ForEach(store.sessions) { session in
                        Button("\(session.displayName): \(session.title ?? session.branch ?? session.state.rawValue)") { attach(.session, session.id, session.displayName) }
                    }
                }
            }
            let meetings = store.meetings.filter { Calendar.current.isDateInToday($0.startAt) }
            if !meetings.isEmpty {
                Menu("Meeting") {
                    ForEach(meetings) { meeting in
                        Button("\(Fmt.time(meeting.startAt))  \(meeting.title)") { attach(.meeting, meeting.id, meeting.title) }
                    }
                }
            }
            if store.snapshot?.now == nil && store.sessions.isEmpty && meetings.isEmpty {
                Text("Nothing to attach right now")
            }
        }
        .help("Attach the current task, a session or a meeting to your next message")
    }

    private func attach(_ kind: MainWindowModel.ContextChip.Kind, _ id: String, _ title: String) {
        // One of each kind: the context is sent as taskId / sessionId / meetingId.
        withAnimation(Motion.snappy) {
            model.agentContext.removeAll { $0.kind == kind }
            model.agentContext.append(.init(kind: kind, id: id, title: title))
        }
    }

    static func icon(_ kind: MainWindowModel.ContextChip.Kind) -> String {
        switch kind {
        case .task: "checklist"
        case .session: "terminal"
        case .meeting: "calendar"
        }
    }
}
