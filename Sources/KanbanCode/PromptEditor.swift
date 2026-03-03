import SwiftUI
import AppKit

/// A TextEditor replacement where Enter submits and Shift+Enter inserts a newline.
/// Reports its intrinsic height so SwiftUI can auto-size via `fixedSize(horizontal:vertical:)`.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var placeholder: String = ""
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PromptEditorScrollView {
        let scrollView = PromptEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmitTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: PromptEditorScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.font = font

        // Update placeholder
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(textView)

        // Recalculate intrinsic height after text/font changes
        scrollView.recalcIntrinsicHeight()
    }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var placeholder: String = ""

        init(_ parent: PromptEditor) {
            self.parent = parent
            self.placeholder = parent.placeholder
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder(textView)
            // Recalculate height when user types
            (textView.enclosingScrollView as? PromptEditorScrollView)?.recalcIntrinsicHeight()
        }

        func updatePlaceholder(_ textView: NSTextView) {
            if textView.string.isEmpty && !placeholder.isEmpty {
                textView.insertionPointColor = .tertiaryLabelColor
            } else {
                textView.insertionPointColor = .labelColor
            }
        }
    }
}

/// NSScrollView subclass that reports intrinsic content height based on the text content,
/// so SwiftUI can auto-size the editor with `fixedSize(horizontal:vertical:)`.
final class PromptEditorScrollView: NSScrollView {
    private var contentHeight: CGFloat = 80

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    func recalcIntrinsicHeight() {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
            + textView.textContainerInset.height * 2
        let newHeight = max(80, textHeight)
        if abs(newHeight - contentHeight) > 1 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}

/// NSTextView subclass that intercepts Return key for submit behavior.
final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 // Return key
        let hasShift = event.modifierFlags.contains(.shift)

        if isReturn && !hasShift {
            // Enter without Shift → submit
            onSubmit()
            return
        }

        if isReturn && hasShift {
            // Shift+Enter → insert newline
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }
}
