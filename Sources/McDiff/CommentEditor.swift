import AppKit
import McDiffCore

@MainActor
final class CommentEditorController: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    private enum Feedback {
        case none
        case discard
        case failure(String)
    }

    private let original: ReviewComment
    private let onSave: (ReviewComment) throws -> Void
    private let onDelete: (() throws -> Void)?
    private let popover = NSPopover()
    private let textView = NSTextView()
    private let startField = LineRangeField()
    private let endField = LineRangeField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!
    private var cancelButton: NSButton!
    private var feedback: Feedback = .none
    private var finished = false

    init(comment: ReviewComment, isNew: Bool, onSave: @escaping (ReviewComment) throws -> Void,
         onDelete: (() throws -> Void)? = nil) {
        original = comment
        self.onSave = onSave
        self.onDelete = onDelete
        super.init()

        let controller = CommentPopoverContentController()
        controller.onCancel = { [weak self] in self?.requestCancellation() }
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 440, height: 260)
        // Outside clicks must not silently discard a draft; the parent mediates selection changes.
        popover.behavior = .applicationDefined

        let path = Style.label(comment.path, size: 12, weight: .semibold)
        path.isSelectable = true
        path.toolTip = comment.path
        startField.stringValue = String(comment.startLine)
        endField.stringValue = String(comment.endLine)
        startField.toolTip = "First line of the comment range"
        endField.toolTip = "Last line of the comment range"
        for field in [startField, endField] {
            field.drawsBackground = false
            field.isBezeled = false
            field.delegate = self
            field.controlSize = .small
            field.font = .systemFont(ofSize: 11)
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        let range = Style.stack([
            Style.label(comment.side == .old ? "Original" : "Changed", size: 11, color: .secondaryLabelColor),
            startField, Style.label("–", size: 11), endField
        ], spacing: 6)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 416, height: 120)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = comment.text
        textView.delegate = self
        textView.drawsBackground = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = NSScroller.preferredScrollerStyle
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView

        saveButton = Style.button("Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save (⌘Return)"
        cancelButton = Style.button("Cancel", target: self, action: #selector(cancelEditing))
        cancelButton.toolTip = "Cancel (Escape)"
        let buttons = Style.stack([], spacing: 6)
        if !isNew, onDelete != nil {
            buttons.addArrangedSubview(Style.button("Delete", icon: "trash", target: self, action: #selector(deleteComment)))
        }
        buttons.addArrangedSubview(Style.spacer())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        for case let button as NSButton in buttons.arrangedSubviews { button.controlSize = .regular }

        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        let content = Style.stack([path, range, scroll, status, buttons], orientation: .vertical, spacing: 8)
        Style.pin(content, in: controller.view, inset: 12)
        for view in [path, scroll, status, buttons] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        updateControls()
    }

    var isShown: Bool { popover.isShown }

    var hasUnsavedEdits: Bool {
        !finished && (textView.string != original.text || startField.stringValue != String(original.startLine) ||
        endField.stringValue != String(original.endLine))
    }

    func present(relativeTo rect: NSRect, of view: NSView) {
        guard !finished, view.window != nil else { return }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        focus()
    }

    func focus() {
        guard popover.isShown else { return }
        textView.window?.makeKey()
        textView.window?.makeFirstResponder(textView)
    }

    @discardableResult
    func dismissIfUnchanged() -> Bool {
        guard !hasUnsavedEdits else { return false }
        finish()
        return true
    }

    private var validRange: (Int, Int)? {
        guard let start = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)),
              let end = Int(endField.stringValue.trimmingCharacters(in: .whitespaces)),
              start >= 1, end >= start else { return nil }
        return (start, end)
    }

    private var hasText: Bool { !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func updateControls() {
        let previousStatus = status.stringValue
        let previousTitle = cancelButton.title
        saveButton.isEnabled = validRange != nil && hasText
        cancelButton.title = "Cancel"
        status.textColor = .secondaryLabelColor
        switch feedback {
        case .none:
            status.stringValue = validRange == nil ? "Use whole line numbers: start ≥ 1, end ≥ start." : ""
        case .discard:
            cancelButton.title = "Discard"
            status.stringValue = "Discard unsaved changes? Click Discard to confirm."
        case .failure(let message):
            status.stringValue = message
            status.textColor = .systemRed
        }
        status.toolTip = status.stringValue
        status.isHidden = status.stringValue.isEmpty
        cancelButton.toolTip = cancelButton.title == "Discard" ? "Discard unsaved changes" : "Cancel (Escape)"
        if previousStatus != status.stringValue { Style.animateStateChange(status) }
        if previousTitle != cancelButton.title { Style.animateStateChange(cancelButton) }
    }

    private func edited() {
        feedback = .none
        updateControls()
    }

    func textDidChange(_ notification: Notification) { edited() }
    func controlTextDidChange(_ notification: Notification) { edited() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        requestCancellation()
        return true
    }

    @objc private func save() {
        guard !finished, let (start, end) = validRange, hasText else { updateControls(); return }
        var comment = original
        comment.startLine = start
        comment.endLine = end
        comment.text = textView.string
        do {
            try onSave(comment)
            finish()
        } catch {
            feedback = .failure("Could not save: \(error.localizedDescription)")
            updateControls()
        }
    }

    @objc private func deleteComment() {
        guard !finished, let onDelete else { return }
        do {
            try onDelete()
            finish()
        } catch {
            feedback = .failure("Could not delete: \(error.localizedDescription)")
            updateControls()
        }
    }

    @objc private func cancelEditing() {
        if case .discard = feedback { finish() }
        else { requestCancellation() }
    }

    private func requestCancellation() {
        guard !finished else { return }
        guard hasUnsavedEdits else { finish(); return }
        feedback = .discard
        updateControls()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        popover.close()
    }
}

private final class LineRangeField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class CommentPopoverContentController: NSViewController {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
