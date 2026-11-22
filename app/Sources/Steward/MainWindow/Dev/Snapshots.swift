import AppKit
import SwiftUI
import StewardKit

/// Headless snapshot mode for machines without previews or screen capture:
///   STEWARD_SNAPSHOT_SAMPLE=1 STEWARD_SNAPSHOT_DIR=/some/dir app/.build-main/debug/Steward
/// renders the whole main window for every scenario below against `SampleBrain` and exits. No window is
/// shown, no brain is started, no hotkeys are registered. `STEWARD_SNAPSHOT_ONLY=today,tasks` narrows the
/// run to scenarios whose name starts with one of the given prefixes. `STEWARD_SAMPLE_EMPTY=1` renders them
/// against an empty brain instead (the first-run experience).
@MainActor
enum MainWindowSnapshots {
    struct Scenario {
        let name: String
        let route: Route
        var size = CGSize(width: 1280, height: 800)
        /// Screen state to preset; screens read it from `MainWindowModel.scenario`.
        var state: [String: String] = [:]
        /// A different sample dataset for this scenario (`SampleData.variant`).
        var data: String?
        var setup: (MainWindowModel) -> Void = { _ in }
        /// Runs once the screen is up (stream chat events, say); the capture follows.
        var live: (MainWindowModel) -> Void = { _ in }
    }

    static var scenarios: [Scenario] {
        var list = Route.allCases.map { Scenario(name: $0.rawValue, route: $0) }
        list += [
            Scenario(name: "onboarding", route: .today, setup: { $0.app.showOnboarding = true }),
            Scenario(name: "guide", route: .guide),
            Scenario(name: "today-inspector", route: .today, setup: { $0.inspectedTaskId = "t1" }),
            Scenario(name: "today-undo", route: .today, setup: { model in model.deferred("Deleted “Book dentist”", hiding: ["t12"]) {} }),
            Scenario(name: "palette", route: .today, setup: { $0.palette = .commands }),
            Scenario(name: "palette-query", route: .tasks, state: ["palette.query": "bill"], setup: { $0.palette = .commands }),
            Scenario(name: "palette-add", route: .today, state: ["palette.query": "Send Teo the rounding examples !! #billing @teo"], setup: { $0.palette = .addTask }),
            Scenario(name: "tasks-grouped", route: .tasks, state: ["tasks.group": "project", "tasks.statuses": "all", "tasks.selected": "t2,t4,t7"]),
            Scenario(name: "tasks-inspector", route: .tasks, state: ["tasks.group": "due"], setup: { $0.inspectedTaskId = "t7" }),
            Scenario(name: "settings-agent", route: .settings, state: ["settings.pane": "agent"]),
            Scenario(name: "settings-budget", route: .settings, state: ["settings.pane": "budget"]),
            Scenario(name: "settings-connectors", route: .settings, state: ["settings.pane": "connectors"]),
            Scenario(name: "settings-jobs", route: .settings, state: ["settings.pane": "jobs"]),
            Scenario(name: "settings-hotkeys", route: .settings, state: ["settings.pane": "hotkeys"]),
            Scenario(name: "settings-interface", route: .settings, state: ["settings.pane": "interface"]),
            Scenario(name: "settings-permissions", route: .settings, state: ["settings.pane": "permissions"]),
            Scenario(name: "settings-memory", route: .settings, state: ["settings.pane": "memory"]),
            Scenario(name: "settings-memory-preview", route: .settings, state: ["settings.pane": "memory", "settings.memory": "preview"]),
            Scenario(name: "settings-runs", route: .settings, state: ["settings.pane": "runs"]),
            Scenario(name: "settings-advanced", route: .settings, state: ["settings.pane": "advanced"]),
            Scenario(name: "projects-initiative", route: .projects, state: ["projects.pick": "i1"]),
            Scenario(name: "projects-loose", route: .projects, state: ["projects.pick": "loose"]),
            Scenario(name: "notes-brief", route: .notes, setup: { $0.focusNoteId = "nb1" }),
            Scenario(name: "notes-edit", route: .notes, setup: { $0.focusNoteId = "nd1" }),
            Scenario(name: "notes-edit-brief", route: .notes, state: ["notes.edit": "1"], setup: { $0.focusNoteId = "nb2" }),
            Scenario(name: "inbox-edit", route: .inbox, state: ["inbox.editing": "g1"]),
            Scenario(name: "inbox-approval-edit", route: .inbox, state: ["inbox.editing": "approval:a2"]),
            Scenario(name: "agent-thread", route: .agent, setup: { $0.threadId = "c1" }),
            Scenario(name: "agent-context", route: .agent, state: ["agent.draft": "/pl"], setup: {
                $0.agentContext = [.init(kind: .task, id: "t1", title: "Fix proration rounding in mid-cycle upgrades"), .init(kind: .session, id: "s2", title: "acme-billing")]
            }),
            Scenario(name: "agent-streaming", route: .agent, setup: { $0.threadId = "c2" }, live: { _ in
                SampleBrain.emit("chat.started", ["threadId": "c2", "runId": "live"])
                SampleBrain.emit("chat.delta", ["threadId": "c2", "runId": "live", "text": "Checking what moved since this morning.\n\n"])
                SampleBrain.emit("chat.tool", ["threadId": "c2", "runId": "live", "callId": "k1", "name": "sessions_list", "input": [String: Any](), "status": "ok", "result": "6 sessions: 1 blocked, 2 waiting"])
                SampleBrain.emit("chat.tool", ["threadId": "c2", "runId": "live", "callId": "k2", "name": "meetings_search", "input": ["from": "today"], "status": "running"])
                SampleBrain.emit("chat.delta", ["threadId": "c2", "runId": "live", "text": "Two things changed:\n\n- The **ledger session** is now blocked on a staging migration\n- Your 1:1 with Mira has no prep yet"])
                SampleBrain.emit("chat.question", ["threadId": "c2", "questionId": "q1", "question": "Want me to draft the prep note for the 1:1 now?", "options": ["Yes, draft it", "After the design review", "Skip"]])
            }),
            Scenario(name: "sessions-board", route: .sessions, state: ["sessions.mode": "board"]),
            Scenario(name: "sessions-recap", route: .sessions, size: CGSize(width: 1280, height: 1700), state: ["sessions.recap": "s1", "sessions.link": "s6"]),
            Scenario(name: "meetings-past", route: .meetings, size: CGSize(width: 1280, height: 1900), state: ["meetings.selected": "m0"]),
            Scenario(name: "people-selected", route: .people, state: ["people.selected": "h3"]),
            Scenario(name: "session-place", route: .sessions, state: ["session.window": "1"], setup: { $0.focusSessionId = "s2" }),
            Scenario(name: "session-place-ended", route: .sessions, size: CGSize(width: 1000, height: 1200), setup: { $0.focusSessionId = "s8" }),
            Scenario(name: "task-place", route: .today, size: CGSize(width: 1280, height: 1700), setup: { $0.inspectedTaskId = "t3" }),
            Scenario(name: "task-place-sessions", route: .tasks, size: CGSize(width: 1280, height: 1500), setup: { $0.inspectedTaskId = "t1" }),
            Scenario(name: "inbox-commitment", route: .inbox, size: CGSize(width: 1280, height: 1100), state: ["inbox.selected": "g10"]),
            Scenario(name: "today-loose-ends", route: .today, size: CGSize(width: 1280, height: 1250)),
            Scenario(name: "palette-loose-ends", route: .today, setup: { $0.palette = .looseEnds }),
            Scenario(name: "guide-places", route: .guide, size: CGSize(width: 1280, height: 1500)),
            Scenario(name: "sessions-many", route: .sessions, size: CGSize(width: 1290, height: 1500), data: "many-sessions"),
            Scenario(name: "sessions-many-tight", route: .sessions, size: CGSize(width: 1370, height: 1500), data: "many-sessions"),
            Scenario(name: "sessions-many-narrow", route: .sessions, size: CGSize(width: 900, height: 1800), data: "many-sessions"),
        ]
        return list
    }

    /// A real, ordered-in window that nobody can see or click: fully transparent, behind everything, never key.
    /// A window that is not ordered in gets no display cycle, and lazy stacks and menus then draw stale content.
    private static func host(_ view: some View, size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = host
        window.orderBack(nil)
        return host
    }

    static var requested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["STEWARD_SNAPSHOT_SAMPLE"] == "1" && !(env["STEWARD_SNAPSHOT_DIR"] ?? "").isEmpty
    }

    static func runHeadless() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["STEWARD_SNAPSHOT_DIR"] ?? "."
        let only = env["STEWARD_SNAPSHOT_ONLY"]?.split(separator: ",").map(String.init)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        // A looping animation in a window that gets no frames freezes its whole row at the first one.
        DesignSettings.shared.reduceMotion = true
        BrainJSON.onDroppedElement = { FileHandle.standardError.write(Data("dropped undecodable element: \($0)\n".utf8)) }

        let app = AppContext(client: SampleBrain.client())
        app.store.start()
        app.store.need(.notes, .people)
        Task {
            for _ in 0..<50 where app.store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for scenario in scenarios where only?.contains(where: scenario.name.hasPrefix) ?? true {
                if SampleData.shared.variant != scenario.data {
                    SampleData.shared.variant = scenario.data
                    app.store.refresh()
                    try? await Task.sleep(for: .milliseconds(400))
                }
                let model = MainWindowModel(app: app)
                model.scenario = scenario.state
                model.threadId = nil
                app.route = scenario.route
                app.showOnboarding = false
                scenario.setup(model)
                let root = RootView().frame(width: scenario.size.width, height: scenario.size.height)
                    .environment(app.store).environment(app).environment(model)
                    // The capture must not land mid-animation, and a transparent window may get no frames at all.
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                let view = host(root, size: scenario.size)
                try? await Task.sleep(for: .milliseconds(900))
                scenario.live(model)
                try? await Task.sleep(for: .milliseconds(500))
                DevSnapshot.write(view, to: "\(dir)/\(scenario.name).png")
                view.window?.orderOut(nil)
                if let error = app.store.lastError { print("\(scenario.name): store error: \(error)") }
            }
            print("snapshots written to \(dir)")
            exit(0)
        }
        NSApplication.shared.run()
    }
}
