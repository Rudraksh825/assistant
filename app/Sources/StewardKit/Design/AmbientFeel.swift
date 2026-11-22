import CoreGraphics
import Foundation

/// Every tunable behind how the notch island, toasts and HUD feel. The island opens the instant the
/// pointer touches it: no dwell, no resistance, nothing the user has to wait out.
public enum AmbientFeel {
    // MARK: Springs

    /// Collapsed → expanded: fast, one barely-there overshoot.
    public static let open = SpringSpec(response: 0.26, damping: 0.84)
    /// Expanded → collapsed: faster still and critically damped. Closing must never bounce.
    public static let close = SpringSpec(response: 0.22, damping: 1.0)
    /// Pointer arrives: the small "it noticed me" swell.
    public static let swell = SpringSpec(response: 0.24, damping: 0.66)
    /// Pointer leaves: relax without wobble.
    public static let relax = SpringSpec(response: 0.34, damping: 0.88)
    /// Ears growing/shrinking and the expanded body following its content.
    public static let track = SpringSpec(response: 0.30, damping: 0.82)
    /// A pull that did not commit snaps back with a little life.
    public static let snapBack = SpringSpec(response: 0.32, damping: 0.64)
    /// Releasing the pull after a commit: quick, so the open spring owns the motion.
    public static let pullRelease = SpringSpec(response: 0.22, damping: 0.90)

    // MARK: Hover and dwell

    /// How much the collapsed shape grows under the pointer.
    public static let swellSize = CGSize(width: 26, height: 6)
    /// Extra points around the collapsed shape that count as "on it".
    public static let hotSlop: CGFloat = 3
    /// The open panel closes the moment the pointer is this far outside its edge.
    public static let closeMargin: CGFloat = 10
    /// Two haptics closer than this collapse into one, so a jittery hover cannot buzz.
    public static let hapticDebounce: TimeInterval = 0.08

    // MARK: Pull to open

    /// Finger travel (before the rubber band) at which the pull lets go and the panel opens.
    public static let pullCommit: CGFloat = 34
    /// A downward flick faster than this (pt/s) commits regardless of distance.
    public static let pullFlick: CGFloat = 650
    /// Rubber band asymptote: the shape never stretches further than this.
    public static let pullLimit: CGFloat = 96
    public static let rubberCoefficient: CGFloat = 0.55
    /// Movement under this is still a click, not a drag.
    public static let dragSlop: CGFloat = 3

    // MARK: Shape

    public static let topRadiusRest: CGFloat = 6
    public static let topRadiusOpen: CGFloat = 12
    public static let bottomRadiusRest: CGFloat = 10
    public static let bottomRadiusOpen: CGFloat = 30
    /// How far width runs ahead of height while opening (and height ahead of width while closing). 0 = locked.
    public static let widthLead: CGFloat = 0.22
    public static let shadowRadiusOpen: CGFloat = 28
    public static let shadowYOpen: CGFloat = 14
    public static let shadowOpacityOpen: Double = 0.45

    // MARK: Content choreography

    /// Sections follow each other this closely as the shell opens over them.
    public static let staggerStep: TimeInterval = 0.012
    /// Content leaves this fast on close.
    public static let contentExit: TimeInterval = 0.07

    // MARK: Rows and toasts

    /// Horizontal travel at which a task-row or toast swipe commits.
    public static let swipeCommit: CGFloat = 64
    public static let swipeLimit: CGFloat = 120

    // MARK: HUD

    /// Gap kept between a snapped HUD and the screen edge.
    public static let hudInset: CGFloat = 12
    /// Distance from the snapped position at which the edge grabs the HUD…
    public static let hudCapture: CGFloat = 16
    /// …and how far it must be dragged to let go again.
    public static let hudRelease: CGFloat = 30
    public static let hudIdleOpacity: Double = 0.58
}

/// Finger distance → on-screen distance with increasing resistance: `f(x) = (1 − 1/(x·c/d + 1))·d`.
/// Starts with slope `c` and approaches `dimension` asymptotically. Odd-symmetric for negative input.
public enum RubberBand {
    public static func offset(_ distance: CGFloat, dimension: CGFloat, coefficient: CGFloat = AmbientFeel.rubberCoefficient) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let x = abs(distance)
        let y = (1 - 1 / (x * coefficient / dimension + 1)) * dimension
        return distance < 0 ? -y : y
    }
}
