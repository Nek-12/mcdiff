import AppKit
import McDiffCore

@MainActor
final class PRHomeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias Loader = PRInbox.Loader
    let searchItem = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("pr-home-search"))
    var onOpenPR: ((String) -> Void)?
    var onResume: (() -> Void)?
    var onAuthenticationRequired: (() -> Void)?
    var resumeTitle: String? { didSet { updateResume() } }
    private var unavailableMessage: String?
    let inbox: PRInbox
    var isLoading: Bool { inbox.isLoading }

    func setUnavailable(_ message: String?, clearResults: Bool = false) {
        unavailableMessage = message
        if clearResults || message != nil { inbox.clear() }
        _ = view
        reloadResults()
    }

    private let openBrowser: (URL) -> Bool
    let table: NSTableView = PRHomeTable()
    let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSStackView()
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let resumeButton = NSButton(title: "", target: nil, action: nil)
    private var browserError: String?
    private var leadingConstraint: NSLayoutConstraint?

    init(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, loader: @escaping Loader) {
        inbox = PRInbox(loader: loader)
        self.openBrowser = openBrowser
        super.init(nibName: nil, bundle: nil)
        inbox.onChange = { [weak self] in self?.reloadResults() }
        inbox.onAuthenticationRequired = { [weak self] in self?.onAuthenticationRequired?() }
        searchItem.searchField.placeholderString = "Search my pull requests"
        searchItem.searchField.delegate = self
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.toolTip = "Search your open pull requests on GitHub. GitHub returns up to 1,000 results per search."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        view = NSView()
        configure(retryButton, action: #selector(retry), tooltip: "Retry loading pull requests")
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
        feedback.spacing = 12
        feedback.setContentHuggingPriority(.required, for: .vertical)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = NSScroller.preferredScrollerStyle
        scroll.autohidesScrollers = true
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
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let content = NSStackView(views: [scroll, feedback, resumeButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let leading = content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        for child in [feedback, scroll] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        updateResume()
        render()
    }

    @objc func refresh() {
        guard unavailableMessage == nil else { return }
        _ = view
        browserError = nil
        inbox.refresh()
    }
    @objc func retry() { inbox.retry() }

    func controlTextDidChange(_ obj: Notification) {
        guard unavailableMessage == nil else { return }
        browserError = nil
        scroll.contentView.scroll(to: .zero)
        inbox.search(searchItem.searchField.stringValue)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let close = view.window?.standardWindowButton(.closeButton) {
            let left = view.convert(close.bounds, from: close).minX - 2
            if leadingConstraint?.constant != left { leadingConstraint?.constant = left }
        }
        viewportChanged()
    }

    @objc private func viewportChanged() {
        guard unavailableMessage == nil, inbox.count > 0 else { return }
        let visible = table.rows(in: scroll.contentView.bounds)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        inbox.show(visible.location..<NSMaxRange(visible))
    }

    private func reloadResults() {
        guard isViewLoaded else { return }
        if table.numberOfRows != inbox.count { table.reloadData() }
        else {
            let visible = table.rows(in: scroll.contentView.bounds)
            if visible.location != NSNotFound, visible.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                 columnIndexes: IndexSet(integer: 0))
            }
        }
        render()
        viewportChanged()
    }

    private func render() {
        if isLoading {
            spinner.startAnimation(nil)
            status.stringValue = inbox.count == 0 ? "Loading pull requests…" : ""
        } else {
            spinner.stopAnimation(nil)
            if let unavailableMessage { status.stringValue = unavailableMessage }
            else if let error = browserError ?? inbox.error { status.stringValue = error }
            else if inbox.count == 0 { status.stringValue = "No matching open pull requests." }
            else {
                status.stringValue = ""
            }
        }
        retryButton.isHidden = inbox.error == nil
        feedback.isHidden = status.stringValue.isEmpty && !isLoading
        retryButton.isEnabled = !isLoading
    }

    private func configure(_ button: NSButton, action: Selector, tooltip: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .glass
        button.toolTip = tooltip
    }

    private func updateResume() {
        resumeButton.title = resumeTitle.map { "Resume \($0)" } ?? ""
        resumeButton.isHidden = resumeTitle == nil
    }

    private var selectedPR: PRSummary? {
        inbox.item(at: table.selectedRow)
    }

    @objc func openSelected() { if let selectedPR { onOpenPR?(selectedPR.pr.url) } }
    @objc private func openClicked() {
        guard let summary = inbox.item(at: table.clickedRow) else { return }
        onOpenPR?(summary.pr.url)
    }
    private func openOnGitHub(_ pr: GitHubPR) {
        guard let url = URL(string: pr.url) else { return }
        if !openBrowser(url) {
            browserError = "Couldn’t open GitHub. Check your default browser and try the link again."
            render()
        }
    }
    @objc private func resume() { onResume?() }

    func numberOfRows(in tableView: NSTableView) -> Int { inbox.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PRSummaryRow()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("pr-summary")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PRSummaryCell) ?? PRSummaryCell()
        cell.identifier = identifier
        let summary = inbox.item(at: row)
        cell.show(summary)
        cell.onOpenGitHub = summary.map { summary in { [weak self] in self?.openOnGitHub(summary.pr) } }
        return cell
    }
}

private final class PRSummaryRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
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
        link.bezelStyle = .glass
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
    func show(_ summary: PRSummary?) {
        link.isEnabled = summary != nil
        guard let summary else {
            title.stringValue = "Loading…"
            metadata.stringValue = ""
            toolTip = nil
            return
        }
        title.stringValue = summary.title
        let age = RelativeDateTimeFormatter().localizedString(for: summary.createdAt, relativeTo: Date())
        metadata.stringValue = "\(summary.pr.repositoryKey) #\(summary.pr.number) · Created \(age)\(summary.isDraft ? " · Draft" : "")"
        toolTip = "\(summary.title)\n\(metadata.stringValue)"
    }
}
