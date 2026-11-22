import Foundation

/// A spring that can be retargeted mid-flight: position and velocity carry over, only the target (and
/// optionally the spec) change. Stepped analytically, so any frame interval is stable.
public struct SpringValue: Sendable {
    public private(set) var value: Double
    public private(set) var velocity: Double
    public private(set) var target: Double
    public private(set) var spec: SpringSpec
    /// Distance and speed under which the spring counts as at rest.
    public var epsilon: Double

    /// Seconds since this motion left rest. Drives the spec's resistance warp, which belongs to starts
    /// from rest only: a retarget mid-flight keeps the clock, so it never stalls a moving shape.
    private var elapsed: Double = 0

    public init(_ value: Double, spec: SpringSpec = .snappy, epsilon: Double = 0.001) {
        self.value = value
        self.target = value
        self.velocity = 0
        self.spec = spec
        self.epsilon = epsilon
    }

    public var isSettled: Bool { value == target && velocity == 0 }

    public mutating func retarget(_ newTarget: Double, spec newSpec: SpringSpec? = nil, velocity newVelocity: Double? = nil) {
        if isSettled { elapsed = 0 }
        if let newSpec { spec = newSpec }
        if let newVelocity { velocity = newVelocity }
        target = newTarget
    }

    /// Jumps to a value with no motion left: direct manipulation (a finger is driving).
    public mutating func set(_ newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    /// Adds velocity without moving the target: a physical nudge the spring then absorbs.
    public mutating func kick(_ impulse: Double) {
        if isSettled { elapsed = spec.resistance * 8 }
        velocity += impulse
    }

    public mutating func step(_ dt: Double) {
        guard !isSettled, dt > 0 else { return }
        let warped = spec.warp(elapsed + dt) - spec.warp(elapsed)
        elapsed += dt
        let t = spec.resistance > 0 ? warped : dt

        let omega = 2 * Double.pi / spec.response
        let zeta = min(spec.damping, 1)
        let x0 = value - target
        let v0 = velocity
        if zeta < 1 {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            let a = x0
            let b = (v0 + zeta * omega * x0) / omegaD
            let c = cos(omegaD * t), s = sin(omegaD * t)
            value = target + decay * (a * c + b * s)
            velocity = decay * ((b * omegaD - zeta * omega * a) * c - (a * omegaD + zeta * omega * b) * s)
        } else {
            let decay = exp(-omega * t)
            let k = v0 + omega * x0
            value = target + decay * (x0 + k * t)
            velocity = decay * (v0 - omega * k * t)
        }
        // Speed is compared per `response`, so a slow drift near the target still counts as moving.
        if abs(value - target) < epsilon && abs(velocity) * spec.response < epsilon * 4 {
            value = target
            velocity = 0
        }
    }
}
