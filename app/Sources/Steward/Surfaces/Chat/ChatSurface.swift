import AppKit
import SwiftUI
import StewardKit

/// Quick chat: a floating window for talking to the agent from anywhere. It shows the whole thread,
/// streams replies, and keeps its thread, draft, size and position when closed, so closing it never
/// loses the conversation. Hotkey name: "agent". Questions asked from the notch, quick capture and
/// voice land here.
@MainActor
final class ChatSurface: Surface {
    private let ambient: AmbientState
    private let scene = ChatScene()
    private var panel: ChatPanel?
    private weak var app: AppContext?
    private var handler: UUID?

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        self.app = app
        let store = app.store, scene = scene

        scene.send = { [weak self] in self?.send($0, spoken: false) }
        scene.stop = { if let id = scene.threadId { store.interrupt(id) } }
        scene.close = { [weak self] in self?.hide() }
        scene.openMain = { [weak self] in
            app.windowModel.threadId = scene.threadId
            self?.hide()
            app.showMainWindow(.agent)
        }

        app.hotkeys.on("agent") { [weak self] phase in
            guard phase == .down, let self else { return }
            if self.panel?.isVisible == true && self.panel?.isKeyWindow == true { self.hide() } else { self.show() }
        }
        ambient.ask = { [weak self] text, spoken in
            guard let self else { return }
            // A question asked from elsewhere continues the chat on screen; with the window closed it starts a new one.
            if self.panel?.isVisible != true { self.scene.threadId = nil }
            self.show()
            self.send(text, spoken: spoken)
        }
        ambient.openChat = { [weak self] id in
            self?.scene.threadId = id
            self?.show()
        }
        handler = store.onEvent { [weak self] event in
            // A reply to a spoken question is spoken back once it is complete.
            guard let self, case .chatDone(let done) = event, done.threadId == self.scene.spokenThread else { return }
            self.scene.spokenThread = nil
            let reply = (store.messages[done.threadId] ?? []).reversed().prefix { $0.role != .user }.reversed()
                .filter { $0.role == .assistant && !$0.text.isEmpty }.map(\.text).joined(separator: "\n\n")
            if !reply.isEmpty { self.ambient.speak(reply) }
        }
        Log.info("chat: started")
    }

    func stop() {
        if let handler { app?.store.removeHandler(handler) }
        panel?.orderOut(nil)
    }

    private func show() {
        guard let app else { return }
        let panel = panel ?? makePanel(app)
        self.panel = panel
        if let id = scene.threadId { app.store.openThread(id) }
        // What the user was looking at when they opened the chat rides along with the next message.
        scene.context = ambient.captureContext(app)
        panel.makeKeyAndOrderFront(nil)
        scene.focus += 1
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(_ app: AppContext) -> ChatPanel {
        let panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640))
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: ChatWindow(scene: scene)
            .environment(app.store).environment(app).environment(app.windowModel))
        // First time: upper middle of the display under the pointer. Afterwards wherever the user left it.
        if !panel.setFrameUsingName(ChatPanel.autosave), let screen = NSScreen.underMouse ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - visible.height * 0.08))
        }
        panel.setFrameAutosaveName(ChatPanel.autosave)
        return panel
    }

    private func send(_ text: String, spoken: Bool) {
        guard let app else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prompt = trimmed.hasPrefix("/") ? AgentComposer.matches(trimmed).first?.prompt ?? trimmed : trimmed
        // `source` tells the brain this came from a quick surface, where a fast first word matters more than depth.
        var fields: [String: JSONValue] = ["source": .string("quick")]
        if let front = scene.context.app { fields["app"] = .string(front) }
        if let title = scene.context.title { fields["title"] = .string(title) }
        if let session = scene.context.sessionId { fields["sessionId"] = .string(session) }
        if case .object(let chips)? = MainWindowModel.contextJSON(app.windowModel.agentContext) { fields.merge(chips) { $1 } }
        app.windowModel.agentContext = []
        scene.draft = ""
        Haptics.tick()
        let thread = scene.threadId
        Task {
            guard let id = await app.store.send(prompt, to: thread, context: .object(fields)) else { return }
            if self.scene.threadId == thread { self.scene.threadId = id }
            if spoken { self.scene.spokenThread = id }
        }
    }
}

/// What the chat window shows. The thread id is remembered across closes and relaunches.
@MainActor @Observable
final class ChatScene {
    var threadId: String? = UserDefaults.standard.string(forKey: "chat.thread") {
        didSet { UserDefaults.standard.set(threadId, forKey: "chat.thread") }
    }
    var draft = ""
    var focus = 0
    var context = CaptureContext()
    /// The thread whose next reply is read aloud (it was asked by voice).
    var spokenThread: String?

    @ObservationIgnored var send: (String) -> Void = { _ in }
    @ObservationIgnored var stop: () -> Void = {}
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var openMain: () -> Void = {}
}

/// Floats over other apps and takes the keyboard for typing without bringing Steward's other windows
/// forward. Esc closes it; the conversation stays.
final class ChatPanel: NSPanel {
    static let autosave = "steward.chat"
    var onCancel: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 480, height: 380)
        backgroundColor = NSColor(Palette.bg)
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

private struct ChatWindow: View {
    @Bindable var scene: ChatScene
    @Environment(AppStore.self) private var store

    var body: some View {
        let threadId = scene.threadId
        let streaming = threadId.map(store.streamingThreads.contains) ?? false
        VStack(spacing: 0) {
            header(threadId)
            OfflineBanner(connection: store.connection, note: store.brainNote) { store.refresh() }.padding(.horizontal, Space.l)
            AgentConversation(threadId: threadId, streaming: streaming) { scene.send($0) }
            AgentComposer(draft: $scene.draft, streaming: streaming, focusToken: scene.focus, returnSends: true,
                          onSend: { scene.send(scene.draft) }, onStop: scene.stop)
                .disabled(!store.connection.isOnline)
        }
        .background(Palette.bg)
        .preferredColorScheme(.dark)
        .task(id: threadId) { if let threadId { store.openThread(threadId) } }
    }

    private func header(_ threadId: String?) -> some View {
        let thread = store.threads.first { $0.id == threadId }
        return HStack(spacing: Space.s) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.violet)
            Menu {
                Button("New chat", systemImage: "square.and.pencil") { newChat() }
                if !store.threads.isEmpty { Divider() }
                ForEach(store.threads.prefix(12)) { other in
                    Button { scene.threadId = other.id } label: {
                        Text(other.title.nonEmpty ?? "Untitled chat")
                        if other.id == threadId { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(thread?.title.nonEmpty ?? "New chat").font(Typo.heading).foregroundStyle(Palette.text).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Switch chat")
            Spacer(minLength: Space.m)
            Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command).help("New chat  ⌘N")
            Button { scene.openMain() } label: { Image(systemName: "macwindow") }
                .keyboardShortcut("o", modifiers: .command).help("Open in the main window  ⌘O")
            Button { scene.close() } label: { Image(systemName: "xmark") }
                .keyboardShortcut("w", modifiers: .command).help("Close  esc — the chat is kept")
        }
        .buttonStyle(.pressable(.ghost))
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, Space.l)
        .padding(.trailing, Space.m)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    private func newChat() {
        scene.threadId = nil
        scene.focus += 1
    }
}
