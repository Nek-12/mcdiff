import AppKit
import McDiffCore

/// A window-wide destination; text editors retain their normal paste responder.
final class PRDropView: NSView, NSMenuItemValidation {
    var onOpenPR: ((String) -> Void)?
    var onPaste: ((String) -> Void)?
    private let pasteboard: NSPasteboard
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        pasteboard = .general
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
    }

    init(frame frameRect: NSRect, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
    }

    override var acceptsFirstResponder: Bool { true }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func pullRequest(from pasteboard: NSPasteboard) -> GitHubPR? {
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              let item = items.first,
              let value = item.string(forType: .URL) ?? item.string(forType: .string) else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace) else { return nil }
        return try? GitHubPR.parse(text)
    }

    @objc func paste(_ sender: Any?) {
        guard let pr = Self.pullRequest(from: pasteboard) else {
            NSSound.beep()
            return
        }
        onPaste?(pr.url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(paste(_:)) else { return true }
        return Self.pullRequest(from: pasteboard) != nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted = Self.pullRequest(from: sender.draggingPasteboard) != nil
        return highlighted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        guard let pr = Self.pullRequest(from: sender.draggingPasteboard), let onOpenPR else { return false }
        onOpenPR(pr.url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
        border.lineWidth = 3
        border.stroke()
    }
}
