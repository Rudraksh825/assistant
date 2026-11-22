import AppKit
import SwiftUI

/// State dot; pulses a halo while the session needs the user (`waiting`, `blocked`).
public struct StateDot: View {
    let state: SessionState
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ state: SessionState, size: CGFloat = 7) {
        self.state = state
        self.size = size
    }

    private var attention: Bool { state == .waiting || state == .blocked }

    public var body: some View {
        let color = Palette.session(state)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if attention && !reduceMotion && !DesignSettings.shared.reduceMotion {
                    PulseHalo(color: color.opacity(0.45), period: state == .blocked ? 0.9 : 1.5)
                }
            }
            .accessibilityLabel(state.rawValue)
    }
}

/// The halo pulses as a Core Animation layer animation, which runs in the render server. A SwiftUI
/// `repeatForever` re-lays out the whole hosting window every frame (~28% CPU at idle with two dots up).
private struct PulseHalo: NSViewRepresentable {
    let color: Color
    let period: Double

    func makeNSView(context: Context) -> HaloView { HaloView() }

    func updateNSView(_ view: HaloView, context: Context) {
        view.pulse(color: NSColor(color), period: period)
    }

    final class HaloView: NSView {
        private let halo = CALayer()
        private var period = 0.0

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            halo.opacity = 0
            layer?.addSublayer(halo)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            halo.frame = bounds
            halo.cornerRadius = bounds.width / 2
        }

        private var color = NSColor.clear

        override func viewDidChangeEffectiveAppearance() {
            effectiveAppearance.performAsCurrentDrawingAppearance { halo.backgroundColor = color.cgColor }
        }

        func pulse(color: NSColor, period: Double) {
            self.color = color
            viewDidChangeEffectiveAppearance()
            guard period != self.period else { return }
            self.period = period
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = period
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            halo.add(group, forKey: "pulse")
        }
    }
}

/// Compact capsule for strips: dot, name, time in state.
public struct SessionChip: View {
    let session: CodeSession
    let onTap: (() -> Void)?
    @State private var hovered = false

    public init(session: CodeSession, onTap: (() -> Void)? = nil) {
        self.session = session
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 6) {
            StateDot(session.state)
            Text(session.displayName).font(Typo.caption).foregroundStyle(Palette.text).lineLimit(1)
            if session.needsAttention {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Fmt.since(session.stateSince, now: context.date)).font(Typo.numeric).foregroundStyle(Palette.session(session.state))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovered ? Palette.pressed : Palette.hover, in: Capsule())
        .overlay(Capsule().strokeBorder(session.needsAttention ? Palette.session(session.state).opacity(0.35) : Palette.stroke, lineWidth: 1))
        .onHover { hovered = $0 }
        .onTapGesture { onTap?() }
        .help(session.title ?? session.cwd)
    }
}

/// Full-width session line with what it is doing, branch, PR and a focus action.
public struct SessionRow: View {
    let session: CodeSession
    let onFocus: (() -> Void)?
    @State private var hovered = false

    public init(session: CodeSession, onFocus: (() -> Void)? = nil) {
        self.session = session
        self.onFocus = onFocus
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.s + 2) {
            StateDot(session.state, size: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text(session.displayName).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                    Text(stateText).font(Typo.caption).foregroundStyle(Palette.session(session.state))
                }
                if let line = session.title ?? session.lastAssistantText ?? session.lastUserPrompt {
                    Text(line).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2)
                }
                HStack(spacing: Space.xs) {
                    if let branch = session.branch { Pill(branch, icon: "arrow.triangle.branch") }
                    if let ticket = session.ticket { Pill(ticket, icon: "ticket", color: Palette.info) }
                    if let pr = session.pr { Pill("#\(pr.number) \(pr.state.lowercased())", icon: "arrow.triangle.pull", color: Palette.violet) }
                }
            }
            Spacer(minLength: Space.s)
            if let onFocus, hovered || session.needsAttention {
                Button("Focus", systemImage: "macwindow", action: onFocus).buttonStyle(.pressable(.ghost)).labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, 7)
        .background(hovered ? Palette.hover : .clear, in: .continuous(Radius.s + 2))
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }

    private var stateText: String {
        let since = Fmt.since(session.stateSince)
        return switch session.state {
        case .working: "working \(since)"
        case .waiting: "waiting for you \(since)"
        case .blocked: "needs an answer \(since)"
        case .idle: "idle \(since)"
        case .ended: "ended"
        case .unknown: ""
        }
    }
}
