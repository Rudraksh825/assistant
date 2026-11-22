import CoreGraphics
import Foundation

/// The parts of an `NSScreen` the notch needs, as plain values so layout is testable.
public struct ScreenMetrics: Hashable, Sendable {
    /// Global coordinates, origin bottom-left (AppKit).
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the height of the camera housing, 0 without one.
    public var safeTop: CGFloat
    /// Widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; nil without a notch.
    public var auxLeftWidth: CGFloat?
    public var auxRightWidth: CGFloat?

    public init(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat = 0, auxLeftWidth: CGFloat? = nil, auxRightWidth: CGFloat? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = safeTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
    }

    /// The hardware cutout in global coordinates, or nil.
    public var notchRect: CGRect? {
        guard safeTop > 0, let left = auxLeftWidth, let right = auxRightWidth else { return nil }
        let width = frame.width - left - right
        guard width > 0 else { return nil }
        return CGRect(x: frame.minX + left, y: frame.maxY - safeTop, width: width, height: safeTop)
    }

    /// Height the menu bar currently takes on this screen; 0 when it is hidden (full-screen space, auto-hide).
    public var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

/// Where the island sits on one screen: over the hardware notch, or a virtual one of the same family.
public struct NotchLayout: Hashable, Sendable {
    public var hasNotch: Bool
    /// Size of the resting shape.
    public var notch: CGSize
    /// Global x of the notch centre and global y of the screen's top edge.
    public var centerX: CGFloat
    public var top: CGFloat
    /// A virtual notch with no menu bar to hang from would sit on top of app content; it tucks away.
    public var tucked: Bool

    /// - Parameters:
    ///   - reference: the hardware notch size of another screen, so virtual notches keep its proportions.
    ///   - statusBarThickness: used when the menu bar height cannot be read off the screen.
    public init(screen: ScreenMetrics, reference: CGSize? = nil, statusBarThickness: CGFloat) {
        top = screen.frame.maxY
        if let rect = screen.notchRect {
            hasNotch = true
            notch = rect.size
            centerX = rect.midX
            tucked = false
        } else {
            hasNotch = false
            let bar = screen.menuBarHeight
            let height = bar > 0 ? bar : statusBarThickness
            let aspect = reference.map { $0.width / $0.height } ?? 5.8
            notch = CGSize(width: (height * aspect).rounded(), height: height)
            centerX = screen.frame.midX
            tucked = bar == 0
        }
    }

    /// The fixed transparent canvas: pinned top-centre, never resized while animating.
    public func panelFrame(canvas: CGSize) -> CGRect {
        CGRect(x: (centerX - canvas.width / 2).rounded(), y: top - canvas.height, width: canvas.width, height: canvas.height)
    }

    /// A shell size as a global rect (shell is centred on the notch and flush with the top edge).
    public func globalRect(of size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

/// The animated scalars. Everything visible about the shell is a pure function of these.
public struct NotchPose: Hashable, Sendable {
    /// 0 collapsed … 1 expanded; overshoots slightly past 1 on open.
    public var open: CGFloat
    /// 0 … 1 hover swell.
    public var swell: CGFloat
    /// Rubber-banded pull distance in points.
    public var pull: CGFloat
    public var earLeft: CGFloat
    public var earRight: CGFloat
    /// Expanded size the shell opens to.
    public var body: CGSize

    public init(open: CGFloat = 0, swell: CGFloat = 0, pull: CGFloat = 0, earLeft: CGFloat = 0, earRight: CGFloat = 0, body: CGSize = .zero) {
        self.open = open
        self.swell = swell
        self.pull = pull
        self.earLeft = earLeft
        self.earRight = earRight
        self.body = body
    }

    public var isResting: Bool { open == 0 && swell == 0 && pull == 0 }
}

public struct NotchShell: Hashable, Sendable {
    public var size: CGSize
    /// How far the shape's centre sits right of the notch centre (ears of different widths).
    public var centerOffset: CGFloat
    /// Concave fillets where the shape meets the screen edge.
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    public var shadowRadius: CGFloat
    public var shadowY: CGFloat
    public var shadowOpacity: Double
}

public enum NotchGeometry {
    /// Width runs ahead of `open`, height behind it; equal at 0 and 1, smooth through overshoot.
    public static func widthProgress(_ open: CGFloat) -> CGFloat { open + AmbientFeel.widthLead * open * (1 - open) }
    public static func heightProgress(_ open: CGFloat) -> CGFloat { open - AmbientFeel.widthLead * open * (1 - open) }

    public static func shell(notch: CGSize, pose: NotchPose) -> NotchShell {
        let wp = widthProgress(pose.open), hp = heightProgress(pose.open)
        let restWidth = notch.width + pose.earLeft + pose.earRight + pose.swell * AmbientFeel.swellSize.width
        let restHeight = notch.height + pose.swell * AmbientFeel.swellSize.height
        let width = max(notch.width, restWidth + (pose.body.width - restWidth) * wp + pose.pull * 0.35)
        let height = max(notch.height, restHeight + (pose.body.height - restHeight) * hp + pose.pull)

        let wc = min(max(wp, 0), 1), hc = min(max(hp, 0), 1)
        let top = AmbientFeel.topRadiusRest + (AmbientFeel.topRadiusOpen - AmbientFeel.topRadiusRest) * wc + pose.swell
        let bottomFree = AmbientFeel.bottomRadiusRest + (AmbientFeel.bottomRadiusOpen - AmbientFeel.bottomRadiusRest) * hc
            + pose.swell * 2 + pose.pull * 0.14
        let bottom = min(bottomFree, height / 2, width / 2)

        // The shadow would give a resting notch away, so it only exists once the shape leaves the bezel.
        let lift = min(1, max(0, max(pose.open, pose.swell * 0.22) + pose.pull / 140))
        return NotchShell(
            size: CGSize(width: width, height: height),
            centerOffset: (pose.earRight - pose.earLeft) / 2 * (1 - wc),
            topRadius: top, bottomRadius: bottom,
            shadowRadius: AmbientFeel.shadowRadiusOpen * lift,
            shadowY: AmbientFeel.shadowYOpen * lift,
            shadowOpacity: AmbientFeel.shadowOpacityOpen * Double(lift))
    }

    /// The island outline in a top-left-origin space: flush with y = 0, concave fillets flaring out to the
    /// screen edge, convex bottom corners. Corners are single cubics with long shoulders (continuous
    /// curvature to the eye), never circular arcs. `rect` is the body; the fillets extend `topRadius` beyond it.
    public static func path(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let rb = min(bottomRadius, rect.height / 2, rect.width / 2)
        let rt = min(topRadius, max(0, rect.height - rb))
        // A corner of radius r occupies `shoulder·r` of each edge; handles sit 30 % of the way out from the corner.
        let shoulder: CGFloat = 1.28, handle: CGFloat = 0.30
        let eb = min(rb * shoulder, rect.height / 2, rect.width / 2)
        let et = min(rt * shoulder, max(0, rect.height - eb))

        func corner(_ c: CGPoint, from a: CGPoint, to b: CGPoint) {
            path.addLine(to: a)
            path.addCurve(to: b,
                          control1: CGPoint(x: c.x + (a.x - c.x) * handle, y: c.y + (a.y - c.y) * handle),
                          control2: CGPoint(x: c.x + (b.x - c.x) * handle, y: c.y + (b.y - c.y) * handle))
        }

        path.move(to: CGPoint(x: rect.minX - et, y: rect.minY))
        corner(CGPoint(x: rect.minX, y: rect.minY), from: CGPoint(x: rect.minX - et, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.minY + et))
        corner(CGPoint(x: rect.minX, y: rect.maxY), from: CGPoint(x: rect.minX, y: rect.maxY - eb), to: CGPoint(x: rect.minX + eb, y: rect.maxY))
        corner(CGPoint(x: rect.maxX, y: rect.maxY), from: CGPoint(x: rect.maxX - eb, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY - eb))
        corner(CGPoint(x: rect.maxX, y: rect.minY), from: CGPoint(x: rect.maxX, y: rect.minY + et), to: CGPoint(x: rect.maxX + et, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// Width of the left ear for a number of session dots (0 = no ear).
    public static func dotsEarWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let shown = min(count, maxDots)
        return dotsLeading + CGFloat(shown) * dotSize + CGFloat(shown - 1) * dotGap + (count > maxDots ? overflowWidth : 0) + dotsTrailing
    }

    public static let maxDots = 6
    public static let dotSize: CGFloat = 6
    public static let dotGap: CGFloat = 5
    public static let dotsLeading: CGFloat = 12
    public static let dotsTrailing: CGFloat = 8
    public static let overflowWidth: CGFloat = 20
}

/// What the right ear shows: the single most urgent live thing.
public enum NotchIndicator: Hashable, Sendable {
    case none
    case voice
    /// Approvals and agent questions waiting on the user.
    case decisions(Int)
    /// A meeting that is live, or starts within the lead window.
    case meeting(start: Date, live: Bool)
    case agent

    /// Meetings closer than this earn the ear.
    public static let meetingLead: TimeInterval = 15 * 60

    public static func pick(listening: Bool, decisions: Int, meetingStart: Date?, meetingLive: Bool, agentBusy: Bool, now: Date = Date()) -> NotchIndicator {
        if listening { return .voice }
        if decisions > 0 { return .decisions(decisions) }
        if let start = meetingStart, meetingLive || (start > now && start.timeIntervalSince(now) <= meetingLead) {
            return .meeting(start: start, live: meetingLive)
        }
        return agentBusy ? .agent : .none
    }

    public var earWidth: CGFloat {
        switch self {
        case .none: 0
        case .voice: 46
        case .decisions: 40
        case .meeting: 58
        case .agent: 40
        }
    }
}
