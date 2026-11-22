import AppKit
import SwiftUI
import StewardKit

// The pieces every "place" shares: where an item came from, what was fetched about it, and how that is asked for.

extension SourceKind {
    /// The explicit way out to the source app. Never the default click.
    var openLabel: String {
        switch self {
        case .chat: "Open in chat"
        case .meeting: "Open the recording"
        case .ticket: "Open the ticket"
        case .doc: "Open the document"
        case .calendar: "Open in calendar"
        case .git: "Open the pull request"
        case .browser: "Open in the browser"
        default: "Open the link"
        }
    }

    /// One origin's kind in words: "message", "action item", "page visit".
    func originNoun(_ kind: String) -> String {
        switch (self, kind) {
        case (_, "commitment"): "what you said"
        case (.chat, _), (.message, _): "message"
        case (.meeting, "action_item"): "action item"
        case (.meeting, _): "meeting"
        case (.ticket, _): "ticket \(kind.replacingOccurrences(of: "_", with: " "))"
        case (.doc, _): "document"
        case (.browser, _): "page you opened"
        case (.git, _): "pull request"
        case (.claude, _): "coding session"
        case (.capture, _): "your capture"
        default: kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension LooseEndKind {
    var icon: String {
        switch self {
        case .commitment: "text.quote"
        case .session: "terminal"
        case .waiting: "hourglass"
        case .pr: "arrow.triangle.pull"
        case .page: "safari"
        case .unknown: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .commitment: Palette.accent
        case .session: Palette.violet
        case .waiting: Palette.info
        case .pr: Palette.danger
        case .page, .unknown: Palette.textDim
        }
    }
}

/// One source, readable in place: who said it, when, the text, and an explicit way out.
struct OriginCard: View {
    let origin: Origin
    var lineLimit: Int? = 8
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: origin.source.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.info).frame(width: 14)
                Text(headline).font(Typo.caption.weight(.medium)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: Space.xs)
                if let at = origin.at {
                    Text("\(Fmt.since(at)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize()
                        .help("\(Fmt.day(at)) \(Fmt.time(at))")
                }
            }
            if !origin.title.isEmpty, origin.title != origin.body {
                Text(origin.title).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !origin.body.isEmpty {
                Text(origin.body).font(Typo.body).foregroundStyle(Palette.text.opacity(0.92)).lineSpacing(2).lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.leading, Space.s)
                    .overlay(alignment: .leading) { Capsule().fill(Palette.info.opacity(0.45)).frame(width: 2) }
            }
            HStack(spacing: Space.m) {
                if let id = origin.sessionId { inside("Open the session", "terminal") { model.openSession(id) } }
                if let id = origin.meetingId { inside("Open the meeting", "calendar") { app.open(view: Route.meetings.rawValue, path: "/meetings/\(id)") } }
                if let id = origin.noteId { inside("Open the note", "note.text") { app.open(view: Route.notes.rawValue, path: "/notes/\(id)") } }
                Spacer(minLength: 0)
                if let url = origin.url, AppContext.canOpen(url) {
                    Button { app.open(url) } label: {
                        HStack(spacing: 3) {
                            Text(origin.source.openLabel).font(Typo.caption)
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Palette.info)
                    }
                    .buttonStyle(.pressable(.bare)).fixedSize()
                    .help(url)
                }
            }
        }
        .padding(Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.stroke, lineWidth: 1))
    }

    private var headline: String {
        let noun = origin.source.originNoun(origin.kind)
        guard let actor = origin.actor, !actor.isEmpty else { return noun.prefix(1).uppercased() + noun.dropFirst() }
        return origin.kind == "commitment" ? "You, to \(actor)" : "\(actor) · \(noun)"
    }

    private func inside(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Typo.caption).foregroundStyle(Palette.textDim)
        }
        .buttonStyle(.pressable(.bare)).fixedSize()
    }
}

/// "See more": the stored context note with when it was fetched, its progress while a run is going, and the one
/// button that starts or refreshes it. Reopening shows what is stored; nothing is fetched again until asked.
struct ContextNote: View {
    let context: ItemContext?
    /// The connector family a fetch would read; nil when there is nothing remote behind the item.
    let via: String?
    /// Why the last request could not even start (agent off, budget spent).
    var refusal: String?
    var keyHint: [String] = []
    let onFetch: (_ refresh: Bool) -> Void

    private var running: Bool { context?.status == .running }
    private var body_: String { context?.body ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !body_.isEmpty {
                MarkdownView(text: body_)
                HStack(spacing: 6) {
                    if running {
                        ProgressView().controlSize(.mini)
                        Text("Reading it again…").font(Typo.caption).foregroundStyle(Palette.textDim)
                    } else if let at = context?.fetchedAt {
                        Text("Fetched \(Fmt.since(at)) ago" + (via.map { " from \($0)" } ?? "")).font(Typo.caption).foregroundStyle(Palette.textFaint)
                            .help("\(Fmt.day(at)) \(Fmt.time(at)) · \(Fmt.usd(context?.costUsd ?? 0)) so far")
                    }
                    Spacer(minLength: 0)
                    if via != nil, !running {
                        IconButton(icon: "arrow.clockwise", help: "Fetch it again", size: 20) { onFetch(true) }
                    }
                }
            } else if running {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading the \(noun) around it…").font(Typo.caption).foregroundStyle(Palette.textDim)
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else if let via {
                Button { onFetch(false) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass").font(.system(size: 11, weight: .medium))
                        Text("See more")
                        ForEach(keyHint, id: \.self) { KeyHint($0) }
                    }
                }
                .buttonStyle(.pressable()).fixedSize()
                .help("Read the rest of the \(noun) from \(via) and keep a short note here. One quick agent run.")
            }
            if let error = refusal ?? (context?.status == .failed ? context?.error ?? "The fetch failed." : nil) {
                InlineNotice(text: error, icon: "exclamationmark.triangle", color: Palette.warn)
            }
        }
        .animation(Motion.snappy, value: context?.status)
    }

    private var noun: String {
        switch via {
        case "chat": "thread"
        case "meetings": "meeting"
        case "tickets": "ticket"
        case "docs": "document"
        default: "source"
        }
    }
}

/// "Where this came from" and "See more" as one block: the Inbox shows it before a decision, the task place after.
struct SourcePanel: View {
    let origins: [Origin]
    let context: ItemContext?
    let via: String?
    var refusal: String?
    var keyHint: [String] = []
    let onFetch: (_ refresh: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(origins.enumerated()), id: \.offset) { _, origin in OriginCard(origin: origin) }
            if via != nil || !(context?.body ?? "").isEmpty || refusal != nil {
                ContextNote(context: context, via: via, refusal: refusal, keyHint: keyHint, onFetch: onFetch)
            }
        }
    }
}

extension AppContext {
    /// Whether `open(_:)` would do anything with this string.
    static func canOpen(_ url: String) -> Bool {
        URL(string: url)?.scheme.map { openable.contains($0.lowercased()) } ?? false
    }
}

/// Copies text to the pasteboard, with the small confirmation every copy button in the window gives.
@MainActor func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    Haptics.tick()
}
