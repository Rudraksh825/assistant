import SwiftUI
import StewardKit

/// The scrolling part of the chat: messages, then whatever the agent is waiting on (answers, approvals).
struct AgentConversation: View {
    let threadId: String?
    let streaming: Bool
    let onPrompt: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var editingApproval: String?
    @State private var expandedApprovals: Set<String> = []

    var body: some View {
        let messages = (threadId.flatMap { store.messages[$0] } ?? []).filter { $0.role == .tool || !$0.text.isEmpty }
        let questions = store.questions.filter { $0.threadId == threadId }
        let approvals = threadId == nil ? [] : store.approvals.filter { $0.threadId == threadId }
        if messages.isEmpty && questions.isEmpty && approvals.isEmpty && !streaming {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.m) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        AgentMessageRow(message: message, cost: message.costUsd)
                            .equatable()
                            // Runs of tool calls read as one block.
                            .padding(.top, message.role == .tool && index > 0 && messages[index - 1].role == .tool ? -Space.s : 0)
                    }
                    ForEach(questions) { question in
                        AgentQuestionCard(question: question) { store.answer(question, $0) }
                    }
                    ForEach(approvals) { approval in
                        ApprovalReviewCard(approval: approval, editing: Binding(get: { editingApproval == approval.id }, set: { editingApproval = $0 ? approval.id : nil }),
                                           expanded: Binding(get: { expandedApprovals.contains(approval.id) }, set: { if $0 { expandedApprovals.insert(approval.id) } else { expandedApprovals.remove(approval.id) } }))
                    }
                    if streaming {
                        HStack(spacing: Space.s) {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                            Text(store.agent.activity ?? "Thinking…").font(Typo.caption).foregroundStyle(Palette.textDim)
                        }
                        .frame(height: 20)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.m)
                .frame(maxWidth: 760 + Space.xl * 2, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Stays pinned to the newest text while a reply streams in.
            .defaultScrollAnchor(.bottom)
        }
    }

    private var empty: some View {
        VStack(spacing: Space.l) {
            Spacer(minLength: Space.xl)
            VStack(spacing: Space.s) {
                Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.accent)
                Text("Ask Steward").font(Typo.title).foregroundStyle(Palette.text)
                Text("It can read your tasks, sessions, meetings and connected tools, and it keeps notes about how you work. Anything visible to other people waits for your approval.")
                    .font(Typo.body).foregroundStyle(Palette.textDim).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 440)
            }
            Grid(horizontalSpacing: Space.s, verticalSpacing: Space.s) {
                ForEach(Array(stride(from: 0, to: CommandPalette.prompts.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(CommandPalette.prompts[start..<min(start + 2, CommandPalette.prompts.count)], id: \.slash) { prompt in
                            Button { onPrompt(prompt.prompt) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(prompt.title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                                    Text(prompt.slash).font(Typo.mono).foregroundStyle(Palette.violet)
                                }
                                .padding(Space.m)
                                .frame(width: 236, alignment: .leading)
                                .cardSurface()
                                .rowSurface(radius: Radius.m)
                            }
                            .buttonStyle(.pressable(.bare))
                            .disabled(!store.connection.isOnline)
                        }
                    }
                }
            }
            Spacer(minLength: Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentMessageRow: View, Equatable {
    let message: ChatMessage
    let cost: Double?

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text).font(Typo.body).foregroundStyle(Palette.text).lineSpacing(3).textSelection(.enabled)
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(Palette.accent.opacity(0.13), in: .continuous(Radius.l))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .tool:
            if let tool = message.tool { AgentToolRow(tool: tool) }
        case .system:
            InlineNotice(text: message.text, icon: "exclamationmark.circle", color: Palette.warn)
        case .assistant, .unknown:
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(text: message.text)
                if let cost {
                    Text(Fmt.usd(cost)).font(Typo.numeric).foregroundStyle(Palette.textFaint).help("What this reply cost")
                }
            }
        }
    }
}

/// One tool call: a single quiet line that opens to show exactly what went in and came out.
private struct AgentToolRow: View {
    let tool: ChatMessage.ToolCall
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.snappy) { open.toggle() } } label: {
                HStack(spacing: Space.s) {
                    status.frame(width: 14, height: 14)
                    Text(tool.name).font(Typo.mono).foregroundStyle(Palette.text)
                    Text(summary).font(Typo.mono).foregroundStyle(Palette.textFaint).lineLimit(1)
                    Spacer(minLength: Space.s)
                    if tool.status == .denied { Text("needs approval").font(Typo.caption).foregroundStyle(Palette.warn) }
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.textFaint).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, Space.s + 2)
                .frame(height: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.pressable(.bare, haptic: false))
            if open {
                VStack(alignment: .leading, spacing: Space.s) {
                    detail("Input", tool.input?.text(pretty: true) ?? "{}")
                    if let result = tool.result, !result.isEmpty { detail(tool.status == .error ? "Error" : "Result", result) }
                }
                .padding(.horizontal, Space.s + 2)
                .padding(.bottom, Space.s + 2)
                .transition(.opacity)
            }
        }
        .background(hovered || open ? Palette.hover : Color.white.opacity(0.025), in: .continuous(Radius.s + 2))
        .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(Palette.stroke, lineWidth: 1))
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
    }

    @ViewBuilder private var status: some View {
        switch tool.status {
        case .running: ProgressView().controlSize(.small).scaleEffect(0.55)
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.ok)
        case .error: Image(systemName: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(Palette.danger)
        case .denied: Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Palette.warn)
        case .unknown: Image(systemName: "circle.dotted").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
        }
    }

    /// The result when there is one (it is what the reader wants), else the arguments on one line.
    private var summary: String {
        if tool.status != .running, let result = tool.result, !result.isEmpty { return result.replacingOccurrences(of: "\n", with: " ") }
        guard let input = tool.input?.object, !input.isEmpty else { return "" }
        return input.keys.sorted().prefix(3).map { "\($0): \(input[$0]?.string ?? input[$0]?.text() ?? "")" }.joined(separator: "  ")
    }

    private func detail(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(Typo.label).kerning(0.5).foregroundStyle(Palette.textFaint)
            Text(text).font(Typo.mono).foregroundStyle(Palette.text.opacity(0.85)).lineSpacing(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s)
                .background(Palette.bgSunken, in: .continuous(Radius.s))
        }
    }
}

/// The agent asked something mid-run: pick an option or type an answer.
private struct AgentQuestionCard: View {
    let question: BrainEvent.ChatQuestion
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 11)).foregroundStyle(Palette.violet)
                Text("Steward is asking").font(Typo.caption).foregroundStyle(Palette.violet)
            }
            Text(question.question).font(Typo.bodyStrong).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                Flow(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button(option) { onAnswer(option) }.buttonStyle(.pressable(index == 0 ? .primary : .secondary)).fixedSize()
                    }
                }
            }
            CaptureField(question.options.isEmpty ? "Type your answer…" : "Or answer in your own words…", icon: "arrowshape.turn.up.left", onSubmit: onAnswer)
        }
        .padding(Space.m)
        .background(Palette.violet.opacity(0.05), in: .continuous(Radius.l))
        .cardSurface(radius: Radius.l)
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.violet.opacity(0.3), lineWidth: 1))
    }
}
