import SwiftUI
import StewardKit

/// What a toast's buttons do. A value so the stack renders without the store.
@MainActor
struct ToastActions {
    var act: (Nudge, NudgeAction) -> Void = { _, _ in }
    var approve: (Approval) -> Void = { _ in }
    var deny: (Approval) -> Void = { _ in }
    var answer: (BrainEvent.ChatQuestion, String) -> Void = { _, _ in }
    /// The body was clicked: open whatever the toast is about.
    var open: (ToastItem) -> Void = { _ in }
}

enum ToastMetrics {
    static let width: CGFloat = 364
    static let spacing: CGFloat = 8
    /// Gap between the island's bottom edge and the first toast.
    static let gap: CGFloat = 8
}

/// The stack under the notch. Each toast is extruded from the notch's centre line and leaves upward
/// (timed out) or sideways (swiped).
struct ToastStack: View {
    let center: ToastCenter
    let displayID: CGDirectDisplayID
    var actions = ToastActions()
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(spacing: ToastMetrics.spacing) {
            if center.displayID == displayID {
                ForEach(center.items) { item in
                    ToastCard(item: item, center: center, actions: actions)
                        .transition(.asymmetric(insertion: .modifier(active: Extrude(progress: 0), identity: Extrude(progress: 1)),
                                                removal: .modifier(active: Extrude(progress: 0), identity: Extrude(progress: 1)).animation(Motion.snappy)))
                }
            }
        }
        .frame(width: ToastMetrics.width)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private struct Extrude: ViewModifier {
        let progress: CGFloat

        func body(content: Content) -> some View {
            content
                .scaleEffect(x: 0.55 + 0.45 * progress, y: 0.4 + 0.6 * progress, anchor: .top)
                .offset(y: -22 * (1 - progress))
                .opacity(Double(progress))
                .blur(radius: 5 * (1 - progress))
        }
    }
}

struct ToastCard: View {
    let item: ToastItem
    let center: ToastCenter
    let actions: ToastActions
    @State private var hovered = false
    @State private var answering = false
    @State private var answer = ""
    @State private var focus = 0
    @State private var drag: CGFloat = 0

    private var dx: CGFloat { drag + (center.swipe?.id == item.id ? center.swipe?.dx ?? 0 : 0) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 28, height: 28)
                .background(item.tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.text)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !item.body.isEmpty {
                    Text(item.body).font(Typo.caption).foregroundStyle(Island.dim).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IslandIconButton(icon: "xmark", size: 18) { dismiss() }
                .opacity(hovered ? 1 : 0)
                .accessibilityLabel("Dismiss")
        }
        .padding(.init(top: 12, leading: 12, bottom: 12, trailing: 10))
        .background(Island.raised, in: .continuous(22))
        .overlay(RoundedRectangle.continuous(22).strokeBorder(
            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: hovered ? 22 : 14, y: hovered ? 11 : 7)
        .scaleEffect(hovered ? 1.012 : 1)
        .offset(x: dx)
        .opacity(1 - min(0.75, abs(dx) / 220))
        .contentShape(.rect)
        .onTapGesture { actions.open(item) }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation.width }
            .onEnded { value in
                if abs(value.predictedEndTranslation.width) > 150 || abs(value.translation.width) > AmbientFeel.swipeCommit {
                    Haptics.tick()
                    dismiss()
                } else {
                    withAnimation(Motion.bounce) { drag = 0 }
                }
            })
        .onPointerHover { inside in
            hovered = inside
            if inside { center.hoveredID = item.id } else if center.hoveredID == item.id { center.hoveredID = nil }
            if inside { center.hold(item.id) } else if !answering { center.release(item.id) }
        }
        .animation(Motion.snappy, value: hovered)
        .animation(Motion.snappy, value: answering)
    }

    @ViewBuilder private var detail: some View {
        switch item.kind {
        case .nudge(let nudge):
            let buttons = nudge.actions.filter { $0.kind != .dismiss }.prefix(3)
            if !buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(buttons.enumerated()), id: \.element.id) { index, action in
                        Button(action.label) {
                            actions.act(nudge, action)
                            center.dismiss(item.id)
                        }
                        .buttonStyle(.island(index == 0 ? .primary : .quiet, compact: true))
                    }
                }
                .padding(.top, 4)
            }
        case .approval(let approval):
            // The payload is always in view; when it does not fit, the only way forward is the full card.
            let complete = ApprovalPayload(approval).compact.complete
            if let target = approval.target, !target.isEmpty { Pill(ApprovalPayload.label(target, max: 60), icon: "arrow.up.right", color: Island.dim) }
            ApprovalCompactPayload(approval: approval, dim: Island.dim, fill: Island.fill)
            HStack(spacing: 6) {
                if complete {
                    Button("Approve") {
                        actions.approve(approval)
                        center.dismiss(item.id)
                    }
                    .buttonStyle(.island(.primary, compact: true))
                } else {
                    Button("Review") {
                        actions.open(item)
                        center.dismiss(item.id)
                    }
                    .buttonStyle(.island(.primary, compact: true))
                }
                Button("Deny") {
                    actions.deny(approval)
                    center.dismiss(item.id)
                }
                .buttonStyle(.island(.danger, compact: true))
            }
            .padding(.top, 4)
        case .question(let question):
            if answering || question.options.isEmpty {
                HStack(spacing: 6) {
                    AmbientTextInput(text: $answer, placeholder: "Answer…", font: .systemFont(ofSize: 12.5), focus: focus,
                                     onSubmit: { _ in send(question, answer) }, onEscape: { answering = false })
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Island.fill, in: .continuous(9))
                    IslandIconButton(icon: "arrow.up", tint: Palette.onAccent, size: 24) { send(question, answer) }
                        .background(Palette.accent, in: Circle())
                }
                .padding(.top, 4)
                .onAppear { if answering { focus += 1 } }
            } else {
                // Options wrap: an answer can be a sentence.
                VStack(alignment: .leading, spacing: 5) {
                    // "Something else" is the free-text button below; an option saying the same would sit twice.
                    ForEach(question.options.filter { !$0.lowercased().hasPrefix("something else") && $0.lowercased() != "other" }.prefix(3), id: \.self) { option in
                        Button(option) { send(question, option) }.buttonStyle(.island(.quiet, compact: true))
                    }
                    Button("Something else…") {
                        answering = true
                        center.hold(item.id)
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.faint)
                }
                .padding(.top, 4)
            }
        case .message:
            EmptyView()
        }
    }

    private func send(_ question: BrainEvent.ChatQuestion, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.answer(question, text)
        center.dismiss(item.id)
    }

    private func dismiss() { center.userDismiss(item.id) }
}
