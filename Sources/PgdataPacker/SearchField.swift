import AppKit
import SwiftUI

/// The system search field (`NSSearchField`) for filtering a list: the magnifier, a placeholder,
/// and the clear button that appears once there is text. SwiftUI's `.searchable` puts its field in
/// the toolbar on macOS 13, which is not where these filters sit, so the AppKit field is wrapped.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityLabel(placeholder)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(placeholder)
        }
    }

    /// The field takes the width it is offered (as flexible as a SwiftUI text field) and its own
    /// natural height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize.height
        let height: CGFloat = natural > 0 ? natural : 22
        let width: CGFloat = proposal.width ?? 220
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        /// Typing, pasting, and cutting.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            push(field.stringValue)
        }

        /// The field's action: sent on every change (`sendsSearchStringImmediately`) and when the
        /// clear button empties it, which does not always post `controlTextDidChange`.
        @objc func searchChanged(_ sender: NSSearchField) { push(sender.stringValue) }

        private func push(_ value: String) {
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}
