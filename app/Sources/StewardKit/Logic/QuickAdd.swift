import Foundation

/// Inline shortcuts typed into any add/capture field: `!`/`!!`/`!!!` (or `!1`…`!3`, `!low`, `!high`, `!urgent`)
/// set priority, `#name` picks a project, `@name` adds a person. Tokens can sit anywhere in the text.
public struct QuickAdd: Equatable, Sendable {
    public var title: String
    /// 1 low, 2 high, 3 urgent; nil when not given.
    public var priority: Int?
    /// Every `#token`, in order. The first one that matches a project becomes the project, the rest are tags.
    public var hashes: [String]
    public var people: [String]

    public static func parse(_ text: String) -> QuickAdd {
        var out = QuickAdd(title: "", priority: nil, hashes: [], people: [])
        var words: [Substring] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            let body = word.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            switch word.first {
            case "!":
                if let p = priority(String(word)) { out.priority = max(out.priority ?? 0, p) } else { words.append(word) }
            case "#" where !body.isEmpty: out.hashes.append(body)
            case "@" where !body.isEmpty: out.people.append(body)
            default: words.append(word)
            }
        }
        out.title = words.joined(separator: " ")
        return out
    }

    private static func priority(_ token: String) -> Int? {
        switch token.lowercased() {
        case "!", "!1", "!low": 1
        case "!!", "!2", "!high": 2
        case "!!!", "!3", "!urgent": 3
        default: nil
        }
    }

    /// Best project for a `#token`: exact, then prefix, then substring, ignoring case, spaces and punctuation.
    public static func match(_ token: String, in projects: [Project]) -> Project? {
        let needle = normalize(token)
        guard !needle.isEmpty else { return nil }
        let scored = projects.compactMap { project -> (Project, Int)? in
            let name = normalize(project.title)
            if name == needle { return (project, 0) }
            if name.hasPrefix(needle) { return (project, 1) }
            if name.contains(needle) { return (project, 2) }
            return nil
        }
        return scored.min { ($0.1, $0.0.title.count) < ($1.1, $1.0.title.count) }?.0
    }

    private static func normalize(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    public func project(in projects: [Project]) -> Project? {
        hashes.lazy.compactMap { QuickAdd.match($0, in: projects) }.first
    }

    /// The `Partial<Task>` body for `POST /tasks` (without the title).
    public func fields(projects: [Project]) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let priority { fields["priority"] = .number(Double(priority)) }
        let project = project(in: projects)
        if let project { fields["projectId"] = .string(project.id) }
        let tags = hashes.filter { tag in project.map { QuickAdd.match(tag, in: [$0]) == nil } ?? true }
        if !tags.isEmpty { fields["tags"] = .array(tags.map(JSONValue.string)) }
        if !people.isEmpty { fields["people"] = .array(people.map(JSONValue.string)) }
        return .object(fields)
    }
}
