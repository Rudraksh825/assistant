import AppKit
import QuartzCore
import StewardKit

/// The fixed transparent canvas inside a notch panel. Three stacked pieces: the toast stack (lowest, so
/// toasts emerge from under the island), the black shell with its shadow, and the SwiftUI content
/// masked to the shell. A frame of animation only rewrites two paths, five shadow numbers and one
/// origin, all on Core Animation layers; no view lays out and SwiftUI is not involved.
final class NotchCanvasView: NSView {
    /// x of the notch centre inside the canvas (the panel frame is rounded to whole points, the notch centre may not be).
    private let centerX: CGFloat
    private let shellLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let shellView = NSView()
    private let clip = NSView()
    private let toasts: NSView

    init(size: CGSize, centerX: CGFloat, content: NSView, toasts: NSView) {
        self.centerX = centerX
        self.toasts = toasts
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true

        toasts.frame = NSRect(x: centerX - (ToastMetrics.width + NotchMetrics.shadowMargin) / 2, y: 0,
                              width: ToastMetrics.width + NotchMetrics.shadowMargin, height: NotchMetrics.toastZone)
        addSubview(toasts)

        shellView.frame = bounds
        shellView.wantsLayer = true
        shellLayer.fillColor = .black
        shellLayer.shadowColor = .black
        shellLayer.frame = bounds
        shellView.layer?.addSublayer(shellLayer)
        addSubview(shellView)

        clip.frame = bounds
        clip.wantsLayer = true
        maskLayer.frame = bounds
        maskLayer.fillColor = .black
        clip.layer?.mask = maskLayer
        content.frame = bounds
        clip.addSubview(content)
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The capture field of the expanded island (not a toast's answer field).
    func contentTextView() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return find(clip)
    }

    /// The shell in canvas coordinates (origin bottom-left), for hit testing.
    private(set) var shellRect = CGRect.zero

    // The content view covers the whole canvas and a hosting view claims every point in its bounds,
    // so clicks on a toast would otherwise die in the empty content above it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let content = openClaim?.union(shellRect) ?? shellRect
        if !content.contains(local), toasts.frame.contains(local) { return toasts.hitTest(local) }
        return super.hitTest(point)
    }

    /// While the island is open: where it will be once its spring settles (canvas coordinates). Content
    /// owns clicks there from the first frame, not only where the shell has already grown to.
    var openClaim: CGRect?

    func apply(_ shell: NotchShell, visible: Bool) {
        // `NotchGeometry.path` is drawn top-down from y = 0; this view's layers are bottom-up.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        let body = CGRect(x: centerX + shell.centerOffset - shell.size.width / 2, y: 0, width: shell.size.width, height: shell.size.height)
        let path = NotchGeometry.path(in: body, topRadius: shell.topRadius, bottomRadius: shell.bottomRadius).copy(using: &flip)
        shellRect = CGRect(x: body.minX, y: bounds.height - body.height, width: body.width, height: body.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.path = path
        shellLayer.shadowPath = path
        shellLayer.shadowRadius = shell.shadowRadius
        shellLayer.shadowOffset = CGSize(width: 0, height: -shell.shadowY)
        shellLayer.shadowOpacity = Float(shell.shadowOpacity)
        shellLayer.opacity = visible ? 1 : 0
        maskLayer.path = path
        clip.layer?.opacity = visible ? 1 : 0
        toasts.setFrameOrigin(NSPoint(x: toasts.frame.minX, y: bounds.height - shell.size.height - ToastMetrics.gap - toasts.frame.height))
        CATransaction.commit()
    }
}
