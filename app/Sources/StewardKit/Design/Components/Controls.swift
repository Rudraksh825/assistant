import SwiftUI

/// Small rounded label: project chips, due dates, states.
public struct Pill: View {
    public enum Style { case soft, outline }

    let text: String
    let icon: String?
    let color: Color
    let style: Style

    public init(_ text: String, icon: String? = nil, color: Color = Palette.textDim, style: Style = .soft) {
        self.text = text
        self.icon = icon
        self.color = color
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(Typo.caption).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style == .soft ? color.opacity(0.13) : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(style == .outline ? 0.4 : 0), lineWidth: 1))
    }
}

/// Keyboard shortcut hint: `KeyHint("⌘", "↩")`.
public struct KeyHint: View {
    let keys: [String]

    public init(_ keys: String...) { self.keys = keys }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textDim)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, key.count > 1 ? 3 : 0)
                    .background(Palette.hover, in: .continuous(4))
                    .overlay(RoundedRectangle.continuous(4).strokeBorder(Palette.stroke, lineWidth: 1))
            }
        }
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// Press-scale + haptic tick. `.buttonStyle(.pressable(.primary))`
public struct PressableButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, danger, bare }

    let kind: Kind
    let haptic: Bool

    public init(_ kind: Kind = .secondary, haptic: Bool = true) {
        self.kind = kind
        self.haptic = haptic
    }

    public func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, kind: kind, haptic: haptic)
    }

    private struct Label: View {
        let configuration: Configuration
        let kind: Kind
        let haptic: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(Typo.bodyStrong)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .bare ? 0 : 10)
                .padding(.vertical, kind == .bare ? 0 : 5)
                .background(background, in: .continuous(Radius.s + 1))
                .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(kind == .secondary ? Palette.stroke : .clear, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.955 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.snappy, value: configuration.isPressed)
                .animation(Motion.snappy, value: hovered)
                .onHover { hovered = $0 }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed && haptic { Haptics.tick() }
                }
                .contentShape(.rect)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Palette.onAccent
            case .danger: Palette.danger
            case .secondary, .ghost, .bare: Palette.text
            }
        }

        private var background: Color {
            let lift = configuration.isPressed ? 0.06 : (hovered ? 0.03 : 0)
            switch kind {
            case .primary: return Palette.accent.opacity(configuration.isPressed ? 0.82 : (hovered ? 0.93 : 1))
            case .danger: return Palette.danger.opacity(0.12 + lift * 2)
            case .secondary: return Color.white.opacity(0.05 + lift)
            case .ghost: return Color.white.opacity(lift * 2)
            case .bare: return .clear
            }
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    public static func pressable(_ kind: PressableButtonStyle.Kind = .secondary, haptic: Bool = true) -> PressableButtonStyle {
        PressableButtonStyle(kind, haptic: haptic)
    }
}

public struct EmptyState: View {
    let icon: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(icon: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.textFaint)
            Text(title).font(Typo.heading).foregroundStyle(Palette.textDim)
            if let message {
                Text(message).font(Typo.caption).foregroundStyle(Palette.textFaint).multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.pressable()).padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
