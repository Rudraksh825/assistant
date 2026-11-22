import Foundation
import StewardKit

/// Append-only log at `logs/app.log` (rotated to `app.log.1` past 2 MB at launch), mirrored to stderr.
enum Log {
    private static let queue = DispatchQueue(label: "steward.log")
    nonisolated(unsafe) private static var handle: FileHandle?

    static func setup(_ dataDir: DataDir) {
        let dir = dataDir.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        handle = open(dir.appendingPathComponent("app.log"))
    }

    /// Opens (rotating if large) a log file for appending.
    static func open(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// Blocks until queued lines are on disk; for the last line before exit.
    static func flush() { queue.sync {} }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) \(level) \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}
