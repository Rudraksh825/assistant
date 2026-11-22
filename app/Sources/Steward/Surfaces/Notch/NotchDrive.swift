import AppKit
import StewardKit

/// The island's motion: a handful of retargetable springs stepped by a display link, reduced every
/// frame to one `NotchShell` through `NotchGeometry`. Nothing here knows about views; the canvas
/// applies the shell to Core Animation layers, so SwiftUI never re-renders for a frame of animation.
@MainActor
final class NotchDrive {
    let notch: CGSize
    private(set) var shell: NotchShell
    /// Called with every new shell while animating.
    var onShell: (NotchShell) -> Void = { _ in }
    /// Called once when every spring has come to rest.
    var onRest: () -> Void = {}

    private var open = SpringValue(0, spec: AmbientFeel.open, epsilon: 0.0006)
    private var swell = SpringValue(0, spec: AmbientFeel.swell, epsilon: 0.002)
    private var pull = SpringValue(0, spec: AmbientFeel.snapBack, epsilon: 0.05)
    private var earLeft = SpringValue(0, spec: AmbientFeel.track, epsilon: 0.05)
    private var earRight = SpringValue(0, spec: AmbientFeel.track, epsilon: 0.05)
    private var bodyWidth: SpringValue
    private var bodyHeight: SpringValue
    private let ticker = FrameTicker()
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(notch: CGSize, body: CGSize) {
        self.notch = notch
        bodyWidth = SpringValue(body.width, spec: AmbientFeel.track, epsilon: 0.05)
        bodyHeight = SpringValue(body.height, spec: AmbientFeel.track, epsilon: 0.05)
        shell = NotchGeometry.shell(notch: notch, pose: NotchPose(body: body))
        ticker.onFrame = { [weak self] dt in self?.step(dt) ?? false }
    }

    func attach(to view: NSView) { ticker.attach(to: view) }
    var frameStats: String {
        String(format: "%d frames in %.2f s, longest gap %.1f ms", ticker.run.frames, ticker.run.seconds, ticker.run.worstGap * 1000)
    }
    func invalidate() { ticker.invalidate() }

    var pose: NotchPose {
        NotchPose(open: open.value, swell: swell.value, pull: pull.value, earLeft: earLeft.value, earRight: earRight.value,
                  body: CGSize(width: bodyWidth.value, height: bodyHeight.value))
    }

    var openProgress: Double { open.value }

    // MARK: Targets

    /// - Parameter velocity: open-progress per second handed over from a gesture.
    func setOpen(_ isOpen: Bool, velocity: Double? = nil) {
        open.retarget(isOpen ? 1 : 0, spec: isOpen ? AmbientFeel.open : AmbientFeel.close, velocity: velocity)
        run()
    }

    func setSwell(_ on: Bool) {
        swell.retarget(on ? 1 : 0, spec: on ? AmbientFeel.swell : AmbientFeel.relax)
        run()
    }

    /// A physical nudge: the island bulges and settles (a toast leaving it, an action landing).
    func kick(_ impulse: Double = 5) {
        swell.kick(impulse)
        run()
    }

    func setEars(left: CGFloat, right: CGFloat) {
        earLeft.retarget(left)
        earRight.retarget(right)
        run()
    }

    /// The size the island opens to. While collapsed there is nothing to animate, so it jumps.
    func setBody(_ size: CGSize) {
        if open.isSettled && open.value == 0 {
            bodyWidth.set(size.width)
            bodyHeight.set(size.height)
        } else {
            bodyWidth.retarget(size.width)
            bodyHeight.retarget(size.height)
        }
        run()
    }

    /// Finger down: the shape follows directly.
    func track(pull distance: CGFloat) {
        pull.set(distance)
        run()
    }

    /// Finger up or threshold crossed: the pull lets go.
    func releasePull(committed: Bool, velocity: Double = 0) {
        pull.retarget(0, spec: committed ? AmbientFeel.pullRelease : AmbientFeel.snapBack, velocity: committed ? 0 : velocity)
        run()
    }

    // MARK: Stepping

    private func run() {
        if reduceMotion {
            // Reduce Motion: no travel. Everything lands at once and the content cross-fades.
            step(10)
            return
        }
        ticker.start()
        // A target that is already met still needs one publish (ears set before the first frame).
        if isSettled { publish() }
    }

    private var isSettled: Bool {
        open.isSettled && swell.isSettled && pull.isSettled && earLeft.isSettled && earRight.isSettled && bodyWidth.isSettled && bodyHeight.isSettled
    }

    @discardableResult
    private func step(_ dt: TimeInterval) -> Bool {
        open.step(dt)
        swell.step(dt)
        pull.step(dt)
        earLeft.step(dt)
        earRight.step(dt)
        bodyWidth.step(dt)
        bodyHeight.step(dt)
        publish()
        guard isSettled else { return true }
        onRest()
        // Coming to rest can start the next motion (the pointer is still on the notch).
        return !isSettled
    }

    private func publish() {
        let next = NotchGeometry.shell(notch: notch, pose: pose)
        guard next != shell else { return }
        shell = next
        onShell(next)
    }
}
