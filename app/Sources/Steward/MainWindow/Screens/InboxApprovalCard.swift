import SwiftUI
import StewardKit

/// An action waiting for a decision. What runs is the literal input, shown field by field; the agent's own
/// description is labelled as such and never stands in for it. Used in the Inbox and inline in the Agent chat.
/// Nothing here approves on its own: every path is a click or ⌘↩ on this card, with the whole payload shown.
struct ApprovalReviewCard: View {
    let approval: Approval
    var selected = false
    @Binding var editing: Bool
    /// "Show all" was pressed. Held by the screen so its ⌘↩ follows the same rule as the button.
    @Binding var expanded: Bool

    @Environment(AppStore.self) private var store
    @State private var json = ""

    private var payload: ApprovalPayload { ApprovalPayload(approval) }
    /// A long payload must be opened in full before it can be approved.
    static func canApprove(_ approval: Approval, expanded: Bool) -> Bool { expanded || !ApprovalPayload(approval).isLong }

    var body: some View {
        let payload = payload
        let cut = payload.isLong && !expanded
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Pill("Needs approval", icon: "hand.raised.fill", color: Palette.danger)
                if let target = approval.target, !target.isEmpty { Pill(ApprovalPayload.label(target, max: 60), icon: "arrow.up.right") }
                Spacer(minLength: Space.s)
                Text(verbatim: ApprovalPayload.label(approval.tool, max: 80)).font(Typo.mono).foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.since(approval.createdAt)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("The agent describes it as").font(Typo.caption).foregroundStyle(Palette.textFaint)
                Text(verbatim: ApprovalPayload.label(approval.summary, max: 300)).font(Typo.bodyStrong).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            }
            if let note = approval.note, !note.isEmpty {
                Label { Text(verbatim: note).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "shield.lefthalf.filled").font(.system(size: 10)).foregroundStyle(Palette.warn) }
            }

            if editing {
                Text("Edit the input, then approve. Your version replaces it and is what runs.").font(Typo.caption).foregroundStyle(Palette.textDim)
                TextEditor(text: $json)
                    .font(Typo.mono)
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.s)
                    .background(Palette.bgSunken, in: .continuous(Radius.s + 2))
                    .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(edits == nil ? Palette.danger.opacity(0.6) : Palette.accent.opacity(0.5), lineWidth: 1))
                if edits == nil {
                    Text("Not a JSON object yet.").font(Typo.caption).foregroundStyle(Palette.danger)
                }
            } else {
                Text(verbatim: "Runs exactly this, once (\(approval.tool == "Bash" ? "shell command" : "tool input"), \(payload.length) characters):").font(Typo.caption).foregroundStyle(Palette.textFaint)
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(cut ? payload.clipped() : payload.fields) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: field.name).font(Typo.caption).foregroundStyle(Palette.textFaint)
                            Text(verbatim: field.text)
                                .font(Typo.mono)
                                .foregroundStyle(Palette.text.opacity(0.9))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if cut {
                        Button("Show all \(payload.length) characters") { withAnimation(Motion.snappy) { expanded = true } }
                            .buttonStyle(.pressable()).fixedSize()
                    }
                }
                .padding(Space.s + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgSunken, in: .continuous(Radius.s + 2))
                ForEach(payload.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(Palette.warn)
                }
            }

            HStack(spacing: Space.s) {
                if editing {
                    Button("Approve edited", systemImage: "checkmark") {
                        if let edits { store.approve(approval, edits: edits) }
                    }
                    .buttonStyle(.pressable(.primary)).labelStyle(.titleAndIcon).fixedSize().disabled(edits == nil)
                    Button("Cancel") { withAnimation(Motion.snappy) { editing = false } }.buttonStyle(.pressable(.ghost)).fixedSize()
                } else {
                    Button { store.approve(approval) } label: {
                        HStack(spacing: 6) {
                            Label("Approve", systemImage: "checkmark").labelStyle(.titleAndIcon)
                            if selected && !cut { ApprovalKeys(keys: ["⌘", "↩"]) }
                        }
                    }
                    .buttonStyle(.pressable(.primary)).fixedSize().disabled(cut)
                    .help(cut ? "Show the whole input first" : "Run exactly what is shown")
                    if approval.kind != "self_modify" {
                        Button { withAnimation(Motion.snappy) { editing = true } } label: {
                            HStack(spacing: 6) { Text("Edit"); if selected { KeyHint("E") } }
                        }
                        .buttonStyle(.pressable()).fixedSize()
                    }
                    Button { store.deny(approval) } label: {
                        HStack(spacing: 6) { Text("Deny"); if selected { KeyHint("X") } }
                    }
                    .buttonStyle(.pressable(.danger)).fixedSize()
                }
                Spacer(minLength: 0)
                Text(cut ? "Show all of it to approve" : approval.kind == "self_modify" ? "Loads this code into the app" : "Runs outside the sandbox once approved")
                    .font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            .padding(.top, 2)
        }
        .padding(Space.m)
        .background(Palette.danger.opacity(0.035), in: .continuous(Radius.l))
        .cardSurface(radius: Radius.l)
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(selected ? Palette.accent.opacity(0.6) : Palette.danger.opacity(0.18), lineWidth: selected ? 1.5 : 1))
        .onChange(of: editing, initial: true) { if editing { json = JSONValue.object(approval.input).text(pretty: true) } }
    }

    /// The edited input as an object, or nil while the text is not valid JSON.
    private var edits: JSONValue? {
        guard let value = try? BrainJSON.decoder.decode(JSONValue.self, from: Data(json.utf8)), value.object != nil else { return nil }
        return value
    }
}

/// Key hint that stays readable on the accent-coloured primary button.
private struct ApprovalKeys: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.onAccent.opacity(0.75))
                    .frame(minWidth: 15, minHeight: 15).background(Palette.onAccent.opacity(0.14), in: .continuous(4))
            }
        }
    }
}

/// The payload as the notch and a toast show it: always in view next to the buttons, and, when it does not fit,
/// with "Review" (which opens the full card) in place of "Approve".
struct ApprovalCompactPayload: View {
    let approval: Approval
    let dim: Color
    let fill: Color

    var body: some View {
        let compact = ApprovalPayload(approval).compact
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(ApprovalPayload.label(approval.tool, max: 48)) runs:").font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
            Text(verbatim: compact.text)
                .font(Typo.mono).foregroundStyle(dim).textSelection(.enabled)
                // No line limit: a payload reported as complete must be drawn completely.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact.complete {
                Text("There is more. Review shows all of it.").font(.system(size: 10)).foregroundStyle(Palette.warn)
            }
        }
        .padding(8)
        .background(fill, in: .continuous(10))
    }
}
