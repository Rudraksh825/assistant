import AppKit
import StewardKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppContext!
    private var surfaces: SurfaceRegistry!
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let relaunched = CommandLine.arguments.contains("--relaunched")
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()

        app = AppContext()
        Log.setup(app.store.client.dataDir)
        Log.info("launch pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") home=\(app.store.client.dataDir.url.path)")
        BrainJSON.onDroppedElement = { Log.error("dropped undecodable element: \($0)") }

        var wasOnline = false
        app.store.onEvent { [app] event in
            switch event {
            case .uiCommand(let command): app?.handle(command)
            case .appRelaunch(let reason): Relauncher.relaunch(reason: reason)
            default: break
            }
        }
        watch { [app] in app!.store.connection } onChange: { [app] connection in
            if connection.isOnline != wasOnline {
                wasOnline = connection.isOnline
                Log.info(connection.isOnline ? "connected to brain" : "brain connection lost: \(connection)")
            }
            if connection.isOnline { app?.activity.flush() }
        }
        watch { [app] in app!.store.snapshot != nil } onChange: { [app] loaded in
            guard loaded, let s = app?.store.snapshot else { return }
            Log.info("state loaded: top=\(s.top.count) sessions=\(s.sessions.count) nudges=\(s.nudges.count)")
        }
        watch { [app] in app!.store.settings["hotkeys"] } onChange: { [app] hotkeys in
            app?.hotkeys.apply(hotkeys.object?.compactMapValues(\.string) ?? [:])
        }

        app.supervisor.start()
        app.store.start()
        app.activity.start()
        app.systemEvents.start()
        surfaces = SurfaceRegistry()
        surfaces.startAll(app: app)

        // SIGTERM/SIGINT skip applicationWillTerminate by default, which would orphan the brain.
        // Not NSApp.terminate: AppKit refuses it while any window has a sheet up.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signals.append(source)
        }

        if !relaunched {
            app.showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
            app.showMainWindow(activate: false)
        }
        DevSnapshot.runIfRequested(app: app)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app.showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        Log.info("quit")
        surfaces.stopAll()
        app.activity.stop()
        app.supervisor.stop()
        Log.flush()
    }
}

/// Calls `onChange` now and again whenever the observed value changes.
@MainActor
func watch<T: Equatable>(_ value: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
    var last: T?
    @MainActor func track() {
        let current = withObservationTracking(value) {
            Task { @MainActor in track() }
        }
        if current != last {
            last = current
            onChange(current)
        }
    }
    track()
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        add("Steward", [
            item("About Steward", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Steward", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Steward", #selector(NSApplication.terminate(_:)), "q"),
        ])
        // Without an Edit menu, text fields get no cut/copy/paste/undo shortcuts.
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}
