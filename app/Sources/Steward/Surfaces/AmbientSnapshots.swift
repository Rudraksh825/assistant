import AppKit
import SwiftUI
import StewardKit

/// Offscreen renders of the ambient surfaces in their key states, with sample data, for machines where
/// the screen cannot be captured. Part of the `STEWARD_SNAPSHOT_DIR` mode; with
/// `STEWARD_SNAPSHOT_AMBIENT=1` as well the process renders just these and exits without starting the
/// app (no windows, no Dock icon, no brain). Blur comes out flat; layout, type and colour are faithful.
@MainActor
enum AmbientSnapshots {
    /// Call first thing in `main`. Returns only when no ambient-only snapshot was asked for.
    static func runStandaloneIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["STEWARD_SNAPSHOT_DIR"], !dir.isEmpty, env["STEWARD_SNAPSHOT_AMBIENT"] == "1" else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let views = views()
        // Layout, geometry callbacks and insertion transitions need a few turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        for (name, view) in views { DevSnapshot.write(view, to: "\(dir)/\(name).png") }
        print("ambient snapshots written to \(dir): \(views.map(\.0).joined(separator: " "))")
        exit(0)
    }

    static func views() -> [(String, NSView)] {
        let builtIn = NotchLayout(screen: ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 58, width: 1728, height: 1026),
                                                        safeTop: 32, auxLeftWidth: 771, auxRightWidth: 772), statusBarThickness: 24)
        let external = NotchLayout(screen: ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 3008, height: 1692), visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1667)),
                                   reference: builtIn.notch, statusBarThickness: 24)
        let ears = (left: NotchGeometry.dotsEarWidth(count: 5), right: NotchIndicator.meeting(start: Date(), live: false).earWidth)

        var out: [(String, NSView)] = []
        out.append(("notch-collapsed", notch(builtIn, height: 150) { _, pose in pose.earLeft = ears.left; pose.earRight = ears.right }))
        out.append(("notch-hover", notch(builtIn, height: 150) { _, pose in pose.earLeft = ears.left; pose.earRight = ears.right; pose.swell = 1 }))
        out.append(("notch-virtual-collapsed", notch(external, height: 150) { _, pose in pose.earLeft = ears.left; pose.earRight = ears.right }))
        out.append(("notch-expanded", notch(builtIn, height: 600) { scene, pose in
            scene.presentation = .full
            scene.selection = .task("t2")
            scene.hovered = .session("s2")
            pose.open = 1
        }))
        out.append(("notch-voice", notch(builtIn, height: 190, listening: true) { scene, pose in
            scene.presentation = .voice
            pose.open = 1
            pose.body = CGSize(width: NotchMetrics.voiceBody.width, height: builtIn.notch.height + NotchMetrics.voiceBody.height)
        }))
        out.append(("toasts", notch(builtIn, height: 520, toasts: true) { _, pose in pose.earLeft = ears.left; pose.earRight = NotchIndicator.decisions(2).earWidth }))

        let voice = VoiceModel()
        let writing = CaptureScene()
        writing.shown = true
        writing.text = "!! fix the login redirect #web-app @dana"
        writing.context = CaptureContext(app: "Editor", title: "auth.ts — web-app")
        writing.sessionName = "web-app"
        out.append(("capture-idle", staged(CapturePanel(scene: writing, voice: voice), size: CGSize(width: CaptureMetrics.canvas.width, height: 260))))

        let captured = CaptureScene()
        captured.shown = true
        captured.phase = .captured
        out.append(("capture-captured", staged(CapturePanel(scene: captured, voice: voice), size: CGSize(width: CaptureMetrics.canvas.width, height: 160))))

        let model = sampleModel()
        let pill = HUDScene()
        pill.hovered = true
        out.append(("hud-pill", staged(HUDView(scene: pill, model: model), size: CGSize(width: HUDMetrics.canvas.width, height: 110))))
        let idle = HUDScene()
        out.append(("hud-pill-idle", staged(HUDView(scene: idle, model: model), size: CGSize(width: HUDMetrics.canvas.width, height: 110))))
        let card = HUDScene()
        card.card = true
        card.hovered = true
        card.saving = .saved
        card.note = model.liveNote?.body ?? ""
        out.append(("hud-card", staged(HUDView(scene: card, model: model), size: CGSize(width: HUDMetrics.canvas.width, height: 420))))
        return out
    }

    // MARK: Stages

    /// One island on a fake desktop with a menu bar and, for a notched layout, the camera housing drawn over it.
    private static func notch(_ layout: NotchLayout, height: CGFloat, listening: Bool = false, toasts: Bool = false,
                              configure: (NotchScene, inout NotchPose) -> Void) -> NSView {
        let ambient = AmbientState()
        copy(sampleModel(), into: ambient.model)
        ambient.model.indicator = toasts ? .decisions(2) : .meeting(start: Date().addingTimeInterval(4 * 60 + 20), live: false)
        if listening {
            ambient.voice.listening = true
            ambient.voice.level = 0.7
            ambient.voice.transcript = "ask what is blocking the login redirect ticket"
            ambient.model.indicator = .voice
        }

        let scene = NotchScene(layout: layout, displayID: 1)
        var pose = NotchPose(body: CGSize(width: NotchMetrics.fullWidth, height: 430))
        configure(scene, &pose)
        scene.isOpen = pose.open > 0
        scene.mounted = scene.isOpen
        scene.revealed = scene.isOpen

        let frame = layout.panelFrame(canvas: NotchMetrics.canvas)
        let canvas = NotchPanelController.makeCanvas(scene: scene, ambient: ambient, toastActions: ToastActions(), frame: frame) { _ in }
        canvas.apply(NotchGeometry.shell(notch: layout.notch, pose: pose), visible: true)
        // The full panel sizes itself to its content, as the live controller does.
        scene.onContentHeight = { [weak canvas] measured in
            var fitted = pose
            fitted.body.height = measured
            canvas?.apply(NotchGeometry.shell(notch: layout.notch, pose: fitted), visible: true)
        }
        if toasts {
            ambient.toasts.chooseDisplay = { 1 }
            for item in sampleToasts() { ambient.toasts.show(item, lifetime: 600) }
        }

        let size = CGSize(width: frame.width, height: height)
        let stage = NSView(frame: NSRect(origin: .zero, size: size))
        let backdrop = NSHostingView(rootView: Desktop(menuBar: layout.hasNotch ? 33 : layout.notch.height))
        backdrop.frame = stage.bounds
        stage.addSubview(backdrop)
        canvas.setFrameOrigin(NSPoint(x: 0, y: height - frame.height))
        stage.addSubview(canvas)
        if layout.hasNotch {
            // What the hardware hides: anything the island draws under here is never seen.
            let housing = NSHostingView(rootView: UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                .fill(Color(hex: 0x050506)).overlay(Circle().fill(Color(hex: 0x1B1E26)).frame(width: 7, height: 7)))
            housing.frame = NSRect(x: layout.centerX - frame.minX - layout.notch.width / 2, y: height - layout.notch.height, width: layout.notch.width, height: layout.notch.height)
            stage.addSubview(housing)
        }
        return windowed(stage)
    }

    private static func staged(_ view: some View, size: CGSize) -> NSView {
        let host = NSHostingView(rootView: ZStack(alignment: .top) {
            Desktop(menuBar: 0)
            view
        }.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        return windowed(host)
    }

    private static func windowed(_ view: NSView) -> NSView {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Something busy enough behind the surfaces to judge contrast against.
    private struct Desktop: View {
        let menuBar: CGFloat

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x30508C), Color(hex: 0x7A5BA8), Color(hex: 0xD98E6B)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    Color.black.opacity(0.28).frame(height: menuBar)
                    RoundedRectangle.continuous(10).fill(Color.white.opacity(0.9)).padding(.horizontal, 60).padding(.top, 36)
                }
            }
        }
    }

    // MARK: Sample data (generic on purpose: nothing here describes a real person or company)

    private static func decode<T: Decodable>(_ json: String) -> T {
        try! BrainJSON.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func ms(_ secondsFromNow: TimeInterval) -> Int { Int((Date().timeIntervalSince1970 + secondsFromNow) * 1000) }

    static func sampleModel() -> AmbientModel {
        let model = AmbientModel()
        let tasks: [TaskItem] = decode("""
        [{"id":"t0","title":"Fix the login redirect loop","status":"doing","priority":3,"projectId":"p1","score":92,"scoreReasons":["due today"],"createdAt":1,"updatedAt":\(ms(-1450))},
         {"id":"t1","title":"Reply to the review on the allow-list change","status":"todo","priority":2,"score":81,"scoreReasons":["session waiting 12m","PR has 1 unresolved thread"],"createdAt":1,"updatedAt":1},
         {"id":"t2","title":"Write the rollout note for the billing migration","status":"todo","priority":2,"score":74,"scoreReasons":["due tomorrow","pinned"],"createdAt":1,"updatedAt":1},
         {"id":"t3","title":"Prep for the platform sync","status":"todo","priority":1,"score":63,"scoreReasons":["meeting in 4m"],"createdAt":1,"updatedAt":1},
         {"id":"t4","title":"Book travel for the offsite","status":"todo","priority":0,"score":41,"scoreReasons":["waiting 6 days"],"createdAt":1,"updatedAt":1}]
        """)
        model.now = tasks[0]
        model.nowSince = Date().addingTimeInterval(-1450)
        model.next = Array(tasks.dropFirst())
        model.sessions = decode("""
        [{"id":"s1","cwd":"/code/web-app","repo":"web-app","ticket":"ENG-123","state":"blocked","stateSince":\(ms(-190)),"title":"Asking whether to rewrite the redirect guard","lastAssistantText":"I can either patch the guard in place or move the allow-list into config. Which do you prefer?","startedAt":1,"updatedAt":1},
         {"id":"s2","cwd":"/code/billing","repo":"billing","ticket":"ENG-98","state":"waiting","stateSince":\(ms(-740)),"title":"Migration script finished","lastAssistantText":"The migration ran clean against the staging copy: 14,203 rows moved, 0 skipped. Ready for your review.","startedAt":1,"updatedAt":1},
         {"id":"s3","cwd":"/code/docs","repo":"docs","state":"working","stateSince":\(ms(-95)),"title":"Rewriting the onboarding guide","startedAt":1,"updatedAt":1},
         {"id":"s4","cwd":"/code/infra","repo":"infra","ticket":"ENG-140","state":"working","stateSince":\(ms(-400)),"title":"Tracing the flaky deploy step","startedAt":1,"updatedAt":1},
         {"id":"s5","cwd":"/code/scratch","repo":"scratch","state":"idle","stateSince":\(ms(-5000)),"title":"Spike: queue backpressure","startedAt":1,"updatedAt":1}]
        """)
        model.sessionStates = model.sessions.map(\.state)
        model.chats = [
            ChatPeek(id: "c1", title: "What is blocking ENG-123?", updatedAt: Date().addingTimeInterval(-40), state: .answering),
            ChatPeek(id: "c2", title: "Draft the rollout note", updatedAt: Date().addingTimeInterval(-1500), state: .needsYou),
            ChatPeek(id: "c3", title: "Plan my day", updatedAt: Date().addingTimeInterval(-9000), state: .idle),
        ]
        model.meeting = decode("""
        {"id":"m1","source":"calendar","externalId":"e1","title":"Platform sync","startAt":\(ms(260)),"endAt":\(ms(2060)),"attendees":["a","b","c"],"joinUrl":"https://example.com/meet","updatedAt":1}
        """)
        model.approvals = decode("""
        [{"id":"a1","kind":"chat.post","summary":"Post the deploy summary to #releases","tool":"chat_post","input":{"channel":"#releases","text":"Deploy 2026.11.3 is out. Two fixes: login redirect loop, slow invoice export."},"note":"chat_post writes to an external service.","target":"#releases","status":"pending","createdAt":1}]
        """)
        model.agentBusy = true
        model.agentActivity = "Reading the review thread…"
        model.suggestionCount = 3
        model.online = true
        model.projectTitles = ["p1": "Web app"]
        model.liveNote = decode("""
        {"id":"n1","kind":"live","title":"Live note","body":"redirect loop: guard runs before the session cookie is read\\n- repro only with SSO\\n- ask dana about the allow-list","pinned":false,"createdAt":1,"updatedAt":1}
        """)
        return model
    }

    private static func copy(_ from: AmbientModel, into to: AmbientModel) {
        to.now = from.now
        to.nowSince = from.nowSince
        to.next = from.next
        to.sessions = from.sessions
        to.sessionStates = from.sessionStates
        to.meeting = from.meeting
        to.approvals = from.approvals
        to.agentBusy = from.agentBusy
        to.agentActivity = from.agentActivity
        to.suggestionCount = from.suggestionCount
        to.online = from.online
        to.projectTitles = from.projectTitles
        to.chats = from.chats
        to.liveNote = from.liveNote
    }

    private static func sampleToasts() -> [ToastItem] {
        let nudge: Nudge = decode("""
        {"id":"n1","kind":"session","title":"billing finished and is waiting","body":"Migration script ran clean against staging. 12 minutes idle.","priority":1,
         "actions":[{"id":"focus","label":"Go to session","kind":"focus_session","sessionId":"s2"},{"id":"later","label":"Later","kind":"api"}],"createdAt":1}
        """)
        let question: BrainEvent.ChatQuestion = decode("""
        {"threadId":"th","questionId":"q1","question":"Should the rollout note go to the whole team or only to on-call?","options":["Whole team","Only on-call"]}
        """)
        return [.question(question), .approval(sampleModel().approvals[0]), .nudge(nudge)]
    }
}
