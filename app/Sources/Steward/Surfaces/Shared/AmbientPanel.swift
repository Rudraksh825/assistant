import AppKit
import QuartzCore
import SwiftUI
import StewardKit

/// Borderless, transparent, non-activating: it can take the keyboard for a text field without ever
/// bringing Steward to the front or pulling the user's app out of focus.
final class AmbientPanel: NSPanel {
    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        // A click on a button must not move the keyboard; only a click into a text field does.
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // Shadows are drawn by the content so they can animate with it.
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        appearance = NSAppearance(named: .darkAqua)
        // Without this, pointer moves over the panel reach nobody: other apps' moves come through the
        // global monitor, ours only through the local one, and only for windows that ask.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // AppKit would push a window out of the menu bar area; the island lives there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Gives the keyboard back to whatever had it. Ordering a key panel out is what makes the window
    /// server re-key the active app's window; it comes straight back in the same turn.
    func yieldKey(keepVisible: Bool) {
        guard isKeyWindow else { return }
        orderOut(nil)
        if keepVisible { orderFrontRegardless() }
    }
}

/// SwiftUI in a panel that is usually not key: clicks must act on the first press, the hosting view
/// must not resize or constrain the window, and the notch's safe area must not inset the content.
final class AmbientHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A display link that only runs while something moves. `onFrame` returns false when everything is at rest.
@MainActor
final class FrameTicker: NSObject {
    var onFrame: (TimeInterval) -> Bool = { _ in false }
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    /// Wanted to run. Outlives a missing link (started before `attach`) and a frame that both finishes
    /// one motion and starts the next.
    private var running = false
    /// The current (or last) run, for the self-test: frames drawn, seconds covered, longest gap between two frames.
    private(set) var run = (frames: 0, seconds: 0.0, worstGap: 0.0)

    /// The view decides which display's refresh the link follows; it must be in a window.
    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = !running
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func start() {
        if !running {
            last = 0
            run = (0, 0, 0)
        }
        running = true
        link?.isPaused = false
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        running = false
    }

    @objc private func step(_ link: CADisplayLink) {
        // A hitch must not turn into a visible jump, so one step never covers more than 1/30 s.
        let gap = last == 0 ? 0 : link.timestamp - last
        let dt = last == 0 ? link.targetTimestamp - link.timestamp : min(gap, 1.0 / 30)
        last = link.timestamp
        run = (run.frames + 1, run.seconds + gap, max(run.worstGap, gap))
        running = false
        // `onFrame` may call `start()` again (coming to rest can trigger the next motion).
        if onFrame(dt) { running = true }
        if !running { link.isPaused = true }
    }
}

/// Mouse position changes anywhere on screen, whether or not Steward is the active app. Tracking areas
/// stop at windows that ignore the mouse, and the ambient panels ignore it at rest so they never eat a click.
@MainActor
final class PointerWatch {
    private var monitors: [Any] = []

    init(_ events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged], onMove: @escaping @MainActor (NSPoint) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated { onMove(NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated { onMove(NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var metrics: ScreenMetrics {
        ScreenMetrics(frame: frame, visibleFrame: visibleFrame, safeTop: safeAreaInsets.top,
                      auxLeftWidth: auxiliaryTopLeftArea?.width, auxRightWidth: auxiliaryTopRightArea?.width)
    }

    static func with(_ id: CGDirectDisplayID?) -> NSScreen? {
        guard let id else { return nil }
        return screens.first { $0.displayID == id }
    }

    static var underMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

/// Behind-window blur for the floating panels (capture, HUD). Liquid Glass samples what is inside its
/// own window, which for a transparent panel is nothing; this samples the desktop behind it.
struct AmbientBackdrop: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = radius
    }
}

extension View {
    /// Dark frosted panel: blur of what is behind the window, a tint for contrast, a hairline, and an
    /// elevation shadow. `solidity` 0 = airy, 1 = nearly opaque.
    func ambientPanel(radius: CGFloat, elevation: CGFloat, solidity: Double = 0.6) -> some View {
        background {
            ZStack {
                AmbientBackdrop(radius: radius)
                // The shadow hangs off the tint: SwiftUI effects do not reach into the AppKit blur view.
                RoundedRectangle.continuous(radius).fill(Palette.bg.opacity(0.42 + 0.5 * solidity)).elevation(elevation)
                RoundedRectangle.continuous(radius).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
    }
}
