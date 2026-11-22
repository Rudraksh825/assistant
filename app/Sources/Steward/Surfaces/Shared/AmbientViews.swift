import AppKit
import QuartzCore
import SwiftUI
import StewardKit

/// Colours for content sitting on the pure-black island and its toasts.
enum Island {
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.60)
    static let faint = Color.white.opacity(0.36)
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.09)
    /// Toast and card surface: a touch above black, so stacked pieces separate from the island.
    static let raised = Color(hex: 0x0B0B0D)
}

/// Session dots for the collapsed notch. Core Animation layers, because the pulse runs for as long as a
/// session waits: a render-server animation costs the app nothing, a SwiftUI one would tick every frame.
struct SessionDots: NSViewRepresentable {
    var states: [SessionState]
    var alignment: NSTextAlignment = .right

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ view: DotsView, context: Context) {
        view.alignment = alignment
        view.states = states
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsView, context: Context) -> CGSize? {
        let count = min(states.count, NotchGeometry.maxDots)
        let overflow = states.count > NotchGeometry.maxDots ? NotchGeometry.overflowWidth : 0
        let width = CGFloat(count) * NotchGeometry.dotSize + CGFloat(max(0, count - 1)) * NotchGeometry.dotGap + overflow
        return CGSize(width: width, height: 16)
    }

    final class DotsView: NSView {
        /// How long a waiting or blocked dot keeps pulsing after the dots last changed.
        static let pulseSeconds: Double = 90

        var alignment = NSTextAlignment.right
        var states: [SessionState] = [] {
            didSet { if states != oldValue { rebuild() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            rebuild()
        }

        private func rebuild() {
            guard let root = layer else { return }
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            let size = NotchGeometry.dotSize, gap = NotchGeometry.dotGap
            let shown = Array(states.prefix(NotchGeometry.maxDots))
            let extra = states.count - shown.count
            let width = CGFloat(shown.count) * size + CGFloat(max(0, shown.count - 1)) * gap + (extra > 0 ? NotchGeometry.overflowWidth : 0)
            var x = alignment == .right ? bounds.maxX - width : bounds.minX
            let y = bounds.midY - size / 2
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

            for state in shown {
                let color = NSColor(Palette.session(state)).cgColor
                let frame = CGRect(x: x, y: y, width: size, height: size)
                if (state == .waiting || state == .blocked) && !reduceMotion {
                    let halo = CALayer()
                    halo.frame = frame
                    halo.cornerRadius = size / 2
                    halo.backgroundColor = color
                    halo.opacity = 0
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = 1
                    grow.toValue = 2.6
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.55
                    fade.toValue = 0
                    let pulse = CAAnimationGroup()
                    pulse.animations = [grow, fade]
                    pulse.duration = state == .blocked ? 1.0 : 1.7
                    pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    // A session can wait for hours. The pulse announces the change, then the dot holds
                    // its colour: an endless animation would keep the compositor awake all day.
                    pulse.repeatCount = Float(Self.pulseSeconds / pulse.duration)
                    halo.add(pulse, forKey: "pulse")
                    root.addSublayer(halo)
                }
                let dot = CALayer()
                dot.frame = frame
                dot.cornerRadius = size / 2
                dot.backgroundColor = color
                root.addSublayer(dot)
                x += size + gap
            }
            if extra > 0 {
                let more = CATextLayer()
                more.string = "+\(extra)"
                more.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
                more.fontSize = 9
                more.foregroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
                more.contentsScale = window?.backingScaleFactor ?? 2
                more.frame = CGRect(x: x, y: bounds.midY - 6, width: NotchGeometry.overflowWidth, height: 12)
                root.addSublayer(more)
            }
        }
    }
}

/// "The agent is working": a soft band of light sweeping across a small capsule. Core Animation, for
/// the same reason as the session pulse.
struct AgentShimmer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }
    func updateNSView(_ view: ShimmerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerView, context: Context) -> CGSize? { CGSize(width: 22, height: 6) }

    final class ShimmerView: NSView {
        private let gradient = CAGradientLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let violet = NSColor(Palette.violet)
            gradient.colors = [violet.withAlphaComponent(0.28).cgColor, violet.cgColor, violet.withAlphaComponent(0.28).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [0, 0.5, 1]
            layer?.addSublayer(gradient)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            gradient.frame = bounds
            gradient.cornerRadius = bounds.height / 2
            guard gradient.animation(forKey: "sweep") == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.6, -0.3, 0]
            sweep.toValue = [1, 1.3, 1.6]
            sweep.duration = 1.5
            sweep.repeatCount = .infinity
            sweep.isRemovedOnCompletion = false
            gradient.add(sweep, forKey: "sweep")
        }
    }
}

/// Microphone level as five bars. Only on screen while listening, so the ~20 Hz updates are bounded.
struct LevelBars: View {
    var level: Float
    var color = Palette.accent
    var height: CGFloat = 14

    private static let shape: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: max(3, height * Self.shape[i] * CGFloat(min(1, max(0.12, level)))))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: level)
    }
}

/// "in 12m" until the last two minutes, then "1:32" on a 1 s tick. Nothing ticks faster than its text changes.
struct CountdownText: View {
    let to: Date

    var body: some View {
        // The schedule only says when to look again; the text is always measured from the real clock.
        TimelineView(.everyMinute) { _ in
            if to.timeIntervalSinceNow > 120 {
                Text(Fmt.span(to.timeIntervalSinceNow))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = Int(to.timeIntervalSinceNow.rounded(.up))
                    Text(left > 0 ? String(format: "%d:%02d", left / 60, left % 60) : "now")
                }
            }
        }
        .monospacedDigit()
    }
}

/// A running timer. `seconds` ticks every second ("24:10"); without it the text changes once a minute ("24m").
struct ElapsedText: View {
    let since: Date
    var seconds = false

    var body: some View {
        if seconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(since)))
                Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
            }
            .monospacedDigit()
        } else {
            TimelineView(.everyMinute) { context in
                Text(Fmt.span(max(60, context.date.timeIntervalSince(since))))
            }
            .monospacedDigit()
        }
    }
}

/// Buttons on black. Press scale and haptic come from the pressed state, so they work in a panel that is not key.
struct IslandButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, danger }
    var kind = Kind.quiet
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tick() }
            }
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.onAccent
        case .quiet: Island.text
        case .danger: Palette.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.accent
        case .quiet: Island.fillStrong
        case .danger: Palette.danger.opacity(0.16)
        }
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    static func island(_ kind: IslandButtonStyle.Kind = .quiet, compact: Bool = false) -> IslandButtonStyle {
        IslandButtonStyle(kind: kind, compact: compact)
    }
}

/// Round icon button for row actions and close buttons.
struct IslandIconButton: View {
    let icon: String
    var tint = Island.dim
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Island.fillStrong, in: Circle())
                // A 22 pt circle is a small target on a trackpad; the hit area reaches a little past it.
                .padding(4).contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .padding(-4)
    }

    private struct PressScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(Motion.snappy, value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { Haptics.tick() }
                }
        }
    }
}

/// Content arrives with its container: each item fades and settles in quick succession, and leaves at once.
struct Stagger: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .animation(shown ? Motion.stagger(index, .snappy, step: AmbientFeel.staggerStep) : .easeOut(duration: AmbientFeel.contentExit), value: shown)
    }
}

extension View {
    func stagger(_ index: Int, shown: Bool) -> some View { modifier(Stagger(index: index, shown: shown)) }
}

/// Small caps label used above sections on the island.
struct IslandLabel: View {
    let text: String
    var count: Int?

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text.uppercased()).font(Typo.label).kerning(0.7).foregroundStyle(Island.faint)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
            }
        }
    }
}

func nudgeIcon(_ kind: NudgeKind) -> String {
    switch kind {
    case .session: "terminal.fill"
    case .meeting: "calendar"
    case .task: "checklist"
    case .brief: "text.alignleft"
    case .approval: "hand.raised.fill"
    case .question: "questionmark.bubble.fill"
    case .insight: "lightbulb.fill"
    case .budget: "dollarsign.circle.fill"
    case .system, .unknown: "bell.fill"
    }
}
