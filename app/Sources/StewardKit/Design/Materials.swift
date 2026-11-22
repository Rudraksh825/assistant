import SwiftUI
import QuartzCore

public enum MaterialStyle: String, CaseIterable, Sendable {
    /// macOS 26 Liquid Glass.
    case glass
    /// Opaque raised fill with a hairline; also used when Reduce Transparency is on.
    case solid
}

@MainActor @Observable
public final class DesignSettings {
    public static let shared = DesignSettings()
    public var materialStyle: MaterialStyle = .glass
    /// Stops looping animations (the pulse on a waiting session) on top of the system's Reduce Motion.
    public var reduceMotion = false
}

/// Shadow that scales with how far a surface floats above what is under it (0 = flat, 4 = floating panel).
public struct Elevation: Hashable, Sendable {
    public var level: CGFloat

    public init(_ level: CGFloat) { self.level = max(0, level) }

    public var keyOpacity: Double { min(0.5, 0.16 + 0.05 * level) }
    public var keyRadius: CGFloat { 3 + 5 * level }
    public var keyOffset: CGFloat { 1 + 2.5 * level }
    public var contactOpacity: Double { level > 0 ? 0.22 : 0 }
    public var contactRadius: CGFloat { 0.5 + 0.5 * level }

    /// Same key shadow on a layer, for AppKit windows and views.
    public func apply(to layer: CALayer) {
        layer.shadowColor = .black
        layer.shadowOpacity = Float(keyOpacity)
        layer.shadowRadius = keyRadius
        layer.shadowOffset = CGSize(width: 0, height: -keyOffset)
    }
}

extension View {
    /// Two-layer shadow for an elevation level; animatable by animating `level`.
    public func elevation(_ level: CGFloat) -> some View {
        let e = Elevation(level)
        return shadow(color: .black.opacity(e.contactOpacity), radius: e.contactRadius, y: 0.5)
            .shadow(color: .black.opacity(level > 0 ? e.keyOpacity : 0), radius: e.keyRadius, y: e.keyOffset)
    }

    /// Floating-panel background: glass or solid per `DesignSettings`, clipped to a continuous shape.
    public func panelSurface(radius: CGFloat = Radius.l, elevation: CGFloat = 2, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(PanelSurface(radius: radius, level: elevation, tint: tint, interactive: interactive))
    }

    /// In-window card: quiet raised fill, hairline, optional hover highlight. Never glass.
    public func cardSurface(radius: CGFloat = Radius.m, hovered: Bool = false) -> some View {
        background(hovered ? Palette.hover : Palette.bgRaised, in: .continuous(radius))
            .overlay(RoundedRectangle.continuous(radius).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

struct PanelSurface: ViewModifier {
    let radius: CGFloat
    let level: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(radius)
        Group {
            if DesignSettings.shared.materialStyle == .glass && !reduceTransparency {
                content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                content
                    .background((tint ?? Palette.bgRaised).opacity(tint == nil ? 1 : 0.25), in: shape)
                    .background(Palette.bgRaised, in: shape)
                    .overlay(shape.strokeBorder(Palette.strokeStrong, lineWidth: 1))
            }
        }
        .elevation(level)
    }
}
