import SwiftUI
import StewardKit

enum HUDMetrics {
    static let pill = CGSize(width: 300, height: 40)
    static let cardWidth: CGFloat = 336
    static let maxCardHeight: CGFloat = 460
    /// Transparent room around the HUD for its shadow.
    static let margin: CGFloat = 28
    static var canvas: CGSize { CGSize(width: cardWidth + margin * 2, height: maxCardHeight + margin * 2) }
}

@MainActor @Observable
final class HUDScene {
    enum Saving { case idle, pending, saved }

    var card = false
    var hovered = false
    var note = ""
    /// Set when the card shows a note other than the live one (`ui.command show_note`).
    var noteTitle: String?
    var saving = Saving.idle
    var noteFocused = false
    var focus = 0

    @ObservationIgnored var actions = AmbientActions()
    @ObservationIgnored var toggleSize: () -> Void = {}
    @ObservationIgnored var dragChanged: () -> Void = {}
    @ObservationIgnored var dragEnded: () -> Void = {}
    @ObservationIgnored var noteEdited: () -> Void = {}
    @ObservationIgnored var backToLiveNote: () -> Void = {}
    @ObservationIgnored var onSize: (CGSize) -> Void = { _ in }
}

/// The floating HUD. A pill (task, timer, session dots) that opens downward into a card (task actions,
/// live-note scratchpad, sessions, next meeting). Airy until the pointer arrives, then solid.
struct HUDView: View {
    @Bindable var scene: HUDScene
    let model: AmbientModel

    var body: some View {
        let solid = scene.hovered || scene.noteFocused
        VStack(alignment: .leading, spacing: 0) {
            header
            if scene.card {
                card.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: scene.card ? HUDMetrics.cardWidth : HUDMetrics.pill.width)
        .ambientPanel(radius: scene.card ? 22 : HUDMetrics.pill.height / 2, elevation: scene.card ? 3.2 : (solid ? 2.4 : 1.4), solidity: solid ? 0.95 : 0.4)
        .opacity(solid ? 1 : AmbientFeel.hudIdleOpacity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.onSize($0) }
        .animation(Motion.resist, value: scene.card)
        .animation(Motion.snappy, value: solid)
        .padding(.top, HUDMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    /// The pill, and the card's title row. Dragging it moves the HUD; a double click changes size.
    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(model.now == nil ? Palette.textFaint : Palette.accent).frame(width: 7, height: 7)
            if let task = model.now {
                Text(task.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 4)
                ElapsedText(since: model.nowSince ?? task.updatedAt)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent)
            } else {
                Text("Nothing in progress").font(.system(size: 12.5)).foregroundStyle(Palette.textDim).lineLimit(1)
                Spacer(minLength: 4)
            }
            if !model.sessionStates.isEmpty {
                SessionDots(states: Array(model.sessionStates.prefix(4)), alignment: .left)
            }
            Button { scene.toggleSize() } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textDim)
                    .rotationEffect(.degrees(scene.card ? 180 : 0))
                    .frame(width: 20, height: 20).background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(scene.card ? "Collapse" : "Expand")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: HUDMetrics.pill.height)
        .contentShape(.rect)
        .onTapGesture(count: 2) { scene.toggleSize() }
        // The gesture only says "the mouse moved while down"; the surface reads the real screen position,
        // because a translation measured inside a window that is itself moving feeds back on itself.
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in scene.dragChanged() }
            .onEnded { _ in scene.dragEnded() })
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let task = model.now {
                HStack(spacing: 7) {
                    Button { scene.actions.complete(task) } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(.island(.primary, compact: true))
                    if let next = model.next.first {
                        Button { scene.actions.start(next) } label: {
                            Label(next.title, systemImage: "forward.end.fill").lineLimit(1)
                        }
                        .buttonStyle(.island(.quiet, compact: true))
                        .help("Switch to: \(next.title)")
                    }
                    Spacer(minLength: 0)
                }
            } else if let next = model.next.first {
                Button { scene.actions.start(next) } label: { Label("Start: \(next.title)", systemImage: "play.fill").lineLimit(1) }
                    .buttonStyle(.island(.quiet, compact: true))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    IslandLabel(scene.noteTitle ?? "Live note")
                    if scene.noteTitle != nil {
                        Button("Back to live note") { scene.backToLiveNote() }
                            .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.accent)
                    }
                    Spacer()
                    Text(scene.saving == .pending ? "Saving…" : scene.saving == .saved ? "Saved" : "")
                        .font(.system(size: 10)).foregroundStyle(Palette.textFaint)
                        .animation(Motion.snappy, value: scene.saving)
                }
                AmbientTextInput(text: $scene.note, placeholder: "Jot while you work. Saved as you type.", font: .systemFont(ofSize: 12.5),
                                 color: NSColor(Palette.text), maxLines: 9, focus: scene.focus,
                                 onSubmit: { _ in }, onFocus: { scene.noteFocused = $0 })
                    .frame(minHeight: 64, alignment: .top)
                    .padding(10)
                    .background(Color.black.opacity(0.28), in: .continuous(12))
                    .overlay(RoundedRectangle.continuous(12).strokeBorder(scene.noteFocused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
                    .onChange(of: scene.note) { scene.noteEdited() }
            }

            if !model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    IslandLabel("Sessions", count: model.sessions.filter(\.needsAttention).count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.sessions) { session in
                                Button { scene.actions.focus(session) } label: {
                                    HStack(spacing: 6) {
                                        SessionDots(states: [session.state], alignment: .left).frame(width: 7)
                                        Text(session.ticket ?? session.displayName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.text)
                                        if session.needsAttention {
                                            TimelineView(.everyMinute) { context in
                                                Text(Fmt.since(session.stateSince, now: context.date))
                                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Palette.session(session.state))
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.white.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(session.title ?? session.cwd)
                            }
                        }
                    }
                }
            }

            if let meeting = model.meeting {
                HStack(spacing: 9) {
                    RoundedRectangle.continuous(2).fill(model.meetingLive ? Palette.accent : Palette.info).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                        HStack(spacing: 3) {
                            if model.meetingLive {
                                Text("now, until \(Fmt.time(meeting.endAt))")
                            } else {
                                Text("\(Fmt.time(meeting.startAt)) · in")
                                CountdownText(to: meeting.startAt)
                            }
                        }
                        .font(.system(size: 10.5)).foregroundStyle(Palette.textDim)
                    }
                    Spacer(minLength: 4)
                    if meeting.joinUrl != nil {
                        Button("Join") { scene.actions.join(meeting) }.buttonStyle(.island(model.meetingLive ? .primary : .quiet, compact: true))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}
