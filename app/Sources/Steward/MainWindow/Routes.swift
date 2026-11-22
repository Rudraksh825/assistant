import SwiftUI

/// The main window's routing table. To add a screen: add a case, its title/icon, and its view below.
/// Raw values are what the brain sends in `ui.command open_view` and nudge `open_view` actions.
/// The first nine cases are ⌘1…⌘9, in this order.
enum Route: String, CaseIterable, Identifiable {
    case today, inbox, tasks, projects, sessions, meetings, notes, people, agent, activity, settings, guide

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .projects: "square.stack.3d.up"
        case .sessions: "terminal"
        case .meetings: "calendar"
        case .notes: "note.text"
        case .people: "person.2"
        case .agent: "sparkles"
        case .activity: "chart.bar.xaxis"
        case .settings: "gearshape"
        case .guide: "questionmark.circle"
        }
    }

    var shortcut: String {
        switch self {
        case .activity: "⌘0"
        case .settings: "⌘,"
        case .guide: "⌘/"
        default: "⌘\((Route.allCases.firstIndex(of: self) ?? 0) + 1)"
        }
    }

    /// The narrowest the screen can get before the task inspector should float over it instead of squeezing it.
    var minWidth: CGFloat {
        switch self {
        case .today: 860
        case .tasks, .inbox: 500
        default: 640
        }
    }

    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .today: TodayScreen()
        case .inbox: InboxScreen()
        case .tasks: TasksScreen()
        case .projects: ProjectsScreen()
        case .sessions: SessionsScreen()
        case .meetings: MeetingsScreen()
        case .notes: NotesScreen()
        case .people: PeopleScreen()
        case .agent: AgentScreen()
        case .activity: ActivityScreen()
        case .settings: SettingsScreen()
        case .guide: GuideScreen()
        }
    }
}
