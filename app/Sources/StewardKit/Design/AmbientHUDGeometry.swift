import CoreGraphics
import Foundation

/// Edge magnetism and position memory for the floating HUD.
public enum HUDGeometry {
    public struct Snap: Equatable, Sendable {
        public var origin: CGPoint
        public var x: Bool
        public var y: Bool
    }

    /// Pulls a dragged frame onto the nearest edge (inset) or the horizontal centre of `visible`.
    /// `was` is the previous result: a snapped axis holds on until dragged `release` away (hysteresis),
    /// which is what makes the edge feel like a detent rather than a line.
    public static func snap(_ frame: CGRect, in visible: CGRect, was: (x: Bool, y: Bool) = (false, false),
                            inset: CGFloat = AmbientFeel.hudInset, capture: CGFloat = AmbientFeel.hudCapture,
                            release: CGFloat = AmbientFeel.hudRelease) -> Snap {
        func axis(_ value: CGFloat, _ stops: [CGFloat], _ held: Bool) -> (CGFloat, Bool) {
            let reach = held ? release : capture
            guard let stop = stops.min(by: { abs($0 - value) < abs($1 - value) }), abs(stop - value) <= reach else { return (value, false) }
            return (stop, true)
        }
        let (x, sx) = axis(frame.minX, [visible.minX + inset, visible.maxX - inset - frame.width, visible.midX - frame.width / 2], was.x)
        let (y, sy) = axis(frame.minY, [visible.minY + inset, visible.maxY - inset - frame.height], was.y)
        return Snap(origin: CGPoint(x: x, y: y), x: sx, y: sy)
    }

    /// Identifies a display arrangement, so the HUD can sit somewhere different at the desk and on the go.
    public static func arrangementKey(_ displays: [(id: UInt32, frame: CGRect)]) -> String {
        displays.sorted { $0.id < $1.id }
            .map { "\($0.id):\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: "|")
    }

    /// Where the HUD sits on a display: distances from the nearest corner (or centred), so the same
    /// corner and gap survive a resolution change and the switch between pill and card.
    public struct Placement: Codable, Equatable, Sendable {
        public var display: UInt32
        public var right: Bool
        public var top: Bool
        public var centered: Bool
        public var dx: Double
        public var dy: Double

        public init(display: UInt32, frame: CGRect, visible: CGRect) {
            self.display = display
            centered = abs(frame.midX - visible.midX) < 1
            right = frame.midX > visible.midX
            top = frame.midY > visible.midY
            dx = Double(right ? visible.maxX - frame.maxX : frame.minX - visible.minX)
            dy = Double(top ? visible.maxY - frame.maxY : frame.minY - visible.minY)
        }

        public func origin(size: CGSize, visible: CGRect) -> CGPoint {
            let x = centered ? visible.midX - size.width / 2 : (right ? visible.maxX - CGFloat(dx) - size.width : visible.minX + CGFloat(dx))
            let y = top ? visible.maxY - CGFloat(dy) - size.height : visible.minY + CGFloat(dy)
            return CGPoint(x: min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width)).rounded(),
                           y: min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height)).rounded())
        }

        /// Default: top-right corner, under the menu bar.
        public static func initial(display: UInt32, size: CGSize, visible: CGRect) -> Placement {
            let inset = AmbientFeel.hudInset
            return Placement(display: display,
                             frame: CGRect(x: visible.maxX - inset - size.width, y: visible.maxY - inset - size.height, width: size.width, height: size.height),
                             visible: visible)
        }
    }
}
