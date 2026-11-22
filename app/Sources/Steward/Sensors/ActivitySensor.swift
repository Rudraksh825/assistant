import AppKit
import ApplicationServices
import StewardKit

/// Records which app and window the user is in as spans, with idle gaps, and posts them in batches.
/// Window titles need Accessibility; without it spans carry the app only.
@MainActor
final class ActivitySensor {
    struct Front: Equatable {
        var app: String
        var bundleId: String?
        var title: String?
    }

    /// The app and window in front right now (never Steward's own idle marker).
    private(set) var frontmost: Front?

    private let client: BrainClient
    private var current: (front: Front, start: Date, idle: Bool)?
    private var buffer: [ActivitySpanInput] = []
    private var timer: Timer?
    private var lastFlush = Date()
    private var observer: NSObjectProtocol?
    /// What the brain was last told is in front, and when: it holds a "session waiting" nudge back while that session's window is.
    private var reported: (front: Front?, idle: Bool, at: Date)?

    private let idleAfter: TimeInterval = 120
    private let sampleEvery: TimeInterval = 5
    private let flushEvery: TimeInterval = 60
    /// The brain forgets a focus report after 150 s, so an unchanged one is repeated.
    private let focusEvery: TimeInterval = 60

    init(client: BrainClient) {
        self.client = client
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: sampleEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    func stop() {
        timer?.invalidate()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        pause()
    }

    /// Ends the open span (sleep, lock, quit) and sends what is buffered.
    func pause(at date: Date = Date()) {
        close(at: date)
        flush()
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        lastFlush = Date()
        Task {
            do { try await client.postActivity(batch) } catch {
                // Keep a bounded backlog so an offline brain does not lose the day or grow without limit.
                buffer = Array((batch + buffer).suffix(500))
            }
        }
    }

    private func sample() {
        let now = Date()
        let idleFor = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let front = readFront()
        frontmost = front
        reportFocus(front, idle: idleFor >= idleAfter, at: now)

        if idleFor >= idleAfter {
            if current?.idle != true {
                let wentIdle = now.addingTimeInterval(-idleFor)
                close(at: wentIdle)
                if let front { current = (front, wentIdle, true) }
            }
        } else if let front, current?.idle == true || current?.front != front {
            close(at: now)
            current = (front, now, false)
        }
        if now.timeIntervalSince(lastFlush) >= flushEvery || buffer.count >= 30 { flush() }
    }

    private func reportFocus(_ front: Front?, idle: Bool, at now: Date) {
        if let last = reported, last.front == front, last.idle == idle, now.timeIntervalSince(last.at) < focusEvery { return }
        reported = (front, idle, now)
        var data: [String: JSONValue] = ["app": .string(front?.app ?? ""), "idle": .bool(idle)]
        if let bundleId = front?.bundleId { data["bundleId"] = .string(bundleId) }
        if let title = front?.title { data["title"] = .string(title) }
        Task { try? await client.postSensorEvent("focus", at: now, data: .object(data)) }
    }

    private func close(at end: Date) {
        guard let span = current else { return }
        current = nil
        guard end.timeIntervalSince(span.start) >= 1 else { return }
        buffer.append(ActivitySpanInput(app: span.front.app, bundleId: span.front.bundleId, title: span.front.title, startAt: span.start, endAt: end, idle: span.idle))
    }

    private func readFront() -> Front? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Front(app: app.localizedName ?? app.bundleIdentifier ?? "Unknown", bundleId: app.bundleIdentifier, title: Self.focusedWindowTitle(pid: app.processIdentifier))
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
