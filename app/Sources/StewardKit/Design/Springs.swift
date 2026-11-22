import SwiftUI
import QuartzCore

/// Spring parameters shared by SwiftUI and AppKit/Core Animation code.
public struct SpringSpec: Hashable, Sendable {
    /// Approximate period in seconds.
    public var response: Double
    /// 1 = critically damped, lower = bouncier.
    public var damping: Double
    /// Seconds the motion lags at the start before the spring takes over ("pushes against a detent").
    public var resistance: Double

    public init(response: Double, damping: Double, resistance: Double = 0) {
        self.response = response
        self.damping = damping
        self.resistance = resistance
    }

    /// Quick, no overshoot: hovers, toggles, list changes.
    public static let snappy = SpringSpec(response: 0.26, damping: 0.88)
    /// Stiff start, then release with a little overshoot: expanding and collapsing surfaces.
    public static let resist = SpringSpec(response: 0.40, damping: 0.74, resistance: 0.085)
    /// Slow, critically damped: things coming to rest, layout settling.
    public static let settle = SpringSpec(response: 0.55, damping: 1.0)
    /// Playful overshoot: confirmations, completion.
    public static let bounce = SpringSpec(response: 0.42, damping: 0.56)

    public var spring: SwiftUI.Spring { SwiftUI.Spring(response: response, dampingRatio: damping) }

    public var animation: Animation {
        resistance > 0 ? Animation(ResistAnimation(spec: self)) : .spring(response: response, dampingFraction: damping)
    }

    public var settlingDuration: TimeInterval { spring.settlingDuration + resistance }

    /// Progress 0→1 (may overshoot) at `time` seconds; drive AppKit frames from a display link with this.
    public func progress(at time: TimeInterval) -> Double {
        spring.value(target: 1.0, time: warp(time))
    }

    // Smooth time warp: velocity starts at zero and eases up to real time, ending `resistance` seconds behind.
    func warp(_ time: TimeInterval) -> TimeInterval {
        guard resistance > 0 else { return max(0, time) }
        return max(0, time - resistance * (1 - exp(-time / resistance)))
    }

    /// A Core Animation spring with the same response and damping. The resistance warp is not representable
    /// in `CASpringAnimation`; use `progress(at:)` when that part of the feel matters.
    public func caAnimation(keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.duration = a.settlingDuration
        return a
    }
}

struct ResistAnimation: CustomAnimation {
    let spec: SpringSpec

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < spec.settlingDuration else { return nil }
        return spec.spring.value(target: value, time: spec.warp(time))
    }
}

/// The named animations. `withAnimation(Motion.resist) { expanded.toggle() }`
public enum Motion {
    public static let snappy = SpringSpec.snappy.animation
    public static let resist = SpringSpec.resist.animation
    public static let settle = SpringSpec.settle.animation
    public static let bounce = SpringSpec.bounce.animation

    /// For staggered content: item `index` starts `step` seconds after the previous one.
    public static func stagger(_ index: Int, _ base: SpringSpec = .snappy, step: Double = 0.035) -> Animation {
        base.animation.delay(Double(index) * step)
    }
}
