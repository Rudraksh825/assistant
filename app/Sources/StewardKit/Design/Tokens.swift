import SwiftUI

// shortcut: dark-only values (the app pins a dark appearance); add light variants here when light mode matters.
public enum Palette {
    public static let bg = Color(hex: 0x0E0F13)
    public static let bgRaised = Color(hex: 0x17191F)
    public static let bgSunken = Color(hex: 0x0A0B0E)
    public static let hover = Color.white.opacity(0.055)
    public static let pressed = Color.white.opacity(0.09)
    public static let stroke = Color.white.opacity(0.08)
    public static let strokeStrong = Color.white.opacity(0.16)

    public static let text = Color(hex: 0xECEDF0)
    public static let textDim = Color(hex: 0xECEDF0).opacity(0.62)
    public static let textFaint = Color(hex: 0xECEDF0).opacity(0.38)

    /// Ember: the one warm accent. Used for "now", primary actions and focus.
    public static let accent = Color(hex: 0xF2A65A)
    public static let onAccent = Color(hex: 0x1A1206)
    /// Tide: calm secondary, used for healthy/working state.
    public static let ok = Color(hex: 0x5CC8B8)
    public static let warn = Color(hex: 0xF2C94C)
    public static let danger = Color(hex: 0xF0616D)
    public static let info = Color(hex: 0x7AA2F7)
    public static let violet = Color(hex: 0xB39DF5)

    public static func priority(_ priority: Int) -> Color {
        switch priority {
        case 3: danger
        case 2: accent
        case 1: info
        default: textFaint
        }
    }

    public static func session(_ state: SessionState) -> Color {
        switch state {
        case .working: ok
        case .waiting: accent
        case .blocked: danger
        case .idle, .ended, .unknown: textFaint
        }
    }

    public static func nudge(_ kind: NudgeKind) -> Color {
        switch kind {
        case .approval, .budget: danger
        case .session, .question: accent
        case .meeting: info
        case .brief, .insight: violet
        case .task, .system, .unknown: textDim
        }
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// "#RRGGBB" or "RRGGBB" (project colours); nil when unparseable.
    public init?(hexString: String?) {
        guard let s = hexString?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

public enum Typo {
    public static let display = Font.system(size: 26, weight: .semibold, design: .rounded)
    public static let title = Font.system(size: 19, weight: .semibold)
    public static let heading = Font.system(size: 14, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let bodyStrong = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 11.5)
    /// Section labels: small caps feel without the shouting.
    public static let label = Font.system(size: 10.5, weight: .semibold).width(.expanded)
    public static let mono = Font.system(size: 11.5, design: .monospaced)
    public static let numeric = Font.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()
}

public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 36
}

public enum Radius {
    public static let s: CGFloat = 6
    public static let m: CGFloat = 10
    public static let l: CGFloat = 14
    public static let xl: CGFloat = 22
}

extension Shape where Self == RoundedRectangle {
    /// Continuous-corner (squircle) rectangle; the default shape for everything.
    public static func continuous(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension Shape where Self == UnevenRoundedRectangle {
    /// Different top/bottom radii with continuous corners; animatable, for shapes that grow out of an edge.
    public static func continuous(top: CGFloat, bottom: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }
}

/// Section label used above lists ("NOW", "NEXT UP").
public struct SectionLabel: View {
    let text: String
    let count: Int?

    public init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Text(text.uppercased()).font(Typo.label).kerning(0.6).foregroundStyle(Palette.textFaint)
            if let count, count > 0 { Text("\(count)").font(Typo.numeric).foregroundStyle(Palette.textFaint) }
        }
    }
}
