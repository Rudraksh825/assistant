import AppKit
import SwiftUI
import StewardKit

/// Something in the expanded island the keyboard or pointer can be on.
enum NotchItem: Hashable {
    case approval(String), question(String), now, task(String), session(String), meeting, field
}

enum NotchMetrics {
    static let fullWidth: CGFloat = 660
    static let leftColumn: CGFloat = 344
    static let padding: CGFloat = 16
    /// Height below the notch line for the two small presentations.
    static let voiceBody = CGSize(width: 470, height: 50)
    static let noticeBody = CGSize(width: 300, height: 40)
    static let maxBodyHeight: CGFloat = 680
    /// Transparent room around the widest shape for its shadow.
    static let shadowMargin: CGFloat = 64
    static let toastZone: CGFloat = 430
    static var canvas: CGSize { CGSize(width: fullWidth + shadowMargin * 2, height: maxBodyHeight + toastZone) }
    static let maxSessionRows = 6
    static let sessionRowHeight: CGFloat = 34
}

/// Discrete state of one island: what it shows and what is selected. Per-frame motion lives in
/// `NotchDrive` and never passes through here.
@MainActor @Observable
final class NotchScene {
    enum Presentation: Equatable {
        case none, full, voice
        case notice(icon: String, text: String)
    }

    let layout: NotchLayout
    let displayID: CGDirectDisplayID

    var presentation = Presentation.none
    var isOpen = false
    /// Content stays mounted through the close so it can leave before the shell does.
    var mounted = false
    /// Flips shortly after the shell starts opening and immediately when it starts closing.
    var revealed = false
    var selection: NotchItem?
    var hovered: NotchItem?
    var swipe: (item: NotchItem, dx: CGFloat)?
    var field = ""
    var focusField = 0
    var fieldFocused = false
    /// Pointer is over something that scrolls vertically, so a vertical swipe belongs to it.
    var overScroller = false

    @ObservationIgnored var actions = AmbientActions()
    @ObservationIgnored var onContentHeight: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var close: () -> Void = {}
    /// Arrow/Tab out of the capture field.
    @ObservationIgnored var moveFromField: (AmbientTextInput.Key) -> Bool = { _ in false }
    @ObservationIgnored var submitField: (NSEvent.ModifierFlags) -> Void = { _ in }

    init(layout: NotchLayout, displayID: CGDirectDisplayID) {
        self.layout = layout
        self.displayID = displayID
    }

    func hover(_ item: NotchItem, _ inside: Bool) {
        if inside { hovered = item } else if hovered == item { hovered = nil }
    }

    func isActive(_ item: NotchItem) -> Bool { hovered == item || selection == item }

    func offset(for item: NotchItem) -> CGFloat { swipe?.item == item ? swipe?.dx ?? 0 : 0 }

    /// Everything the keyboard can reach, top to bottom.
    func items(in model: AmbientModel) -> [NotchItem] {
        var items: [NotchItem] = model.approvals.prefix(2).map { .approval($0.id) } + model.questions.prefix(1).map { .question($0.id) }
        if model.now != nil { items.append(.now) }
        items += model.next.map { .task($0.id) }
        items += model.sessions.map { .session($0.id) }
        if model.meeting != nil { items.append(.meeting) }
        items.append(.field)
        return items
    }
}

/// Root of the island's SwiftUI content. It fills the whole canvas; the canvas masks it to the shell.
struct NotchContent: View {
    let scene: NotchScene
    let ambient: AmbientState

    var body: some View {
        ZStack(alignment: .top) {
            NotchEars(layout: scene.layout, model: ambient.model, voice: ambient.voice)
                .opacity(scene.isOpen ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: scene.isOpen)
            if scene.mounted {
                switch scene.presentation {
                case .full: NotchExpanded(scene: scene, model: ambient.model)
                case .voice: NotchVoice(scene: scene, voice: ambient.voice)
                case .notice(let icon, let text): NotchNotice(scene: scene, icon: icon, text: text)
                case .none: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: scene.layout.centerX - scene.layout.panelFrame(canvas: NotchMetrics.canvas).midX)
        .preferredColorScheme(.dark)
    }
}

/// Collapsed: session dots hugging the notch on the left, the one most urgent live thing on the right.
struct NotchEars: View {
    let layout: NotchLayout
    let model: AmbientModel
    let voice: VoiceModel

    var body: some View {
        HStack(spacing: 0) {
            SessionDots(states: model.sessionStates)
                .padding(.trailing, NotchGeometry.dotsTrailing)
                .frame(width: 200, alignment: .trailing)
            // The camera housing: nothing drawn here is visible on a hardware notch. A virtual notch has no
            // camera, so the current task can live there. (Not a `Group`: a modifier on an empty group
            // applies to nothing, and without this width both ears slide under the housing.)
            Color.clear.frame(width: layout.notch.width, height: 1)
                .overlay {
                    if !layout.hasNotch, let task = model.now {
                        Text(task.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Island.dim).lineLimit(1).padding(.horizontal, 10)
                    }
                }
            indicator
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.leading, 9)
                .frame(width: 200, alignment: .leading)
        }
        .frame(height: layout.notch.height)
    }

    @ViewBuilder private var indicator: some View {
        switch model.indicator {
        case .none:
            EmptyView()
        case .voice:
            LevelBars(level: voice.level, height: 13)
        case .decisions(let count):
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold)).symbolEffect(.bounce, value: count)
                Text("\(count)").contentTransition(.numericText()).animation(Motion.snappy, value: count)
            }
            .foregroundStyle(Palette.danger)
        case .meeting(let start, let live):
            HStack(spacing: 4) {
                Image(systemName: live ? "video.fill" : "calendar").font(.system(size: 9, weight: .bold))
                if live { Text("now") } else { CountdownText(to: start) }
            }
            .foregroundStyle(live ? Palette.accent : Palette.info)
        case .agent:
            AgentShimmer()
        }
    }
}

/// Listening: level on the left, the words as they are heard, where they will go on the right.
struct NotchVoice: View {
    let scene: NotchScene
    let voice: VoiceModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: scene.layout.notch.height)
            HStack(spacing: 12) {
                LevelBars(level: voice.level, color: voice.problem == nil ? Palette.accent : Palette.warn, height: 18)
                Text(voice.problem ?? (voice.transcript.isEmpty ? "Listening…" : voice.transcript))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(voice.transcript.isEmpty || voice.problem != nil ? Island.dim : Island.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if voice.problem == nil {
                    let toAgent = VoiceRoute.route(voice.transcript).isAgent
                    Label(toAgent ? "Ask" : "Capture", systemImage: toAgent ? "sparkles" : "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(toAgent ? Palette.violet : Island.dim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((toAgent ? Palette.violet : .white).opacity(0.12), in: Capsule())
                        .animation(Motion.snappy, value: toAgent)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: NotchMetrics.voiceBody.height)
            .stagger(0, shown: scene.revealed)
        }
        .frame(width: NotchMetrics.voiceBody.width)
    }
}

/// A short confirmation ("Captured") that the island shows by itself.
struct NotchNotice: View {
    let scene: NotchScene
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: scene.layout.notch.height)
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ok)
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Island.text).lineLimit(1)
            }
            .frame(height: NotchMetrics.noticeBody.height)
            .stagger(0, shown: scene.revealed)
        }
        .frame(width: NotchMetrics.noticeBody.width)
    }
}
