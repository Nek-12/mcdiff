import AppKit
import McDiffCore

@MainActor
final class PRHomeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias Loader = @Sendable (Int) async throws -> [PRSummary]
    let searchItem = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("pr-home-search"))
    var onOpenPR: ((String) -> Void)?
    var onResume: (() -> Void)?
    var onAuthenticationRequired: (() -> Void)?
    var resumeTitle: String? { didSet { updateResume() } }
    private var unavailableMessage: String?

    func setUnavailable(_ message: String?, clearResults: Bool = false) {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        unavailableMessage = message
        loadError = nil
        if clearResults {
            results = []
            hasLoaded = false
            loadedLimit = 100
        }
        _ = view
        filterResults()
    }

    private(set) var results: [PRSummary] = []
    private(set) var filteredResults: [PRSummary] = []
    private(set) var isLoading = false
    private(set) var loadedLimit = 100
    private var requestedLimit = 100
    private var hasLoaded = false
    private var loadError: String?
    private static let maximumLimit = 1_000
    private let loader: Loader
    private var loadTask: Task<Void, Never>?
    let table: NSTableView = PRHomeTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let moreButton = NSButton(title: "Load more", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    private let githubButton = NSButton(title: "Open on GitHub", target: nil, action: nil)
    private let resumeButton = NSButton(title: "", target: nil, action: nil)

    init(loader: @escaping Loader) {
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        searchItem.searchField.placeholderString = "Search my pull requests"
        searchItem.searchField.delegate = self
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.toolTip = "Search pull request titles, repositories, and numbers"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        configure(retryButton, action: #selector(retry), tooltip: "Retry loading pull requests")
        configure(moreButton, action: #selector(loadMore), tooltip: "Load the next 100 pull requests")
        configure(reviewButton, action: #selector(openSelected), tooltip: "Review the selected pull request")
        configure(githubButton, action: #selector(openOnGitHub), tooltip: "Open the selected pull request in your browser")
        configure(resumeButton, action: #selector(resume), tooltip: "Return to the current review")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.isSelectable = true
        status.maximumNumberOfLines = 0

        let feedback = NSStackView(views: [spinner, status, retryButton])
        feedback.alignment = .top
        let footer = NSStackView(views: [moreButton, resumeButton, NSView(), githubButton, reviewButton])
        for stack in [feedback, footer] { stack.spacing = 12 }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pull-request"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        (table as? PRHomeTable)?.onReturn = { [weak self] in self?.openSelected() }
        scroll.documentView = table
        let content = NSStackView(views: [feedback, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        for child in [feedback, scroll, footer] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        updateResume()
        render()
    }

    @objc func refresh() { startLoading(limit: loadedLimit) }
    @objc func retry() { startLoading(limit: requestedLimit) }
    @objc func loadMore() {
        guard hasLoaded, results.count == loadedLimit, loadedLimit < Self.maximumLimit else { return }
        startLoading(limit: min(loadedLimit + 100, Self.maximumLimit))
    }

    private func startLoading(limit: Int) {
        guard !isLoading, unavailableMessage == nil else { return }
        _ = view
        isLoading = true
        requestedLimit = limit
        loadError = nil
        render()
        loadTask = Task { [weak self, loader] in
            do {
                let result = try await loader(limit)
                try Task.checkCancellation()
                guard result.count <= limit else {
                    throw GitError("GitHub returned more pull requests than requested. Retry the request.")
                }
                guard let self else { return }
                self.results = result
                self.loadedLimit = limit
                self.hasLoaded = true
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if case GitHubError.unauthenticated = error {
                    self.isLoading = false
                    self.loadTask = nil
                    self.onAuthenticationRequired?()
                    return
                }
                self.loadError = "Couldn’t load your pull requests. Check your connection and GitHub sign-in, then retry.\n\(error.localizedDescription)"
            }
            guard let self else { return }
            self.isLoading = false
            self.loadTask = nil
            self.filterResults()
        }
    }

    func controlTextDidChange(_ obj: Notification) { filterResults() }

    private func filterResults() {
        let selectedURL = selectedPR?.pr.url
        let query = searchItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredResults = results.filter {
            query.isEmpty || "\($0.title) \($0.pr.repositoryKey) #\($0.pr.number)".localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        if let row = filteredResults.firstIndex(where: { $0.pr.url == selectedURL }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        render()
    }

    private func render() {
        if isLoading {
            spinner.startAnimation(nil)
            status.stringValue = results.isEmpty ? "Loading your open pull requests…" : "Loading… Showing \(results.count) previously loaded pull requests."
        } else {
            spinner.stopAnimation(nil)
            if let unavailableMessage { status.stringValue = unavailableMessage }
            else if let loadError { status.stringValue = loadError }
            else if !hasLoaded { status.stringValue = "Refresh to load your open pull requests." }
            else if results.isEmpty { status.stringValue = "No open pull requests for your current GitHub account." }
            else {
                let prefix = filteredResults.isEmpty ? "No matching pull requests." : "\(filteredResults.count) of \(results.count) loaded pull requests."
                let limit = results.count < loadedLimit ? "" : loadedLimit == Self.maximumLimit
                    ? " Showing the newest 1,000; GitHub search is limited to 1,000 results."
                    : " Showing the newest \(loadedLimit). Load more to search older pull requests."
                status.stringValue = prefix + limit
            }
        }
        retryButton.isHidden = loadError == nil
        retryButton.isEnabled = !isLoading
        moreButton.isHidden = !hasLoaded || results.count < loadedLimit || loadedLimit == Self.maximumLimit
        moreButton.isEnabled = !isLoading
        reviewButton.isEnabled = selectedPR != nil
        githubButton.isEnabled = selectedPR != nil
    }

    private func configure(_ button: NSButton, action: Selector, tooltip: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.toolTip = tooltip
    }

    private func updateResume() {
        resumeButton.title = resumeTitle.map { "Resume \($0)" } ?? ""
        resumeButton.isHidden = resumeTitle == nil
    }

    private var selectedPR: PRSummary? {
        filteredResults.indices.contains(table.selectedRow) ? filteredResults[table.selectedRow] : nil
    }

    @objc func openSelected() { if let selectedPR { onOpenPR?(selectedPR.pr.url) } }
    @objc private func openOnGitHub() {
        if let selectedPR, let url = URL(string: selectedPR.pr.url) { NSWorkspace.shared.open(url) }
    }
    @objc private func resume() { onResume?() }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredResults.count }
    func tableViewSelectionDidChange(_ notification: Notification) { render() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PRSummaryRow()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("pr-summary")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PRSummaryCell) ?? PRSummaryCell()
        cell.identifier = identifier
        cell.show(filteredResults[row])
        return cell
    }
}

private final class PRSummaryRow: NSTableRowView {
    private var isMouseInside = false {
        didSet { needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isMouseInside = true }
    override func mouseExited(with event: NSEvent) { isMouseInside = false }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMouseInside && !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }
}

private final class PRHomeTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

private final class PRSummaryCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: Icons.image("git-pull-request") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])
        title.font = .systemFont(ofSize: 13, weight: .medium)
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        for field in [title, metadata] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12).isActive = true
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        }
        title.topAnchor.constraint(equalTo: topAnchor, constant: 7).isActive = true
        metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ summary: PRSummary) {
        title.stringValue = summary.title
        let age = RelativeDateTimeFormatter().localizedString(for: summary.createdAt, relativeTo: Date())
        metadata.stringValue = "\(summary.pr.repositoryKey) #\(summary.pr.number) · Created \(age)\(summary.isDraft ? " · Draft" : "")"
        toolTip = "\(summary.title)\n\(metadata.stringValue)"
    }
}
