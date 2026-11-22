import AppKit

/// Trackpad haptics. Silent when the `ui.haptics` setting is off (the store keeps `enabled` in sync).
@MainActor
public enum Haptics {
    public static var enabled = true

    /// Light detent: hover snaps, selection moves, button presses.
    public static func tick() { perform(.alignment) }

    /// Heavier: a surface opening or locking into place.
    public static func thunk() { perform(.levelChange) }

    /// Double tap: something completed.
    public static func success() {
        perform(.generic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { perform(.levelChange) }
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
