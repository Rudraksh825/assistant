import AppKit
import AVFoundation
import StewardKit

/// What the island and the capture panel show while dictating.
@MainActor @Observable
final class VoiceModel {
    var listening = false
    var transcript = ""
    var level: Float = 0
    /// Why voice cannot run right now, in words for the user.
    var problem: String?
}

/// Hold the hotkey to talk, release to send; a quick tap latches listening until the next tap.
/// The utterance goes to capture, or to the agent when it opens with a wake phrase ("ask…", "hey steward…").
/// Also speaks: `ui.command speak`, and replies to questions that were asked by voice. Hotkey name: "voice".
@MainActor
final class VoiceSurface: Surface {
    /// A press shorter than this is a tap (toggle), longer is hold-to-talk.
    private static let tapThreshold: TimeInterval = 0.35

    private let ambient: AmbientState
    private let engine = SpeechEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private weak var app: AppContext?
    private var handler: UUID?
    private var pressedAt = Date.distantPast
    private var latched = false
    private var keyDown = false
    private var starting = false
    private var problemTimer: DispatchWorkItem?

    init(ambient: AmbientState) {
        self.ambient = ambient
    }

    func start(app: AppContext) {
        self.app = app
        let voice = ambient.voice
        engine.onLevel = { level in voice.level = level }
        engine.onPartial = { [weak self] text in
            voice.transcript = text
            if self?.ambient.captureIsOpen() == true { self?.ambient.dictateIntoCapture(text, false) }
        }
        engine.onFinal = { [weak self] text in self?.finished(text) }

        app.hotkeys.on("voice") { [weak self] phase in
            guard let self else { return }
            self.keyDown = phase == .down
            switch phase {
            case .down:
                if voice.listening && self.latched { self.engine.stop() } else if !voice.listening && !self.starting { self.begin() }
            case .up:
                guard voice.listening, !self.latched else { return }
                if Date().timeIntervalSince(self.pressedAt) < Self.tapThreshold { self.latched = true } else { self.engine.stop() }
            }
        }
        ambient.speak = { [weak self] in self?.speak($0) }
        handler = app.store.onEvent { [weak self] event in
            if case .uiCommand(let command) = event, command.command == .speak, let text = command.args?["text"].string {
                self?.speak(text, fallbackToast: true)
            }
        }
        Log.info("voice: started (\(Self.bundled ? "on-device dictation via SFSpeechRecognizer" : "disabled: not running from an app bundle"))")
    }

    func stop() {
        engine.stop()
        synthesizer.stopSpeaking(at: .immediate)
        if let handler { app?.store.removeHandler(handler) }
    }

    /// TCC kills a process that asks for the microphone without usage strings, i.e. `swift run`.
    private static var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    private func begin() {
        pressedAt = Date()
        latched = false
        synthesizer.stopSpeaking(at: .immediate)
        guard Self.bundled else { return fail("Voice needs the bundled app (scripts/build.sh)") }
        starting = true
        Task {
            defer { starting = false }
            for permission in [Permission.microphone, .speech] {
                // The system prompt appears here once, in answer to the user's own hotkey.
                if await permission.status() == .notDetermined { await permission.request() }
                guard await permission.status() == .granted else {
                    return fail("\(permission.title) access is off. Turn it on in System Settings › Privacy.")
                }
            }
            do {
                try engine.start()
            } catch SpeechEngine.Failure.notOnDevice {
                return fail("On-device dictation is not available for this language yet.")
            } catch {
                Log.error("voice: could not start: \(error)")
                return fail("Could not start listening.")
            }
            let voice = ambient.voice
            voice.problem = nil
            voice.transcript = ""
            voice.level = 0
            voice.listening = true
            Haptics.tick()
            if !ambient.captureIsOpen() { ambient.presentVoice(true) }
            // The key may already be up again (permission prompt, slow start): no release is coming, so
            // treat the press as a tap and wait for the next one.
            if !keyDown { latched = true }
        }
    }

    private func finished(_ text: String) {
        let voice = ambient.voice
        voice.listening = false
        voice.level = 0
        ambient.presentVoice(false)
        guard let app else { return }
        if ambient.captureIsOpen() {
            ambient.dictateIntoCapture(text, true)
            return
        }
        switch VoiceRoute.route(text) {
        case .capture(let text) where text.isEmpty:
            break
        case .capture(let text):
            app.store.capture(text, source: .voice, context: ambient.captureContext(app))
            Haptics.success()
            ambient.notice("checkmark.circle.fill", "Captured")
        case .agent(let question):
            Haptics.thunk()
            ambient.ask(question, true)
        }
    }

    /// Shows why voice is unavailable in the island for a moment.
    private func fail(_ message: String) {
        let voice = ambient.voice
        voice.problem = message
        voice.transcript = ""
        ambient.presentVoice(true)
        problemTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ambient.voice.listening else { return }
            self.ambient.presentVoice(false)
            self.ambient.voice.problem = nil
        }
        problemTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func speak(_ text: String, fallbackToast: Bool = false) {
        let enabled = app?.store.settings["ui"]["speakReplies"].bool ?? true
        guard enabled else {
            if fallbackToast {
                ambient.toasts.show(ToastItem(id: "message:\(UUID().uuidString)", kind: .message, title: text), lifetime: ToastDelivery.lifetime(priority: 1))
            }
            return
        }
        // Markdown read aloud is noise.
        let plain = text.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: plain))
    }
}
