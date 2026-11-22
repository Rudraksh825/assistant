import SwiftUI
import StewardKit

@MainActor @Observable
final class CaptureScene {
    enum Phase: Equatable { case writing, captured }

    var phase = Phase.writing
    var text = ""
    var focus = 0
    /// Drives the entrance and exit; the panel itself is ordered in before and out after.
    var shown = false
    var context = CaptureContext()
    var sessionName: String?

    @ObservationIgnored var submit: (NSEvent.ModifierFlags) -> Void = { _ in }
    @ObservationIgnored var dismiss: () -> Void = {}
}

enum CaptureMetrics {
    static let width: CGFloat = 640
    static let margin: CGFloat = 56
    static let canvas = CGSize(width: width + margin * 2, height: 420)
}

/// Spotlight-style capture: a field and chips for what it understood and what it will attach.
/// ⌘↩ (or a leading `>`) hands the text to the chat window instead.
struct CapturePanel: View {
    @Bindable var scene: CaptureScene
    let voice: VoiceModel

    var body: some View {
        let captured = scene.phase == .captured
        VStack(spacing: 0) {
            if captured {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.ok)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                    Text("Captured").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                }
                .padding(.horizontal, 18).frame(height: 46)
                .transition(.opacity)
            } else {
                writing.transition(.opacity)
            }
        }
        .frame(width: captured ? nil : CaptureMetrics.width)
        .ambientPanel(radius: captured ? 23 : 24, elevation: 4, solidity: 0.78)
        .scaleEffect(scene.shown ? 1 : 0.955, anchor: .top)
        .opacity(scene.shown ? 1 : 0)
        .offset(y: scene.shown ? 0 : -10)
        .animation(Motion.snappy, value: scene.shown)
        .animation(Motion.bounce, value: captured)
        .padding(.top, CaptureMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var writing: some View {
        let draft = CaptureDraft.parse(scene.text)
        let asking = draft.forceAgent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // An AppKit text view has no baseline to align to; the glyph is centred on the first line instead.
                Image(systemName: voice.listening ? "mic.fill" : (asking ? "sparkles" : "plus"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(voice.listening ? Palette.danger : (asking ? Palette.violet : Palette.accent))
                    .frame(width: 20, height: 22)
                    .contentTransition(.symbolEffect(.replace))
                AmbientTextInput(text: $scene.text, placeholder: "Capture a thought, or ask Steward…",
                                 font: .systemFont(ofSize: 18), color: NSColor(Palette.text), maxLines: 8, focus: scene.focus,
                                 onSubmit: { scene.submit($0) }, onEscape: { scene.dismiss() })
                if voice.listening { LevelBars(level: voice.level, color: Palette.danger, height: 18) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            chips(draft).padding(.horizontal, 20).padding(.bottom, 12)

            Divider().overlay(Palette.stroke)
            footer(forceAgent: asking)
        }
    }

    /// What the text was understood to mean, then what will ride along with it.
    private func chips(_ draft: CaptureDraft) -> some View {
        HStack(spacing: 6) {
            if draft.forceAgent { Pill("to the agent", icon: "sparkles", color: Palette.violet) }
            if let priority = draft.quick.priority {
                Pill(["", "Low", "High", "Urgent"][min(3, max(0, priority))], icon: "flag.fill", color: Palette.priority(priority))
            }
            ForEach(draft.quick.hashes, id: \.self) { Pill($0, icon: "number", color: Palette.info) }
            ForEach(draft.quick.people, id: \.self) { Pill($0, icon: "at", color: Palette.ok) }
            if draft.forceAgent || draft.quick.priority != nil || !draft.quick.hashes.isEmpty || !draft.quick.people.isEmpty {
                Text("·").foregroundStyle(Palette.textFaint)
            }
            if let app = scene.context.app {
                Pill(String([app, scene.context.title].compactMap { $0 }.joined(separator: " — ").prefix(52)), icon: "macwindow", color: Palette.textDim)
            }
            if let session = scene.sessionName { Pill(session, icon: "terminal", color: Palette.accent) }
            if scene.context.app == nil && scene.sessionName == nil {
                Text("No context attached").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .animation(Motion.snappy, value: draft)
    }

    private func footer(forceAgent: Bool) -> some View {
        HStack(spacing: 14) {
            hint(["↩"], forceAgent ? "ask in chat" : "capture")
            if !forceAgent { hint(["⌘", "↩"], "ask in chat") }
            hint(["⇧", "↩"], "new line")
            Spacer()
            hint(["esc"], "close")
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textDim)
                        .padding(.horizontal, key.count > 1 ? 4 : 0).frame(minWidth: 16, minHeight: 16)
                        .background(Color.white.opacity(0.08), in: .continuous(4))
                }
            }
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.textFaint)
        }
    }
}
