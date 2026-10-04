import AppKit

final class FinishReviewSheet: NSWindowController {
    enum Completion { case cancelled, reset, finished }
    private let text: String
    private let pasteboard: NSPasteboard
    private let archive: () async throws -> Void
    private let onClose: (Completion) -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var buttons: [NSButton] = []
    private var operation: Task<Void, Never>?

    init(text: String, pasteboard: NSPasteboard = .general,
         archive: @escaping () async throws -> Void, onClose: @escaping (Completion) -> Void) {
        self.text = text; self.pasteboard = pasteboard
        self.archive = archive; self.onClose = onClose
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
        copyAgain()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func copyAgain() {
        guard operation == nil else { return }
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            showStatus("Review copied to clipboard.")
        } else {
            showStatus("Could not copy the review. Try Copy again or Export.", failed: true)
        }
    }

    @objc private func exportMarkdown() {
        guard operation == nil, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "review.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func export(to url: URL) {
        guard operation == nil else { return }
        setWorking("Exporting review…")
        operation = Task { [weak self, text] in
            do {
                try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
                self?.showStatus("Exported \(url.lastPathComponent).")
            } catch {
                self?.showStatus("Could not export: \(error.localizedDescription) Try Export again.", failed: true)
            }
            self?.setWorking(nil)
        }
    }

    @objc func finish() { archiveAndDismiss(.finished) }
    @objc func reset() { archiveAndDismiss(.reset) }

    private func archiveAndDismiss(_ completion: Completion) {
        guard operation == nil else { return }
        setWorking("Archiving review…")
        operation = Task { [weak self, archive] in
            do {
                try await archive()
                self?.setWorking(nil)
                self?.dismiss(completion)
            } catch {
                self?.showStatus("Could not archive: \(error.localizedDescription) Your active review is unchanged. Try again.", failed: true)
                self?.setWorking(nil)
            }
        }
    }

    @objc func cancel() {
        guard operation == nil else { return }
        dismiss(.cancelled)
    }

    private func dismiss(_ completion: Completion) {
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        onClose(completion)
    }
    private func setWorking(_ message: String?) {
        for button in buttons { button.isEnabled = message == nil }
        spinner.isHidden = message == nil
        if let message {
            spinner.startAnimation(nil)
            showStatus(message)
        } else {
            spinner.stopAnimation(nil)
            operation = nil
        }
    }
    private func showStatus(_ message: String, failed: Bool = false) {
        status.stringValue = message
        status.toolTip = message
        status.textColor = failed ? .systemRed : .secondaryLabelColor
    }
}
