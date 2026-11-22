import AppKit
import ApplicationServices
import AVFoundation
import Speech
import UserNotifications

/// The optional system permissions Steward can use. Nothing here is required to run.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, notifications, microphone, speech, screenRecording, fullDiskAccess

    enum Status { case granted, denied, notDetermined }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    var why: String {
        switch self {
        case .accessibility: "Read the focused window's title for the activity log, and bring a session's editor or terminal window to the front."
        case .notifications: "Show a system notification when something needs you: an approval, a blocked session, a meeting about to start."
        case .microphone: "Hold the voice hotkey and talk instead of typing a capture."
        case .speech: "Turn what you say into text on this Mac."
        case .screenRecording: "See window titles of other apps when Accessibility can't. Steward does not record your screen."
        case .fullDiskAccess: "Let the brain read local message and browser history, if you turn those collectors on."
        }
    }

    var icon: String {
        switch self {
        case .accessibility: "accessibility"
        case .notifications: "bell.badge"
        case .microphone: "mic"
        case .speech: "waveform"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .fullDiskAccess: "externaldrive"
        }
    }

    /// TCC prompts for these kill a process that has no Info.plist usage strings, i.e. `swift run`.
    private static var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    func status() async -> Status {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .notifications:
            guard Self.bundled else { return .notDetermined }
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .fullDiskAccess:
            // There is no API; reading a TCC-protected file is the accepted probe.
            let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
            return FileManager.default.isReadableFile(atPath: probe.path) ? .granted : .notDetermined
        }
    }

    /// Shows the system prompt where one exists, otherwise opens the right Settings pane.
    @MainActor
    func request() async {
        switch self {
        case .accessibility:
            // The string value of kAXTrustedCheckOptionPrompt, which is not concurrency-safe to reference directly.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .notifications where Self.bundled:
            if await status() == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                openSettings()
            }
        case .microphone where Self.bundled:
            if await status() == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) } else { openSettings() }
        case .speech where Self.bundled:
            if await status() == .notDetermined {
                _ = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
            } else {
                openSettings()
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings() }
        default:
            openSettings()
        }
    }

    @MainActor
    func openSettings() {
        let pane = switch self {
        case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
        case .notifications: "com.apple.Notifications-Settings.extension"
        case .microphone: "com.apple.preference.security?Privacy_Microphone"
        case .speech: "com.apple.preference.security?Privacy_SpeechRecognition"
        case .screenRecording: "com.apple.preference.security?Privacy_ScreenCapture"
        case .fullDiskAccess: "com.apple.preference.security?Privacy_AllFiles"
        }
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
