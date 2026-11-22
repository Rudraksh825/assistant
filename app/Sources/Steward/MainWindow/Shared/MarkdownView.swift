import AppKit
import SwiftUI
import StewardKit

/// Renders markdown as native blocks: headings, lists, code, quotes, tables. Parses on every render,
/// which keeps a streaming reply laid out exactly as the finished one will be.
struct MarkdownView: View {
    let text: String
    /// Document mode: roomier type for briefs and notes read as pages.
    var document = false

    var body: some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: document ? 12 : 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyFont: Font { document ? .system(size: 14) : Typo.body }

    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .system(size: document ? 22 : 18, weight: .semibold, design: .rounded)
                    : level == 2 ? .system(size: document ? 17 : 15, weight: .semibold) : Typo.heading)
                .foregroundStyle(Palette.text)
                .padding(.top, level <= 2 ? 4 : 1)
        case .paragraph(let text):
            Text(Self.inline(text)).font(bodyFont).foregroundStyle(Palette.text).lineSpacing(document ? 5 : 3.5)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: document ? 6 : 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(item)
                        Text(Self.inline(item.text)).font(bodyFont)
                            .foregroundStyle(item.checked == true ? Palette.textDim : Palette.text)
                            .strikethrough(item.checked == true, color: Palette.textFaint)
                            .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let text):
            Text(Self.inline(text)).font(bodyFont).foregroundStyle(Palette.textDim).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.m)
                .overlay(alignment: .leading) { Capsule().fill(Palette.accent.opacity(0.6)).frame(width: 2.5) }
        case .table(let header, let rows):
            table(header, rows)
        case .rule:
            Rectangle().fill(Palette.stroke).frame(height: 1).padding(.vertical, 2)
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownBlock.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                .foregroundStyle(checked ? Palette.ok : Palette.textFaint)
        } else if let number = item.number {
            Text("\(number).").font(Typo.numeric).foregroundStyle(Palette.textDim).frame(minWidth: 14, alignment: .trailing)
        } else {
            Circle().fill(Palette.textFaint).frame(width: 4, height: 4).offset(y: -3)
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(Self.inline(cell)).font(Typo.caption.weight(.semibold)).foregroundStyle(Palette.textDim).padding(.vertical, 6)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(Palette.stroke).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell)).font(Typo.body).foregroundStyle(Palette.text).padding(.vertical, 6).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 2)
        .background(Palette.bgRaised.opacity(0.6), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.stroke, lineWidth: 1))
    }

    /// Inline markdown (bold, italic, code, links). Falls back to the raw text while a span is still open mid-stream.
    static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range].font = .system(size: 12, design: .monospaced)
                out[run.range].backgroundColor = Palette.pressed
            }
            if run.link != nil {
                out[run.range].foregroundColor = Palette.info
                out[run.range].underlineStyle = .single
            }
        }
        return out
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(Typo.label).kerning(0.5).foregroundStyle(Palette.textFaint)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Motion.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(Motion.snappy) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Typo.caption).foregroundStyle(copied ? Palette.ok : Palette.textDim)
                }
                .buttonStyle(.pressable(.bare))
            }
            .padding(.horizontal, Space.m)
            .frame(height: 26)
            .background(Color.white.opacity(0.03))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.text.opacity(0.92))
                    .lineSpacing(3).textSelection(.enabled).fixedSize()
                    .padding(Space.m)
            }
        }
        .background(Palette.bgSunken, in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.stroke, lineWidth: 1))
        .clipShape(.continuous(Radius.m))
    }
}
