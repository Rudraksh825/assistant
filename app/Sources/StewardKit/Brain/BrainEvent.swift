import Foundation

/// One typed server-sent event from `GET /events`.
public enum BrainEvent: Sendable {
    public enum Entity: String, LenientEnum {
        case tasks, projects, initiatives, suggestions, sessions, meetings, notes, approvals, nudges, budget, settings, people, jobs, places, unknown
    }

    public struct ChatRef: Decodable, Sendable { public var threadId: String; public var runId: String }
    public struct ChatDelta: Decodable, Sendable { public var threadId: String; public var runId: String; public var text: String }
    public struct ChatTool: Decodable, Sendable {
        public var threadId: String, runId: String, callId: String, name: String
        public var input: JSONValue?
        public var status: ToolStatus
        public var result: String?
    }
    public struct ChatQuestion: Decodable, Identifiable, Hashable, Sendable {
        public var threadId: String, questionId: String, question: String
        public var options: [String]
        public var id: String { questionId }
    }
    public struct ChatDone: Decodable, Sendable { public var threadId: String, runId: String, messageId: String; public var costUsd: Double }
    public struct ChatError: Decodable, Sendable { public var threadId: String, runId: String, message: String }
    public struct UICommand: Decodable, Sendable {
        public enum Command: String, LenientEnum {
            case openView = "open_view", showNote = "show_note", focusSession = "focus_session", speak, openURL = "open_url", toast, unknown
        }
        public var command: Command
        public var args: JSONValue?
        public init(command: Command, args: JSONValue? = nil) { self.command = command; self.args = args }
    }

    case hello(version: String)
    case stateChanged([Entity])
    case sessionUpdated(CodeSession)
    case nudge(Nudge)
    case nudgeDismissed(id: String)
    case chatStarted(ChatRef)
    case chatDelta(ChatDelta)
    case chatTool(ChatTool)
    case chatQuestion(ChatQuestion)
    case chatDone(ChatDone)
    case chatError(ChatError)
    case agentActivity(StateSnapshot.AgentStatus)
    case approvalRequested(Approval)
    case uiCommand(UICommand)
    case appRelaunch(reason: String)
    case ping

    private struct Hello: Decodable { var version: String }
    private struct Changed: Decodable { var entities: [Entity] }
    private struct Ref: Decodable { var id: String }
    private struct Relaunch: Decodable { var reason: String }

    /// nil for event types this build does not know (forward compatible).
    public static func parse(type: String, data: Data) throws -> BrainEvent? {
        func d<T: Decodable>(_ t: T.Type) throws -> T { try BrainJSON.decoder.decode(t, from: data) }
        switch type {
        case "hello": return .hello(version: try d(Hello.self).version)
        case "state.changed": return .stateChanged(try d(Changed.self).entities)
        case "session.updated": return .sessionUpdated(try d(CodeSession.self))
        case "nudge": return .nudge(try d(Nudge.self))
        case "nudge.dismissed": return .nudgeDismissed(id: try d(Ref.self).id)
        case "chat.started": return .chatStarted(try d(ChatRef.self))
        case "chat.delta": return .chatDelta(try d(ChatDelta.self))
        case "chat.tool": return .chatTool(try d(ChatTool.self))
        case "chat.question": return .chatQuestion(try d(ChatQuestion.self))
        case "chat.done": return .chatDone(try d(ChatDone.self))
        case "chat.error": return .chatError(try d(ChatError.self))
        case "agent.activity": return .agentActivity(try d(StateSnapshot.AgentStatus.self))
        case "approval.requested": return .approvalRequested(try d(Approval.self))
        case "ui.command": return .uiCommand(try d(UICommand.self))
        case "app.relaunch": return .appRelaunch(reason: try d(Relaunch.self).reason)
        case "ping": return .ping
        default: return nil
        }
    }
}
