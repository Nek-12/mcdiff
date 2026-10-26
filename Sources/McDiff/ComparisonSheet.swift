import AppKit
import McDiffCore

final class ComparisonSheet: NSWindowController {
    enum Action {
        case chooseRepository
        case open(ComparisonInput)
        case cancel
    }
    private let tabs = NSSegmentedControl(labels: ["GitHub pull request", "Local comparison"], trackingMode: .selectOne, target: nil, action: nil)
    private let urlField = NSTextField()
    private let repositoryField = NSTextField()
    private let baseField = NSComboBox()
    private let targetField = NSPopUpButton()
    private let revisionField = NSTextField()
    private let revisionItem = NSMenuItem(title: "Revision…", action: nil, keyEquivalent: "")
    private let mergeBase = AnimatedCheckbox(checkboxWithTitle: "Compare from common ancestor (changes since branching)", target: nil, action: nil)
    private let descriptionField = Style.label("", size: 11, color: .secondaryLabelColor)
    private let prContent = NSView()
    private let localContent = NSView()
    private let onAction: (Action) -> Void
    private var openButton: NSButton!

    init(recent: ComparisonRequest?, clipboardURL: String? = nil, onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Open a review"
        let root = NSView()
        window.contentView = root
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .automatic
        tabs.setToolTip("Open a GitHub pull request using an existing checkout", forSegment: 0)
        tabs.setToolTip("Compare local branches, revisions, or working changes", forSegment: 1)
        if #available(macOS 27, *) { tabs.role = .tabs }
        let title = Style.label("Open review", size: 17, weight: .semibold)
        let close = Style.button("", icon: .close, target: self, action: #selector(cancel))
        close.keyEquivalent = "\u{1b}"; close.toolTip = "Close"
        let header = Style.stack([title, Style.spacer(), tabs, close], spacing: 16)
        header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        for content in [prContent, localContent] {
            content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
                content.heightAnchor.constraint(equalToConstant: 116)
            ])
        }
        urlField.placeholderString = "https://github.com/owner/repo/pull/123"
        urlField.font = .systemFont(ofSize: 14)
        let prStack = Style.stack([
            Style.label("Pull request URL", size: 12, weight: .medium), urlField
        ], orientation: .vertical, spacing: 8)
        Style.pin(prStack, in: prContent)
        urlField.widthAnchor.constraint(equalTo: prStack.widthAnchor).isActive = true
        prStack.alignment = .leading
        prStack.distribution = .gravityAreas
        repositoryField.placeholderString = "Choose a local Git checkout…"
        repositoryField.isEditable = false
        repositoryField.lineBreakMode = .byTruncatingMiddle
        let browse = Style.button("Choose…", icon: .folder, target: self, action: #selector(chooseFolder))
        let repoRow = Style.stack([repositoryField, browse])
        let baseLabel = Style.label("Base")
        let targetLabel = Style.label("Target")
        baseField.usesDataSource = false; baseField.completes = true; baseField.stringValue = recent?.base ?? "main"
        baseField.toolTip = "Base branch, tag, or commit"
        targetField.addItem(withTitle: "Working tree")
        if let target = recent?.target { targetField.addItem(withTitle: target); targetField.lastItem?.representedObject = target; targetField.selectItem(at: 1) }
        targetField.menu?.addItem(revisionItem)
        targetField.target = self; targetField.action = #selector(targetChanged)
        revisionField.placeholderString = "Tag, commit, or ref"
        revisionField.toolTip = "Target tag, commit, or Git ref"
        revisionField.isHidden = true
        targetField.toolTip = "Working tree includes every committed, staged, unstaged and non-ignored untracked change."
        let refs = Style.stack([baseLabel, baseField, targetLabel, targetField, revisionField], spacing: 12)
        revisionField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        mergeBase.state = (recent?.mergeBase ?? true) ? .on : .off
        mergeBase.toolTip = "Compare against the common ancestor instead of the base revision itself"
        let localStack = Style.stack([repoRow, refs, mergeBase], orientation: .vertical, spacing: 12)
        Style.pin(localStack, in: localContent)
        repoRow.widthAnchor.constraint(equalTo: localStack.widthAnchor).isActive = true
        refs.widthAnchor.constraint(equalTo: localStack.widthAnchor).isActive = true
        baseField.widthAnchor.constraint(equalTo: targetField.widthAnchor).isActive = true
        localStack.distribution = .gravityAreas
        openButton = Style.button("Open review", icon: .compare, target: self, action: #selector(openReview))
        openButton.keyEquivalent = "\r"
        let actions = Style.stack([descriptionField, Style.spacer(), openButton])
        actions.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(actions)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        if let recent { repositoryField.stringValue = recent.repository; tabs.selectedSegment = recent.pullRequestURL == nil ? 1 : 0 }
        if let clipboardURL {
            urlField.stringValue = clipboardURL
            tabs.selectedSegment = 0
        } else if let url = recent?.pullRequestURL { urlField.stringValue = url }
        tabChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(tabs.selectedSegment == 0 ? urlField : baseField)
    }
    @objc private func tabChanged() {
        prContent.isHidden = tabs.selectedSegment != 0
        localContent.isHidden = tabs.selectedSegment != 1
        Style.animateStateChange(tabs.selectedSegment == 0 ? prContent : localContent)
    }
    @objc private func targetChanged() {
        revisionField.isHidden = targetField.selectedItem !== revisionItem
        if !revisionField.isHidden { window?.makeFirstResponder(revisionField) }
    }
    @objc private func chooseFolder() {
        onAction(.chooseRepository)
    }
    func setRepository(path: String) {
        repositoryField.stringValue = path
    }
    func setBranches(_ result: ComparisonBranches, chooseDefault: Bool) {
        let base = baseField.stringValue
        baseField.removeAllItems()
        baseField.addItems(withObjectValues: result.branches)
        baseField.stringValue = chooseDefault ? result.defaultBase : base
        let selected = targetField.selectedItem?.representedObject as? String
        let customRevision = targetField.selectedItem === revisionItem
        targetField.removeAllItems()
        targetField.addItem(withTitle: "Working tree")
        var branches = result.branches
        if !chooseDefault, let selected, !branches.contains(selected) { branches.append(selected) }
        for branch in branches {
            targetField.addItem(withTitle: branch)
            targetField.lastItem?.representedObject = branch
        }
        targetField.menu?.addItem(revisionItem)
        if !chooseDefault, let selected { targetField.selectItem(withTitle: selected) }
        if !chooseDefault, customRevision { targetField.select(revisionItem) }
        targetChanged()
        showStatus("")
    }
    func showStatus(_ message: String, failed: Bool = false) {
        descriptionField.stringValue = message
        descriptionField.textColor = failed ? .systemRed : .secondaryLabelColor
        descriptionField.toolTip = message
    }
    @objc private func openReview() {
        if tabs.selectedSegment == 0 {
            onAction(.open(.pullRequest(urlField.stringValue)))
        } else {
            let path = repositoryField.stringValue
            let base = baseField.stringValue
            let target = targetField.selectedItem === revisionItem
                ? revisionField.stringValue
                : targetField.selectedItem?.representedObject as? String
            onAction(.open(.local(repository: path, base: base, target: target, mergeBase: mergeBase.state == .on)))
        }
    }
    @objc private func cancel() { onAction(.cancel) }
    func dismiss() {
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    }
}
