import Foundation

/// The private data dir (`~/Library/Application Support/Steward`, or `STEWARD_HOME`).
public struct DataDir: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var `default`: DataDir {
        if let home = ProcessInfo.processInfo.environment["STEWARD_HOME"], !home.isEmpty {
            return DataDir(url: URL(fileURLWithPath: (home as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DataDir(url: support.appendingPathComponent("Steward"))
    }

    public var logs: URL { url.appendingPathComponent("logs") }

    public var port: Int? { read("brain.port").flatMap(Int.init) }
    public var token: String? { read("brain.token") }

    private func read(_ name: String) -> String? {
        guard let s = try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
