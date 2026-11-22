import SwiftUI
import StewardKit

/// Everything the app can do, in one place: where each surface lives, what it watches, what it does
/// unasked, what to ask the agent, and where the line on outside actions is. Hotkeys are read from
/// settings so the page is never out of date after a rebind.
struct GuideScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        ScreenScaffold(title: "Guide", subtitle: "What Steward does and how to reach it") {
            Button("Welcome screen") { withAnimation(Motion.snappy) { app.showOnboarding = true } }
                .buttonStyle(.pressable(.secondary))
        } content: {
            section("Wherever you are", icon: "sparkles.rectangle.stack") {
                item("Notch", key: hotkey("notch"),
                     "Touch the notch and it opens. Now, Next up, your coding sessions, the next meeting, and a field at the bottom. "
                     + "Click a session to jump to its window; when no open window has its folder, its page opens here instead. "
                     + "Click a task's ring to complete it, the row to start it, the arrow under the pointer to open it; swipe right to complete, left to snooze. "
                     + "Recent chats are listed too; click one to pick it back up. Type in the field: ↩ captures, ⌘↩ asks in Quick chat.")
                item("Quick capture", key: hotkey("capture"),
                     "A field on whatever screen you are on. ↩ saves a thought and the agent turns it into tasks; ⌘↩ sends it to Quick chat as a question. "
                     + "Prefixes: ! !! !!! priority, #project, @person, > forces a question.")
                item("Voice", key: hotkey("voice"),
                     "Hold to talk, or tap to latch and tap again to stop. Transcribed on this Mac. "
                     + "Start with “ask” or “hey steward” to send it to the agent; anything else is captured.")
                item("Floating panel", key: hotkey("hud"),
                     "A pill or card that stays on top on any display: current task and timer, a scratchpad for live notes, session dots. Drag it; it snaps to edges.")
                item("Quick chat", key: hotkey("agent"),
                     "A floating chat with the agent that stays where you put it. Replies stream in, the whole conversation is there, and closing it (esc) keeps everything: "
                     + "open it again and you are where you left off. ⌘N starts a new chat, the title switches between recent ones, ⌘O moves it into this window.")
                item("Toasts", "Drop from the notch when a session finishes, a meeting is about to start, the agent has a question, or something needs your approval.")
                item("Menu bar", "The Steward icon shows how many things are waiting on you; clicking it opens the notch panel.")
            }

            section("A place for everything it tracks", icon: "mappin.and.ellipse") {
                item("Task place", key: "↩",
                     "Open any task and its page slides in: where it came from, readable here (the message, the meeting moment, the ticket change, the page, the session, who said it and when); "
                     + "See more, which has the agent read the rest of the thread, meeting or ticket once and keeps a short note; Draft a reply, which files the reply as an approval for you to read, edit and approve; "
                     + "its sessions; and other tasks, suggestions, sessions and meetings that share its ticket, thread or person.")
                item("Session place", key: "↩",
                     "Open a session on the Sessions screen, from ⌘K, or from a toast: state and how long, repo, branch, ticket, pull request with checks and open threads, the linked task, the recap, "
                     + "the question it is blocked on, the last stretch of the conversation, and your own notes. Go to window works only when an open editor window has that folder, and says so when none does. Ended sessions keep their page.")
                item("Inbox, before you decide", "The selected suggestion shows the same source and See more, so you can judge it without opening the other app. What you said you would do sits under its own heading.")
                item("Loose ends", key: "L",
                     "On Today and in ⌘K: promises still open after a couple of days, sessions left waiting or ended with their task still open, people you are waiting on who went quiet, "
                     + "your pull requests stuck on failing checks or open threads, and pages you keep opening that nothing tracks. Computed on this Mac, no agent run. At most one nudge a day, and only when the list changed.")
                item("Other apps are a button", "A click opens the place in Steward. Leaving for chat, the tracker, the browser or the editor is always a labelled Open button.")
            }

            section("What it watches", icon: "eye") {
                item("Coding sessions", "Every Claude Code session on this Mac: working, finished and waiting for you, or blocked on a question; its repo, branch, ticket and pull request.")
                item("Pull requests", "Review decisions, failing checks and unresolved threads on your open PRs, through the GitHub CLI.")
                item("Chat, tickets, calendar, meetings", "Read through the connectors on your Claude login: direct messages, mentions and requests; tickets assigned to you; today's and tomorrow's events; recordings with summaries and action items.")
                item("Unread badges", "A Dock badge going up triggers an early sync, so quiet hours cost nothing.")
                item("Where your time goes", "The frontmost app and window, summarised under Activity. Window titles need Accessibility.")
                item("Off until you turn them on", "iMessage (needs Full Disk Access) and documents. Settings › Connectors.")
            }

            section("What it does without being asked", icon: "clock.arrow.circlepath") {
                item("Fills the Inbox", "Turns what it reads into suggested tasks, follow-ups and updates, each with its reason and a link to the source. Nothing reaches your task list until you accept it.")
                item("Ranks", "Every task carries a score and the reasons for it: due dates, project weight, a session waiting on you, a meeting coming up. Drag to override.")
                item("Nudges", "A session has been waiting, a meeting starts in a few minutes, something is due or overdue, an approval has been sitting.")
                item("Prepares and reviews", "A prep note before meetings with other people; a morning brief, an evening review and a weekly review, saved under Notes.")
                item("Remembers", "Keeps plain-text notes about your people, projects and preferences. Read, edit or delete them in Settings › Memory.")
            }

            section("What to ask the agent", icon: "bubble.left.and.text.bubble.right") {
                ForEach(CommandPalette.prompts, id: \.slash) { prompt in
                    item(prompt.slash, prompt.prompt)
                }
                item("Anything across your tools", "“What did we decide about the migration last week?” “Who is waiting on me?” “Summarise the thread with the design team and add the follow-ups.”")
                item("Changes to your list", "“Push everything due today that isn't urgent to tomorrow.” “Make a project for the launch and file these under it.”")
                item("Changes to this app", "“Add a column for estimates to the Tasks screen.” It edits its own source, shows you what changed, and rebuilds when you approve.")
                Button("Open the agent") { model.go(.agent) }.buttonStyle(.pressable(.primary)).padding(.top, Space.xs)
            }

            section("What it will not do on its own", icon: "hand.raised") {
                item("Anything other people can see", "Sending a message, editing a ticket or document, changing a calendar event, pushing code, commenting on a pull request. Each one waits in the Inbox as an approval card showing the exact action, and runs once, only after you approve it.")
                item("Spend past your cap", "Background work stops at the daily or monthly cap in Settings › Budget. The status bar shows today's spend.")
            }

            section("Keys in this window", icon: "keyboard") {
                keys([(["⌘", "K"], "search or run anything"), (["⌘", "N"], "new task"), (["⌘", "1…9"], "screens"), (["⌘", "/"], "this guide"), (["⌘", "Z"], "undo")])
                keys([(["J", "K"], "move"), (["␣"], "complete"), (["↩"], "open"), (["⌘", "↩"], "start"), (["S"], "snooze"), (["P"], "pin"), (["0…3"], "priority")])
                keys([(["A"], "accept"), (["E"], "edit, then accept"), (["X"], "dismiss"), (["M"], "see more"), (["⌘", "↩"], "approve an outside action")])
                keys([(["⌥", "M"], "task: see more"), (["⌥", "R"], "draft a reply"), (["⌥", "A"], "ask the agent"), (["⌥", "O"], "open the source")])
                keys([(["G"], "session: go to window"), (["C"], "copy resume"), (["R"], "recap"), (["L"], "link task"), (["N"], "notes"), (["E"], "unfold"), (["esc"], "back")])
                Text("Every screen lists its own keys along the bottom.").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
        }
    }

    private func hotkey(_ name: String) -> String? {
        store.settings["hotkeys"][name].string.map(HotkeyCombo.display)
    }

    private func section(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label(title, systemImage: icon).font(Typo.heading).foregroundStyle(Palette.text)
            VStack(alignment: .leading, spacing: Space.m) { content() }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.l)
    }

    private func item(_ title: String, key: String? = nil, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Space.s) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                if let key { KeyHint(key) }
            }
            Text(text).font(Typo.body).foregroundStyle(Palette.textDim).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keys(_ entries: [([String], String)]) -> some View {
        HStack(spacing: Space.l) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 5) {
                    HStack(spacing: 2) { ForEach(entry.0, id: \.self) { KeyHint($0) } }
                    Text(entry.1).font(Typo.caption).foregroundStyle(Palette.textDim)
                }
            }
        }
    }
}
