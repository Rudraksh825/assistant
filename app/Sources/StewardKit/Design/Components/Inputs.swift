import SwiftUI

/// Single-line capture/add field. Enter submits and clears; ⌘↩ calls `onAlternate` when provided.
public struct CaptureField: View {
    let placeholder: String
    let icon: String
    let onSubmit: (String) -> Void
    let onAlternate: ((String) -> Void)?
    @State private var text = ""
    @FocusState private var focused: Bool

    public init(_ placeholder: String = "Capture a thought…", icon: String = "plus", onAlternate: ((String) -> Void)? = nil, onSubmit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.icon = icon
        self.onAlternate = onAlternate
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(focused ? Palette.accent : Palette.textFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .onSubmit { submit(onSubmit) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command), let onAlternate else { return .ignored }
                    submit(onAlternate)
                    return .handled
                }
            if !text.isEmpty { KeyHint("↩") }
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, 7)
        .background(Palette.bgSunken.opacity(0.7), in: .continuous(Radius.s + 2))
        .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: focused)
    }

    private func submit(_ handler: (String) -> Void) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        handler(value)
        text = ""
        Haptics.tick()
    }
}

/// Shown wherever live data would be while the brain is unreachable.
public struct OfflineBanner: View {
    let connection: AppStore.Connection
    let note: String?
    let onRetry: (() -> Void)?

    public init(connection: AppStore.Connection, note: String? = nil, onRetry: (() -> Void)? = nil) {
        self.connection = connection
        self.note = note
        self.onRetry = onRetry
    }

    public var body: some View {
        if !connection.isOnline {
            HStack(spacing: Space.s) {
                Image(systemName: connection == .connecting ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle")
                    .foregroundStyle(connection == .connecting ? Palette.textDim : Palette.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection == .connecting ? "Connecting to the brain…" : "Brain offline")
                        .font(Typo.bodyStrong).foregroundStyle(Palette.text)
                    if let detail {
                        Text(detail).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(2)
                    }
                }
                Spacer(minLength: Space.s)
                if let onRetry { Button("Retry", action: onRetry).buttonStyle(.pressable()) }
            }
            .padding(Space.m)
            .background(Palette.warn.opacity(0.07), in: .continuous(Radius.m))
            .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(Palette.warn.opacity(0.25), lineWidth: 1))
        }
    }

    private var detail: String? {
        if let note { return note }
        if case .offline(let why) = connection { return why }
        return nil
    }
}
