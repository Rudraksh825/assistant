import AppKit
import ApplicationServices

/// Brings the editor or terminal window that already shows a directory to the front. It never opens a
/// new window: when nothing on screen holds the directory, the answer is `.notFound`.
@MainActor
final class WindowFocuser {
    enum Result: Equatable {
        /// Found the window by title and raised it.
        case raised(app: String)
        /// No Accessibility: asked the editor for a folder it already has open, which focuses that window.
        case opened(app: String)
        case notFound
    }

    private static let editors = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4", "com.vscodium",
    ]
    private static let terminals = [
        "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "org.alacritty", "com.apple.Terminal",
    ]

    @discardableResult
    func focus(directory: String) -> Result {
        let path = (directory as NSString).standardizingPath
        let name = (path as NSString).lastPathComponent
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.editors.contains(id) || Self.terminals.contains(id) || id.hasPrefix("com.jetbrains.")
        }

        // A session usually runs in a terminal inside an editor window whose folder is a parent of its
        // directory (a worktree under the workspace). Asking the editor to open the session's own directory
        // would make a new window; asking for the folder it already has open focuses the existing one.
        let workspace = running.lazy.compactMap { app in Self.openFolder(containing: path, in: app).map { (app, $0) } }.first

        if AXIsProcessTrusted() {
            let folder = workspace.map { ($0.1 as NSString).lastPathComponent }
            let needles = [path, (path as NSString).abbreviatingWithTildeInPath, name] + (folder.map { [$0] } ?? [])
            // Full-path matches beat bare-name matches, so "api" does not grab a window titled "api-docs".
            for needle in needles {
                for app in running {
                    if let window = Self.windows(of: app).first(where: { Self.title($0)?.localizedCaseInsensitiveContains(needle) == true }) {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        app.activate()
                        return .raised(app: app.localizedName ?? "")
                    }
                }
            }
        }

        if let (editor, folder) = workspace, let bundle = editor.bundleURL {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", bundle.path, folder]
            try? open.run()
            return .opened(app: editor.localizedName ?? "")
        }
        return .notFound
    }

    /// Editors of the VS Code family keep their open windows in `storage.json`. Returns the deepest open
    /// folder that is `path` or contains it.
    private static let stateDirs = [
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.microsoft.VSCode": "Code", "com.vscodium": "VSCodium",
    ]

    static func openFolder(containing path: String, in app: NSRunningApplication) -> String? {
        guard let dir = app.bundleIdentifier.flatMap({ stateDirs[$0] }) else { return nil }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dir)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return nil }
        let windows = (state["openedWindows"] as? [[String: Any]] ?? []) + [state["lastActiveWindow"] as? [String: Any] ?? [:]]
        return deepestFolder(containing: path, among: windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:))?.path })
    }

    static func deepestFolder(containing path: String, among folders: [String]) -> String? {
        folders.map { ($0 as NSString).standardizingPath }
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func title(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
