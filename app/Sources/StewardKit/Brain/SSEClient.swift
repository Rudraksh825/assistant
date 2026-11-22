import Foundation

public enum SSESignal: Sendable {
    case connected
    case event(BrainEvent)
    case disconnected(String)
}

extension BrainClient {
    /// Connects to `/events` and keeps reconnecting (0.5s doubling to 10s) until the consumer stops iterating.
    public func events() -> AsyncStream<SSESignal> {
        AsyncStream { continuation in
            let task = Task {
                var delay = 0.5
                while !Task.isCancelled {
                    do {
                        // Idle timeout: pings arrive every 15s, so 45s of silence means the stream is dead.
                        let (bytes, response) = try await session.bytes(for: try request("GET", "/events", timeout: 45))
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw BrainError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "sse", message: "event stream refused")
                        }
                        continuation.yield(.connected)
                        delay = 0.5
                        var parser = SSEParser()
                        // Not `bytes.lines`: that drops the blank lines that terminate an event.
                        for try await byte in bytes {
                            if let (type, data) = parser.feed(byte), let event = try? BrainEvent.parse(type: type, data: data) {
                                continuation.yield(.event(event))
                            }
                        }
                        continuation.yield(.disconnected("stream closed"))
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.disconnected(BrainError.describe(error)))
                    }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 10)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Incremental `text/event-stream` parser: feed bytes, get `(event, data)` at each blank line.
struct SSEParser {
    private var line: [UInt8] = []
    private var type = "message"
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) -> (String, Data)? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        if line.last == 0x0D { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)

        if text.isEmpty {
            defer { type = "message"; data = [] }
            return data.isEmpty ? nil : (type, Data(data.joined(separator: "\n").utf8))
        }
        guard !text.hasPrefix(":") else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts.count > 1 ? String(parts[1].hasPrefix(" ") ? parts[1].dropFirst() : parts[1]) : ""
        switch parts[0] {
        case "event": type = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}
