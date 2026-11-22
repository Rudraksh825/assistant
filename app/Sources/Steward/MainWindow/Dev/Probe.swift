import Foundation
import StewardKit

/// Dev aid: with `STEWARD_PROBE=1` the app calls every read endpoint the main window uses, once, a few
/// seconds after the brain comes online (`STEWARD_PROBE_DELAY`, default 10), and logs one line per call to
/// `app.log`. A decode error against a newer brain shows up here instead of as an empty screen.
@MainActor
enum BrainProbe {
    static func runIfRequested(app: AppContext) {
        let env = ProcessInfo.processInfo.environment
        guard env["STEWARD_PROBE"] == "1" else { return }
        Task {
            for _ in 0..<120 where !app.store.connection.isOnline { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(Double(env["STEWARD_PROBE_DELAY"] ?? "") ?? 10))
            let client = app.store.client
            let day = Calendar.current.startOfDay(for: Date()), now = Date()
            var failures = 0

            func check(_ name: String, _ call: () async throws -> String) async {
                do {
                    Log.info("probe \(name): ok \(try await call())")
                } catch where error.isAgentUnavailable {
                    Log.info("probe \(name): agent unavailable (handled)")
                } catch {
                    failures += 1
                    Log.error("probe \(name): \(error.brief)")
                }
            }

            await check("/state") { let s = try await client.state(); return "top=\(s.top.count) sessions=\(s.sessions.count)" }
            var tasks: [TaskItem] = []
            await check("/tasks?limit=5000") { tasks = try await client.tasks(limit: 5000); return "\(tasks.count) tasks" }
            if let first = tasks.first {
                await check("/tasks/:id") { try await client.task(first.id).title }
                await check("/tasks?parentId=") { "\(try await client.tasks(parentId: first.id).count) subtasks" }
            }
            await check("/tree") { let t = try await client.tree(); return "\(t.initiatives.count) initiatives, \(t.allProjects.count) projects" }
            await check("/suggestions") { "\(try await client.suggestions().count)" }
            var sessions: [CodeSession] = []
            await check("/sessions?includeEnded=1") { sessions = try await client.sessions(includeEnded: true); return "\(sessions.count)" }
            if let first = sessions.first { await check("/sessions/:id/recap") { "\(try await client.sessionRecap(first.id).count) chars" } }
            await check("/meetings") { "\(try await client.meetings(from: now.addingTimeInterval(-21 * 86_400), to: now.addingTimeInterval(7 * 86_400)).count)" }
            await check("/notes") { "\(try await client.notes().count)" }
            await check("/people") { "\(try await client.people().count)" }
            await check("/approvals") { "\(try await client.approvals().count)" }
            await check("/nudges") { "\(try await client.nudges().count)" }
            var threads: [ChatThread] = []
            await check("/chat/threads") { threads = try await client.chatThreads(); return "\(threads.count)" }
            if let first = threads.first { await check("/chat/threads/:id/messages") { "\(try await client.chatMessages(first.id).count)" } }
            await check("/chat/questions") { "\(try await client.chatQuestions().count)" }
            await check("/signals") { "\(try await client.signals(limit: 500).count)" }
            await check("/activity") { "\(try await client.activity(from: day, to: now).count) spans" }
            await check("/activity/summary") { let s = try await client.activitySummary(from: day, to: now); return "\(s.byApp.count) apps, \(s.switches) switches" }
            await check("/runs") { "\(try await client.runs(limit: 100).count)" }
            await check("/cost") { let c = try await client.cost(days: 30); return "\(c.byDay.count) days, \(c.byKind.count) kinds" }
            await check("/settings") { "billing=\(try await client.settings()["agent"]["billing"].string ?? "?")" }
            await check("/jobs") { try await client.jobs().map(\.name).joined(separator: ",") }
            var files: [MemoryFile] = []
            await check("/memory") { files = try await client.memoryFiles(); return "\(files.count) files" }
            if let first = files.first { await check("/memory/:path") { "\(try await client.memoryFile(first.path).count) chars" } }
            Log.info("probe done: \(failures) failure\(failures == 1 ? "" : "s")")
        }
    }
}
