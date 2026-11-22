import AppKit

// A second copy (direct exec, `open -n`) hands over to the running one instead of fighting for the hotkeys and the brain.
if let id = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
    other.activate()
    exit(0)
}

MainActor.assumeIsolated {
    // Dev aid: render the main window against sample data and exit, without starting the app proper.
    if MainWindowSnapshots.requested { MainWindowSnapshots.runHeadless() }
    AmbientSnapshots.runStandaloneIfRequested()
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
