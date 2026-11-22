import AppKit
import SwiftUI
import StewardKit

@MainActor
final class MainWindowController: NSObject {
    private let window: NSWindow
    let model: MainWindowModel
    private var monitor: Any?

    init(app: AppContext) {
        model = MainWindowModel(app: app)
        // Where the user left off: the route here, the sidebar width and chat thread in their own defaults keys.
        if let saved = UserDefaults.standard.string(forKey: "main.route"), let route = Route(rawValue: saved) { app.route = route }
        if let style = UserDefaults.standard.string(forKey: "ui.materialStyle").flatMap(MaterialStyle.init) { DesignSettings.shared.materialStyle = style }
        DesignSettings.shared.reduceMotion = UserDefaults.standard.bool(forKey: "ui.reduceMotion")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Steward"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 560)
        window.backgroundColor = NSColor(Palette.bg)
        window.contentViewController = NSHostingController(rootView: RootView().environment(app.store).environment(app).environment(model))
        window.setContentSize(NSSize(width: 1220, height: 780))
        window.center()
        window.setFrameAutosaveName("StewardMainWindow")
        super.init()

        watch { app.route } onChange: { UserDefaults.standard.set($0.rawValue, forKey: "main.route") }
        watch { app.store.connection.isOnline ? app.store.lastError : nil } onChange: { if let error = $0 { Log.error("store: \(error)") } }
        BrainProbe.runIfRequested(app: app)
        // One key path for the whole window: global shortcuts first, then the visible screen's single-key actions.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, let stroke = KeyStroke(event) else { return event }
            let editing = self.window.firstResponder is NSTextView
            let used = self.model.handle(stroke, editingText: editing) { self.window.makeFirstResponder(nil) }
            return used ? nil : event
        }
    }

    /// `activate: false` is for launch: a normal launch is already frontmost, and a background one must stay there.
    func show(activate: Bool = true) {
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }
}
