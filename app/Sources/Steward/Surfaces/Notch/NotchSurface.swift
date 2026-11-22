import AppKit
import StewardKit

/// The notch island: one panel over the hardware notch, plus a virtual notch at the top-centre of every
/// other display when `ui.notchOnAllDisplays` is on. Hotkey name: "notch".
@MainActor
final class NotchSurface: Surface {
    private let ambient: AmbientState
    private var controllers: [CGDirectDisplayID: NotchPanelController] = [:]
    private var toastActions = ToastActions()
    private var pointer: PointerWatch?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var allDisplays = true
    private var started = false
    private var indicatorTimer: DispatchWorkItem?

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        toastActions = ToastActions(app: app)
        started = true

        watch { app.store.settings["ui"]["notchOnAllDisplays"].bool ?? true } onChange: { [weak self] in
            self?.allDisplays = $0
            self?.rebuild(reason: "settings")
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuild(reason: "displays changed") }
        // Entering or leaving a full-screen space changes whether a virtual notch has a menu bar to hang from.
        // The screen's visible frame settles a moment after the notification.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { surface in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { surface.rebuild(reason: "space changed") }
        }
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked")) { surface in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { surface.rebuild(reason: "unlocked") }
        }

        pointer = PointerWatch { [weak self] point in
            guard let self else { return }
            for controller in self.controllers.values { controller.pointerMoved(point) }
        }
        app.hotkeys.on("notch") { [weak self] phase in
            if phase == .down { self?.active()?.toggle() }
        }

        ambient.toasts.chooseDisplay = { [weak self] in self?.active()?.displayID }
        ambient.notice = { [weak self] icon, text in self?.active()?.notice(icon: icon, text: text) }
        ambient.presentVoice = { [weak self] listening in
            guard let self else { return }
            if listening { self.active()?.setVoice(true) } else { self.controllers.values.forEach { $0.setVoice(false) } }
        }

        let model = ambient.model, voice = ambient.voice
        watch { [model.approvals.count + model.questions.count, model.agentBusy ? 1 : 0, model.meetingLive ? 1 : 0, voice.listening ? 1 : 0] } onChange: { [weak self] _ in
            self?.updateIndicator()
        }
        watch { model.meeting?.startAt } onChange: { [weak self] _ in self?.updateIndicator() }
        watch { [model.sessionStates.count, Int(model.indicator.earWidth)] } onChange: { [weak self] _ in
            self?.controllers.values.forEach { $0.updateEars() }
        }
        var seen: Set<String> = []
        watch { [ambient] in ambient.toasts.items.map(\.id) } onChange: { [weak self] ids in
            let arrived = !Set(ids).isSubset(of: seen)
            seen = Set(ids)
            self?.controllers.values.forEach { $0.toastsChanged(arrived: arrived) }
        }

        if ProcessInfo.processInfo.environment["STEWARD_AMBIENT_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                // On a display the pointer is not on, to stay out of the way.
                let away = self?.controllers.values.first { $0.displayID != NSScreen.underMouse?.displayID }
                (away ?? self?.active())?.selfTest()
            }
        }
    }

    func stop() {
        pointer?.stop()
        indicatorTimer?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        controllers.values.forEach { $0.teardown() }
        controllers = [:]
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (NotchSurface) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        observers.append((center, token))
    }

    /// The island the user is nearest to: the display under the pointer, else the one with the real notch.
    private func active() -> NotchPanelController? {
        if let id = NSScreen.underMouse?.displayID, let controller = controllers[id] { return controller }
        return controllers.values.first { $0.layout.hasNotch } ?? controllers.values.first
    }

    /// Brings the set of panels in line with the displays that exist now. Unchanged displays keep their panel.
    private func rebuild(reason: String) {
        guard started else { return }
        let screens = NSScreen.screens
        let reference = screens.compactMap { $0.metrics.notchRect?.size }.first
        let thickness = NSStatusBar.system.thickness
        var wanted: [(NSScreen, NotchLayout)] = screens.compactMap { screen in
            let layout = NotchLayout(screen: screen.metrics, reference: reference, statusBarThickness: thickness)
            return layout.hasNotch || allDisplays ? (screen, layout) : nil
        }
        // Lid closed with the setting off would leave nowhere for toasts and the hotkey to land.
        if wanted.isEmpty, let main = NSScreen.main ?? screens.first {
            wanted = [(main, NotchLayout(screen: main.metrics, reference: reference, statusBarThickness: thickness))]
        }

        let ids = Set(wanted.map { $0.0.displayID })
        for (id, controller) in controllers where !ids.contains(id) {
            controller.teardown()
            controllers[id] = nil
            Log.info("notch: removed panel for display \(id) (\(reason))")
        }
        for (screen, layout) in wanted {
            let id = screen.displayID
            if let existing = controllers[id] {
                if existing.layout == layout { continue }
                existing.teardown()
            }
            let controller = NotchPanelController(screen: screen, layout: layout, ambient: ambient, toastActions: toastActions)
            controllers[id] = controller
            let frame = controller.panel.frame
            Log.info("notch: panel on display \(id) \"\(screen.localizedName)\" \(layout.hasNotch ? "hardware notch" : layout.tucked ? "virtual notch, tucked" : "virtual notch") "
                + "\(Int(layout.notch.width))x\(Int(layout.notch.height)) at x=\(layout.centerX) top=\(layout.top); "
                + "canvas (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) (\(reason))")
        }
    }

    private func updateIndicator() {
        let model = ambient.model
        let indicator = NotchIndicator.pick(
            listening: ambient.voice.listening, decisions: model.approvals.count + model.questions.count,
            meetingStart: model.meeting?.startAt, meetingLive: model.meetingLive, agentBusy: model.agentBusy)
        if indicator != model.indicator { model.indicator = indicator }

        // One wake-up for the moment the next meeting comes within range; nothing polls.
        indicatorTimer?.cancel()
        guard let start = model.meeting?.startAt, !model.meetingLive else { return }
        let wait = start.timeIntervalSinceNow - NotchIndicator.meetingLead
        guard wait > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.updateIndicator() }
        indicatorTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.5, execute: work)
    }
}
