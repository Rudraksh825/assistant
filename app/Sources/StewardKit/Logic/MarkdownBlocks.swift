import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var text: String
        /// Nesting depth, 0 for top level.
        public var indent: Int
        /// The item's own number for ordered lists.
        public var number: Int?
        /// `- [ ]` / `- [x]` task items.
        public var checked: Bool?
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list([Item])
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// Block-level markdown, enough for agent replies and briefs. Inline styling is left to `AttributedString`.
/// Tolerates text that is still streaming: an unclosed code fence runs to the end.
public enum Markdown {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                i += 1
            } else if trimmed.isEmpty {
                flush()
                i += 1
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
            } else if trimmed.count >= 3, Set(trimmed).isSubset(of: ["-", " "]) || Set(trimmed).isSubset(of: ["*", " "]) || Set(trimmed) == ["_"],
                      trimmed.filter({ $0 != " " }).count >= 3 {
                flush()
                blocks.append(.rule)
                i += 1
            } else if trimmed.hasPrefix(">") {
                flush()
                var body: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    body.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i])
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if item(line) != nil {
                flush()
                var items: [MarkdownBlock.Item] = []
                while i < lines.count {
                    if let next = item(lines[i]) {
                        items.append(next)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix(" "), !items.isEmpty {
                        // Hanging continuation of the previous item.
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.list(items))
            } else {
                paragraph.append(trimmed)
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func item(_ line: String) -> MarkdownBlock.Item? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var text: Substring
        var number: Int?
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            text = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            let rest = body.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 4, let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
            number = Int(digits)
            text = rest.dropFirst(2)
        }
        var checked: Bool?
        if number == nil, text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            checked = !text.hasPrefix("[ ]")
            text = text.dropFirst(4)
        }
        return .init(text: text.trimmingCharacters(in: .whitespaces), indent: spaces / 2, number: number, checked: checked)
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && Set(t).isSubset(of: ["|", "-", ":", " "])
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
