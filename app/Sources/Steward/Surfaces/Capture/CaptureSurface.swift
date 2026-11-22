import AppKit
import SwiftUI
import StewardKit

/// Quick capture: a Spotlight-style panel on the display under the pointer. ↩ captures; ⌘↩ (or a
/// leading `>`) hands the text to the chat window. Hotkey name: "capture".
@MainActor
final class CaptureSurface: Surface {
    private let ambient: AmbientState
    private let scene = CaptureScene()
    private var panel: AmbientPanel?
    private weak var app: AppContext?
    private var outsideMonitors: [Any] = []
    private var hiding: DispatchWorkItem?
    /// Text in the field before dictation started; partial transcripts are appended to it.
    private var dictationBase: String?

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        self.app = app
        let scene = scene

        scene.submit = { [weak self] in self?.submit(modifiers: $0) }
        scene.dismiss = { [weak self] in self?.hide() }

        app.hotkeys.on("capture") { [weak self] phase in
            guard phase == .down, let self else { return }
            if self.scene.shown { self.hide() } else { self.show() }
        }
        ambient.captureIsOpen = { [weak self] in self?.scene.shown == true }
        ambient.dictateIntoCapture = { [weak self] text, final in
            guard let self else { return }
            let base = self.dictationBase ?? self.scene.text
            self.dictationBase = final ? nil : base
            self.scene.text = base.isEmpty ? text : "\(base) \(text)"
        }
        Log.info("capture: started")

        // Dev aid: lay the panel out for a second on a display the pointer is not on, without taking the keyboard.
        if ProcessInfo.processInfo.environment["STEWARD_AMBIENT_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) { [weak self] in
                self?.show(on: NSScreen.screens.first { $0 != NSScreen.underMouse }, takeKey: false)
                self?.scene.text = "!! self-test #sample"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.hide() }
            }
        }
    }

    func stop() {
        removeOutsideMonitors()
        panel?.orderOut(nil)
    }

    // MARK: Showing and hiding

    private func makePanel(_ app: AppContext) -> AmbientPanel {
        let panel = AmbientPanel(frame: NSRect(origin: .zero, size: CaptureMetrics.canvas), level: .floating)
        panel.contentView = AmbientHostingView(rootView: CapturePanel(scene: scene, voice: ambient.voice))
        return panel
    }

    private func show(on override: NSScreen? = nil, takeKey: Bool = true) {
        guard let app else { return }
        hiding?.cancel()
        let panel = panel ?? makePanel(app)
        self.panel = panel

        // Context is what the user was looking at when they pressed the hotkey; read it before the panel takes the keyboard.
        scene.context = ambient.captureContext(app)
        scene.sessionName = ambient.model.sessions.first { $0.id == scene.context.sessionId }?.displayName
        scene.phase = .writing

        guard let screen = override ?? NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame, size = CaptureMetrics.canvas
        // The field sits a little above centre, like Spotlight; the canvas hangs down from there.
        let top = visible.maxY - visible.height * 0.22 + CaptureMetrics.margin
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height), display: false)
        if takeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        scene.focus += 1
        scene.shown = true
        installOutsideMonitors()
        Log.info("capture: shown on display \(screen.displayID) at (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
    }

    private func hide(after delay: TimeInterval = 0) {
        guard scene.shown || delay > 0 else { return }
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scene.shown = false
            self.removeOutsideMonitors()
            self.dictationBase = nil
            // Giving the keyboard back at once matters more than the last frames of the fade.
            self.panel?.yieldKey(keepVisible: true)
            let out = DispatchWorkItem { [weak self] in
                guard let self, !self.scene.shown else { return }
                self.panel?.orderOut(nil)
                self.scene.text = ""
            }
            self.hiding = out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: out)
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func installOutsideMonitors() {
        guard outsideMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { outsideMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // Outside: another Steward window, or the transparent margin of this one.
                let card = NSRect(x: CaptureMetrics.margin, y: 0, width: CaptureMetrics.width, height: panel.frame.height - CaptureMetrics.margin)
                if event.window !== panel || !card.contains(event.locationInWindow) { self.hide() }
            }
            return event
        }) { outsideMonitors.append(local) }
    }

    private func removeOutsideMonitors() {
        outsideMonitors.forEach(NSEvent.removeMonitor)
        outsideMonitors = []
    }

    // MARK: Sending

    private func submit(modifiers: NSEvent.ModifierFlags) {
        guard let app else { return }
        let text = scene.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let draft = CaptureDraft.parse(text)
        if modifiers.contains(.command) || draft.forceAgent {
            hide()
            ambient.ask(draft.forceAgent ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text, false)
        } else {
            app.store.capture(text, source: .hotkey, context: scene.context)
            Haptics.success()
            scene.phase = .captured
            hide(after: 0.55)
        }
    }
}
