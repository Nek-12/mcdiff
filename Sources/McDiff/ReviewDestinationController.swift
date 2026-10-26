import AppKit
import McDiffCore

enum ReviewIntent: Equatable, Sendable {
    case local(ComparisonRequest)
    case pullRequest(GitHubPR)
}

struct PreparedReview: Sendable {
    let snapshot: ReviewSnapshot
    let progress: ReviewProgress
    let presentations: [String: [PresentedRow]]
    let markdown: [String: MarkdownFileContent]

    static func load(_ request: ComparisonRequest, store: ReviewStore) async throws -> PreparedReview {
        try await Task.detached(priority: .userInitiated) {
            let git = GitRepository(path: request.repository)
            let snapshot = try git.load(request)
            let progress = try store.loadProgress(identity: snapshot.identity)
            let presentations = Dictionary(uniqueKeysWithValues: snapshot.files.map {
                ($0.path, DiffPresentation.rows(for: $0))
            })
            var markdown: [String: MarkdownFileContent] = [:]
            for file in snapshot.files where RenderedMarkdown.accepts(file.path) && !file.isBinary {
                do {
                    markdown[file.path] = try MarkdownFileContent(
                        old: git.content(snapshot: snapshot, file: file, side: .old),
                        new: git.content(snapshot: snapshot, file: file, side: .new))
                } catch {
                    markdown[file.path] = MarkdownFileContent(old: nil, new: nil, error: error.localizedDescription)
                }
            }
            return PreparedReview(snapshot: snapshot, progress: progress, presentations: presentations, markdown: markdown)
        }.value
    }
}

/// The destination owns work and feedback; navigation supplies only an intent.
@MainActor
final class ReviewDestinationController: NSViewController {
    enum Phase: Equatable {
        case inactive, waiting, loading, ready, failed
    }
    private(set) var intent: ReviewIntent?
    private(set) var phase: Phase = .inactive
    var onStateChange: (() -> Void)?
    var onHome: (() -> Void)?
    private let titleLabel = Style.label("Opening review…", size: 20, weight: .semibold)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var retry = Style.button("Retry", target: self, action: #selector(retryAction))
    private lazy var home = Style.button("Home", icon: .home, target: self, action: #selector(homeAction))
    private var recovery: (() -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    override func loadView() {
        view = NSView()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0
        let content = Style.stack([titleLabel, spinner, message, Style.stack([retry, home])],
                                  orientation: .vertical, spacing: 16)
        content.alignment = .centerX
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    func enter(_ intent: ReviewIntent) {
        cancel()
        self.intent = intent
        render(.waiting, title: "Opening review…", message: "Preparing comparison…")
    }

    func wait(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        invalidateWork()
        recovery = action
        render(.waiting, title: "Opening review…", message: text, actionTitle: actionTitle)
    }

    func fail(_ text: String, actionTitle: String, action: @escaping () -> Void) {
        invalidateWork()
        recovery = action
        render(.failed, title: "Could not open review", message: text, actionTitle: actionTitle)
    }

    func load(store: ReviewStore, github: GitHubClient, checkout: String? = nil,
              accept: @escaping (PreparedReview) throws -> Void,
              failureAction: ((Error) -> (String, () -> Void))? = nil) {
        guard let intent else { preconditionFailure("Enter the review destination before loading it.") }
        let message: String
        switch intent {
        case .local: message = "Reading Git changes…"
        case .pullRequest: message = ""
        }
        performLoad(message: message, operation: {
            let request: ComparisonRequest
            switch intent {
            case .local(let local): request = local
            case .pullRequest(let pr):
                guard let checkout else { throw GitError("Choose an existing local checkout for \(pr.repositoryKey).") }
                let revisions = try await github.revisions(for: pr)
                try Task.checkCancellation()
                request = try await Task.detached(priority: .userInitiated) {
                    try pr.resolve(localRepository: checkout, revisions: revisions)
                }.value
                try Task.checkCancellation()
            }
            return try await PreparedReview.load(request, store: store)
        }, accept: accept, recover: { [weak self] in
            self?.load(store: store, github: github, checkout: checkout, accept: accept, failureAction: failureAction)
        }, failureAction: failureAction)
    }

    func performLoad(message: String, operation: @escaping () async throws -> PreparedReview,
              accept: @escaping (PreparedReview) throws -> Void,
              recover: @escaping () -> Void, failureAction: ((Error) -> (String, () -> Void))? = nil) {
        invalidateWork()
        let token = generation
        render(.loading, title: "Loading review…", message: message)
        task = Task { [weak self] in
            do {
                let review = try await operation()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                try accept(review)
                guard self.generation == token else { return }
                self.task = nil
                self.renderReady(isEmpty: review.snapshot.files.isEmpty)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.task = nil
                let action = failureAction?(error) ?? ("Retry", recover)
                self.recovery = action.1
                self.render(.failed, title: "Could not open review", message: error.localizedDescription,
                            actionTitle: action.0)
            }
        }
    }

    func resume(isEmpty: Bool) {
        invalidateWork()
        renderReady(isEmpty: isEmpty)
    }

    func cancel() {
        invalidateWork()
        intent = nil
        recovery = nil
        render(.inactive, title: "", message: "")
    }

    private func invalidateWork() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func renderReady(isEmpty: Bool) {
        recovery = nil
        render(.ready, title: isEmpty ? "No changes in this comparison." : "",
               message: isEmpty ? "This comparison has no changed files to review." : "")
    }

    private func render(_ phase: Phase, title: String, message: String, actionTitle: String? = nil) {
        _ = view
        Style.animateStateChange(view.superview)
        self.phase = phase
        titleLabel.stringValue = title
        self.message.stringValue = message
        self.message.toolTip = message
        self.message.isHidden = message.isEmpty
        retry.isHidden = actionTitle == nil
        retry.title = actionTitle ?? "Retry"
        retry.toolTip = retry.title
        if phase == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        onStateChange?()
    }

    @objc private func retryAction() { recovery?() }
    @objc private func homeAction() { onHome?() }
}
