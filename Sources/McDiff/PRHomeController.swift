import AppKit
import McDiffCore

@MainActor
final class PRHomeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias Loader = @Sendable (String, Int) async throws -> PRPage
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
            loaded = nil
            requested = Request(query: searchQuery, page: 1)
        }
        _ = view
        reloadResults()
    }

    private struct Request: Equatable {
        let query: String
        let page: Int
        var description: String { query.isEmpty ? "page \(page)" : "page \(page) for “\(query)”" }
    }
    private struct Loaded {
        let request: Request
        let page: PRPage
    }
    private var requested = Request(query: "", page: 1)
    private var loaded: Loaded?
    var results: [PRSummary] {
        guard !isLoading || loaded?.request == requested else { return [] }
        return loaded?.page.items ?? []
    }
    private(set) var isLoading = false
    private var loadError: String?
    private let loader: Loader
    private let openBrowser: (URL) -> Bool
    private var loadTask: Task<Void, Never>?
    let table: NSTableView = PRHomeTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSStackView()
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")
    private let resumeButton = NSButton(title: "", target: nil, action: nil)

    init(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, loader: @escaping Loader) {
        self.loader = loader
        self.openBrowser = openBrowser
        super.init(nibName: nil, bundle: nil)
        searchItem.searchField.placeholderString = "Search my pull requests"
        searchItem.searchField.delegate = self
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.toolTip = "Search your open pull requests on GitHub. GitHub returns up to 1,000 results per search."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        configure(retryButton, action: #selector(retry), tooltip: "Retry loading pull requests")
        configure(previousButton, action: #selector(previousPage), tooltip: "Load the previous page")
        configure(nextButton, action: #selector(nextPage), tooltip: "Load the next page")
        pageLabel.font = .systemFont(ofSize: 12)
        pageLabel.textColor = .secondaryLabelColor
        configure(resumeButton, action: #selector(resume), tooltip: "Return to the current review")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.isSelectable = true
        status.maximumNumberOfLines = 0

        for child in [spinner, status, retryButton] { feedback.addArrangedSubview(child) }
        feedback.alignment = .top
        let footer = NSStackView(views: [resumeButton, NSView(), previousButton, pageLabel, nextButton])
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
        table.action = #selector(openClicked)
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
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        for child in [feedback, scroll, footer] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        updateResume()
        render()
    }

    @objc func refresh() { startLoading(requested) }
    @objc func retry() { startLoading(requested) }
    @objc func previousPage() {
        guard canNavigate, requested.page > 1 else { return }
        startLoading(Request(query: requested.query, page: requested.page - 1))
    }
    @objc func nextPage() {
        guard canNavigate, loaded?.page.hasNext == true else { return }
        startLoading(Request(query: requested.query, page: requested.page + 1))
    }

    private var canNavigate: Bool {
        !isLoading && unavailableMessage == nil && loaded?.request == requested
    }
    private var searchQuery: String {
        searchItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startLoading(_ request: Request, debounce: Bool = false) {
        guard !isLoading || requested != request else { return }
        loadTask?.cancel()
        let selectedURL = selectedPR?.pr.url
        requested = request
        guard unavailableMessage == nil else { return }
        _ = view
        isLoading = true
        loadError = nil
        reloadResults(preserving: selectedURL)
        loadTask = Task { [weak self, loader] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                let page = try await loader(request.query, request.page)
                try Task.checkCancellation()
                guard let self else { return }
                self.loaded = Loaded(request: request, page: page)
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if case GitHubError.unauthenticated = error, let onAuthenticationRequired = self.onAuthenticationRequired {
                    self.isLoading = false
                    self.loadTask = nil
                    onAuthenticationRequired()
                    return
                }
                self.loadError = "Couldn’t load \(request.description). Retry the request.\n\(error.localizedDescription)"
            }
            guard let self else { return }
            self.isLoading = false
            self.loadTask = nil
            self.reloadResults(preserving: selectedURL)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard searchQuery != requested.query else { return }
        startLoading(Request(query: searchQuery, page: 1), debounce: true)
    }

    private func reloadResults(preserving selectedURL: String? = nil) {
        table.reloadData()
        if let row = results.firstIndex(where: { $0.pr.url == selectedURL }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        render()
    }

    private func render() {
        if isLoading {
            spinner.startAnimation(nil)
            status.stringValue = "Loading \(requested.description)…"
        } else {
            spinner.stopAnimation(nil)
            if let unavailableMessage { status.stringValue = unavailableMessage }
            else if let loadError {
                let previous = loaded.map { "\nShowing previously loaded \($0.request.description)." } ?? ""
                status.stringValue = loadError + previous
            }
            else if loaded == nil { status.stringValue = "Refresh to load your open pull requests." }
            else if results.isEmpty {
                status.stringValue = requested.query.isEmpty ? "No open pull requests on this page." : "No matching pull requests on this page."
            }
            else {
                status.stringValue = ""
            }
        }
        retryButton.isHidden = loadError == nil
        feedback.isHidden = status.stringValue.isEmpty && !isLoading && loadError == nil
        retryButton.isEnabled = !isLoading
        previousButton.isEnabled = canNavigate && requested.page > 1
        nextButton.isEnabled = canNavigate && loaded?.page.hasNext == true
        pageLabel.stringValue = "Page \(isLoading ? requested.page : loaded?.request.page ?? requested.page)"
        for control in [previousButton, pageLabel, nextButton] {
            control.isHidden = unavailableMessage != nil || (!isLoading && loaded == nil)
        }
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
        results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
    }

    @objc func openSelected() { if let selectedPR { onOpenPR?(selectedPR.pr.url) } }
    @objc private func openClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        onOpenPR?(results[table.clickedRow].pr.url)
    }
    private func openOnGitHub(_ pr: GitHubPR) {
        guard let url = URL(string: pr.url) else { return }
        if !openBrowser(url) {
            status.stringValue = "Couldn’t open GitHub. Check your default browser and try the link again."
        }
    }
    @objc private func resume() { onResume?() }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PRSummaryRow()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("pr-summary")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PRSummaryCell) ?? PRSummaryCell()
        cell.identifier = identifier
        let summary = results[row]
        cell.show(summary)
        cell.onOpenGitHub = { [weak self] in self?.openOnGitHub(summary.pr) }
        return cell
    }
}

private final class PRSummaryRow: NSTableRowView {
    private var isMouseInside = false {
        didSet {
            needsDisplay = true
            for cell in subviews.compactMap({ $0 as? PRSummaryCell }) { cell.setHovered(isMouseInside) }
        }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? PRSummaryCell)?.setHovered(isMouseInside)
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
    private let link = NSButton()
    var onOpenGitHub: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: Icons.image("git-pull-request") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        link.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        link.title = ""
        link.isBordered = false
        link.toolTip = "Open on GitHub"
        link.target = self
        link.action = #selector(openGitHub)
        link.translatesAutoresizingMaskIntoConstraints = false
        link.isHidden = true
        addSubview(link)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            link.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            link.centerYAnchor.constraint(equalTo: centerYAnchor),
            link.widthAnchor.constraint(equalToConstant: 24),
            link.heightAnchor.constraint(equalToConstant: 24)
        ])
        title.font = .systemFont(ofSize: 13, weight: .medium)
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        for field in [title, metadata] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12).isActive = true
            field.trailingAnchor.constraint(equalTo: link.leadingAnchor, constant: -8).isActive = true
        }
        title.topAnchor.constraint(equalTo: topAnchor, constant: 7).isActive = true
        metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setHovered(_ hovered: Bool) { link.isHidden = !hovered }
    @objc private func openGitHub() { onOpenGitHub?() }
    func show(_ summary: PRSummary) {
        title.stringValue = summary.title
        let age = RelativeDateTimeFormatter().localizedString(for: summary.createdAt, relativeTo: Date())
        metadata.stringValue = "\(summary.pr.repositoryKey) #\(summary.pr.number) · Created \(age)\(summary.isDraft ? " · Draft" : "")"
        toolTip = "\(summary.title)\n\(metadata.stringValue)"
    }
}
