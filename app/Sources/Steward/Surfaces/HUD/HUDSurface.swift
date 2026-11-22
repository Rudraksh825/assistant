import AppKit
import SwiftUI
import StewardKit

/// The floating HUD: always on top, on any display, never activating. Drag it by its top row; edges
/// and the centre line hold it like a magnet. Remembers where it sat for each display arrangement.
/// Hotkey name: "hud" (toggles it).
@MainActor
final class HUDSurface: Surface {
    private let ambient: AmbientState
    private let scene = HUDScene()
    private var panel: AmbientPanel?
    private weak var app: AppContext?
    private var pointer: PointerWatch?
    private var handler: UUID?
    private var screenObserver: NSObjectProtocol?

    /// Where the pill sits, in global coordinates. The card hangs from the same top-centre point.
    private var pillFrame = CGRect(origin: .zero, size: HUDMetrics.pill)
    private var contentSize = HUDMetrics.pill
    private var displayPreference = "auto"
    private var drag: (mouse: NSPoint, origin: CGPoint, snapped: (x: Bool, y: Bool))?

    // The window glides when the card has to slide back onto the screen, instead of jumping.
    private var originX = SpringValue(0, spec: AmbientFeel.track, epsilon: 0.2)
    private var originY = SpringValue(0, spec: AmbientFeel.track, epsilon: 0.2)
    private let ticker = FrameTicker()

    // Scratchpad autosave.
    private var noteId: String?
    private var liveBody = ""
    private var saveTask: Task<Void, Never>?
    private var showingOther = false

    private static let visibleKey = "hud.visible", cardKey = "hud.card"

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        self.app = app
        scene.actions = ambient.actions
        scene.card = UserDefaults.standard.bool(forKey: Self.cardKey)
        scene.toggleSize = { [weak self] in self?.toggleSize() }
        scene.dragChanged = { [weak self] in self?.dragChanged() }
        scene.dragEnded = { [weak self] in self?.dragEnded() }
        scene.noteEdited = { [weak self] in self?.noteEdited() }
        scene.backToLiveNote = { [weak self] in self?.adoptLiveNote(force: true) }
        scene.onSize = { [weak self] size in
            guard let self, size != self.contentSize else { return }
            self.contentSize = size
            self.place(animated: true)
        }
        ticker.onFrame = { [weak self] dt in self?.step(dt) ?? false }

        app.hotkeys.on("hud") { [weak self] phase in
            guard phase == .down, let self else { return }
            self.setVisible(self.panel?.isVisible != true)
        }
        handler = app.store.onEvent { [weak self] event in
            if case .uiCommand(let command) = event, command.command == .showNote, let id = command.args?["noteId"].string {
                self?.show(noteId: id)
            }
        }
        watch { [ambient] in ambient.model.liveNote } onChange: { [weak self] _ in self?.adoptLiveNote(force: false) }
        watch { app.store.settings["ui"]["hudDisplay"].string ?? "auto" } onChange: { [weak self] in
            self?.displayPreference = $0
            self?.restorePlacement()
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePlacement() }
        }

        restorePlacement()
        let visible = UserDefaults.standard.bool(forKey: Self.visibleKey)
        Log.info("hud: started, \(visible ? "visible" : "hidden") \(scene.card ? "card" : "pill") at (\(Int(pillFrame.minX)),\(Int(pillFrame.minY)),\(Int(pillFrame.width)),\(Int(pillFrame.height))) "
            + "arrangement \(arrangementKey)")
        if visible { setVisible(true) }

        // Dev aid: show, grow to the card, shrink, and go back to how it was, logging each frame on the way.
        if ProcessInfo.processInfo.environment["STEWARD_AMBIENT_SELFTEST"] == "1" {
            let steps: [(TimeInterval, @MainActor () -> Void)] = [
                (9, { [weak self] in self?.setVisible(true); self?.logSelfTest("shown") }),
                (9.6, { [weak self] in self?.toggleSize() }),
                (10.6, { [weak self] in self?.logSelfTest("resized"); self?.toggleSize() }),
                (11.4, { [weak self] in self?.logSelfTest("restored"); self?.setVisible(visible) }),
            ]
            for (delay, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() } }
        }
    }

    private func logSelfTest(_ what: String) {
        let frame = contentFrame
        Log.info("hud: self-test \(what): \(scene.card ? "card" : "pill") (\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))) "
            + "window \(panel.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "none") ignoresMouse=\(panel?.ignoresMouseEvents ?? true)")
    }

    func stop() {
        flushNote()
        pointer?.stop()
        ticker.invalidate()
        if let handler { app?.store.removeHandler(handler) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel?.orderOut(nil)
    }

    // MARK: Visibility

    private func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
        guard visible else {
            flushNote()
            pointer?.stop()
            pointer = nil
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(animated: false)
        panel.orderFrontRegardless()
        ticker.attach(to: panel.contentView!)
        // The transparent margin must never take a click, so the panel only listens while the pointer is on the HUD itself.
        pointer = pointer ?? PointerWatch { [weak self] point in self?.pointerMoved(point) }
        pointerMoved(NSEvent.mouseLocation)
    }

    private func makePanel() -> AmbientPanel {
        let panel = AmbientPanel(frame: NSRect(origin: .zero, size: HUDMetrics.canvas), level: .floating)
        panel.ignoresMouseEvents = true
        panel.contentView = AmbientHostingView(rootView: HUDView(scene: scene, model: ambient.model))
        return panel
    }

    private func pointerMoved(_ point: NSPoint) {
        guard let panel, panel.isVisible else { return }
        let inside = drag != nil || contentFrame.insetBy(dx: -2, dy: -2).contains(point)
        panel.ignoresMouseEvents = !inside
        if scene.hovered != inside { scene.hovered = inside }
    }

    // MARK: Geometry

    private var arrangementKey: String {
        HUDGeometry.arrangementKey(NSScreen.screens.map { ($0.displayID, $0.frame) })
    }

    /// `ui.hudDisplay`: "auto" (where it was left), "builtin", "main", a display id, or part of a display's name.
    private func preferredScreen(remembered: CGDirectDisplayID?) -> NSScreen {
        let screens = NSScreen.screens
        let fallback = NSScreen.with(remembered) ?? NSScreen.main ?? screens[0]
        switch displayPreference.lowercased() {
        case "auto", "": return fallback
        case "builtin", "built-in": return screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? fallback
        case "main": return NSScreen.main ?? fallback
        case let other:
            return screens.first { String($0.displayID) == other || $0.localizedName.lowercased().contains(other) } ?? fallback
        }
    }

    private func restorePlacement() {
        guard !NSScreen.screens.isEmpty else { return }
        let stored = UserDefaults.standard.data(forKey: "hud.placement.\(arrangementKey)").flatMap { try? JSONDecoder().decode(HUDGeometry.Placement.self, from: $0) }
        let screen = preferredScreen(remembered: stored?.display)
        let placement = stored ?? .initial(display: screen.displayID, size: HUDMetrics.pill, visible: screen.visibleFrame)
        pillFrame = CGRect(origin: placement.origin(size: HUDMetrics.pill, visible: screen.visibleFrame), size: HUDMetrics.pill)
        place(animated: false)
    }

    private func savePlacement() {
        guard let screen = screen(for: pillFrame) else { return }
        let placement = HUDGeometry.Placement(display: screen.displayID, frame: pillFrame, visible: screen.visibleFrame)
        if let data = try? JSONEncoder().encode(placement) { UserDefaults.standard.set(data, forKey: "hud.placement.\(arrangementKey)") }
    }

    private func screen(for frame: CGRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }

    /// What is actually drawn: the pill, or the card hanging from the pill's top-centre, nudged back onto the screen if it would overflow.
    private var contentFrame: CGRect {
        var frame = CGRect(x: pillFrame.midX - contentSize.width / 2, y: pillFrame.maxY - contentSize.height, width: contentSize.width, height: contentSize.height)
        if let visible = screen(for: pillFrame)?.visibleFrame.insetBy(dx: AmbientFeel.hudInset, dy: AmbientFeel.hudInset), visible.width > frame.width, visible.height > frame.height {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    private func place(animated: Bool) {
        guard let panel else { return }
        let content = contentFrame
        let origin = CGPoint(x: content.midX - HUDMetrics.canvas.width / 2, y: content.maxY + HUDMetrics.margin - HUDMetrics.canvas.height)
        if animated && panel.isVisible && drag == nil {
            if originX.isSettled && originY.isSettled {
                originX.set(panel.frame.minX)
                originY.set(panel.frame.minY)
            }
            originX.retarget(origin.x)
            originY.retarget(origin.y)
            ticker.start()
        } else {
            originX.set(origin.x)
            originY.set(origin.y)
            panel.setFrameOrigin(origin)
        }
    }

    private func step(_ dt: TimeInterval) -> Bool {
        originX.step(dt)
        originY.step(dt)
        panel?.setFrameOrigin(NSPoint(x: originX.value, y: originY.value))
        return !(originX.isSettled && originY.isSettled)
    }

    // MARK: Size and dragging

    private func toggleSize() {
        scene.card.toggle()
        UserDefaults.standard.set(scene.card, forKey: Self.cardKey)
        Haptics.tick()
        if scene.card { adoptLiveNote(force: false) } else { flushNote() }
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if drag == nil { drag = (mouse, contentFrame.origin, (false, false)) }
        guard var drag else { return }
        let raw = CGRect(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y, width: contentSize.width, height: contentSize.height)
        guard let visible = screen(for: raw)?.visibleFrame else { return }
        let snap = HUDGeometry.snap(raw, in: visible, was: drag.snapped)
        // The detent is felt at the moment an edge takes hold, not while it holds.
        if (snap.x && !drag.snapped.x) || (snap.y && !drag.snapped.y) { Haptics.tick() }
        drag.snapped = (snap.x, snap.y)
        self.drag = drag
        pillFrame = CGRect(x: snap.origin.x + (contentSize.width - HUDMetrics.pill.width) / 2, y: snap.origin.y + contentSize.height - HUDMetrics.pill.height,
                           width: HUDMetrics.pill.width, height: HUDMetrics.pill.height)
        place(animated: false)
    }

    private func dragEnded() {
        guard drag != nil else { return }
        drag = nil
        savePlacement()
        pointerMoved(NSEvent.mouseLocation)
    }

    // MARK: Scratchpad

    /// Takes the brain's live note as the scratchpad text, unless the user has unsaved typing in it.
    private func adoptLiveNote(force: Bool) {
        if force {
            flushNote()
            showingOther = false
            scene.noteTitle = nil
        }
        guard !showingOther, scene.saving != .pending else { return }
        let live = ambient.model.liveNote
        noteId = live?.id
        liveBody = live?.body ?? ""
        if scene.note != liveBody { scene.note = liveBody }
    }

    private func show(noteId id: String) {
        guard let app else { return }
        Task {
            guard let note = try? await app.store.client.note(id) else { return }
            flushNote()
            showingOther = note.id != ambient.model.liveNote?.id
            noteId = note.id
            liveBody = note.body
            scene.note = note.body
            scene.noteTitle = showingOther ? (note.title.isEmpty ? "Note" : note.title) : nil
            if !scene.card { toggleSize() }
            setVisible(true)
        }
    }

    private func noteEdited() {
        guard scene.note != liveBody else { return }
        scene.saving = .pending
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func flushNote() {
        guard scene.saving == .pending else { return }
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        guard let app else { return }
        let body = scene.note
        do {
            if let noteId {
                _ = try await app.store.client.updateNote(noteId, ["body": .string(body)])
            } else {
                noteId = try await app.store.client.createNote(["kind": "live", "title": "Live note", "body": .string(body)]).id
            }
            liveBody = body
            if scene.note == body { scene.saving = .saved }
        } catch {
            Log.error("hud: saving the note failed: \(error)")
        }
    }
}
