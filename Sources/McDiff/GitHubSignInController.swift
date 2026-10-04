import AppKit
import McDiffCore

@MainActor
final class GitHubSignInController: NSWindowController, NSWindowDelegate {
    private let client: GitHubClient
    private let onSignedIn: (GitHubUser) -> Void
    private let onCancelled: () -> Void
    private var completed = false
    private let pasteboard: NSPasteboard
    private let openBrowser: (URL) -> Bool
    private var task: Task<Void, Never>?
    private var authorization: GitHubDeviceAuthorization?
    private let code = Style.label("", size: 24, weight: .semibold)
    private let expiry = Style.label("", size: 12, color: .secondaryLabelColor)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var continueButton: NSButton!
    private var retryButton: NSButton!

    init(client: GitHubClient, onSignedIn: @escaping (GitHubUser) -> Void,
         onCancelled: @escaping () -> Void = {},
         pasteboard: NSPasteboard = .general,
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.client = client
        self.onSignedIn = onSignedIn
        self.onCancelled = onCancelled
        self.pasteboard = pasteboard
        self.openBrowser = openBrowser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Sign in to GitHub"
        window.delegate = self
        let title = Style.label("Sign in to GitHub", size: 20, weight: .semibold)
        code.isSelectable = true
        code.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        continueButton = Style.button("Copy code & continue", target: self, action: #selector(continueSignIn))
        continueButton.toolTip = "Copy the sign-in code and open GitHub in your browser"
        continueButton.keyEquivalent = "\r"
        retryButton = Style.button("Retry", target: self, action: #selector(requestCode))
        retryButton.toolTip = "Request a fresh GitHub sign-in code"
        let cancel = Style.button("", icon: .close, target: self, action: #selector(cancelSignIn))
        cancel.toolTip = "Cancel GitHub sign-in"
        cancel.keyEquivalent = "\u{1b}"
        let heading = Style.stack([title, Style.spacer(), cancel])
        let feedback = Style.stack([spinner, status])
        let actions = Style.stack([Style.spacer(), retryButton, continueButton])
        let content = Style.stack([heading, code, expiry, feedback, Style.spacer(), actions],
                                  orientation: .vertical, spacing: 12)
        let root = NSView()
        window.contentView = root
        Style.pin(content, in: root, inset: 24)
        for child in [heading, feedback, actions] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        continueButton.isEnabled = false
        retryButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(on parent: NSWindow) {
        guard let window, window.sheetParent == nil, !window.isVisible else { return }
        parent.beginSheet(window) { [weak self] _ in self?.stop() }
        requestCode()
    }

    @objc private func requestCode() {
        guard task == nil else { return }
        authorization = nil
        code.stringValue = ""
        expiry.stringValue = ""
        setLoading("Requesting your GitHub sign-in code…")
        task = Task { [weak self, client] in
            do {
                let authorization = try await client.beginSignIn()
                try Task.checkCancellation()
                guard let self else { return }
                self.task = nil
                self.authorization = authorization
                self.code.stringValue = authorization.userCode
                self.expiry.stringValue = "Code expires at \(authorization.expiresAt.formatted(date: .omitted, time: .standard))."
                self.status.stringValue = ""
                self.spinner.stopAnimation(nil)
                self.continueButton.isEnabled = true
                Style.animateStateChange(self.window?.contentView)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showError(error.localizedDescription)
            }
        }
    }

    @objc private func continueSignIn() {
        guard task == nil, let authorization else { return }
        guard authorization.expiresAt > Date() else {
            showError(GitHubError.expiredAuthorization.localizedDescription)
            return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(authorization.userCode, forType: .string) else {
            showError("The sign-in code couldn’t be copied. Retry to request a new code.")
            return
        }
        guard openBrowser(authorization.verificationURL) else {
            showError("GitHub couldn’t open in your browser. Check your default browser, then retry.")
            return
        }
        setLoading("Code copied. Waiting for you to authorize McDiff on GitHub…")
        task = Task { [weak self, client] in
            do {
                let user = try await client.completeSignIn(authorization)
                try Task.checkCancellation()
                guard let self else { return }
                self.task = nil
                self.authorization = nil
                self.completed = true
                self.close()
                self.onSignedIn(user)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showError(error.localizedDescription)
            }
        }
    }

    private func setLoading(_ message: String) {
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
        continueButton.isEnabled = false
        retryButton.isHidden = true
    }

    private func showError(_ message: String) {
        task = nil
        authorization = nil
        spinner.stopAnimation(nil)
        status.stringValue = message
        status.textColor = .systemRed
        continueButton.isEnabled = false
        retryButton.isHidden = false
        Style.animateStateChange(window?.contentView)
    }

    private func stop() {
        task?.cancel()
        task = nil
        authorization = nil
        spinner.stopAnimation(nil)
    }

    @objc private func cancelSignIn() { close() }

    override func close() {
        stop()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
        if !completed {
            completed = true
            onCancelled()
        }
    }

    func windowWillClose(_ notification: Notification) { stop() }
}
