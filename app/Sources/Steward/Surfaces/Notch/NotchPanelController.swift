import AppKit
import SwiftUI
import StewardKit

/// One island on one display: the panel, its motion, and every way in and out of it (hover, click,
/// pull, swipe, hotkey, keyboard). The panel ignores the mouse unless the pointer is on the
/// shape or a toast, so it can never swallow a click meant for the menu bar or an app.
@MainActor
final class NotchPanelController {
    let displayID: CGDirectDisplayID
    let layout: NotchLayout
    let scene: NotchScene
    let panel: AmbientPanel

    private let ambient: AmbientState
    private let drive: NotchDrive
    private let canvas: NotchCanvasView
    private var localMonitor: Any?
    private var outsideMonitor: Any?
    private var keyObservers: [NSObjectProtocol] = []

    /// After a close the pointer must leave the island before hover arms again; otherwise
    /// closing with the pointer resting on the notch would reopen it.
    private var hoverSuppressed = false
    /// The pointer has been inside the open panel at least once; only then does leaving close it.
    private var pointerVisited = false
    private var noticeTimer: DispatchWorkItem?
    private var lastHaptic = Date.distantPast
    private var toastHeight: CGFloat = 0

    private struct Press {
        var start: NSPoint
        var last: NSPoint
        var lastTime: TimeInterval
        var velocity: CGFloat = 0
        var dragging = false
        var committed = false
    }
    private var press: Press?

    private struct Scroll {
        enum Axis { case undecided, pull, row(NotchItem), toast(String), passthrough }
        var axis = Axis.undecided
        var total: CGFloat = 0
        var velocity: CGFloat = 0
        var lastTime: TimeInterval = 0
        var armed = false
        var committed = false
    }
    private var scroll: Scroll?
    private var swallowMomentum = false

    /// Last measured height of the full content, so the next open aims at the right size from its first frame.
    private static var lastFullHeight: CGFloat = 430

    init(screen: NSScreen, layout: NotchLayout, ambient: AmbientState, toastActions: ToastActions) {
        displayID = screen.displayID
        self.layout = layout
        self.ambient = ambient
        scene = NotchScene(layout: layout, displayID: displayID)
        drive = NotchDrive(notch: layout.notch, body: CGSize(width: NotchMetrics.fullWidth, height: Self.lastFullHeight))

        let frame = layout.panelFrame(canvas: NotchMetrics.canvas)
        // Above the menu bar and its status items, below menus and the screen saver.
        panel = AmbientPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.ignoresMouseEvents = true

        var reportToastHeight: (CGFloat) -> Void = { _ in }
        canvas = Self.makeCanvas(scene: scene, ambient: ambient, toastActions: toastActions, frame: frame) { reportToastHeight($0) }
        panel.contentView = canvas
        reportToastHeight = { [weak self] in self?.toastHeight = $0 }

        wire()
        updateEars()
        canvas.apply(drive.shell, visible: isVisible)
        panel.orderFrontRegardless()
        drive.attach(to: canvas)
    }

    /// The view tree of one island; also what the offscreen snapshots render.
    static func makeCanvas(scene: NotchScene, ambient: AmbientState, toastActions: ToastActions, frame: CGRect,
                           onToastHeight: @escaping (CGFloat) -> Void) -> NotchCanvasView {
        let content = AmbientHostingView(rootView: NotchContent(scene: scene, ambient: ambient))
        let toasts = AmbientHostingView(rootView: ToastStack(center: ambient.toasts, displayID: scene.displayID, actions: toastActions, onHeight: onToastHeight))
        return NotchCanvasView(size: frame.size, centerX: scene.layout.centerX - frame.minX, content: content, toasts: toasts)
    }

    func teardown() {
        noticeTimer?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        removeOutsideMonitor()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        drive.invalidate()
        panel.orderOut(nil)
    }

    private func wire() {
        drive.onShell = { [weak self] shell in
            guard let self else { return }
            self.canvas.apply(shell, visible: self.isVisible)
        }
        drive.onRest = { [weak self] in self?.cameToRest() }

        var actions = ambient.actions
        let base = ambient.actions
        actions.focus = { [weak self] in base.focus($0); self?.close() }
        actions.join = { [weak self] in base.join($0); self?.close() }
        actions.openMain = { [weak self] in base.openMain($0); self?.close() }
        actions.ask = { [weak self] in base.ask($0); self?.close() }
        actions.openChat = { [weak self] in base.openChat($0); self?.close() }
        actions.complete = { [weak self] in base.complete($0); self?.drive.kick(3) }
        scene.actions = actions
        scene.close = { [weak self] in self?.close() }
        scene.onContentHeight = { [weak self] height in
            guard let self, self.scene.presentation == .full else { return }
            Self.lastFullHeight = height
            self.drive.setBody(self.bodySize(for: .full))
            self.claimOpenRect()
        }
        scene.submitField = { [weak self] in self?.submitField(modifiers: $0) }
        scene.moveFromField = { [weak self] key in
            self?.moveSelection(key == .down || key == .tab ? 1 : -1)
            return true
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            // Local monitors run on the main thread; the event never crosses to another one.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    // MARK: Shape state

    /// A resting hardware notch shows nothing of ours; a tucked virtual one hides entirely.
    private var isVisible: Bool {
        let pose = drive.pose
        guard pose.isResting else { return true }
        if layout.tucked { return false }
        return !layout.hasNotch || pose.earLeft > 0.5 || pose.earRight > 0.5
    }

    // The surface watches the model once and tells every island; a watch per island would outlive it.

    func updateEars() {
        // Equal ears keep the island centred on the camera, and the toasts under it centred on the island.
        let ear = max(NotchGeometry.dotsEarWidth(count: ambient.model.sessionStates.count), ambient.model.indicator.earWidth)
        drive.setEars(left: ear, right: ear)
    }

    /// The stack changed: the island swallows visibly when a toast leaves it, and lets go of the keyboard
    /// once no toast is being typed into.
    func toastsChanged(arrived: Bool) {
        guard ambient.toasts.displayID == displayID else { return }
        if arrived { drive.kick(9) }
        // After SwiftUI has taken a departed toast's answer field out of the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.scene.isOpen else { return }
            if let field = self.panel.firstResponder as? NSTextView, field.window === self.panel { return }
            self.panel.yieldKey(keepVisible: true)
        }
    }

    private func bodySize(for presentation: NotchScene.Presentation) -> CGSize {
        let notch = layout.notch.height
        switch presentation {
        case .full: return CGSize(width: NotchMetrics.fullWidth, height: min(NotchMetrics.maxBodyHeight, max(notch + 80, Self.lastFullHeight)))
        case .voice: return CGSize(width: NotchMetrics.voiceBody.width, height: notch + NotchMetrics.voiceBody.height)
        case .notice: return CGSize(width: NotchMetrics.noticeBody.width, height: notch + NotchMetrics.noticeBody.height)
        case .none: return CGSize(width: layout.notch.width, height: notch)
        }
    }

    private var shellRectOnScreen: CGRect {
        canvas.shellRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Where the open island will be once its spring settles. The pointer is judged against this, not the
    /// shape mid-flight: a click that beats the animation must still land, and must not fall through to
    /// the app underneath.
    private var openRectOnScreen: CGRect {
        let size = bodySize(for: scene.presentation)
        return CGRect(x: layout.centerX - size.width / 2, y: layout.top - size.height, width: size.width, height: size.height)
            .union(shellRectOnScreen)
    }

    private func claimOpenRect() {
        canvas.openClaim = scene.isOpen ? openRectOnScreen.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) : nil
    }

    private var toastRectOnScreen: CGRect? {
        guard toastHeight > 0, ambient.toasts.displayID == displayID, !ambient.toasts.items.isEmpty else { return nil }
        let top = layout.top - drive.shell.size.height - ToastMetrics.gap
        return CGRect(x: layout.centerX - ToastMetrics.width / 2, y: top - toastHeight, width: ToastMetrics.width, height: toastHeight)
    }

    // MARK: Open and close

    func toggle() {
        if scene.isOpen && scene.presentation == .full { close() } else { open(.full, key: true, haptic: true) }
    }

    /// - Parameters:
    ///   - key: take the keyboard. Only for the user's own hotkey; hover never does.
    ///   - velocity: open-progress per second carried over from a pull.
    func open(_ presentation: NotchScene.Presentation, key: Bool = false, haptic: Bool = false, velocity: Double? = nil) {
        noticeTimer?.cancel()
        let wasOpen = scene.isOpen
        scene.presentation = presentation
        scene.mounted = true
        scene.isOpen = true
        scene.revealed = true
        drive.setBody(bodySize(for: presentation))
        drive.setSwell(false)
        drive.setOpen(true, velocity: velocity)
        if haptic { self.haptic(Haptics.thunk) }
        if !wasOpen { pointerVisited = false }
        claimOpenRect()
        if presentation == .full {
            installOutsideMonitor()
            if key {
                panel.makeKey()
                scene.selection = .field
                scene.focusField += 1
            }
        }
        pointerMoved(NSEvent.mouseLocation)
    }

    func close() {
        guard scene.isOpen else { return }
        scene.isOpen = false
        scene.revealed = false
        scene.selection = nil
        scene.swipe = nil
        noticeTimer?.cancel()
        hoverSuppressed = true
        removeOutsideMonitor()
        panel.yieldKey(keepVisible: true)
        drive.setOpen(false)
        claimOpenRect()
    }

    /// Shows a line in the island for a moment, unless the full panel is up (which says more already).
    func notice(icon: String, text: String) {
        guard !(scene.isOpen && scene.presentation == .full) else { return }
        open(.notice(icon: icon, text: text))
        let work = DispatchWorkItem { [weak self] in self?.close() }
        noticeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func setVoice(_ listening: Bool) {
        if listening {
            open(.voice)
        } else if scene.presentation == .voice {
            close()
        }
    }

    /// Dev aid (`STEWARD_AMBIENT_SELFTEST=1`): opens and closes once without taking the keyboard and logs how the frames paced.
    func selfTest() {
        // Below the collapsed island is toast territory; inside the open one is content.
        let below = NSPoint(x: layout.centerX - panel.frame.minX, y: layout.top - panel.frame.minY - layout.notch.height - 60)
        Log.info("notch: self-test hit below the island -> \(canvas.hitTest(below).map { String(describing: type(of: $0)) } ?? "nil")")
        open(.full)
        Log.info("notch: self-test hit in the open island -> \(canvas.hitTest(below).map { String(describing: type(of: $0)) } ?? "nil"); takes mouse there: \(openRectOnScreen.contains(NSPoint(x: layout.centerX, y: layout.top - layout.notch.height - 60)))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            Log.info("notch: self-test open on display \(self.displayID): \(self.drive.frameStats); shell \(Int(self.drive.shell.size.width))x\(Int(self.drive.shell.size.height))")
            self.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                Log.info("notch: self-test close: \(self.drive.frameStats); shell \(Int(self.drive.shell.size.width))x\(Int(self.drive.shell.size.height)) mounted=\(self.scene.mounted)")
            }
        }
    }

    private func cameToRest() {
        if !scene.isOpen && drive.openProgress == 0 && scene.mounted {
            scene.mounted = false
            scene.presentation = .none
        }
        canvas.apply(drive.shell, visible: isVisible)
        pointerMoved(NSEvent.mouseLocation)
    }

    // MARK: Pointer

    func pointerMoved(_ point: NSPoint) {
        let onToasts = toastRectOnScreen?.contains(point) ?? false
        if scene.isOpen {
            let open = openRectOnScreen
            panel.ignoresMouseEvents = !(open.insetBy(dx: -2, dy: -2).contains(point) || onToasts)
            guard scene.presentation == .full else { return }
            if open.insetBy(dx: -AmbientFeel.closeMargin, dy: -AmbientFeel.closeMargin).contains(point) || onToasts {
                pointerVisited = true
            } else if pointerVisited, mayAutoClose, RunLoop.current.currentMode != .eventTracking {
                // Clear of the panel: gone, with no grace period. (A menu opened from the panel is tracking:
                // the pointer is on that menu, not gone.)
                close()
            }
            return
        }

        let slop = AmbientFeel.hotSlop
        // A scroll gesture whose end never arrived (the panel stopped taking events mid-gesture) must not
        // leave the island deaf to hover.
        if scroll != nil, NSEvent.pressedMouseButtons == 0, !panel.frame.contains(point) { scroll = nil }
        let onShell = isVisible || !layout.tucked ? shellRectOnScreen.insetBy(dx: -slop, dy: -slop).contains(point) : false
        if hoverSuppressed {
            if !onShell { hoverSuppressed = false }
        } else if onShell && press == nil && scroll == nil {
            // Touching the island opens it, at once. One haptic, with the motion.
            open(.full, haptic: true)
            return
        }
        panel.ignoresMouseEvents = !(onShell || onToasts || press != nil)
    }

    /// Not while typing, and not mid-drag or mid-swipe (a row dragged past the edge is still held).
    private var mayAutoClose: Bool {
        scene.isOpen && scene.presentation == .full && press == nil && scroll == nil && scene.swipe == nil
            && NSEvent.pressedMouseButtons == 0 && !(scene.fieldFocused && !scene.field.isEmpty)
    }

    private func haptic(_ perform: () -> Void) {
        guard Date().timeIntervalSince(lastHaptic) > AmbientFeel.hapticDebounce else { return }
        lastHaptic = Date()
        perform()
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    // MARK: Events in our own windows

    /// True when the event was used up here and must not reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        // A press that began on the island owns the drag and the release, wherever they land.
        if press != nil, event.type == .leftMouseDragged { return mouseDragged(event) }
        if press != nil, event.type == .leftMouseUp { return mouseUp(event) }
        guard event.window === panel else {
            // A click in another Steward window is an outside click too.
            // …except on the menu bar item, whose click toggles the island itself.
            if event.type == .leftMouseDown && scene.isOpen && scene.presentation == .full && !(event.window is AmbientPanel)
                && event.window?.level != .statusBar { close() }
            return false
        }
        switch event.type {
        case .leftMouseDown: return mouseDown(event)
        case .leftMouseDragged: return mouseDragged(event)
        case .leftMouseUp: return mouseUp(event)
        case .scrollWheel: return scrolled(event)
        case .keyDown: return keyDown(event)
        default: return false
        }
    }

    private func mouseDown(_ event: NSEvent) -> Bool {
        let point = NSEvent.mouseLocation
        guard !scene.isOpen, shellRectOnScreen.insetBy(dx: -AmbientFeel.hotSlop, dy: -AmbientFeel.hotSlop).contains(point) else { return false }
        press = Press(start: point, last: point, lastTime: event.timestamp)
        return true
    }

    private func mouseDragged(_ event: NSEvent) -> Bool {
        guard var press else { return false }
        let point = NSEvent.mouseLocation
        let dt = event.timestamp - press.lastTime
        if dt > 0 { press.velocity = (press.last.y - point.y) / CGFloat(dt) }
        press.last = point
        press.lastTime = event.timestamp
        let travel = press.start.y - point.y
        if !press.dragging && travel > AmbientFeel.dragSlop { press.dragging = true }
        if press.dragging && !press.committed {
            if travel >= AmbientFeel.pullCommit {
                press.committed = true
                commitPull(velocity: press.velocity)
            } else {
                drive.track(pull: RubberBand.offset(max(0, travel), dimension: AmbientFeel.pullLimit))
            }
        }
        self.press = press
        return true
    }

    private func mouseUp(_ event: NSEvent) -> Bool {
        guard let press else { return false }
        self.press = nil
        if press.committed { return true }
        if !press.dragging {
            open(.full, haptic: true)
        } else if press.velocity >= AmbientFeel.pullFlick {
            commitPull(velocity: press.velocity)
        } else {
            drive.releasePull(committed: false, velocity: Double(-press.velocity) * 0.2)
            pointerMoved(NSEvent.mouseLocation)
        }
        return true
    }

    /// The pull lets go: the open spring takes over with the finger's speed.
    private func commitPull(velocity: CGFloat) {
        let travel = max(120, bodySize(for: .full).height - layout.notch.height)
        drive.releasePull(committed: true)
        open(.full, haptic: true, velocity: Double(max(0, velocity) / travel))
    }

    private func scrolled(_ event: NSEvent) -> Bool {
        // Momentum after the fingers lift is not the user asking for anything; after a gesture the island
        // used itself, it must not leak into a list underneath either.
        if !event.momentumPhase.isEmpty {
            let swallow = swallowMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return swallow
        }
        let natural: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let down = event.scrollingDeltaY * natural, right = event.scrollingDeltaX * natural

        if event.phase.isEmpty {
            // A clicky wheel has no gesture phases: one notch down on the island opens it.
            if !scene.isOpen && down > 0 { open(.full, haptic: true) }
            return !scene.isOpen
        }
        if event.phase.contains(.began) || scroll == nil {
            scroll = Scroll(lastTime: event.timestamp)
            swallowMomentum = false
        }
        guard var gesture = scroll else { return false }

        if case .undecided = gesture.axis, abs(down) + abs(right) > 0 {
            if abs(right) > abs(down) {
                if let id = ambient.toasts.hoveredID { gesture.axis = .toast(id) }
                else if case .task? = scene.hovered, scene.isOpen { gesture.axis = .row(scene.hovered!) }
                else { gesture.axis = .passthrough }
            } else {
                let overToast = ambient.toasts.hoveredID != nil
                gesture.axis = (scene.isOpen && (scene.overScroller || scene.presentation != .full)) || overToast ? .passthrough : .pull
            }
        }

        let dt = event.timestamp - gesture.lastTime
        gesture.lastTime = event.timestamp
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)

        switch gesture.axis {
        case .undecided, .passthrough:
            scroll = ended ? nil : gesture
            return false
        case .pull:
            // Down opens a collapsed island; up closes an open one. Same rubber band both ways.
            let sign: CGFloat = scene.isOpen ? -1 : 1
            gesture.total += down * sign
            if dt > 0 { gesture.velocity = down * sign / CGFloat(dt) }
            if !gesture.committed {
                if gesture.total >= AmbientFeel.pullCommit {
                    gesture.committed = true
                    if scene.isOpen {
                        drive.releasePull(committed: true)
                        haptic(Haptics.thunk)
                        close()
                    } else {
                        commitPull(velocity: gesture.velocity)
                    }
                } else if ended {
                    drive.releasePull(committed: false)
                } else {
                    drive.track(pull: sign * RubberBand.offset(max(0, gesture.total), dimension: AmbientFeel.pullLimit))
                }
            }
        case .row(let item):
            gesture.total += right
            let armed = abs(gesture.total) >= AmbientFeel.swipeCommit
            if armed != gesture.armed { haptic(Haptics.tick) }
            gesture.armed = armed
            if ended {
                withAnimation(Motion.bounce) { scene.swipe = nil }
                if armed, case .task(let id) = item, let task = ambient.model.next.first(where: { $0.id == id }) {
                    NotchSwipe.commit(task, right: gesture.total > 0, actions: scene.actions)
                }
            } else {
                scene.swipe = (item, RubberBand.offset(gesture.total, dimension: AmbientFeel.swipeLimit, coefficient: 0.9))
            }
        case .toast(let id):
            gesture.total += right
            if ended {
                if abs(gesture.total) >= AmbientFeel.swipeCommit {
                    haptic(Haptics.tick)
                    ambient.toasts.userDismiss(id)
                } else {
                    withAnimation(Motion.bounce) { ambient.toasts.swipe = nil }
                }
            } else {
                ambient.toasts.swipe = (id, gesture.total)
            }
        }
        scroll = ended ? nil : gesture
        if ended {
            swallowMomentum = true
            pointerMoved(NSEvent.mouseLocation)
        }
        return true
    }

    // MARK: Keyboard (only when the panel is key: after the hotkey or a click inside)

    private func keyDown(_ event: NSEvent) -> Bool {
        guard scene.isOpen, scene.presentation == .full else { return false }
        // A text view handles its own keys and calls back for the ones that leave it.
        if panel.firstResponder is NSTextView { return false }
        switch Int(event.keyCode) {
        case 53:
            close()
        case 125:
            moveSelection(1)
        case 126:
            moveSelection(-1)
        case 48:
            moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76:
            if event.modifierFlags.contains(.command) { submitField(modifiers: event.modifierFlags) } else { actOnSelection() }
        default:
            // Typing anywhere in the panel starts a capture: hand the key to the field.
            let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
            // 0xF700 and up are AppKit's function-key code points (arrows, F-keys).
            let typed = scalar.map { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 } ?? false
            if typed, event.modifierFlags.intersection([.command, .control]).isEmpty, let field = canvas.contentTextView() {
                scene.selection = .field
                panel.makeFirstResponder(field)
            }
            return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        let items = scene.items(in: ambient.model)
        guard !items.isEmpty else { return }
        let current = scene.selection.flatMap(items.firstIndex) ?? (step > 0 ? -1 : 0)
        let next = items[(current + step + items.count) % items.count]
        scene.selection = next
        haptic(Haptics.tick)
        if next == .field {
            scene.focusField += 1
        } else if panel.firstResponder is NSTextView {
            panel.makeFirstResponder(nil)
        }
    }

    private func actOnSelection() {
        let model = ambient.model
        switch scene.selection {
        case .approval:
            // Return never approves: approving takes a click on the button. It opens the full card instead.
            scene.actions.openMain(.inbox)
        case .question:
            scene.actions.openMain(.agent)
        case .now:
            if let task = model.now { Haptics.success(); scene.actions.complete(task) }
        case .task(let id):
            if let task = model.next.first(where: { $0.id == id }) { scene.actions.start(task) }
        case .session(let id):
            if let session = model.sessions.first(where: { $0.id == id }) { scene.actions.focus(session) }
        case .meeting:
            if let meeting = model.meeting { scene.actions.join(meeting) }
        case .field, nil:
            break
        }
    }

    private func submitField(modifiers: NSEvent.ModifierFlags) {
        let text = scene.field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let draft = CaptureDraft.parse(text)
        scene.field = ""
        if modifiers.contains(.command) || draft.forceAgent {
            scene.actions.ask(draft.forceAgent ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text)
        } else {
            scene.actions.capture(text, .notch)
            Haptics.success()
            drive.kick(6)
        }
    }
}
