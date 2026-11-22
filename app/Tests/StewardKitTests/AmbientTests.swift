import CoreGraphics
import Foundation
import Testing
@testable import StewardKit

// MARK: Geometry

private let builtIn = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 58, width: 1728, height: 1026),
    safeTop: 32, auxLeftWidth: 771, auxRightWidth: 772)
private let external = ScreenMetrics(
    frame: CGRect(x: -2133, y: 1117, width: 3008, height: 1692), visibleFrame: CGRect(x: -2133, y: 1117, width: 3008, height: 1667))

@Test func notchLayoutComesFromScreenMetrics() {
    #expect(builtIn.notchRect == CGRect(x: 771, y: 1085, width: 185, height: 32))
    let layout = NotchLayout(screen: builtIn, statusBarThickness: 24)
    #expect(layout.hasNotch && !layout.tucked)
    #expect(layout.notch == CGSize(width: 185, height: 32))
    #expect(layout.centerX == 863.5 && layout.top == 1117)

    let panel = layout.panelFrame(canvas: CGSize(width: 760, height: 800))
    #expect(panel.maxY == 1117 && panel.width == 760, "pinned to the top edge")
    #expect(abs(panel.midX - layout.centerX) <= 0.5)
    #expect(layout.globalRect(of: layout.notch) == builtIn.notchRect)

    // The same screen placed elsewhere in the arrangement: the notch moves with the frame.
    var moved = builtIn
    moved.frame.origin = CGPoint(x: 3008, y: -200)
    #expect(moved.notchRect?.minX == 3008 + 771 && moved.notchRect?.maxY == moved.frame.maxY)
}

@Test func notchlessScreensGetAVirtualNotchOfTheSameFamily() {
    #expect(external.notchRect == nil)
    let layout = NotchLayout(screen: external, reference: CGSize(width: 185, height: 32), statusBarThickness: 24)
    #expect(!layout.hasNotch && !layout.tucked)
    #expect(layout.notch.height == 25, "hangs exactly as deep as that screen's menu bar")
    #expect(abs(layout.notch.width / layout.notch.height - 185.0 / 32.0) < 0.05, "keeps the hardware notch's proportions")
    #expect(layout.centerX == external.frame.midX && layout.top == external.frame.maxY)

    // No menu bar (full-screen space): fall back to the status bar thickness and tuck away.
    var fullScreen = external
    fullScreen.visibleFrame = fullScreen.frame
    let tucked = NotchLayout(screen: fullScreen, statusBarThickness: 24)
    #expect(tucked.tucked && tucked.notch.height == 24 && tucked.notch.width > 100)
}

@Test func shellIsThePureFunctionOfOneProgressValue() {
    let notch = CGSize(width: 185, height: 32), body = CGSize(width: 660, height: 420)
    func shell(_ open: CGFloat) -> NotchShell { NotchGeometry.shell(notch: notch, pose: NotchPose(open: open, body: body)) }

    let rest = shell(0), full = shell(1)
    #expect(rest.size == notch && rest.shadowOpacity == 0 && rest.shadowRadius == 0, "at rest it is the notch, with no shadow to give it away")
    #expect(rest.bottomRadius == AmbientFeel.bottomRadiusRest && rest.topRadius == AmbientFeel.topRadiusRest)
    #expect(full.size == body && full.bottomRadius == AmbientFeel.bottomRadiusOpen && full.topRadius == AmbientFeel.topRadiusOpen)
    #expect(full.shadowRadius == AmbientFeel.shadowRadiusOpen && full.shadowOpacity == AmbientFeel.shadowOpacityOpen)

    // Size, radius and shadow all rise together, with width ahead of height on the way.
    var previous = rest
    for step in 1...20 {
        let p = CGFloat(step) / 20, s = shell(p)
        #expect(s.size.width > previous.size.width && s.size.height > previous.size.height)
        #expect(s.bottomRadius >= previous.bottomRadius && s.shadowRadius > previous.shadowRadius)
        if step < 20 {
            let widthDone = (s.size.width - notch.width) / (body.width - notch.width)
            let heightDone = (s.size.height - notch.height) / (body.height - notch.height)
            #expect(widthDone > heightDone)
        }
        previous = s
    }

    // Overshoot stays smooth and the shadow does not run away.
    let over = shell(1.03)
    #expect(over.size.height > body.height && over.size.height < body.height * 1.06)
    #expect(over.shadowOpacity == AmbientFeel.shadowOpacityOpen)
}

@Test func hoverPullAndEarsShapeTheRestingShell() {
    let notch = CGSize(width: 185, height: 32), body = CGSize(width: 660, height: 420)
    let hover = NotchGeometry.shell(notch: notch, pose: NotchPose(swell: 1, body: body))
    #expect(hover.size == CGSize(width: 185 + AmbientFeel.swellSize.width, height: 32 + AmbientFeel.swellSize.height))
    #expect(hover.shadowOpacity > 0 && hover.shadowOpacity < 0.15)

    let ears = NotchGeometry.shell(notch: notch, pose: NotchPose(earLeft: 40, earRight: 10, body: body))
    #expect(ears.size.width == 235 && ears.size.height == 32 && ears.centerOffset == -15, "covers the notch plus both ears")
    #expect(NotchGeometry.shell(notch: notch, pose: NotchPose(open: 1, earLeft: 40, earRight: 10, body: body)).centerOffset == 0)

    let pulled = NotchGeometry.shell(notch: notch, pose: NotchPose(pull: 30, body: body))
    #expect(pulled.size.height == 62 && pulled.size.width > 185 && pulled.bottomRadius > AmbientFeel.bottomRadiusRest)

    // A tiny shape can never have a corner bigger than itself.
    let tiny = NotchGeometry.shell(notch: CGSize(width: 30, height: 12), pose: NotchPose(body: body))
    #expect(tiny.bottomRadius <= 6)

    let bounds = NotchGeometry.path(in: CGRect(x: 100, y: 0, width: 185, height: 32), topRadius: 6, bottomRadius: 10).boundingBoxOfPath
    #expect(bounds.minY == 0 && bounds.maxY == 32, "flush with the top edge")
    #expect(bounds.minX < 100 && bounds.maxX > 285, "fillets flare out into the bezel")
}

@Test func earsAndIndicatorFollowWhatIsLive() {
    #expect(NotchGeometry.dotsEarWidth(count: 0) == 0)
    #expect(NotchGeometry.dotsEarWidth(count: 3) < NotchGeometry.dotsEarWidth(count: 4))
    #expect(NotchGeometry.dotsEarWidth(count: 30) == NotchGeometry.dotsEarWidth(count: 9), "overflow collapses into +N")

    let now = Date(timeIntervalSince1970: 1_000_000)
    func pick(listening: Bool = false, decisions: Int = 0, meetingIn: TimeInterval? = nil, live: Bool = false, busy: Bool = false) -> NotchIndicator {
        NotchIndicator.pick(listening: listening, decisions: decisions, meetingStart: meetingIn.map(now.addingTimeInterval), meetingLive: live, agentBusy: busy, now: now)
    }
    #expect(pick() == .none && NotchIndicator.none.earWidth == 0)
    #expect(pick(busy: true) == .agent)
    #expect(pick(meetingIn: 3600, busy: true) == .agent, "a meeting an hour out is not live yet")
    #expect(pick(meetingIn: 300, busy: true) == .meeting(start: now.addingTimeInterval(300), live: false))
    #expect(pick(decisions: 2, meetingIn: 300, busy: true) == .decisions(2))
    #expect(pick(listening: true, decisions: 2) == .voice)
    #expect(pick(meetingIn: -600, live: true) == .meeting(start: now.addingTimeInterval(-600), live: true))
}

// MARK: Motion

@Test func rubberBandResistsMoreTheFurtherYouPull() {
    let d = AmbientFeel.pullLimit
    #expect(RubberBand.offset(0, dimension: d) == 0)
    #expect(abs(RubberBand.offset(1, dimension: d) - AmbientFeel.rubberCoefficient) < 0.01, "starts at the coefficient's slope")
    var last: CGFloat = 0, lastGain = CGFloat.infinity
    for x in stride(from: CGFloat(10), through: 400, by: 10) {
        let y = RubberBand.offset(x, dimension: d)
        #expect(y > last && y < d && y < x)
        #expect(y - last < lastGain, "each extra point of finger buys less")
        lastGain = y - last
        last = y
    }
    #expect(RubberBand.offset(-50, dimension: d) == -RubberBand.offset(50, dimension: d))
    #expect(RubberBand.offset(50, dimension: 0) == 0)
}

@Test func springRetargetsFromWhereItIsAndNeverRestarts() {
    let dt = 1.0 / 120
    var spring = SpringValue(0, spec: AmbientFeel.open)
    #expect(spring.isSettled)
    spring.retarget(1)
    for _ in 0..<6 { spring.step(dt) }
    let (mid, velocity) = (spring.value, spring.velocity)
    #expect(mid > 0.1 && mid < 0.9 && velocity > 0)

    // Reverse mid-flight: no jump, and momentum carries it a little further before it turns.
    spring.retarget(0, spec: AmbientFeel.close)
    #expect(spring.value == mid && spring.velocity == velocity)
    spring.step(dt)
    #expect(spring.value > mid && spring.value - mid < velocity * dt * 1.01)
    var peak = spring.value, steps = 0
    while !spring.isSettled && steps < 600 {
        let before = spring.value
        spring.step(dt)
        peak = max(peak, spring.value)
        #expect(abs(spring.value - before) < 0.12, "no frame ever jumps")
        steps += 1
    }
    #expect(spring.isSettled && spring.value == 0 && steps < 150)
    #expect(peak < mid + 0.2)
}

@Test func openOvershootsOnceAndCloseNeverBounces() {
    let dt = 1.0 / 120
    var open = SpringValue(0, spec: AmbientFeel.open)
    open.retarget(1)
    var peak = 0.0, time = 0.0, firstFrame = 0.0
    while !open.isSettled && time < 3 {
        open.step(dt)
        if time == 0 { firstFrame = open.value }
        peak = max(peak, open.value)
        time += dt
    }
    #expect(open.value == 1 && time < 1.2)
    #expect((1.005...1.06).contains(peak), "one soft overshoot, got \(peak)")

    var plain = SpringValue(0, spec: SpringSpec(response: AmbientFeel.open.response, damping: AmbientFeel.open.damping))
    plain.retarget(1)
    plain.step(dt)
    #expect(firstFrame == plain.value && firstFrame > 0.01, "no resistance: the island moves on the very first frame")

    var close = SpringValue(1, spec: AmbientFeel.close)
    close.retarget(0)
    var low = 1.0
    while !close.isSettled { close.step(dt); low = min(low, close.value) }
    #expect(low > -0.004, "closing does not dip past collapsed")

    // A flick's velocity is handed to the spring, so it arrives sooner than from a standing start.
    var flicked = SpringValue(0.1, spec: AmbientFeel.open), standing = SpringValue(0.1, spec: AmbientFeel.open)
    flicked.retarget(1, velocity: 4)
    standing.retarget(1)
    for _ in 0..<12 { flicked.step(dt); standing.step(dt) }
    #expect(flicked.value > standing.value + 0.03)

    // Frame rate does not change where the spring is.
    var coarse = SpringValue(0, spec: AmbientFeel.close), fine = SpringValue(0, spec: AmbientFeel.close)
    coarse.retarget(1); fine.retarget(1)
    for _ in 0..<6 { coarse.step(1.0 / 60) }
    for _ in 0..<12 { fine.step(1.0 / 120) }
    #expect(abs(coarse.value - fine.value) < 1e-9)

    var kicked = SpringValue(0, spec: AmbientFeel.relax)
    kicked.kick(3)
    kicked.step(dt)
    #expect(kicked.value > 0 && !kicked.isSettled)
    for _ in 0..<400 { kicked.step(dt) }
    #expect(kicked.isSettled && kicked.value == 0)
}

// MARK: Toasts

@Test func toastQueueShowsThreeHoldsOnHoverAndQueuesWhenQuiet() {
    let t0 = Date(timeIntervalSince1970: 0)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    var queue = ToastQueue<String>()

    for (i, id) in ["a", "b", "c", "d"].enumerated() { queue.push(id, priority: 1, lifetime: 6, now: at(Double(i))) }
    #expect(queue.visible.map(\.id) == ["c", "b", "a"], "newest nearest the notch, three at most")
    #expect(queue.waiting.map(\.id) == ["d"])
    #expect(queue.nextDeadline == at(6))

    queue.push("urgent", priority: 2, lifetime: 11, now: at(3))
    queue.push("b", priority: 1, lifetime: 6, now: at(3))
    #expect(queue.visible.count == 3 && queue.waiting.count == 2, "a repeat updates in place")

    // Hover holds the timer and marks the toast seen; leaving grants at least the grace period.
    queue.hold("a", now: at(5.5))
    #expect(queue.expire(now: at(6.5)).isEmpty)
    queue.release("a", now: at(20))
    #expect(queue.visible.first { $0.id == "a" }?.deadline == at(20 + ToastQueue<String>.graceAfterHold))

    let gone = queue.expire(now: at(7.5))
    #expect(gone.map(\.id) == ["b"] && gone[0].seen == false)
    #expect(queue.visible.map(\.id) == ["urgent", "c", "a"], "the higher priority jumps the line")
    #expect(queue.visible[0].deadline == at(18.5))

    queue.remove("c", now: at(8))
    #expect(queue.visible.map(\.id) == ["d", "urgent", "a"] && queue.waiting.isEmpty)

    // Quiet (meeting live): arrivals wait, and stale ones are dropped instead of shown late.
    queue.setQuiet(true, now: at(9))
    queue.remove("d", now: at(9))
    queue.push("later", priority: 1, lifetime: 6, now: at(10))
    queue.push("stale", priority: 2, lifetime: 11, expiresAt: at(60), now: at(10))
    #expect(queue.visible.map(\.id) == ["urgent", "a"] && queue.waiting.count == 2)
    queue.setQuiet(false, now: at(100))
    #expect(queue.visible.first?.id == "later" && queue.waiting.isEmpty)
    #expect(queue.visible.first?.deadline == at(106))
}

@Test func deliveryPlanNeverDoublesUpWhenTheToastWasSeen() {
    #expect(ToastDelivery.plan(priority: 0, userActive: true, quiet: false) == ToastDelivery(toast: false, notifyNow: false, notifyIfUnseen: false))
    #expect(ToastDelivery.plan(priority: 1, userActive: false, quiet: true) == ToastDelivery(toast: true, notifyNow: false, notifyIfUnseen: false))
    #expect(ToastDelivery.plan(priority: 2, userActive: true, quiet: false) == ToastDelivery(toast: true, notifyNow: false, notifyIfUnseen: true))
    #expect(ToastDelivery.plan(priority: 2, userActive: false, quiet: false) == ToastDelivery(toast: true, notifyNow: true, notifyIfUnseen: false))
    #expect(ToastDelivery.plan(priority: 2, userActive: true, quiet: true) == ToastDelivery(toast: true, notifyNow: true, notifyIfUnseen: false))
    #expect(ToastDelivery.lifetime(priority: 1) < ToastDelivery.lifetime(priority: 2))
    #expect(ToastDelivery.lifetime(priority: 2) < ToastDelivery.lifetime(priority: 2, needsDecision: true))
}

// MARK: Capture and voice

@Test func captureDraftAddsTheAgentPrefixToQuickAdd() {
    #expect(CaptureDraft.parse("  ").isEmpty && !CaptureDraft.parse("  ").forceAgent)
    let plain = CaptureDraft.parse("!! fix login redirect #web-app @dana")
    #expect(!plain.forceAgent && plain.quick.priority == 2 && plain.quick.hashes == ["web-app"] && plain.quick.people == ["dana"])
    #expect(plain.quick.title == "fix login redirect")

    let agent = CaptureDraft.parse(" > what is blocking ENG-123?")
    #expect(agent.forceAgent && agent.quick.title == "what is blocking ENG-123?")
    #expect(CaptureDraft.parse(">").forceAgent && CaptureDraft.parse(">").isEmpty)
    #expect(CaptureDraft.parse("a > b").forceAgent == false, "only a leading > counts")
}

@Test func voiceGoesToCaptureUnlessItStartsWithAWakePhrase() {
    #expect(VoiceRoute.route("remember to renew the domain") == .capture("remember to renew the domain"))
    #expect(VoiceRoute.route("Ask what's on my plate today") == .agent("what's on my plate today"))
    #expect(VoiceRoute.route("Hey Steward, what is next?") == .agent("what is next?"))
    #expect(VoiceRoute.route("ask steward which sessions are waiting") == .agent("which sessions are waiting"))
    #expect(VoiceRoute.route("asking for a friend") == .capture("asking for a friend"))
    #expect(VoiceRoute.route("stewardship notes") == .capture("stewardship notes"))
    #expect(VoiceRoute.route("ask") == .capture("ask"), "a wake phrase with nothing after it is not a question")
    #expect(VoiceRoute.route("  ") == .capture(""))
}

// MARK: HUD

@Test func hudSnapsToEdgesWithHysteresisAndRemembersItsCorner() {
    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    let size = CGSize(width: 240, height: 44)
    func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: size) }
    let inset = AmbientFeel.hudInset

    let free = HUDGeometry.snap(frame(600, 500), in: visible)
    #expect(free == .init(origin: CGPoint(x: 600, y: 500), x: false, y: false))

    let corner = HUDGeometry.snap(frame(1728 - 240 - 20, 1084 - 44 - 5), in: visible)
    #expect(corner.x && corner.y)
    #expect(corner.origin == CGPoint(x: 1728 - inset - 240, y: 1084 - inset - 44))

    // 25 pt from the edge: too far to be captured, close enough to be held.
    let near = frame(inset + 25, 500)
    #expect(HUDGeometry.snap(near, in: visible).x == false)
    #expect(HUDGeometry.snap(near, in: visible, was: (true, false)).origin.x == inset)
    #expect(HUDGeometry.snap(frame(inset + 40, 500), in: visible, was: (true, false)).x == false)

    #expect(HUDGeometry.snap(frame(864 - 120 + 9, 500), in: visible).origin.x == CGFloat(744), "the centre line is a stop too")

    let placed = HUDGeometry.Placement(display: 1, frame: CGRect(origin: corner.origin, size: size), visible: visible)
    #expect(placed.origin(size: size, visible: visible) == corner.origin)
    let card = CGSize(width: 320, height: 380)
    let grown = placed.origin(size: card, visible: visible)
    #expect(grown == CGPoint(x: 1728 - inset - 320, y: 1084 - inset - 380), "the card grows from the same corner")
    #expect(placed.origin(size: size, visible: CGRect(x: 0, y: 0, width: 200, height: 30)) == .zero, "never off a screen that shrank")
    #expect(HUDGeometry.Placement.initial(display: 1, size: size, visible: visible).origin(size: size, visible: visible) == CGPoint(x: 1728 - inset - 240, y: 1084 - inset - 44))

    let a = HUDGeometry.arrangementKey([(1, CGRect(x: 0, y: 0, width: 1728, height: 1117)), (3, CGRect(x: -2133, y: 1117, width: 3008, height: 1692))])
    let b = HUDGeometry.arrangementKey([(3, CGRect(x: -2133, y: 1117, width: 3008, height: 1692)), (1, CGRect(x: 0, y: 0, width: 1728, height: 1117))])
    #expect(a == b && a != HUDGeometry.arrangementKey([(1, CGRect(x: 0, y: 0, width: 1728, height: 1117))]))
}
