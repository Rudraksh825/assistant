import Foundation
import StewardKit

/// An in-process stand-in for the brain, used by the snapshot mode: answers every GET with an invented
/// dataset through the real `BrainClient` and decoders, and keeps `/events` open so the store goes online.
/// Writes are accepted and ignored.
final class SampleBrain: URLProtocol, @unchecked Sendable {
    static let port = 47_999

    /// A client wired to the sample brain, with a throwaway data dir that only holds the port.
    static func client() -> BrainClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steward-sample-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(port)".write(to: dir.appendingPathComponent("brain.port"), atomically: true, encoding: .utf8)
        return BrainClient(dataDir: DataDir(url: dir), protocolClasses: [SampleBrain.self])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams: [SampleBrain] = []

    /// Pushes one server-sent event to every open `/events` stream.
    static func emit(_ type: String, _ payload: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let frame = Data("event: \(type)\ndata: ".utf8) + data + Data("\n\n".utf8)
        lock.lock()
        let open = streams
        lock.unlock()
        for stream in open { stream.client?.urlProtocol(stream, didLoad: frame) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == port }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        if url.path == "/events" {
            respond(200, "text/event-stream")
            client?.urlProtocol(self, didLoad: Data("event: hello\ndata: {\"version\":\"sample\"}\n\n".utf8))
            Self.lock.lock()
            Self.streams.append(self)
            Self.lock.unlock()
            return
        }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let (status, body) = SampleData.shared.respond(method, url.path, query)
        respond(status, "application/json")
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.streams.removeAll { $0 === self }
        Self.lock.unlock()
    }

    private func respond(_ status: Int, _ type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

/// The invented dataset. Every name, repo, ticket and message here is made up.
final class SampleData: @unchecked Sendable {
    static let shared = SampleData()
    typealias Obj = [String: Any]
    /// `STEWARD_SAMPLE_EMPTY=1`: a brain on its first run, with nothing in it yet.
    static let empty = ProcessInfo.processInfo.environment["STEWARD_SAMPLE_EMPTY"] == "1"

    let now = Date()
    private func at(_ minutes: Double) -> Int64 { Int64((now.timeIntervalSince1970 + minutes * 60) * 1000) }
    private var null: NSNull { NSNull() }
    private func opt(_ value: Any?) -> Any { value ?? NSNull() }

    lazy var initiatives: [Obj] = [
        initiative("i1", "Ship usage-based billing", 3, "Q4", "Metered plans live for every workspace, with invoices finance trusts."),
        initiative("i2", "Reliability", 2, "ongoing", "Fewer pages, faster search."),
        initiative("i3", "Team", 1, nil, ""),
    ]

    lazy var projects: [Obj] = [
        project("p1", "i1", "Billing engine", "F2A65A", 3),
        project("p2", "i1", "Invoice UI", "7AA2F7", 2),
        project("p3", "i1", "Migration and backfill", "5CC8B8", 2),
        project("p4", "i2", "Search latency", "B39DF5", 2),
        project("p5", "i2", "On-call hygiene", "F2C94C", 1),
        project("p6", "i3", "Hiring: backend", "E59FCB", 1),
        project("p7", "i3", "Onboarding guide", "8BD3A0", 0, status: "paused"),
        project("p8", nil, "Home and errands", "D9B38C", 1),
        project("p9", nil, "Garden sensors", "6CC4E8", 0),
    ]

    lazy var tasks: [Obj] = {
        var list: [Obj] = [
            task("t1", "Fix proration rounding in mid-cycle upgrades", status: "doing", priority: 3, project: "p1", due: 190, estimate: 90, score: 94,
                 reasons: ["due today", "session waiting 12m", "urgent"], people: ["Jonas Lindqvist"], tags: ["bug"],
                 notes: "Upgrades in the middle of a 31-day cycle are off by a cent.\n\n- Reproduce with the March fixture\n- Banker's rounding in `prorate()`\n- Confirm the half-cent rule with finance",
                 links: [link("ticket", "ENG-412", "https://tickets.example.com/ENG-412"), link("pr", "acme-billing #1841", "https://git.example.com/acme/billing/pull/1841")],
                 source: "ticket", updated: -47),
            task("t2", "Review Jonas's ledger schema PR", priority: 2, project: "p1", estimate: 30, pinned: true, score: 81,
                 reasons: ["review requested 3h ago", "blocks Jonas"], people: ["Jonas Lindqvist"],
                 links: [link("pr", "acme-billing #1836", "https://git.example.com/acme/billing/pull/1836")], source: "git"),
            task("t3", "Reply to Mira about the launch date", priority: 2, project: "p1", score: 77, reasons: ["asked 2h ago", "1:1 at 4:30"], people: ["Mira Okafor"],
                 links: [link("thread", "#billing-launch", "https://chat.example.com/billing-launch/p1712")], source: "chat"),
            task("t6", "Prep for the billing design review", project: "p2", due: 40, estimate: 20, score: 72, reasons: ["meeting in 40m"], source: "calendar"),
            task("t7", "p95 search latency regression after the index change", priority: 2, project: "p4", due: -1500, score: 69,
                 reasons: ["1d overdue", "alert fired twice"], people: ["Hana Sato"], links: [link("ticket", "ENG-440", "https://tickets.example.com/ENG-440")], source: "ticket"),
            task("t4", "Write the backfill dry-run plan", priority: 2, project: "p3", due: 1500, estimate: 60, score: 58, reasons: ["due tomorrow", "project weight 2"]),
            task("t11", "Phone screen feedback: backend candidate", project: "p6", due: 300, estimate: 15, score: 55, reasons: ["due today"], people: ["Dev Malhotra"]),
            task("t5", "Invoice PDF: tax line wraps on long names", priority: 1, project: "p2", score: 46, reasons: ["session working"],
                 links: [link("ticket", "ENG-431", "https://tickets.example.com/ENG-431")], source: "ticket"),
            task("t8", "Finance sign-off on tax rounding rules", status: "waiting", project: "p1", score: 41, reasons: ["waiting 2d"], waitingOn: "Teo Alvarez", people: ["Teo Alvarez"]),
            task("t10", "Rotate on-call handoff notes", priority: 1, project: "p5", due: 4300, score: 33, reasons: ["due in 3d"]),
            task("t9", "Design for the empty invoice state", status: "waiting", project: "p2", score: 28, reasons: ["waiting 5h"], waitingOn: "Priya Raman", people: ["Priya Raman"]),
            task("t14", "Look into the flaky webhook retry test", status: "inbox", project: "p1", score: 24, reasons: ["seen in 2 sessions"], source: "claude"),
            task("t15", "Idea: usage alerts by email", status: "inbox", score: 12, source: "capture"),
            task("t13", "Renew passport", project: "p8", due: 17_000, score: 11, reasons: ["due in 12d"]),
            task("t12", "Book dentist", project: "p8", score: 8),
            task("t16", "Draft Q1 reliability goals", project: "p5", score: 0, snoozed: 5000),
            task("t17", "Add a regression test for 31-day months", project: "p1", parent: "t1", score: 40),
            task("t18", "Check the half-cent rule with finance", status: "done", project: "p1", parent: "t1", completed: -180),
        ]
        let done: [(String, String)] = [
            ("p1", "Model usage records as an append-only ledger"), ("p1", "Spike: provider meter events vs. our own counters"), ("p1", "Unit tests for tiered pricing"),
            ("p2", "Invoice list: pagination"), ("p2", "Download as PDF"), ("p3", "Inventory legacy plans"), ("p4", "Add tracing to the query planner"),
            ("p5", "Quiet the disk-space alert"), ("p6", "Write the take-home rubric"), ("p8", "Renew car insurance"),
        ]
        for (index, item) in done.enumerated() {
            list.append(task("d\(index)", item.1, status: "done", project: item.0, completed: Double(-200 - index * 310)))
        }
        if let extra = Int(ProcessInfo.processInfo.environment["STEWARD_SAMPLE_TASKS"] ?? "") {
            let verbs = ["Review", "Fix", "Draft", "Ship", "Check", "Reply about", "Plan", "Measure"]
            let nouns = ["invoice rounding", "search index", "alert routing", "plan migration", "webhook retries", "tax rules", "usage export", "onboarding doc"]
            for i in 0..<extra {
                list.append(task("x\(i)", "\(verbs[i % verbs.count]) \(nouns[(i / 8) % nouns.count]) #\(i)", status: i % 9 == 0 ? "done" : i % 7 == 0 ? "waiting" : "todo",
                                 priority: i % 4, project: "p\(1 + i % 9)", due: i % 3 == 0 ? Double(i * 37 - 2000) : nil, score: Double(i % 90)))
            }
        }
        return list
    }()

    lazy var sessions: [Obj] = [
        session("s2", "acme-billing", "feat/ledger-schema", "ENG-398", "blocked", -4, "Wants to run the ledger migration against staging",
                prompt: "apply the review comments and re-run the migration locally", reply: "The schema changes are in. To verify them I need to run `pnpm migrate:staging`, which touches the shared staging database. Allow it?",
                pr: ["number": 1836, "url": "https://git.example.com/acme/billing/pull/1836", "state": "OPEN", "reviewDecision": "CHANGES_REQUESTED", "checks": "failing", "unresolved": 3], task: "t2",
                notes: "Jonas wants the staging run announced in #billing-launch first.\nDo not let it touch the usage tables."),
        session("s1", "acme-billing", "fix/proration-rounding", "ENG-412", "waiting", -12, "Fixed proration rounding for mid-cycle upgrades",
                prompt: "run the proration suite again and show me the failing cases", reply: "All 48 proration tests pass now. The 31-day case needed banker's rounding in `prorate()`. Want me to push and mark the PR ready?",
                pr: ["number": 1841, "url": "https://git.example.com/acme/billing/pull/1841", "state": "OPEN", "reviewDecision": NSNull(), "checks": "passing", "unresolved": 0], task: "t1"),
        session("s6", "acme-web", "chore/deps", nil, "waiting", -65, "Dependency bumps are ready for review",
                prompt: "bump the minor versions and fix whatever breaks", reply: "Bumped 14 packages. Two snapshot tests changed because of a date-format fix upstream; I updated them. Ready for you to look.",
                pr: ["number": 977, "url": "https://git.example.com/acme/web/pull/977", "state": "OPEN", "reviewDecision": "APPROVED", "checks": "passing", "unresolved": 1]),
        session("s3", "acme-web", "fix/invoice-pdf-wrap", "ENG-431", "working", -3, "Reworking the tax line layout in the invoice PDF",
                prompt: "long legal names push the tax line to a second page, fix the layout", reply: "Measuring the text before layout so the row can grow instead of overflowing…", task: "t5"),
        session("s4", "search-service", "perf/index-warmup", "ENG-440", "working", -22, "Profiling index warm-up after the shard change",
                prompt: "profile cold queries after a deploy and tell me where the time goes", reply: "Collecting flame graphs for the first 200 queries after restart…", task: "t7"),
        session("s5", "infra", "main", nil, "idle", -40, "Reviewed the Terraform drift report", prompt: "summarise the drift report", reply: "Three resources drifted; none are urgent. Details are in drift.md."),
    ]

    /// `variant == "many-sessions"`: a busy afternoon, with the long worktree names and branches real sessions have.
    var variant: String?
    var liveSessions: [Obj] { variant == "many-sessions" ? manySessions : sessions }

    lazy var manySessions: [Obj] = {
        let rows: [(String, String, String?, String, Double, String)] = [
            ("acme-billing-eng-412-proration-rounding", "fix/eng-412-proration-rounding-mid-cycle-upgrades", "ENG-412", "blocked", -6, "Wants to run the ledger migration against the shared staging database"),
            ("acme-billing-eng-398-ledger-schema-review", "feat/eng-398-ledger-schema-append-only-usage-records", "ENG-398", "waiting", -14, "Applied the review comments on the ledger schema and re-ran the migration locally"),
            ("acme-web-eng-431-invoice-pdf-tax-line-wrap", "fix/eng-431-invoice-pdf-tax-line-wraps-on-long-legal-names", "ENG-431", "waiting", -52, "Reworked the tax line layout so long legal names grow the row"),
            ("search-service-eng-440-index-warmup", "perf/eng-440-index-warmup-after-shard-change", "ENG-440", "working", -3, "Profiling index warm-up after the shard change"),
            ("acme-web", "chore/dependency-bumps-and-snapshot-test-updates", nil, "working", -9, "Bumping minor versions and fixing what breaks"),
            ("infra-terraform-drift-report", "main", nil, "working", -21, "Summarising the Terraform drift report"),
            ("acme-docs-billing-api-reference", "docs/billing-api-usage-endpoints", nil, "working", -2, "Documenting the new usage endpoints"),
            ("acme-billing-eng-405-backfill-dry-run", "chore/eng-405-backfill-dry-run-on-production-snapshot", "ENG-405", "working", -33, "Dry-running the backfill on yesterday's snapshot"),
            ("acme-mobile-eng-455-usage-alerts", "feat/eng-455-usage-alerts-push-notifications", "ENG-455", "idle", -240, "Sketched the usage alert settings screen"),
            ("search-service", "spike/query-planner-tracing", nil, "idle", -410, "Added tracing to the query planner"),
            ("acme-billing-eng-447-webhook-retry-flake", "fix/eng-447-flaky-webhook-retry-test", "ENG-447", "idle", -95, "Looked into the flaky webhook retry test"),
            ("onboarding-guide", "docs/first-week-checklist", nil, "idle", -1300, "Outlined the first-week checklist"),
            ("garden-sensors-firmware", "feat/soil-moisture-calibration-table", nil, "idle", -2600, "Calibrated the soil moisture table"),
        ]
        return rows.enumerated().map { index, row in
            let pr: Obj? = index % 3 == 0 ? ["number": 1800 + index, "url": "https://git.example.com/acme/billing/pull/\(1800 + index)", "state": "OPEN",
                                             "reviewDecision": index == 0 ? "CHANGES_REQUESTED" : NSNull(), "checks": index == 0 ? "failing" : "passing", "unresolved": index == 0 ? 3 : 0] : nil
            return session("x\(index)", row.0.components(separatedBy: "-eng-").first ?? row.0, row.1, row.2, row.3, row.4, row.5,
                           prompt: "pick up where we left off and tell me what is still failing before you change anything else",
                           reply: "Done with the pass. `pnpm test --filter billing` is green except for two snapshot tests that changed because of the date-format fix upstream; I updated them and left a note in the PR.",
                           pr: pr, task: index == 0 ? "t1" : index == 2 ? "t5" : nil, name: row.0 + "-" + String(format: "%02x", index * 7 + 16))
        }
    }()

    lazy var endedSessions: [Obj] = [
        session("s9", "acme-billing", "spike/proration-fixtures", "ENG-412", "ended", -2100, "Built the March fixture that reproduces the off-by-a-cent upgrade",
                prompt: "make a fixture for a mid-cycle upgrade in a 31-day month", reply: "The fixture is in `fixtures/march-upgrade.json` and fails the way the ticket describes.", task: "t1"),
        session("s7", "acme-docs", "docs/billing-api", nil, "ended", -130, "Updated the billing API reference", prompt: "document the new usage endpoints", reply: "Reference pages are updated and the examples run."),
        session("s8", "acme-billing", "chore/backfill-dry-run", "ENG-405", "ended", -1300, "Backfill script dry run on a copy of production",
                prompt: "dry-run the backfill on yesterday's snapshot", reply: "Dry run finished: 41,204 workspaces, 12 with mismatched plan ids (listed in report.csv)."),
    ]

    lazy var meetings: [Obj] = [
        meeting("m0", "Launch readiness check", -1560, 45, ["Mira Okafor", "Teo Alvarez", "Hana Sato", "Jonas Lindqvist"],
                summary: "Launch stays on the 3rd if the proration fix lands this week. Finance wants the backfill timeline in writing. Search latency is a risk for the usage dashboard.",
                actions: ["Share the backfill timeline with finance", "Confirm the on-call rota for launch week", "Decide whether usage alerts ship in v1"],
                recording: "https://meet.example.com/rec/launch-readiness"),
        meeting("m1", "Standup", -200, 15, ["Jonas Lindqvist", "Priya Raman", "Hana Sato"],
                summary: "Jonas is blocked on the ledger schema review. Priya has the empty invoice state ready tomorrow.", actions: ["Review the ledger schema PR today"]),
        meeting("m2", "Billing design review", 40, 50, ["Priya Raman", "Teo Alvarez", "Jonas Lindqvist", "Mira Okafor"], join: "https://meet.example.com/billing-design",
                prep: "## Goal\nAgree on the invoice layout for metered plans.\n\n## Open questions\n- Does tax show per line or as one total?\n- Where does the usage breakdown live: inline or a second page?\n\n## You owe\n- An answer on the **half-cent rule** (waiting on Teo)\n- A look at Priya's empty-state mock"),
        meeting("m3", "1:1 with Mira", 220, 30, ["Mira Okafor"], join: "https://meet.example.com/mira-1-1"),
        meeting("m4", "Search latency sync", 1500, 30, ["Hana Sato", "Jonas Lindqvist"], join: "https://meet.example.com/search-sync"),
        meeting("m5", "Hiring debrief: backend", 1740, 45, ["Dev Malhotra", "Mira Okafor", "Jonas Lindqvist"], join: "https://meet.example.com/hiring-debrief"),
        meeting("m6", "Billing launch go/no-go", 4400, 60, ["Mira Okafor", "Teo Alvarez", "Hana Sato", "Priya Raman", "Jonas Lindqvist", "Dev Malhotra"], join: "https://meet.example.com/go-no-go"),
    ]

    lazy var suggestions: [Obj] = [
        suggestion("g10", "followup", "Send Priya the copy for the empty invoice state", "You told Priya in #invoice-design that you would; nothing has been sent since.",
                   ["title": "Send Priya the copy for the empty invoice state", "projectId": "p2", "people": ["Priya Raman"],
                    "commitment": ["quote": "I'll write the copy for the empty state and send it over tomorrow", "to": "Priya Raman", "madeAt": at(-2900)] as Obj],
                   "chat", 0.84, "https://chat.example.com/invoice-design/p1711", -2880, ref: "C-inv:1711.2"),
        suggestion("g11", "followup", "Confirm the on-call rota for launch week", "Your action item from Launch readiness check.",
                   ["title": "Confirm the on-call rota for launch week", "projectId": "p5",
                    "commitment": ["quote": "Confirm the on-call rota for launch week", "to": "Launch readiness check", "madeAt": at(-1560)] as Obj],
                   "meeting", 0.8, "https://meet.example.com/rec/launch-readiness", -1500, ref: "rec-launch:2"),
        suggestion("g1", "new_task", "Send Hana the load-test numbers", "Hana asked in #perf at 10:12: “can you share the p95 numbers before the sync?” Nobody has answered.",
                   ["title": "Send Hana the load-test numbers", "priority": 2, "projectId": "p4", "dueAt": at(1400), "people": ["Hana Sato"]], "chat", 0.86, "https://chat.example.com/perf/p2291", -35),
        suggestion("g2", "followup", "Follow up with Teo on the tax rounding sign-off", "You asked two days ago; the thread has been quiet since.",
                   ["title": "Follow up with Teo on the tax rounding sign-off", "waitingOn": "Teo Alvarez", "projectId": "p1"], "chat", 0.74, "https://chat.example.com/finance/p880", -90),
        suggestion("g3", "update_task", "Raise priority: search latency regression", "ENG-440 was escalated to P1 by Hana twenty minutes ago.",
                   ["taskId": "t7", "patch": ["priority": 3, "dueAt": at(240)] as Obj], "ticket", 0.91, "https://tickets.example.com/ENG-440", -20),
        suggestion("g4", "complete_task", "Looks done: Invoice PDF tax line wraps", "The acme-web session pushed a fix and CI is green on the branch.", ["taskId": "t5"], "claude", 0.68, nil, -8),
        suggestion("g6", "new_task", "Share the backfill timeline with finance", "Action item from Launch readiness check, assigned to you.",
                   ["title": "Share the backfill timeline with finance", "projectId": "p3", "dueAt": at(2900)], "meeting", 0.82, "https://meet.example.com/rec/launch-readiness", -1500),
        suggestion("g9", "new_task", "Add a tax-ID field to the invoice mock", "Teo said in the design thread that enterprise invoices need it before launch.",
                   ["title": "Add a tax-ID field to the invoice mock", "projectId": "p2", "priority": 1], "meeting", 0.9, nil, -1490),
        suggestion("g7", "link", "Link ENG-412 to “Fix proration rounding”", "The ticket and the task describe the same bug.",
                   ["taskId": "t1", "link": ["kind": "ticket", "title": "ENG-412", "url": "https://tickets.example.com/ENG-412"] as Obj], "ticket", 0.95, "https://tickets.example.com/ENG-412", -400),
        suggestion("g5", "question", "Should standup notes become tasks automatically?", "Three of the last five standups had an item with your name on it.",
                   ["question": "Should standup notes become tasks automatically?", "options": ["Yes, always", "Only when I'm named", "No"]], "agent", 0.5, nil, -300),
        suggestion("g8", "insight", "You switched sessions 14 times in the last hour", "Most switches were between the proration fix and the ledger review. Finishing one first would free a session.", [:], "agent", 0.55, nil, -15),
    ]

    lazy var approvals: [Obj] = [
        ["id": "a1", "kind": "chat.post", "summary": "Reply to Mira in #billing-launch", "tool": "chat_post_message",
         "input": ["channel": "#billing-launch", "text": "We're on track for the 3rd. The proration fix is in review today; the only open risk is finance sign-off on rounding, which I'm chasing."] as Obj,
         "note": "chat_post_message writes to an external service.",
         "target": "#billing-launch", "status": "pending", "result": null, "threadId": "c1", "createdAt": at(-6), "decidedAt": null],
        ["id": "a2", "kind": "gh.pr.comment", "summary": "Comment on PR #1836 with the migration plan", "tool": "Bash",
         "input": ["command": "gh pr comment 1836 --repo acme/billing --body \"Migration plan: run on staging first, then backfill in two batches.\""] as Obj,
         "note": "gh pr comment is not a known read.",
         "target": "acme/billing #1836", "status": "pending", "result": null, "threadId": null, "createdAt": at(-50), "decidedAt": null],
    ]

    lazy var nudges: [Obj] = [
        ["id": "n1", "kind": "session", "title": "acme-billing needs an answer", "body": "Wants to run the ledger migration against staging.", "priority": 2,
         "actions": [["id": "focus", "label": "Focus", "kind": "focus_session", "sessionId": "s2"] as Obj, ["id": "x", "label": "Dismiss", "kind": "dismiss"] as Obj],
         "dedupeKey": "session:s2", "createdAt": at(-4), "expiresAt": null, "dismissedAt": null],
    ]

    static let brief = """
    # Morning brief

    Three things need you before lunch, and one session is blocked.

    ## Needs you now
    1. **acme-billing** (ledger schema) is blocked: it wants to run the staging migration.
    2. The proration fix is done and waiting for you to push.
    3. Mira asked about the launch date two hours ago.

    ## Today
    | Time | What | Prep |
    |---|---|---|
    | 2:30 PM | Billing design review | ready |
    | 4:30 PM | 1:1 with Mira | none yet |

    ## Can wait
    - Dependency bumps on acme-web (approved, one open comment)
    - Passport renewal is due in 12 days

    > Search latency was escalated to P1 overnight. Hana wants the p95 numbers before tomorrow's sync.
    """

    lazy var notes: [Obj] = [
        note("nb1", "brief", "Morning brief", Self.brief, -150, pinned: true),
        note("nl1", "live", "Scratch", "half-cent rule: ask Teo whether we round per line or per invoice\nprorate() uses floor today\n31-day months are the failing case", -20),
        note("nm1", "meeting", "Launch readiness check", "- Launch stays on the 3rd if proration lands\n- Finance wants the backfill timeline in writing\n- Search latency is a risk for the usage dashboard", -1500, meeting: "m0"),
        note("nb2", "brief", "Before: Billing design review", "## Goal\nAgree on the invoice layout for metered plans.\n\n## Open questions\n- Tax per line or one total?\n- Usage breakdown inline or on a second page?", -60, meeting: "m2"),
        note("nd1", "dump", "billing thoughts", "usage alerts by email? maybe v2\nask Jonas whether meter events are idempotent\nthe invoice PDF needs a tax-ID field for enterprise", -400),
        note("nj1", "journal", "Wednesday wrap-up", "Got the ledger design agreed. Lost an hour to the flaky webhook test again.\n\nTomorrow: proration fix first, then reviews.", -1100),
        note("nd2", "dump", "passport renewal checklist", "- photos\n- old passport\n- form DS-82", -4000, task: "t13"),
    ]

    lazy var people: [Obj] = [
        person("h1", "Mira Okafor", ["chat": "@mira", "email": "mira@acme.example"], "Engineering manager. Prefers a short written update before 1:1s.", -120),
        person("h2", "Jonas Lindqvist", ["chat": "@jonas", "git": "jonasl"], "Backend. Owns the ledger. Reviews fast in the morning.", -200),
        person("h3", "Teo Alvarez", ["chat": "@teo", "email": "teo@acme.example"], "Finance partner for billing. Slow on chat, quick on email.", -2900),
        person("h4", "Priya Raman", ["chat": "@priya"], "Design lead for the invoice UI.", -300),
        person("h5", "Hana Sato", ["chat": "@hana", "git": "hsato"], "SRE. Runs the search latency sync.", -35),
        person("h6", "Dev Malhotra", ["email": "dev@acme.example"], "Recruiter for the backend role.", -7200),
    ]

    lazy var threads: [Obj] = [
        ["id": "c1", "title": "Launch date reply to Mira", "createdAt": at(-30), "updatedAt": at(-6), "agentSessionId": null],
        ["id": "c2", "title": "Plan my day", "createdAt": at(-170), "updatedAt": at(-160), "agentSessionId": null],
        ["id": "c3", "title": "Why is cold search slow?", "createdAt": at(-1400), "updatedAt": at(-1380), "agentSessionId": null],
    ]

    lazy var messages: [String: [Obj]] = [
        "c1": [
            message("m1", "c1", "user", "Mira asked whether we're still on for the 3rd. Draft a reply from what you know.", -30),
            message("m2", "c1", "tool", "", -29.8, tool: ["name": "tasks_search", "input": ["q": "proration", "status": ["doing", "todo"]] as Obj, "result": "1 task: Fix proration rounding in mid-cycle upgrades (doing, due today)", "status": "ok"]),
            message("m3", "c1", "tool", "", -29.6, tool: ["name": "sessions_list", "input": [:] as Obj, "result": "6 sessions: 1 blocked, 2 waiting, 2 working, 1 idle", "status": "ok"]),
            message("m4", "c1", "tool", "", -29.3, tool: ["name": "chat_search", "input": ["query": "launch date in:#billing-launch"] as Obj, "result": "connector timed out after 20s", "status": "error"]),
            message("m5", "c1", "assistant", """
            Here's where the launch stands:

            | Item | State | Risk |
            |---|---|---|
            | Proration fix | tests pass, PR ready | low |
            | Ledger schema | changes requested | **medium** |
            | Finance sign-off | waiting on Teo, 2 days | **medium** |

            Suggested reply:

            > We're on track for the 3rd. The proration fix is in review today; the only open risk is finance sign-off on rounding, which I'm chasing.

            I've queued that as a message to `#billing-launch`. It won't send until you approve it.
            """, -29),
        ],
        "c2": [
            message("m6", "c2", "user", "/plan my day", -170),
            message("m7", "c2", "assistant", "## Plan\n1. **Push the proration fix** (session is waiting, 10 minutes)\n2. **Unblock the ledger session**: approve or deny the staging migration\n3. Prep for the design review at 2:30\n4. Reply to Mira before your 1:1\n\nDrop for today: dependency bumps and the on-call notes.\n\n```sh\ncd ~/code/acme-billing && git push && gh pr ready 1841\n```", -160),
        ],
        "c3": [message("m8", "c3", "user", "Why is cold search slow after deploys?", -1400),
               message("m9", "c3", "assistant", "Short answer: the index warms lazily, so the first queries after a restart pay for loading shards.", -1380)],
    ]

    lazy var activity: [Obj] = {
        let apps: [(String, String, String?)] = [
            ("Terminal", "acme-billing — claude", "t1"), ("Editor", "prorate.ts — acme-billing", "t1"), ("Browser", "PR #1836 · acme/billing", "t2"),
            ("Chat", "#billing-launch", nil), ("Terminal", "search-service — claude", "t7"), ("Meet", "Standup", nil), ("Editor", "ledger.sql — acme-billing", "t2"),
            ("Mail", "Inbox", nil), ("Browser", "ENG-440 · Tickets", "t7"), ("Notes", "Scratch", nil),
        ]
        var spans: [Obj] = []
        var cursor = -420.0
        var seed = 7
        var index = 0
        while cursor < -1 {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff
            let length = min(Double(2 + seed % 23), -cursor)
            let idle = seed % 5 == 0
            let app = apps[(seed / 7) % apps.count]
            spans.append(["id": "sp\(index)", "app": idle ? "Idle" : app.0, "bundleId": null, "title": idle ? null : app.1, "startAt": at(cursor), "endAt": at(cursor + length),
                          "idle": idle, "sessionId": null, "taskId": idle ? null : opt(app.2)])
            cursor += length
            index += 1
        }
        return spans
    }()

    lazy var runs: [Obj] = {
        let kinds: [(String, String, String, Double, String)] = [
            ("chat", "user", "claude-opus-5-5", 0.412, "Drafted a reply to Mira about the launch date"), ("triage", "event", "claude-haiku-5-5", 0.006, "4 signals, 2 suggestions"),
            ("sync:chat", "schedule", "claude-haiku-5-5", 0.021, "38 messages, 3 mentions"), ("recap", "user", "claude-haiku-5-5", 0.009, "Recap for acme-billing"),
            ("brief", "schedule", "claude-opus-5-5", 0.387, "Morning brief"), ("sync:tickets", "schedule", "claude-haiku-5-5", 0.012, "2 tickets changed"),
            ("capture", "user", "claude-haiku-5-5", 0.004, "1 task from a capture"), ("chat", "user", "claude-opus-5-5", 0.298, "Planned the day"),
            ("sync:calendar", "schedule", "claude-haiku-5-5", 0.003, "No changes"), ("triage", "event", "claude-haiku-5-5", 0.005, "error: connector timed out"),
        ]
        return kinds.enumerated().map { index, run in
            ["id": "r\(index)", "kind": run.0, "trigger": run.1, "model": run.2, "status": index == 9 ? "error" : "ok", "inputTokens": 1200 + index * 830,
             "outputTokens": 140 + index * 95, "costUsd": run.3, "billing": index % 4 == 0 ? "api" : "login", "summary": run.4,
             "startedAt": at(Double(-6 - index * 37)), "endedAt": at(Double(-5 - index * 37))]
        }
    }()

    lazy var jobs: [Obj] = [
        job("triage", "every 10m", -4, "ok", 6), job("sync:chat", "every 15m", -9, "ok", 6), job("sync:calendar", "every 30m", -22, "ok", 8),
        job("sync:tickets", "every 20m", -14, "error", 6), job("brief:morning", "08:30 mon,tue,wed,thu,fri", -150, "ok", 1290), job("brief:evening", "18:00 mon,tue,wed,thu,fri", -900, "ok", 480),
        job("core.rerank", "every 5m", -1, "ok", 4), job("onboarding-scan", "04:00 daily", nil, nil, nil),
    ]

    static let memory: [(String, String)] = [
        ("profile.md", "# Profile\n\n- Works on billing and reliability at Acme\n- Deep work in the morning; meetings cluster after 2 PM\n- Prefers short written updates over calls\n- Reviews PRs in two passes: design first, then details\n"),
        ("preferences.md", "# Preferences\n\n- Never schedule over lunch (12:30–1:15)\n- Summaries: bullets, most urgent first\n- Don't nudge about errands during work hours\n"),
        ("people/mira-okafor.md", "# Mira Okafor\n\nEngineering manager. Wants a written status before each 1:1.\nCares most about: launch date confidence, hiring pipeline.\n"),
        ("people/teo-alvarez.md", "# Teo Alvarez\n\nFinance partner. Email works better than chat.\n"),
        ("projects/billing.md", "# Usage-based billing\n\nLaunch target: the 3rd.\n\n## Decisions\n- Usage records are an append-only ledger\n- Banker's rounding for proration\n\n## Open\n- Half-cent rule: per line or per invoice?\n"),
    ]

    var settings: Obj {
        ["port": 47600, "user": ["name": "Alex", "workHours": ["start": "09:00", "end": "19:00", "days": [1, 2, 3, 4, 5]] as Obj, "timezone": ""] as Obj,
         "models": ["main": "claude-opus-5-5", "fast": "claude-haiku-5-5"], "agent": ["billing": "login", "writableRoots": [String](), "effort": "medium"] as Obj,
         "budget": ["dailyCapUsd": 15, "monthlyCapUsd": 300],
         "connectors": ["chat": ["enabled": true, "everyMin": 15] as Obj, "calendar": ["enabled": true, "everyMin": 30] as Obj, "tickets": ["enabled": true, "everyMin": 20] as Obj,
                        "meetings": ["enabled": true, "everyMin": 60] as Obj, "docs": ["enabled": false, "everyMin": 720] as Obj, "messages": ["enabled": false] as Obj, "browser": ["enabled": true] as Obj] as Obj,
         "nudges": ["sessionWaitingAfterSec": 45, "meetingLeadMin": 3, "quietHours": null] as Obj,
         "hotkeys": ["capture": "ctrl+opt+space", "agent": "ctrl+opt+a", "voice": "ctrl+opt+v", "hud": "ctrl+opt+h", "notch": "ctrl+opt+n"],
         "ui": ["hudDisplay": "auto", "notchOnAllDisplays": true, "haptics": true, "sounds": false] as Obj, "secretsSet": ["ANTHROPIC_API_KEY"]]
    }

    var state: Obj {
        let open = tasks.filter { !["done", "dropped"].contains($0["status"] as? String ?? "") && $0["snoozedUntil"] is NSNull && $0["parentId"] is NSNull }
        return ["now": tasks[0], "top": Array(open.prefix(12)), "sessions": liveSessions, "nextMeeting": meetings[2], "currentMeeting": null,
                "counts": ["inbox": 2, "suggestions": suggestions.count, "approvals": approvals.count, "waiting": 2, "dueToday": 3, "overdue": 1],
                "nudges": nudges, "liveNote": notes[1], "budget": ["todayUsd": 4.37, "dailyCapUsd": 15, "monthUsd": 86.2, "billing": "mixed"],
                "agent": ["busy": true, "activity": "Reading #billing-launch…"],
                "health": ["connectors": ["chat": "ok", "calendar": "ok", "tickets": "error", "meetings": "ok", "docs": "off", "messages": "off", "browser": "unknown"],
                           "lastSyncAt": ["chat": at(-9), "calendar": at(-22), "tickets": at(-74), "meetings": at(-48)]] as Obj,
                "serverTime": at(0)]
    }

    // MARK: Routing

    func respond(_ method: String, _ path: String, _ query: [String: String]) -> (Int, Any) {
        let parts = path.split(separator: "/").map(String.init)
        func items(_ list: [Obj]) -> (Int, Any) { (200, ["items": list]) }
        func find(_ list: [Obj], _ id: String) -> (Int, Any) {
            list.first { $0["id"] as? String == id }.map { (200, $0 as Any) } ?? (404, ["error": ["code": "not_found", "message": "not found"]])
        }
        if Self.empty, method == "GET" {
            switch parts.first ?? "" {
            case "health", "settings", "jobs": break
            case "state":
                return (200, ["now": null, "top": [Obj](), "sessions": [Obj](), "nextMeeting": null, "currentMeeting": null,
                              "counts": ["inbox": 0, "suggestions": 0, "approvals": 0, "waiting": 0, "dueToday": 0, "overdue": 0],
                              "nudges": [Obj](), "liveNote": null, "budget": ["todayUsd": 0, "dailyCapUsd": 15, "monthUsd": 0, "billing": "login"],
                              "agent": ["busy": false, "activity": null, "available": true], "health": ["connectors": Obj(), "lastSyncAt": Obj()] as Obj, "serverTime": at(0)])
            case "tree": return (200, ["initiatives": [Obj](), "looseProjects": [Obj]()])
            case "cost": return (200, ["today": 0, "month": 0, "byDay": [Obj](), "byKind": [Obj](), "byDayKind": [Obj]()])
            case "activity" where parts.count == 2: return (200, ["byApp": [Obj](), "byTask": [Obj](), "focusMs": 0, "switches": 0])
            default: return parts.count == 1 || parts.first == "chat" ? items([]) : (404, ["error": ["code": "not_found", "message": "not found"]])
            }
        }
        guard method == "GET" else {
            switch (parts.first, parts.count) {
            case ("tasks", 1): return (200, tasks[3])
            case ("tasks", 3) where parts[2] == "context" || parts[2] == "draft-reply", ("suggestions", 3) where parts[2] == "context":
                return (200, context("sample:\(parts[1])", status: parts[2] == "context" ? "running" : nil, draftStatus: parts[2] == "draft-reply" ? "running" : nil))
            case ("loose-ends", 2) where parts[1] == "track": return (200, tasks[3])
            case ("tasks", 2), ("tasks", 3): return find(tasks, parts[1])
            case ("chat", 2): return (200, threads[0])
            case ("chat", 4): return (200, ["messageId": "local", "runId": "run-sample"])
            case ("notes", _): return (200, notes[0])
            case ("meetings", 3), ("sessions", 3): return (503, ["error": ["code": "agent_unavailable", "message": "The agent runtime is not available in the sample brain."]])
            case ("settings", 1): return (200, settings)
            case ("app", _): return (200, ["ok": false, "log": "sample brain: nothing to rebuild"])
            default: return (200, ["ok": true])
            }
        }
        switch parts.first ?? "" {
        case "health": return (200, ["ok": true, "version": "sample", "uptimeMs": 1000])
        case "state": return (200, state)
        case "tasks":
            if parts.count == 3, parts[2] == "place" { return taskPlace(parts[1]) }
            if parts.count == 2 { return find(tasks, parts[1]) }
            let statuses = query["status"].map { Set($0.split(separator: ",").map(String.init)) }
            if let parent = query["parentId"] { return items(tasks.filter { $0["parentId"] as? String == parent }) }
            return items(tasks.filter { statuses?.contains($0["status"] as? String ?? "") ?? true })
        case "projects": return parts.count == 2 ? find(projects, parts[1]) : items(projects)
        case "initiatives": return parts.count == 2 ? find(initiatives, parts[1]) : items(initiatives)
        case "tree":
            let open = Dictionary(grouping: tasks.filter { !["done", "dropped"].contains($0["status"] as? String ?? "") }) { $0["projectId"] as? String ?? "" }
            let done = Dictionary(grouping: tasks.filter { $0["status"] as? String == "done" }) { $0["projectId"] as? String ?? "" }
            let withCounts = projects.map { $0.merging(["openTasks": open[$0["id"] as? String ?? ""]?.count ?? 0, "doneTasks": done[$0["id"] as? String ?? ""]?.count ?? 0]) { $1 } }
            return (200, ["initiatives": initiatives.map { i in i.merging(["projects": withCounts.filter { $0["initiativeId"] as? String == i["id"] as? String }]) { $1 } },
                          "looseProjects": withCounts.filter { $0["initiativeId"] is NSNull }])
        case "suggestions": return parts.count == 3 ? suggestionPlace(parts[1]) : items(suggestions)
        case "loose-ends": return (200, looseEnds)
        case "sessions":
            let known = liveSessions + endedSessions
            if parts.count == 2 { return find(known, parts[1]) }
            if parts.count == 3, parts[2] == "turns" { return (200, turns(known.first { $0["id"] as? String == parts[1] })) }
            if parts.count == 3, parts[2] == "place" {
                guard let found = known.first(where: { $0["id"] as? String == parts[1] }) else { return find(known, parts[1]) }
                let recap: Obj = ["text": "**Goal:** land the append-only ledger schema (ENG-398).\n\n- Applied all three review comments from Jonas\n- Both migrations pass locally\n\n**Open:** one run against staging before the PR can go green.", "at": at(-30)]
                return (200, ["session": found, "task": opt(tasks.first { $0["id"] as? String == found["taskId"] as? String }),
                              "ticketUrl": opt((found["ticket"] as? String).map { "https://tickets.example.com/\($0)" }), "recap": parts[1] == "s2" ? recap as Any : null as Any])
            }
            if parts.count == 3 {
                return (200, ["text": "**Goal:** fix the off-by-a-cent proration on mid-cycle upgrades (ENG-412).\n\n- Reproduced with the March fixture: 31-day cycles rounded down twice\n- Switched `prorate()` to banker's rounding and added 6 cases\n- All 48 tests pass; PR #1841 is open, checks green\n\n**Needs you:** say whether to push and mark the PR ready."])
            }
            return items(query["includeEnded"] == "1" ? liveSessions + endedSessions : liveSessions)
        case "meetings":
            if parts.count == 2 { return find(meetings, parts[1]) }
            let from = Int64(query["from"] ?? "") ?? 0, to = Int64(query["to"] ?? "") ?? .max
            return items(meetings.filter { ($0["endAt"] as! Int64) > from && ($0["startAt"] as! Int64) < to })
        case "notes": return parts.count == 2 ? find(notes, parts[1]) : items(notes)
        case "people": return items(people)
        case "signals": return items([])
        case "activity":
            let from = Int64(query["from"] ?? "") ?? 0, to = Int64(query["to"] ?? "") ?? .max
            let spans = activity.filter { ($0["endAt"] as! Int64) > from && ($0["startAt"] as! Int64) < to }
            return parts.count == 2 ? (200, summary(spans)) : items(spans)
        case "chat":
            if parts.count == 2, parts[1] == "questions" { return items([]) }
            return parts.count == 4 ? items(messages[parts[2]] ?? []) : items(threads)
        case "approvals": return items(approvals)
        case "nudges": return items(nudges)
        case "runs": return items(runs)
        case "cost":
            let days = (0..<30).map { i -> Obj in
                let date = Calendar.current.date(byAdding: .day, value: i - 29, to: now)!
                let usd = i == 29 ? 4.37 : 1.2 + Double((i * 37) % 11) * 0.55 + (Calendar.current.isDateInWeekend(date) ? -1.0 : 0.8)
                return ["day": date.formatted(.iso8601.year().month().day()), "usd": max(0.1, usd)]
            }
            // The same split every day keeps the fixture small; the chart only needs the kinds to add up to the day.
            let share: [(String, Double)] = [("chat", 0.48), ("brief", 0.23), ("sync:chat", 0.11), ("triage", 0.08), ("recap", 0.05), ("sync:tickets", 0.03), ("capture", 0.02)]
            let byDayKind = days.flatMap { day in share.map { ["day": day["day"]!, "kind": $0.0, "usd": (day["usd"] as! Double) * $0.1] as Obj } }
            return (200, ["today": 4.37, "month": 86.2, "byDay": days, "byDayKind": byDayKind,
                          "byKind": [["kind": "chat", "usd": 41.8], ["kind": "brief", "usd": 19.6], ["kind": "sync:chat", "usd": 9.4], ["kind": "triage", "usd": 7.1],
                                     ["kind": "recap", "usd": 4.2], ["kind": "sync:tickets", "usd": 2.6], ["kind": "capture", "usd": 1.5]]])
        case "settings": return (200, settings)
        case "jobs": return items(jobs)
        case "memory":
            if parts.count == 1 {
                return items(Self.memory.enumerated().map { ["path": $0.element.0, "size": $0.element.1.utf8.count, "updatedAt": at(Double(-60 - $0.offset * 900))] })
            }
            let wanted = parts.dropFirst().joined(separator: "/")
            guard let file = Self.memory.first(where: { $0.0 == wanted }) else { return (404, ["error": ["code": "not_found", "message": "memory file not found"]]) }
            return (200, ["path": file.0, "content": file.1, "updatedAt": at(-60)])
        default:
            return (404, ["error": ["code": "not_found", "message": "no route \(path)"]])
        }
    }

    // MARK: Places

    private func origin(_ source: String, _ kind: String, _ title: String, _ body: String, actor: String?, minutes: Double?, url: String?, session: String? = nil, meeting: String? = nil) -> Obj {
        ["source": source, "kind": kind, "title": title, "body": body, "actor": opt(actor), "at": opt(minutes.map(at)), "url": opt(url),
         "signalId": null, "sessionId": opt(session), "meetingId": opt(meeting), "noteId": null]
    }

    private func context(_ subject: String, status: String?, body: String = "", fetched: Double? = nil, draftStatus: String? = nil, draft: String? = nil, approval: String? = nil, note: String? = nil) -> Obj {
        ["id": "ctx-\(subject)", "subject": subject, "status": opt(status), "body": body, "error": null, "fetchedAt": opt(fetched.map(at)), "costUsd": 0.03,
         "draftStatus": opt(draftStatus), "draft": opt(draft), "draftApprovalId": opt(approval), "draftNote": opt(note), "draftAt": opt(draft == nil ? nil : at(-6)),
         "createdAt": at(-60), "updatedAt": at(-6)]
    }

    private func byId(_ list: [Obj], _ id: String) -> Obj { list.first { $0["id"] as? String == id } ?? [:] }

    private static let launchContext = """
    **Asked**: a launch date for usage-based billing that Mira can give finance.
    **By**: Mira Okafor, two hours ago in #billing-launch.
    **Already said or decided**:
    - Jonas: the ledger schema is in review and blocks nothing else.
    - Teo: finance needs the backfill timeline in writing before they sign off on rounding.
    - Mira: the 3rd holds only if the proration fix lands this week.

    **Still open**: nobody has answered Mira. The rounding sign-off from Teo is two days old.
    **Links**: [the thread](https://chat.example.com/billing-launch/p1712)
    """

    private static let copyContext = """
    **Asked**: the copy for the empty invoice state, so the mock can be finished.
    **By**: Priya Raman, on Tuesday in #invoice-design.
    **Already said or decided**:
    - You: “I'll write the copy for the empty state and send it over tomorrow.”
    - Priya: the mock is otherwise ready and goes to review on Friday.

    **Still open**: the copy. Priya asked again this morning.
    """

    private func taskPlace(_ id: String) -> (Int, Any) {
        guard let task = tasks.first(where: { $0["id"] as? String == id }) else { return (404, ["error": ["code": "not_found", "message": "not found"]]) }
        var place: Obj = ["task": task, "origins": [Obj](), "context": null, "sessions": (liveSessions + endedSessions).filter { $0["taskId"] as? String == id },
                          "related": ["tasks": [Obj](), "suggestions": [Obj](), "sessions": [Obj](), "meetings": [Obj]()] as Obj, "seeMoreVia": null, "replyVia": null]
        if id == "t3" {
            place["origins"] = [origin("chat", "mention", "#billing-launch", "Are we still good for the 3rd? Finance asked me this morning and I'd like to give them a date I won't have to walk back.",
                                       actor: "Mira Okafor", minutes: -120, url: "https://chat.example.com/billing-launch/p1712")]
            place["context"] = context("src:chat:C-launch:1712.4", status: "ok", body: Self.launchContext, fetched: -34, draftStatus: "ok",
                                       draft: (approvals[0]["input"] as? Obj)?["text"] as? String, approval: "a1", note: "Waiting in Approvals. Nothing is sent until you approve it there.")
            place["related"] = ["tasks": [["task": byId(tasks, "t8"), "why": "same thread"] as Obj, ["task": byId(tasks, "t6"), "why": "also with Mira Okafor"] as Obj],
                                "suggestions": [["suggestion": byId(suggestions, "g2"), "why": "same thread"] as Obj],
                                "sessions": [Obj](),
                                "meetings": [["meeting": byId(meetings, "m3"), "why": "with Mira Okafor"] as Obj, ["meeting": byId(meetings, "m0"), "why": "with Mira Okafor"] as Obj]] as Obj
            place["seeMoreVia"] = "chat"
            place["replyVia"] = "chat"
        } else if id == "t1" {
            place["origins"] = [origin("ticket", "assigned", "ENG-412 Proration is off by a cent on mid-cycle upgrades: assigned to you",
                                       "Upgrades in the middle of a 31-day cycle bill one cent less than the invoice preview shows. Two customers have noticed.",
                                       actor: "Jonas Lindqvist", minutes: -4000, url: "https://tickets.example.com/ENG-412"),
                                origin("claude", "session", "Fixed proration rounding for mid-cycle upgrades", "run the proration suite again and show me the failing cases", actor: nil, minutes: -107, url: nil, session: "s1")]
            place["related"] = ["tasks": [["task": byId(tasks, "t8"), "why": "also with Teo Alvarez"] as Obj],
                                "suggestions": [["suggestion": byId(suggestions, "g7"), "why": "proposes a change to this task"] as Obj],
                                "sessions": [Obj](), "meetings": [["meeting": byId(meetings, "m0"), "why": "mentions ENG-412"] as Obj]] as Obj
            place["seeMoreVia"] = "tickets"
            place["replyVia"] = "tickets"
        }
        return (200, place)
    }

    private func suggestionPlace(_ id: String) -> (Int, Any) {
        guard let suggestion = suggestions.first(where: { $0["id"] as? String == id }) else { return (404, ["error": ["code": "not_found", "message": "not found"]]) }
        var place: Obj = ["suggestion": suggestion, "origins": [Obj](), "context": null, "seeMoreVia": null]
        switch id {
        case "g10":
            place["origins"] = [origin("chat", "commitment", "#invoice-design", "I'll write the copy for the empty state and send it over tomorrow", actor: "Priya Raman", minutes: -2900,
                                       url: "https://chat.example.com/invoice-design/p1711")]
            place["context"] = context("src:chat:C-inv:1711.2", status: "ok", body: Self.copyContext, fetched: -12)
            place["seeMoreVia"] = "chat"
        case "g1":
            place["origins"] = [origin("chat", "mention", "#perf", "can you share the p95 numbers before the sync?", actor: "Hana Sato", minutes: -35, url: "https://chat.example.com/perf/p2291")]
            place["seeMoreVia"] = "chat"
        case "g6", "g11":
            place["origins"] = [origin("meeting", id == "g11" ? "commitment" : "action_item", "Launch readiness check", (suggestion["title"] as? String) ?? "", actor: "Launch readiness check", minutes: -1560,
                                       url: "https://meet.example.com/rec/launch-readiness", meeting: "m0")]
            place["seeMoreVia"] = "meetings"
        default:
            if let url = suggestion["sourceUrl"] as? String {
                place["origins"] = [origin((suggestion["source"] as? String) ?? "agent", "link", (suggestion["title"] as? String) ?? "", "", actor: nil, minutes: nil, url: url)]
            }
        }
        return (200, place)
    }

    private static let longReply = """
    Two of the three change the migration:

    1. **Nullable `plan_id`**: Jonas wants it `NOT NULL` with a backfill, which means the migration has to run in two steps.
    2. **Index on `(workspace_id, recorded_at)`**: it has to be created concurrently or it locks the table for a few minutes on production-sized data.
    3. The naming comment (`usage_event` vs `usage_record`) is cosmetic and touches no SQL.

    For the first one I would add the column as nullable, backfill in batches of 5,000, then set `NOT NULL` in a second migration. That keeps each step under the lock timeout.

    For the second, `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so that migration needs `disable_ddl_transaction`.

    The existing tests cover neither path; I would add one that runs both migrations against a copy of the fixture database and checks row counts before and after.
    """

    private func turns(_ session: Obj?) -> Obj {
        guard let session else { return ["items": [Obj](), "from": "none", "truncated": false] }
        let prompt = (session["lastUserPrompt"] as? String) ?? "", reply = (session["lastAssistantText"] as? String) ?? ""
        func turn(_ role: String, _ minutes: Double, _ text: String) -> Obj { ["role": role, "at": at(minutes), "text": text] }
        let items: [Obj] = [
            turn("user", -96, "The review on the ledger schema came back. Read the three comments and tell me which ones change the migration."),
            turn("tools", -96, "Bash · Read ×4 · Grep ×2"),
            turn("assistant", -93, Self.longReply),
            turn("user", -80, prompt),
            turn("tools", -79, "Edit ×5 · Bash ×3 · Read ×2"),
            turn("assistant", -64, "All three comments are applied. The migration is split in two, the index is created concurrently, and the table is `usage_record` everywhere.\n\nLocally: 212 tests pass, and both migrations run clean on the fixture database."),
            turn("user", -20, "good. what is left before this can merge?"),
            turn("tools", -19, "Bash ×2 · Tracker get issue"),
            turn("assistant", -4, reply),
        ]
        return ["from": "transcript", "truncated": true, "items": items]
    }

    var looseEnds: Obj {
        func end(_ id: String, _ kind: String, _ title: String, _ reason: String, _ since: Double, view: String?, path: String?, url: String? = nil) -> Obj {
            ["id": id, "kind": kind, "title": title, "reason": reason, "since": at(since), "place": opt(view.map { ["view": $0, "path": path ?? ""] as Obj }), "url": opt(url)]
        }
        let groups: [Obj] = [
            ["kind": "commitment", "title": "You said you would", "items": [
                end("commitment:s:g10", "commitment", "Send Priya the copy for the empty invoice state", "You told Priya Raman this 2 days ago; it is still in the Inbox.", -2900,
                    view: "inbox", path: "/suggestions/g10", url: "https://chat.example.com/invoice-design/p1711"),
            ]],
            ["kind": "session", "title": "Sessions left waiting", "items": [
                end("session:s6", "session", "Dependency bumps are ready for review", "Finished and waiting on you for 6 hours in acme-web.", -360, view: "sessions", path: "/sessions/s6"),
                end("session:s8", "session", "Backfill script dry run on a copy of production", "Its session ended a day ago; the task “Write the backfill dry-run plan” is still open.", -1300,
                    view: "sessions", path: "/sessions/s8"),
            ]],
            ["kind": "waiting", "title": "Waiting with no word", "items": [
                end("waiting:t8", "waiting", "Finance sign-off on tax rounding rules", "Nothing from Teo Alvarez for 4 days.", -5800, view: "today", path: "/tasks/t8"),
            ]],
            ["kind": "pr", "title": "Pull requests stuck", "items": [
                end("pr:977", "pr", "#977 Bump minor versions", "1 unresolved thread, untouched for 3 days.", -4400, view: "sessions", path: "/sessions/s6", url: "https://git.example.com/acme/web/pull/977"),
            ]],
            ["kind": "page", "title": "Pages you keep opening", "items": [
                end("page:teardown", "page", "Usage-based pricing: competitor teardown", "Opened on 4 days since 12 Mar; nothing tracks it.", -7300, view: nil, path: nil, url: "https://docs.example.com/d/pricing-teardown"),
            ]],
        ]
        return ["groups": groups, "count": 6, "at": at(0)]
    }

    private func summary(_ spans: [Obj]) -> Obj {
        var byApp: [String: Int64] = [:], byTask: [String: Int64] = [:]
        var focus: Int64 = 0, switches = 0
        var last: String?
        for span in spans where span["idle"] as? Bool != true {
            let ms = (span["endAt"] as! Int64) - (span["startAt"] as! Int64)
            let app = span["app"] as! String
            focus += ms
            byApp[app, default: 0] += ms
            if let task = span["taskId"] as? String { byTask[task, default: 0] += ms }
            if let last, last != app { switches += 1 }
            last = app
        }
        return ["byApp": byApp.sorted { $0.value > $1.value }.map { ["app": $0.key, "ms": $0.value] },
                "byTask": byTask.sorted { $0.value > $1.value }.map { entry in ["taskId": entry.key, "title": tasks.first { $0["id"] as? String == entry.key }?["title"] ?? "", "ms": entry.value] },
                "focusMs": focus, "switches": switches]
    }

    // MARK: Builders

    private func initiative(_ id: String, _ title: String, _ weight: Int, _ horizon: String?, _ notes: String) -> Obj {
        ["id": id, "title": title, "notes": notes, "status": "active", "weight": weight, "horizon": opt(horizon), "createdAt": at(-90_000), "updatedAt": at(-900)]
    }

    private func project(_ id: String, _ initiative: String?, _ title: String, _ color: String, _ weight: Int, status: String = "active") -> Obj {
        ["id": id, "initiativeId": opt(initiative), "title": title, "notes": "", "status": status, "color": "#\(color)", "weight": weight, "createdAt": at(-80_000), "updatedAt": at(-600)]
    }

    private func link(_ kind: String, _ title: String, _ url: String) -> Obj { ["kind": kind, "title": title, "url": url] }

    private func task(_ id: String, _ title: String, status: String = "todo", priority: Int = 0, project: String? = nil, parent: String? = nil, due: Double? = nil,
                      estimate: Int? = nil, pinned: Bool = false, score: Double = 0, reasons: [String] = [], waitingOn: String? = nil, people: [String] = [], tags: [String] = [],
                      notes: String = "", links: [Obj] = [], source: String = "manual", snoozed: Double? = nil, completed: Double? = nil, updated: Double = -300) -> Obj {
        ["id": id, "title": title, "notes": notes, "status": status, "priority": priority, "projectId": opt(project), "parentId": opt(parent), "dueAt": opt(due.map(at)),
         "scheduledFor": null, "snoozedUntil": opt(snoozed.map(at)), "estimateMin": opt(estimate), "pinned": pinned, "manualRank": null, "score": score, "scoreReasons": reasons,
         "waitingOn": opt(waitingOn), "people": people, "tags": tags, "links": links, "source": source, "sourceRef": null, "createdAt": at(-4000),
         "updatedAt": at(completed ?? updated), "completedAt": opt(completed.map(at))]
    }

    private func session(_ id: String, _ repo: String, _ branch: String, _ ticket: String?, _ state: String, _ since: Double, _ title: String,
                         prompt: String, reply: String, pr: Obj? = nil, task: String? = nil, name: String? = nil, notes: String = "") -> Obj {
        ["id": id, "pid": 4000 + (Int(id.dropFirst()) ?? 0), "name": opt(name), "cwd": "/opt/code/\(repo)", "repo": repo, "branch": branch, "ticket": opt(ticket), "state": state,
         "stateSince": at(since), "title": title, "lastUserPrompt": prompt, "lastAssistantText": reply, "pr": opt(pr), "taskId": opt(task), "notes": notes,
         "startedAt": at(since - 95), "updatedAt": at(since)]
    }

    private func meeting(_ id: String, _ title: String, _ start: Double, _ minutes: Double, _ attendees: [String], join: String? = nil, summary: String? = nil,
                         actions: [String] = [], recording: String? = nil, prep: String? = nil) -> Obj {
        ["id": id, "source": "calendar", "externalId": "cal-\(id)", "title": title, "startAt": at(start), "endAt": at(start + minutes), "attendees": attendees, "joinUrl": opt(join),
         "location": null, "summary": opt(summary), "actionItems": actions, "recordingUrl": opt(recording), "prepNote": opt(prep), "updatedAt": at(-30)]
    }

    private func suggestion(_ id: String, _ kind: String, _ title: String, _ rationale: String, _ payload: Obj, _ source: String, _ confidence: Double, _ url: String?, _ created: Double,
                            ref: String? = nil) -> Obj {
        ["id": id, "kind": kind, "title": title, "rationale": rationale, "payload": payload, "source": source, "sourceRef": opt(ref), "sourceUrl": opt(url), "confidence": confidence,
         "status": "pending", "createdAt": at(created), "decidedAt": null]
    }

    private func note(_ id: String, _ kind: String, _ title: String, _ body: String, _ updated: Double, pinned: Bool = false, task: String? = nil, meeting: String? = nil) -> Obj {
        ["id": id, "kind": kind, "title": title, "body": body, "taskId": opt(task), "meetingId": opt(meeting), "pinned": pinned, "createdAt": at(updated - 30), "updatedAt": at(updated)]
    }

    private func person(_ id: String, _ name: String, _ handles: [String: String], _ notes: String, _ contact: Double) -> Obj {
        ["id": id, "name": name, "handles": handles, "notes": notes, "lastContactAt": at(contact)]
    }

    private func message(_ id: String, _ thread: String, _ role: String, _ text: String, _ created: Double, tool: Obj? = nil) -> Obj {
        ["id": id, "threadId": thread, "role": role, "text": text, "tool": opt(tool), "costUsd": opt(id == "m5" ? 0.41 : nil), "createdAt": at(created)]
    }

    private func job(_ name: String, _ schedule: String, _ last: Double?, _ status: String?, _ next: Double?) -> Obj {
        let spec: Obj = schedule.hasPrefix("every ") ? ["everyMin": Int(schedule.dropFirst(6).dropLast()) ?? 1] : ["at": String(schedule.prefix(5))]
        return ["name": name, "schedule": schedule, "lastRunAt": opt(last.map(at)), "lastStatus": opt(status), "nextRunAt": opt(next.map(at)), "enabled": true, "running": name == "sync:chat",
                "scheduleSpec": spec, "customSchedule": false]
    }
}
