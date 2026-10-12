import SwiftUI

/// Plain text only: no smart punctuation, data detectors, or rich-text paste conversion.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var accessibilityLabel = "HTML body"
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false
        editor.isEditable = isEditable && context.environment.isEnabled
        editor.isSelectable = true
        editor.textColor = isEditable ? .textColor : .secondaryLabelColor
        editor.importsGraphics = false
        editor.allowsUndo = isEditable
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 15, height: 15)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEditable && context.environment.isEnabled
        guard editor.string != text else { return }
        editor.string = text
        editor.undoManager?.removeAllActions()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
