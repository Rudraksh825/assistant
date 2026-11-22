import AppKit
import StewardKit

/// An ambient piece of UI with its own windows (notch, HUD, toasts…). Each lives in its own folder
/// under `Surfaces/` and is listed once in `SurfaceRegistry.all`.
@MainActor
protocol Surface: AnyObject {
    /// Create windows, subscribe to `app.store` / `app.store.onEvent`, register hotkeys with `app.hotkeys.on`.
    func start(app: AppContext)
    /// Tear everything down; called on quit.
    func stop()
}

@MainActor
final class SurfaceRegistry {
    /// What the ambient surfaces share (sliced model, toast stack, voice state).
    private let ambient = AmbientState()
    /// The only place surfaces are wired in. Order is start order.
    let all: [Surface]

    init() {
        all = [
            MenuBarSurface(),
            NotchSurface(ambient: ambient),
            HUDSurface(ambient: ambient),
            CaptureSurface(ambient: ambient),
            ChatSurface(ambient: ambient),
            VoiceSurface(ambient: ambient),
            ToastSurface(ambient: ambient),
        ]
    }

    func startAll(app: AppContext) {
        ambient.model.bind(to: app.store)
        ambient.actions = AmbientActions(app: app, ambient: ambient)
        for surface in all { surface.start(app: app) }
    }

    func stopAll() {
        for surface in all { surface.stop() }
    }
}
