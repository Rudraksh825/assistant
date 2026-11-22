import AppKit
import SwiftUI
import StewardKit

/// Development aid for machines without Xcode previews or screen-recording permission: with
/// `STEWARD_SNAPSHOT_DIR=/some/dir` the app writes a PNG of every screen and the onboarding card
/// a few seconds after launch (`STEWARD_SNAPSHOT_DELAY` seconds, default 6).
/// Views are rendered offscreen, outside the real windows: glass and vibrancy come out flat, and
/// window chrome (sidebar, popover) is not captured. Layout, type and colour are faithful.
@MainActor
enum DevSnapshot {
    static func runIfRequested(app: AppContext) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["STEWARD_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(Double(env["STEWARD_SNAPSHOT_DELAY"] ?? "") ?? 6))
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Screens read the main window's UI state from the environment; live data here, a throwaway model.
            let model = MainWindowModel(app: app)
            var views: [(String, NSView)] = Route.allCases.map { route in
                (route.rawValue, offscreen(route.screen.frame(width: 900, height: 680).background(Palette.bg).environment(app.store).environment(app).environment(model)))
            }
            views.append(("onboarding", offscreen(OnboardingView {}.environment(app.store).environment(app))))
            views += AmbientSnapshots.views()
            // Give `.task`/`.onAppear` loads a moment to land before capturing.
            try? await Task.sleep(for: .seconds(1))
            for (name, view) in views { write(view, to: "\(dir)/\(name).png") }
            Log.info("snapshots written to \(dir)")
        }
    }

    /// Hosts any view in an offscreen window so it can be passed to `write`.
    static func offscreen(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func write(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
