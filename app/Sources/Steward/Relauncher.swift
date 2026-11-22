import AppKit

/// Restarts the app from its bundle (after a self-rebuild). If the new build does not stay up,
/// the previous bundle kept by `scripts/build.sh` is opened instead.
@MainActor
enum Relauncher {
    static func relaunch(reason: String) {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else {
            Log.info("relaunch requested (\(reason)) but not running from a bundle; ignoring")
            return
        }
        Log.info("relaunching: \(reason)")
        let previous = (bundle as NSString).deletingLastPathComponent + "/Steward.prev.app"
        // `open` does not pass our environment on, so a custom data dir has to be handed over explicitly.
        let env = ProcessInfo.processInfo.environment["STEWARD_HOME"].map { "--env STEWARD_HOME='\($0)'" } ?? ""
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
        open -g \(env) "$1" --args --relaunched
        sleep 8
        pgrep -f "$1/Contents/MacOS/" >/dev/null || { [ -d "$2" ] && open -g \(env) "$2" --args --relaunched; }
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", bundle, previous]
        do { try helper.run() } catch {
            Log.error("relaunch helper failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
}
