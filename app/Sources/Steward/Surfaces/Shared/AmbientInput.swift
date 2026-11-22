import AppKit
import SwiftUI
import StewardKit

/// Text entry for the ambient panels. AppKit rather than `TextField` because these panels are rarely
/// key when they appear: first responder has to be taken explicitly, and Return, ⇧Return, ⌘Return,
/// Esc and the arrows each mean something specific.
struct AmbientTextInput: NSViewRepresentable {
    enum Key { case up, down, tab, backTab }

    @Binding var text: String
    var placeholder = ""
    var font = NSFont.systemFont(ofSize: 13)
    var color = NSColor.white
    /// 1 = a single line (Return always submits). More = grows to that many lines, ⇧Return inserts a newline.
    var maxLines = 1
    /// Bump to take first responder.
    var focus = 0
    /// Return, with the modifiers held (⌘Return arrives here too).
    var onSubmit: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onEscape: (() -> Void)?
    /// Arrow/Tab navigation out of the field; return true when handled.
    var onMove: ((Key) -> Bool)?
    var onFocus: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.insertionPointColor = NSColor(Palette.accent)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        configure(textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? InputTextView else { return }
        context.coordinator.parent = self
        configure(textView, coordinator: context.coordinator)
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            // The window may only just have become key in this same turn.
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? InputTextView, let container = textView.textContainer, let manager = textView.layoutManager else { return nil }
        let width = proposal.width ?? 240
        let line = manager.defaultLineHeight(for: font)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return CGSize(width: width, height: min(max(used, line), line * CGFloat(maxLines)).rounded(.up))
    }

    private func configure(_ textView: InputTextView, coordinator: Coordinator) {
        textView.font = font
        textView.textColor = color
        textView.placeholder = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.34)])
        textView.multiline = maxLines > 1
        textView.coordinator = coordinator
        textView.textContainer?.maximumNumberOfLines = maxLines > 1 ? 0 : 1
        textView.textContainer?.lineBreakMode = maxLines > 1 ? .byWordWrapping : .byTruncatingHead
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AmbientTextInput
        var lastFocus = 0

        init(_ parent: AmbientTextInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    final class InputTextView: NSTextView {
        var placeholder = NSAttributedString()
        var multiline = false
        weak var coordinator: Coordinator?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty { placeholder.draw(at: textContainerOrigin) }
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.parent.onFocus?(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.parent.onFocus?(false) }
            return resigned
        }

        // ⌘Return never reaches keyDown: key equivalents are offered to the view tree first.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, isReturn(event), event.modifierFlags.contains(.command), window?.firstResponder === self {
                coordinator?.parent.onSubmit(event.modifierFlags)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            // Mid-composition (an input method is open) every key belongs to the input method.
            guard !hasMarkedText(), let parent = coordinator?.parent else { return super.keyDown(with: event) }
            let shift = event.modifierFlags.contains(.shift)
            switch Int(event.keyCode) {
            case 36, 76:
                if shift && multiline { insertNewlineIgnoringFieldEditor(nil) } else { parent.onSubmit(event.modifierFlags) }
            case 53:
                if let onEscape = parent.onEscape { onEscape() } else { super.keyDown(with: event) }
            case 48:
                if parent.onMove?(shift ? .backTab : .tab) != true { super.keyDown(with: event) }
            case 126 where !multiline || string.isEmpty:
                if parent.onMove?(.up) != true { super.keyDown(with: event) }
            case 125 where !multiline || string.isEmpty:
                if parent.onMove?(.down) != true { super.keyDown(with: event) }
            default:
                super.keyDown(with: event)
            }
        }

        private func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }
    }
}

/// Hover that works while Steward is not the active app and the panel is not key (SwiftUI's `onHover`
/// needs a key window). Sits behind the content and never takes a click.
struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Sensor { Sensor() }

    func updateNSView(_ view: Sensor, context: Context) { view.onChange = onChange }

    static func dismantleNSView(_ view: Sensor, coordinator: ()) {
        if view.inside { view.onChange(false) }
    }

    final class Sensor: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private(set) var inside = false

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        // AppKit sends no `mouseEntered` to a view the pointer was already over when its window started
        // taking mouse events again; the first move inside makes up for it.
        override func mouseMoved(with event: NSEvent) {
            guard !inside else { return }
            inside = true
            onChange(true)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            inside = true
            onChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            inside = false
            onChange(false)
        }
    }
}

extension View {
    func onPointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(HoverSensor(onChange: action))
    }
}
