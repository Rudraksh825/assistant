import SwiftUI
import StewardKit

/// The open island: decisions first, then now + next on the left, sessions + meeting on the right, and
/// a capture field along the bottom. The header row sits in the ears, either side of the camera.
/// Each section reads only its own slice of the model, so a session tick does not redraw the tasks.
struct NotchExpanded: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchHeader(scene: scene, model: model)
                .frame(height: scene.layout.notch.height)
                .stagger(0, shown: scene.revealed)
            VStack(alignment: .leading, spacing: 12) {
                NotchDecisions(scene: scene, model: model).stagger(1, shown: scene.revealed)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        NotchNow(scene: scene, model: model).stagger(1, shown: scene.revealed)
                        NotchNextUp(scene: scene, model: model).stagger(2, shown: scene.revealed)
                        NotchChats(scene: scene, model: model).stagger(3, shown: scene.revealed)
                    }
                    .frame(width: NotchMetrics.leftColumn, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        NotchSessions(scene: scene, model: model).stagger(2, shown: scene.revealed)
                        NotchMeeting(scene: scene, model: model).stagger(3, shown: scene.revealed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                NotchField(scene: scene, online: model.online).stagger(4, shown: scene.revealed)
            }
            .padding(.horizontal, NotchMetrics.padding)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(width: NotchMetrics.fullWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scene.onContentHeight($0) }
    }
}

private struct SelectionRing: ViewModifier {
    let on: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle.continuous(radius).strokeBorder(Palette.accent.opacity(on ? 0.7 : 0), lineWidth: 1.5))
    }
}

private extension View {
    func selectionRing(_ on: Bool, radius: CGFloat = 12) -> some View { modifier(SelectionRing(on: on, radius: radius)) }
}

// MARK: Header

private struct NotchHeader: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if model.agentBusy {
                    AgentShimmer()
                } else {
                    Circle().fill(model.online ? Palette.ok : Palette.warn).frame(width: 6, height: 6)
                }
                Text(model.agentActivity ?? (model.online ? "Steward" : "Brain offline"))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Island.dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The camera housing covers this stretch on a notched display.
            Color.clear.frame(width: scene.layout.notch.width + 20)
            HStack(spacing: 8) {
                if model.suggestionCount > 0 {
                    Button { scene.actions.openMain(.inbox) } label: {
                        Label("\(model.suggestionCount) to review", systemImage: "tray.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
                Button { scene.actions.openMain(nil) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .medium)).foregroundStyle(Island.dim)
                }
                .buttonStyle(.plain)
                .help("Open Steward")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, NotchMetrics.padding + 4)
    }
}

// MARK: Decisions

private struct NotchDecisions: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        if !model.approvals.isEmpty || !model.questions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                IslandLabel("Needs you", count: model.approvals.count + model.questions.count)
                ForEach(model.approvals.prefix(2)) { approval in
                    ApprovalRow(scene: scene, approval: approval)
                }
                ForEach(model.questions.prefix(1)) { question in
                    QuestionRow(scene: scene, question: question)
                }
                let more = model.approvals.count + model.questions.count - min(2, model.approvals.count) - min(1, model.questions.count)
                if more > 0 {
                    Button("\(more) more in the inbox") { scene.actions.openMain(.inbox) }
                        .buttonStyle(.plain).font(Typo.caption).foregroundStyle(Island.dim)
                }
            }
        }
    }

    /// The payload is always in view beside the buttons. If it does not fit here, there is no Approve: Review opens the full card.
    private struct ApprovalRow: View {
        let scene: NotchScene
        let approval: Approval

        var body: some View {
            let complete = ApprovalPayload(approval).compact.complete
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.danger)
                        .frame(width: 26, height: 26).background(Palette.danger.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Agent: \(ApprovalPayload.label(approval.summary, max: 120))").font(.system(size: 13, weight: .medium)).foregroundStyle(Island.text).lineLimit(2)
                        if let target = approval.target, !target.isEmpty {
                            Text(verbatim: ApprovalPayload.label(target, max: 60)).font(Typo.caption).foregroundStyle(Island.dim).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Deny") { scene.actions.deny(approval) }.buttonStyle(.island(.danger, compact: true))
                    if complete {
                        Button("Approve") { scene.actions.approve(approval) }.buttonStyle(.island(.primary, compact: true))
                    } else {
                        Button("Review") { scene.actions.openMain(.inbox) }.buttonStyle(.island(.primary, compact: true))
                    }
                }
                ApprovalCompactPayload(approval: approval, dim: Island.dim, fill: Color.black.opacity(0.5))
            }
            .padding(10)
            .background(Palette.danger.opacity(0.07), in: .continuous(14))
            .selectionRing(scene.selection == .approval(approval.id), radius: 14)
        }
    }

    private struct QuestionRow: View {
        let scene: NotchScene
        let question: BrainEvent.ChatQuestion

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 26, height: 26).background(Palette.accent.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 7) {
                    Text(question.question).font(.system(size: 13, weight: .medium)).foregroundStyle(Island.text).lineLimit(3)
                    HStack(spacing: 6) {
                        ForEach(question.options.prefix(3), id: \.self) { option in
                            Button(option) { scene.actions.answer(question, option) }.buttonStyle(.island(.quiet, compact: true))
                        }
                        Button("Answer in chat") { scene.actions.openMain(.agent) }
                            .buttonStyle(.plain).font(Typo.caption).foregroundStyle(Island.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Palette.accent.opacity(0.07), in: .continuous(14))
            .selectionRing(scene.selection == .question(question.id), radius: 14)
        }
    }
}

// MARK: Now

private struct NotchNow: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandLabel("Now")
            if let task = model.now {
                HStack(spacing: 11) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Island.text).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Image(systemName: "timer").font(.system(size: 10, weight: .semibold))
                            ElapsedText(since: model.nowSince ?? task.updatedAt, seconds: true)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            if let project = task.projectId.flatMap({ model.projectTitles[$0] }) {
                                Text("·  \(project)").font(Typo.caption).foregroundStyle(Island.dim).lineLimit(1)
                            }
                        }
                        .foregroundStyle(Palette.accent)
                    }
                    Spacer(minLength: 6)
                    if let next = model.next.first {
                        IslandIconButton(icon: "forward.end.fill") { scene.actions.start(next) }.help("Switch to: \(next.title)")
                    }
                    Button { scene.actions.complete(task) } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(.island(.primary, compact: true))
                }
                .padding(.init(top: 11, leading: 13, bottom: 11, trailing: 11))
                .background(
                    LinearGradient(colors: [Palette.accent.opacity(0.17), Palette.accent.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .continuous(16))
                .overlay(RoundedRectangle.continuous(16).strokeBorder(Palette.accent.opacity(0.22), lineWidth: 1))
                .selectionRing(scene.selection == .now, radius: 16)
            } else {
                Text("Nothing in progress. Start one below.")
                    .font(Typo.caption).foregroundStyle(Island.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Island.fill, in: .continuous(16))
            }
        }
    }
}

// MARK: Next up

private struct NotchNextUp: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        if !model.next.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                IslandLabel("Next up").padding(.bottom, 2)
                ForEach(model.next) { task in
                    TaskLine(scene: scene, task: task)
                }
            }
        }
    }

    /// Click the ring to complete, the row to start. Swipe right completes, left snoozes; the same
    /// actions appear as buttons under the pointer.
    private struct TaskLine: View {
        let scene: NotchScene
        let task: TaskItem
        @State private var drag: CGFloat = 0

        private var item: NotchItem { .task(task.id) }

        var body: some View {
            let dx = drag + scene.offset(for: item)
            let active = scene.isActive(item)
            HStack(spacing: 10) {
                Button {
                    Haptics.success()
                    scene.actions.complete(task)
                } label: {
                    Circle().strokeBorder(Palette.priority(task.priority), lineWidth: 1.6).frame(width: 13, height: 13)
                        .padding(7).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(-7)
                .help("Complete")
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.system(size: 13)).foregroundStyle(Island.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(Int(task.score))").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent.opacity(0.9))
                        Text(task.scoreReasons.isEmpty ? "ranked by the brain" : task.scoreReasons.prefix(3).joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Island.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if active {
                    HStack(spacing: 5) {
                        IslandIconButton(icon: "arrow.up.forward.square") { scene.actions.open(task) }.help("Open in Steward")
                        IslandIconButton(icon: "play.fill", tint: Palette.accent) { scene.actions.start(task) }.help("Start")
                        Menu {
                            ForEach(Snooze.options(), id: \.title) { option in
                                Button(option.title) { scene.actions.snooze(task, option.date) }
                            }
                        } label: {
                            Image(systemName: "moon.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Island.dim)
                                .frame(width: 22, height: 22).background(Island.fillStrong, in: Circle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Snooze")
                        IslandIconButton(icon: "checkmark", tint: Palette.ok) { scene.actions.complete(task) }.help("Complete")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? Island.fill : .clear, in: .continuous(12))
            .selectionRing(scene.selection == item)
            .offset(x: dx)
            .background(alignment: dx > 0 ? .leading : .trailing) { reveal(dx) }
            .contentShape(.rect)
            .onTapGesture { scene.actions.start(task) }
            .onPointerHover { scene.hover(item, $0) }
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { drag = RubberBand.offset($0.translation.width, dimension: AmbientFeel.swipeLimit, coefficient: 0.9) }
                .onEnded { value in
                    let committed = abs(value.translation.width) >= AmbientFeel.swipeCommit
                    withAnimation(Motion.bounce) { drag = 0 }
                    if committed { NotchSwipe.commit(task, right: value.translation.width > 0, actions: scene.actions) }
                })
            .animation(Motion.snappy, value: active)
        }

        @ViewBuilder private func reveal(_ dx: CGFloat) -> some View {
            if dx != 0 {
                let armed = abs(dx) >= NotchSwipe.armedAt
                let color = dx > 0 ? Palette.ok : Palette.info
                Image(systemName: dx > 0 ? "checkmark.circle.fill" : "moon.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color.opacity(armed ? 1 : 0.5))
                    .scaleEffect(armed ? 1.15 : 0.9)
                    .padding(.horizontal, 12)
                    .animation(Motion.bounce, value: armed)
            }
        }
    }
}

// MARK: Chats

/// The last few conversations with the agent. A chat that is answering or waiting on the user says so;
/// a click brings the chat window up on it, with everything said so far.
private struct NotchChats: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        if !model.chats.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                IslandLabel("Chats", count: model.chats.filter { $0.state == .needsYou }.count).padding(.bottom, 6)
                ForEach(model.chats) { chat in
                    Button { scene.actions.openChat(chat.id) } label: {
                        HStack(spacing: 8) {
                            Group {
                                switch chat.state {
                                case .answering: AgentShimmer()
                                case .needsYou: Circle().fill(Palette.accent).frame(width: 6, height: 6)
                                case .idle: Image(systemName: "bubble.left").font(.system(size: 9, weight: .semibold)).foregroundStyle(Island.faint)
                                }
                            }
                            .frame(width: 22)
                            Text(chat.title).font(.system(size: 12.5)).foregroundStyle(Island.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(chat.state == .answering ? "answering" : chat.state == .needsYou ? "needs you" : Fmt.since(chat.updatedAt))
                                .font(.system(size: 10.5)).foregroundStyle(chat.state == .needsYou ? Palette.accent : Island.faint)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(IslandRowStyle())
                }
            }
        }
    }
}

/// A row that lights up while pressed. Not on hover: hover state comes from tracking areas, and a row
/// whose look depends on them is one more thing that can flicker.
private struct IslandRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Island.fillStrong : Island.fill.opacity(0.5), in: .continuous(10))
            .padding(.vertical, 1.5)
    }
}

enum NotchSwipe {
    /// What the rubber band shows once the finger has travelled `swipeCommit`.
    static let armedAt = RubberBand.offset(AmbientFeel.swipeCommit, dimension: AmbientFeel.swipeLimit, coefficient: 0.9)

    @MainActor static func commit(_ task: TaskItem, right: Bool, actions: AmbientActions) {
        if right {
            Haptics.success()
            actions.complete(task)
        } else {
            Haptics.thunk()
            actions.snooze(task, Snooze.options()[0].date)
        }
    }
}

// MARK: Sessions

private struct NotchSessions: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IslandLabel("Sessions", count: model.sessions.filter(\.needsAttention).count).padding(.bottom, 2)
            if model.sessions.isEmpty {
                Text("No coding sessions running.")
                    .font(Typo.caption).foregroundStyle(Island.faint)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else if model.sessions.count > NotchMetrics.maxSessionRows {
                ScrollView(showsIndicators: false) { rows }
                    .frame(height: CGFloat(NotchMetrics.maxSessionRows) * NotchMetrics.sessionRowHeight + 14)
                    .onPointerHover { scene.overScroller = $0 }
            } else {
                rows
            }
            if !model.sessions.isEmpty { peek }
        }
    }

    /// Where the session under the pointer stopped (or, with nothing under it, the one that has waited
    /// longest). A fixed-height strip: a row that grew on hover pushed the rows below it out from under
    /// the pointer, which un-hovered it, which shrank it again.
    private var peek: some View {
        let hoveredID: String? = { if case .session(let id)? = scene.hovered ?? scene.selection { return id } else { return nil } }()
        let session = hoveredID.flatMap { id in model.sessions.first { $0.id == id } } ?? model.sessions.first(where: \.needsAttention)
        let text = session.flatMap { $0.lastAssistantText?.isEmpty == false ? $0.lastAssistantText : $0.lastUserPrompt }
        return Text(text ?? "Point at a session to see where it stopped.")
            .font(.system(size: 11)).foregroundStyle(text == nil ? Island.faint : Island.dim)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Island.fill.opacity(0.6), in: .continuous(10))
            .padding(.top, 4)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sessions) { session in
                SessionLine(scene: scene, session: session)
            }
        }
    }

    private struct SessionLine: View {
        let scene: NotchScene
        let session: CodeSession

        private var item: NotchItem { .session(session.id) }

        var body: some View {
            let active = scene.isActive(item)
            Button { scene.actions.focus(session) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        SessionDots(states: [session.state], alignment: .left).frame(width: 8)
                        Text(session.ticket ?? session.displayName)
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Island.text).lineLimit(1).layoutPriority(1)
                        Text(session.title ?? session.lastUserPrompt ?? session.displayName)
                            .font(.system(size: 11.5)).foregroundStyle(Island.dim).lineLimit(1)
                        Spacer(minLength: 4)
                        if session.needsAttention {
                            TimelineView(.everyMinute) { context in
                                Text(Fmt.since(session.stateSince, now: context.date))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(Palette.session(session.state))
                            }
                        } else {
                            Text(session.state == .working ? "working" : "idle").font(.system(size: 10.5)).foregroundStyle(Island.faint)
                        }
                    }
                    .frame(height: NotchMetrics.sessionRowHeight - 12)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Island.fill : .clear, in: .continuous(12))
                .selectionRing(scene.selection == item)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onPointerHover { scene.hover(item, $0) }
            .animation(Motion.snappy, value: active)
            .help(session.cwd)
        }
    }
}

// MARK: Meeting

private struct NotchMeeting: View {
    let scene: NotchScene
    let model: AmbientModel

    var body: some View {
        if let meeting = model.meeting {
            VStack(alignment: .leading, spacing: 6) {
                IslandLabel(model.meetingLive ? "In a meeting" : "Next meeting")
                HStack(spacing: 10) {
                    RoundedRectangle.continuous(2).fill(model.meetingLive ? Palette.accent : Palette.info).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Island.text).lineLimit(1)
                        HStack(spacing: 5) {
                            Text("\(Fmt.time(meeting.startAt)) – \(Fmt.time(meeting.endAt))").monospacedDigit()
                            if !model.meetingLive {
                                Text("·")
                                HStack(spacing: 3) {
                                    Text("in")
                                    CountdownText(to: meeting.startAt)
                                }
                                .foregroundStyle(Palette.info)
                            }
                        }
                        .font(.system(size: 11)).foregroundStyle(Island.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if meeting.joinUrl != nil {
                        Button("Join") { scene.actions.join(meeting) }.buttonStyle(.island(model.meetingLive ? .primary : .quiet, compact: true))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Island.fill, in: .continuous(12))
                .selectionRing(scene.selection == .meeting)
            }
        }
    }
}

// MARK: Capture field

private struct NotchField: View {
    @Bindable var scene: NotchScene
    let online: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: CaptureDraft.parse(scene.field).forceAgent ? "sparkles" : "plus")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(scene.fieldFocused ? Palette.accent : Island.faint)
                .frame(height: 16)
            AmbientTextInput(text: $scene.field, placeholder: online ? "Capture a thought, or ask…" : "Brain offline", maxLines: 3, focus: scene.focusField,
                             onSubmit: { scene.submitField($0) }, onEscape: { scene.close() },
                             onMove: { scene.moveFromField($0) }, onFocus: { scene.fieldFocused = $0 })
            if !scene.field.isEmpty {
                HStack(spacing: 8) {
                    hint("↩", "capture")
                    hint("⌘↩", "ask")
                }
                .frame(height: 16)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Island.fill, in: .continuous(13))
        .overlay(RoundedRectangle.continuous(13).strokeBorder(scene.fieldFocused ? Palette.accent.opacity(0.55) : Island.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: scene.fieldFocused)
        .animation(Motion.snappy, value: scene.field.isEmpty)
        .disabled(!online)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Island.dim)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Island.faint)
        }
    }
}
