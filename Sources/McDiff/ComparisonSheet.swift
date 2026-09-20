import AppKit
import McDiffCore

final class ComparisonSheet: NSWindowController {
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
    private var onOpen: (String?, ComparisonRequest?) -> Void
    private var branchTask: Task<Void, Never>?
    private var openButton: NSButton!

    init(recent: ComparisonRequest?, onOpen: @escaping (String?, ComparisonRequest?) -> Void) {
        self.onOpen = onOpen
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
        let close = Style.button("", icon: "x", target: self, action: #selector(cancel))
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
        let browse = Style.button("Choose…", icon: "folder-open", target: self, action: #selector(chooseFolder))
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
        openButton = Style.button("Open review", icon: "git-compare-arrows", target: self, action: #selector(openReview))
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
        if let clipboard = NSPasteboard.general.string(forType: .string), (try? GitHubPR.parse(clipboard.trimmingCharacters(in: .whitespacesAndNewlines))) != nil {
            urlField.stringValue = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            tabs.selectedSegment = 0
        } else if let url = recent?.pullRequestURL { urlField.stringValue = url }
        tabChanged()
        if let recent { loadBranches(path: recent.repository, chooseDefault: false) }
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
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.message = "Select the Git checkout or worktree to review."
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let path = picker.url?.path else { return }
            self?.repositoryField.stringValue = path
            self?.loadBranches(path: path, chooseDefault: true)
        }
    }
    private func loadBranches(path: String, chooseDefault: Bool) {
        branchTask?.cancel()
        descriptionField.stringValue = "Reading local branches…"
        branchTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let git = GitRepository(path: path)
                    return try (git.branches(), git.defaultBase())
                }.value
                guard !Task.isCancelled, let self else { return }
                self.baseField.removeAllItems(); self.baseField.addItems(withObjectValues: result.0)
                let selected = self.targetField.selectedItem?.representedObject as? String
                let customRevision = self.targetField.selectedItem === self.revisionItem
                self.targetField.removeAllItems()
                self.targetField.addItem(withTitle: "Working tree")
                var branches = result.0
                if let selected, !branches.contains(selected) { branches.append(selected) }
                for branch in branches {
                    self.targetField.addItem(withTitle: branch)
                    self.targetField.lastItem?.representedObject = branch
                }
                self.targetField.menu?.addItem(self.revisionItem)
                if !chooseDefault, let selected { self.targetField.selectItem(withTitle: selected) }
                if !chooseDefault, customRevision { self.targetField.select(self.revisionItem) }
                self.targetChanged()
                if chooseDefault { self.baseField.stringValue = result.1 }
                self.descriptionField.stringValue = ""
            } catch {
                guard !Task.isCancelled else { return }
                self?.descriptionField.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func openReview() {
        if tabs.selectedSegment == 0 {
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do { _ = try GitHubPR.parse(url) }
            catch { showError(error.localizedDescription); return }
            dismiss(); onOpen(url, nil)
        } else {
            let path = repositoryField.stringValue
            let base = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = targetField.selectedItem === revisionItem
                ? revisionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : targetField.selectedItem?.representedObject as? String
            guard target != "" else {
                showError("Enter a tag, commit, or ref for the target revision."); return
            }
            guard !path.isEmpty, !base.isEmpty else {
                showError("Choose a repository and enter the revisions to compare."); return
            }
            let request = ComparisonRequest(repository: path, base: base, target: target, mergeBase: mergeBase.state == .on)
            dismiss(); onOpen(nil, request)
        }
    }
    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Cannot open review"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc private func cancel() { dismiss() }
    private func dismiss() {
        branchTask?.cancel()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    }
}
