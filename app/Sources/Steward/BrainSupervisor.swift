import Foundation
import StewardKit

/// Runs the brain (`node brain/dist/main.js`) as a child: spawn, wait for `/health`, restart with
/// backoff on crash, kill on quit. A healthy brain that is already running (dev mode) is adopted instead.
@MainActor @Observable
final class BrainSupervisor {
    enum Status: Equatable {
        case idle
        case adopted
        case starting
        case running
        case unavailable(String)
        case restarting(String)
    }

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            Log.info("brain: \(status)")
            switch status {
            case .unavailable(let why), .restarting(let why): store.brainNote = why
            default: store.brainNote = nil
            }
        }
    }

    private let store: AppStore
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var quitting = false
    private let env = ProcessInfo.processInfo.environment

    init(store: AppStore) {
        self.store = store
    }

    func start() {
        Task { await launch() }
    }

    func stop() {
        quitting = true
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func launch() async {
        guard !quitting else { return }
        if await healthy() {
            status = .adopted
            return
        }
        if env["STEWARD_NO_BRAIN"] == "1" {
            status = .unavailable("Waiting for an externally run brain (STEWARD_NO_BRAIN=1).")
            return
        }
        guard let repo = Self.repoRoot() else {
            return retry("Can't find the Steward repo. Set STEWARD_REPO or rebuild with scripts/build.sh.", fixed: 15)
        }
        let entry = repo.appendingPathComponent("brain/dist/main.js")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            return retry("The brain isn't built yet (\(entry.path) is missing). Run scripts/build.sh.", fixed: 15)
        }
        guard let node = Self.findNode() else {
            return retry("Node.js not found. Install Node 24 or set STEWARD_NODE to its path.", fixed: 30)
        }

        let logs = store.client.dataDir.logs
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = node
        p.arguments = [entry.path]
        p.currentDirectoryURL = repo
        var childEnv = env
        childEnv["PATH"] = node.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = childEnv
        if let out = Log.open(logs.appendingPathComponent("brain.stdout.log")) {
            p.standardOutput = out
            p.standardError = out
        }
        p.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.exited(finished) }
        }
        do { try p.run() } catch {
            return retry("Couldn't start the brain: \(error.localizedDescription)")
        }
        process = p
        startedAt = Date()
        status = .starting
        Log.info("brain: spawned pid=\(p.processIdentifier) node=\(node.path) entry=\(entry.path)")

        for _ in 0..<100 where p.isRunning {
            if await healthy() {
                status = .running
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if p.isRunning { status = .unavailable("The brain started but isn't answering /health. See logs/brain.stdout.log.") }
    }

    private func exited(_ finished: Process) {
        guard finished === process, !quitting else { return }
        process = nil
        if Date().timeIntervalSince(startedAt) > 60 { attempts = 0 }
        retry("The brain exited (status \(finished.terminationStatus)).")
    }

    /// Schedules another launch: 1s doubling to 30s for crashes, or a fixed interval for "not installed yet".
    private func retry(_ why: String, fixed: Double? = nil) {
        let delay = fixed ?? min(30, pow(2, Double(attempts)))
        if fixed == nil { attempts += 1 }
        status = fixed == nil ? .restarting("\(why) Restarting in \(Int(delay))s.") : .unavailable(why)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await launch()
        }
    }

    private func healthy() async -> Bool {
        (try? await store.client.health().ok) == true
    }

    // MARK: Locating things

    /// `STEWARD_REPO`, then the path recorded in Info.plist at build time, then (for `swift run`) the
    /// nearest ancestor of the executable that contains `brain/`.
    static func repoRoot() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["STEWARD_REPO"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let recorded = Bundle.main.object(forInfoDictionaryKey: "StewardRepoPath") as? String, fm.fileExists(atPath: recorded) {
            return URL(fileURLWithPath: recorded)
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if fm.fileExists(atPath: d.appendingPathComponent("brain/package.json").path) { return d }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// GUI apps get a minimal PATH, so look where version managers and package managers put node.
    static func findNode() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let override = env["STEWARD_NODE"] { candidates.append((override as NSString).expandingTildeInPath) }
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "\(home)/.volta/bin/node", "\(home)/.local/share/mise/shims/node",
                       "\(home)/.asdf/shims/node", "\(home)/.local/bin/node"]
        for root in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions", "\(home)/Library/Application Support/fnm/node-versions"] {
            let versions = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += versions.flatMap { ["\(root)/\($0)/bin/node", "\(root)/\($0)/installation/bin/node"] }
        }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}
