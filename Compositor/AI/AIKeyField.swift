import AppKit
import SwiftUI

/// An API key field that does not offer to save or choose a website password. A normal secure field sitting
/// under a URL is treated as a login, and macOS then presents Choose a Password when Save is clicked.
struct AIKeyField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = "API key"
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.isAutomaticTextCompletionEnabled = false
        field.stringValue = text
        // Password and an empty content type both summon the Passwords panel. A one-time code does not.
        field.contentType = .oneTimeCode
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        field.contentType = .oneTimeCode
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
