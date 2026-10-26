import AppKit

final class FinishReviewSheet: NSWindowController {
    enum Completion { case cancelled, reset, finished }
    enum Action: Equatable { case copy, export, reset, finish, cancel }
    private let onAction: (Action) -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var buttons: [NSButton] = []
    private var working = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 168),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Finish review?"
        let copy = Style.button("Copy again", icon: .copy, target: self, action: #selector(copyAgain))
        let export = Style.button("Export…", icon: .export, target: self, action: #selector(exportMarkdown))
        let reset = Style.button("Reset", target: self, action: #selector(reset))
        reset.toolTip = "Archive this round and start fresh in the same comparison"
        let cancel = Style.button("Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let finish = Style.button("Finish & archive", target: self, action: #selector(finish))
        finish.toolTip = "Archive this round and return Home"
        finish.keyEquivalent = "\r"
        buttons = [copy, export, reset, cancel, finish]
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        status.font = .systemFont(ofSize: 12)
        let feedback = Style.stack([spinner, status], spacing: 8)
        feedback.detachesHiddenViews = true
        let actions = Style.stack([copy, export, Style.spacer(), reset, cancel, finish], spacing: 8)
        let content = Style.stack([
            Style.label("Finish review?", size: 17, weight: .semibold),
            feedback, Style.spacer(), actions
        ], orientation: .vertical, spacing: 12)
        content.alignment = .leading
        window.contentView = NSView()
        Style.pin(content, in: window.contentView!, inset: 20)
        for view in [feedback, actions] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func copyAgain() {
        guard !working else { return }
        onAction(.copy)
    }

    @objc private func exportMarkdown() {
        guard !working else { return }
        onAction(.export)
    }
    @objc func finish() {
        guard !working else { return }
        onAction(.finish)
    }
    @objc func reset() {
        guard !working else { return }
        onAction(.reset)
    }

    @objc func cancel() {
        guard !working else { return }
        onAction(.cancel)
    }

    func dismiss() {
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
    }
    func render(message: String, failed: Bool = false, working: Bool = false) {
        self.working = working
        for button in buttons { button.isEnabled = !working }
        spinner.isHidden = !working
        if working {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        showStatus(message, failed: failed)
    }
    private func showStatus(_ message: String, failed: Bool = false) {
        status.stringValue = message
        status.toolTip = message
        status.textColor = failed ? .systemRed : .secondaryLabelColor
    }
}
