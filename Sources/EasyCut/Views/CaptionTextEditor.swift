import AppKit
import SwiftUI

/// 한글 조합을 SwiftUI의 문자열 재설정으로 끊지 않고 동일 자막에 반영한다.
struct CaptionTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let editor = CaptionNSTextView(usingTextLayoutManager: false)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.setAccessibilityLabel(label)
        editor.string = text
        editor.delegate = context.coordinator
        editor.onTextChange = { [weak coordinator = context.coordinator, weak editor] in
            if let editor { coordinator?.publish(editor) }
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.synchronize(editor, value: text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var lastValue: String
        private var applyingModel = false
        init(text: Binding<String>) {
            self.text = text
            self.lastValue = text.wrappedValue
        }

        func synchronize(_ editor: NSTextView, value: String) {
            // 같은 모델 값의 echo는 IME 내부의 unmark/replace 사이에도 재설정하지 않는다.
            guard value != lastValue, !editor.hasMarkedText() else { return }
            lastValue = value
            guard editor.string != value else { return }
            applyingModel = true
            defer { applyingModel = false }
            let selection = editor.selectedRange()
            editor.string = value
            let length = (value as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }

        func textDidChange(_ notification: Notification) { publish(notification) }
        func textDidEndEditing(_ notification: Notification) { publish(notification) }

        private func publish(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publish(editor)
        }

        func publish(_ editor: NSTextView) {
            guard !applyingModel else { return }
            // 조합 중 문자열도 전달하되, updateNSView는 marked text에 재설정하지 않는다.
            lastValue = editor.string
            if text.wrappedValue != editor.string { text.wrappedValue = editor.string }
        }
    }
}

/// 조합·삭제가 끝난 직후의 실제 문자열을 전달한다. IME 알림의 중간 값에 의존하지 않는다.
final class CaptionNSTextView: NSTextView {
    var onTextChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onTextChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onTextChange?()
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        onTextChange?()
    }

    override func resignFirstResponder() -> Bool {
        // 포커스를 잃은 편집기에 marked range가 남으면 다른 칸의 수정도 막힌다.
        if hasMarkedText() { unmarkText() }
        let resigned = super.resignFirstResponder()
        if resigned { onTextChange?() }
        return resigned
    }
}
