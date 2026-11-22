import Foundation

public enum BrainError: Error, LocalizedError, Sendable {
    /// No port/token file yet, or nothing listening.
    case offline(String)
    case http(status: Int, code: String, message: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .offline(let why): "Brain offline: \(why)"
        case .http(let status, _, let message): "\(message) (\(status))"
        case .decoding(let why): "Unexpected response: \(why)"
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? BrainError)?.errorDescription ?? error.localizedDescription
    }
}

/// Async client for the brain's localhost API. Port and token are re-read from the data dir on every
/// request, so a restarted brain on a new port is picked up without any coordination.
public final class BrainClient: Sendable {
    public let dataDir: DataDir
    let session: URLSession

    /// `protocolClasses` lets a dev build answer requests in-process (the snapshot mode's sample brain).
    public init(dataDir: DataDir = .default, protocolClasses: [AnyClass] = []) {
        self.dataDir = dataDir
        let config = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: Transport

    public typealias Query = [String: String?]

    func request(_ method: String, _ path: String, query: Query = [:], body: Data? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let port = dataDir.port else { throw BrainError.offline("no brain.port in \(dataDir.url.path)") }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = port
        parts.percentEncodedPath = path
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { parts.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = parts.url else { throw BrainError.offline("bad path \(path)") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let token = dataDir.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { var code: String; var message: String }
        var error: Inner
    }

    /// Any endpoint, raw bytes back. Throws `BrainError.http` on non-2xx.
    @discardableResult
    public func raw(_ method: String, _ path: String, query: Query = [:], body: (any Encodable)? = nil) async throws -> Data {
        let payload = try body.map { try BrainJSON.encoder.encode($0) }
        let req = try request(method, path, query: query, body: payload)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch let error as URLError {
            throw BrainError.offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let e = try? BrainJSON.decoder.decode(ErrorBody.self, from: data)
            throw BrainError.http(status: status, code: e?.error.code ?? "http_\(status)", message: e?.error.message ?? "HTTP \(status)")
        }
        return data
    }

    public func call<T: Decodable>(_ method: String, _ path: String, query: Query = [:], body: (any Encodable)? = nil) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        do { return try BrainJSON.decoder.decode(T.self, from: data) } catch {
            throw BrainError.decoding("\(method) \(path): \(error)")
        }
    }

    private func items<T: Decodable>(_ path: String, _ query: Query = [:]) async throws -> [T] {
        try await (call("GET", path, query: query) as ItemsResponse<T>).items
    }

    private func ms(_ date: Date?) -> String? { date.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } }
    private func seg(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? s }

    // MARK: Core

    public func health() async throws -> HealthResponse { try await call("GET", "/health") }
    public func state() async throws -> StateSnapshot { try await call("GET", "/state") }

    // MARK: Tasks

    /// The brain caps a list at 500 unless `limit` says otherwise.
    public func tasks(status: [TaskStatus] = [], projectId: String? = nil, parentId: String? = nil, q: String? = nil, limit: Int? = nil) async throws -> [TaskItem] {
        try await items("/tasks", [
            "status": status.isEmpty ? nil : status.map(\.rawValue).joined(separator: ","),
            "projectId": projectId, "parentId": parentId, "q": q, "limit": limit.map(String.init),
        ])
    }
    public func createTask(_ fields: JSONValue) async throws -> TaskItem { try await call("POST", "/tasks", body: fields) }
    public func task(_ id: String) async throws -> TaskItem { try await call("GET", "/tasks/\(seg(id))") }
    public func updateTask(_ id: String, _ patch: JSONValue) async throws -> TaskItem { try await call("PATCH", "/tasks/\(seg(id))", body: patch) }
    public func deleteTask(_ id: String) async throws { try await raw("DELETE", "/tasks/\(seg(id))") }
    public func completeTask(_ id: String) async throws -> TaskItem { try await call("POST", "/tasks/\(seg(id))/complete") }
    public func startTask(_ id: String, exclusive: Bool = false) async throws -> TaskItem {
        try await call("POST", "/tasks/\(seg(id))/start", query: ["exclusive": exclusive ? "1" : nil])
    }
    public func snoozeTask(_ id: String, until: Date) async throws -> TaskItem {
        try await call("POST", "/tasks/\(seg(id))/snooze", body: ["until": JSONValue.ms(until)])
    }
    public func reorderTasks(_ ids: [String]) async throws { try await raw("POST", "/tasks/reorder", body: ["ids": ids]) }
    public func rerankTasks() async throws { try await raw("POST", "/tasks/rerank") }

    // MARK: Projects, initiatives

    public func projects() async throws -> [Project] { try await items("/projects") }
    public func createProject(_ fields: JSONValue) async throws -> Project { try await call("POST", "/projects", body: fields) }
    public func project(_ id: String) async throws -> Project { try await call("GET", "/projects/\(seg(id))") }
    public func updateProject(_ id: String, _ patch: JSONValue) async throws -> Project { try await call("PATCH", "/projects/\(seg(id))", body: patch) }
    public func deleteProject(_ id: String) async throws { try await raw("DELETE", "/projects/\(seg(id))") }

    public func initiatives() async throws -> [Initiative] { try await items("/initiatives") }
    public func createInitiative(_ fields: JSONValue) async throws -> Initiative { try await call("POST", "/initiatives", body: fields) }
    public func initiative(_ id: String) async throws -> Initiative { try await call("GET", "/initiatives/\(seg(id))") }
    public func updateInitiative(_ id: String, _ patch: JSONValue) async throws -> Initiative { try await call("PATCH", "/initiatives/\(seg(id))", body: patch) }
    public func deleteInitiative(_ id: String) async throws { try await raw("DELETE", "/initiatives/\(seg(id))") }

    public func tree() async throws -> Tree { try await call("GET", "/tree") }

    // MARK: Suggestions

    public func suggestions(status: SuggestionStatus? = .pending) async throws -> [Suggestion] {
        try await items("/suggestions", ["status": status?.rawValue])
    }
    public func acceptSuggestion(_ id: String, edits: JSONValue? = nil) async throws -> AcceptResponse {
        try await call("POST", "/suggestions/\(seg(id))/accept", body: edits.map { ["edits": $0] })
    }
    public func dismissSuggestion(_ id: String) async throws { try await raw("POST", "/suggestions/\(seg(id))/dismiss") }
    public func acceptAllSuggestions(_ ids: [String]) async throws { try await raw("POST", "/suggestions/accept-all", body: ["ids": ids]) }

    // MARK: Sessions

    public func sessions(includeEnded: Bool = false) async throws -> [CodeSession] {
        try await items("/sessions", ["includeEnded": includeEnded ? "1" : "0"])
    }
    public func updateSession(_ id: String, _ patch: JSONValue) async throws { try await raw("PATCH", "/sessions/\(seg(id))", body: patch) }
    public func sessionRecap(_ id: String, refresh: Bool = false) async throws -> String {
        try await (call("GET", "/sessions/\(seg(id))/recap", query: ["refresh": refresh ? "1" : nil]) as RecapResponse).text
    }

    public func session(_ id: String) async throws -> CodeSession { try await call("GET", "/sessions/\(seg(id))") }
    public func sessionPlace(_ id: String) async throws -> SessionPlace { try await call("GET", "/sessions/\(seg(id))/place") }
    /// The readable tail of the session's conversation, read from the transcript on this Mac.
    public func sessionTurns(_ id: String, limit: Int = 30) async throws -> SessionTurns {
        try await call("GET", "/sessions/\(seg(id))/turns", query: ["limit": String(limit)])
    }

    // MARK: Places

    public func taskPlace(_ id: String) async throws -> TaskPlace { try await call("GET", "/tasks/\(seg(id))/place") }
    /// Starts "See more" (or returns what is stored). The note arrives with `state.changed{places}`.
    @discardableResult
    public func seeMore(task id: String, refresh: Bool = false) async throws -> ItemContext {
        try await call("POST", "/tasks/\(seg(id))/context", query: ["refresh": refresh ? "1" : nil])
    }
    @discardableResult
    public func draftReply(task id: String) async throws -> ItemContext { try await call("POST", "/tasks/\(seg(id))/draft-reply") }
    public func suggestionPlace(_ id: String) async throws -> SuggestionPlace { try await call("GET", "/suggestions/\(seg(id))/place") }
    @discardableResult
    public func seeMore(suggestion id: String, refresh: Bool = false) async throws -> ItemContext {
        try await call("POST", "/suggestions/\(seg(id))/context", query: ["refresh": refresh ? "1" : nil])
    }

    public func looseEnds() async throws -> LooseEnds { try await call("GET", "/loose-ends") }
    public func dismissLooseEnd(_ id: String) async throws { try await raw("POST", "/loose-ends/dismiss", body: ["id": id]) }
    /// Gives a loose end that nothing tracks (a page, a pull request) a task, and returns it.
    public func trackLooseEnd(_ id: String) async throws -> TaskItem { try await call("POST", "/loose-ends/track", body: ["id": id]) }

    // MARK: Meetings

    public func meetings(from: Date? = nil, to: Date? = nil) async throws -> [Meeting] {
        try await items("/meetings", ["from": ms(from), "to": ms(to)])
    }
    public func meeting(_ id: String) async throws -> Meeting { try await call("GET", "/meetings/\(seg(id))") }
    public func prepMeeting(_ id: String) async throws -> String { try await (call("POST", "/meetings/\(seg(id))/prep") as RunRef).runId }

    // MARK: Notes, people, signals, activity

    public func notes(q: String? = nil, limit: Int? = nil) async throws -> [Note] { try await items("/notes", ["q": q, "limit": limit.map(String.init)]) }
    public func createNote(_ fields: JSONValue) async throws -> Note { try await call("POST", "/notes", body: fields) }
    public func note(_ id: String) async throws -> Note { try await call("GET", "/notes/\(seg(id))") }
    public func updateNote(_ id: String, _ patch: JSONValue) async throws -> Note { try await call("PATCH", "/notes/\(seg(id))", body: patch) }
    public func deleteNote(_ id: String) async throws { try await raw("DELETE", "/notes/\(seg(id))") }

    public func people() async throws -> [Person] { try await items("/people") }
    public func createPerson(_ fields: JSONValue) async throws -> Person { try await call("POST", "/people", body: fields) }
    public func updatePerson(_ id: String, _ patch: JSONValue) async throws { try await raw("PATCH", "/people/\(seg(id))", body: patch) }
    public func deletePerson(_ id: String) async throws { try await raw("DELETE", "/people/\(seg(id))") }

    public func signals(source: SourceKind? = nil, since: Date? = nil, limit: Int? = nil) async throws -> [Signal] {
        try await items("/signals", ["source": source?.rawValue, "since": ms(since), "limit": limit.map(String.init)])
    }
    public func activity(from: Date? = nil, to: Date? = nil) async throws -> [ActivitySpan] {
        try await items("/activity", ["from": ms(from), "to": ms(to)])
    }
    public func activitySummary(from: Date? = nil, to: Date? = nil) async throws -> ActivitySummary {
        try await call("GET", "/activity/summary", query: ["from": ms(from), "to": ms(to)])
    }

    // MARK: Capture, chat

    private struct CaptureBody: Encodable { var text: String; var source: CaptureSource?; var context: CaptureContext? }
    @discardableResult
    public func capture(_ text: String, source: CaptureSource? = nil, context: CaptureContext? = nil) async throws -> String {
        try await (call("POST", "/capture", body: CaptureBody(text: text, source: source, context: context)) as CaptureResponse).noteId
    }

    public func chatThreads() async throws -> [ChatThread] { try await items("/chat/threads") }
    public func createChatThread(title: String? = nil) async throws -> ChatThread {
        try await call("POST", "/chat/threads", body: title.map { ["title": $0] } ?? [:])
    }
    public func renameChatThread(_ id: String, title: String) async throws -> ChatThread {
        try await call("PATCH", "/chat/threads/\(seg(id))", body: ["title": title])
    }
    public func deleteChatThread(_ id: String) async throws { try await raw("DELETE", "/chat/threads/\(seg(id))") }
    /// Questions the agent asked that nobody answered yet (a client that was offline missed their events).
    public func chatQuestions() async throws -> [BrainEvent.ChatQuestion] { try await items("/chat/questions") }
    public func chatMessages(_ threadId: String) async throws -> [ChatMessage] { try await items("/chat/threads/\(seg(threadId))/messages") }
    private struct ChatBody: Encodable { var text: String; var context: JSONValue? }
    public func sendChat(_ threadId: String, text: String, context: JSONValue? = nil) async throws -> SendResponse {
        try await call("POST", "/chat/threads/\(seg(threadId))/messages", body: ChatBody(text: text, context: context))
    }
    public func interruptChat(_ threadId: String) async throws { try await raw("POST", "/chat/threads/\(seg(threadId))/interrupt") }
    public func answerQuestion(_ questionId: String, answer: String) async throws {
        try await raw("POST", "/chat/answer", body: ["questionId": questionId, "answer": answer])
    }

    // MARK: Approvals

    public func approvals(status: ApprovalStatus? = .pending) async throws -> [Approval] {
        try await items("/approvals", ["status": status?.rawValue])
    }
    public func approve(_ id: String, edits: JSONValue? = nil) async throws -> Approval {
        try await call("POST", "/approvals/\(seg(id))/approve", body: edits.map { ["edits": $0] })
    }
    public func deny(_ id: String, reason: String? = nil) async throws {
        try await raw("POST", "/approvals/\(seg(id))/deny", body: reason.map { ["reason": $0] })
    }

    // MARK: Sensors

    public func postActivity(_ spans: [ActivitySpanInput]) async throws { try await raw("POST", "/sensors/activity", body: ["spans": spans]) }
    private struct SensorEvent: Encodable { var kind: String; var at: Date; var data: JSONValue? }
    public func postSensorEvent(_ kind: String, at: Date = Date(), data: JSONValue? = nil) async throws {
        try await raw("POST", "/sensors/event", body: SensorEvent(kind: kind, at: at, data: data))
    }

    // MARK: Nudges, runs, cost, settings, jobs, memory

    public func nudges() async throws -> [Nudge] { try await items("/nudges") }
    public func dismissNudge(_ id: String) async throws { try await raw("POST", "/nudges/\(seg(id))/dismiss") }
    public func actOnNudge(_ id: String, actionId: String) async throws {
        try await raw("POST", "/nudges/\(seg(id))/act", body: ["actionId": actionId])
    }

    public func runs(limit: Int? = nil) async throws -> [AgentRun] { try await items("/runs", ["limit": limit.map(String.init)]) }
    public func cost(days: Int = 30) async throws -> CostReport { try await call("GET", "/cost", query: ["days": String(days)]) }

    public func settings() async throws -> JSONValue { try await call("GET", "/settings") }
    @discardableResult
    public func putSettings(_ settings: JSONValue) async throws -> Data { try await raw("PUT", "/settings", body: settings) }
    public func setSecret(name: String, value: String) async throws {
        try await raw("POST", "/settings/secret", body: ["name": name, "value": value])
    }

    public func jobs() async throws -> [Job] { try await items("/jobs") }
    public func runJob(_ name: String) async throws { try await raw("POST", "/jobs/\(seg(name))/run") }
    /// `schedule: .some(nil)` puts the job back on its own schedule; leaving a parameter out leaves it alone.
    @discardableResult
    public func updateJob(_ name: String, enabled: Bool? = nil, schedule: Job.Schedule?? = nil) async throws -> Job {
        var body: [String: JSONValue] = [:]
        if let enabled { body["enabled"] = .bool(enabled) }
        if let schedule {
            body["schedule"] = try schedule.map { try BrainJSON.decoder.decode(JSONValue.self, from: BrainJSON.encoder.encode($0)) } ?? .null
        }
        return try await call("PATCH", "/jobs/\(seg(name))", body: JSONValue.object(body))
    }

    public func memoryIndex() async throws -> JSONValue { try await call("GET", "/memory") }
    public func memoryFile(_ path: String) async throws -> String {
        let data = try await raw("GET", "/memory/" + path.split(separator: "/").map { seg(String($0)) }.joined(separator: "/"))
        if let json = try? BrainJSON.decoder.decode(JSONValue.self, from: data), let content = json["content"].string { return content }
        return String(decoding: data, as: UTF8.self)
    }
    public func putMemory(_ path: String, content: String) async throws {
        try await raw("PUT", "/memory/" + path.split(separator: "/").map { seg(String($0)) }.joined(separator: "/"), body: ["content": content])
    }

    public func memoryFiles() async throws -> [MemoryFile] { try await items("/memory") }
    public func deleteMemory(_ path: String) async throws {
        try await raw("DELETE", "/memory/" + path.split(separator: "/").map { seg(String($0)) }.joined(separator: "/"))
    }

    @discardableResult
    public func rebuildApp() async throws -> RebuildResponse { try await call("POST", "/app/rebuild") }
}
