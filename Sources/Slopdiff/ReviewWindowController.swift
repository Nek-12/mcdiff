import AppKit
import SlopdiffCore
import UniformTypeIdentifiers

final class ReviewWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSWindowDelegate {
    private var store: ReviewStore?
    private var preferences = ReviewPreferences()
    private var snapshot: ReviewSnapshot?
    private var progress = ReviewProgress()
    private var files: [FileDiff] = []
    private var presentations: [String: [PresentedRow]] = [:]
    private var sidebarIndices: [Int] = []
    private var focused = 0
    private var loadTask: Task<Void, Never>?
    private var comparisonSheet: ComparisonSheet?
    private var commentEditor: CommentEditorController?
    private var preview: MarkdownPreviewController?
    private let diff = DiffViewport()
    private let sidebar = NSTableView()
    private let search = NSSearchField()
    private let status = Style.label("", size: 11, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private var reviewNext: NSToolbarItem!
    private var reviewedCheck: NSToolbarItemGroup!
    private var previewButton: NSToolbarItem!
    private var finishButton: NSToolbarItem!
    private var refreshButton: NSToolbarItem!
    private var commentsButton: NSToolbarItem!
    private var wrapButton: NSToolbarItemGroup!
    private let splitController = NSSplitViewController()
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let toolbarOrder: [NSToolbarItem.Identifier] = [
        .init("open"), .init("recent"), .init("refresh"), .space, .init("navigation"),
        .init("status"), .flexibleSpace, .init("reviewed"), .space, .init("wrap"), .init("preview"),
        .init("comments"), .space, .init("reviewNext"), .space, .init("copy"), .init("export")
    ]
    private let testsFilter = NSButton(checkboxWithTitle: "Tests", target: nil, action: nil)
    private let docsFilter = NSButton(checkboxWithTitle: "Documentation / non-code", target: nil, action: nil)
    private let noiseFilter = NSButton(checkboxWithTitle: "Generated / noise", target: nil, action: nil)
    private let empty = NSView()
    private var busy = false
    private var statusDismissal: DispatchWorkItem?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Slopdiff"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 1080, height: 680)
        window.center()
        window.setFrameAutosaveName("Slopdiff.review")
        super.init(window: window)
        window.delegate = self
        buildUI()
        configureCallbacks()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func start() {
        do {
            let args = ProcessInfo.processInfo.arguments
            let state: URL?
            if let i = args.firstIndex(of: "--state-directory"), args.indices.contains(i + 1) { state = URL(fileURLWithPath: args[i + 1]) }
            else { state = nil }
            store = try ReviewStore(directory: state)
            preferences = try store!.loadPreferences()
            updateFilters()
            diff.softWrap = preferences.softWrap
            wrapButton.setSelected(preferences.softWrap, at: 0)
            if let i = args.firstIndex(of: "--repo"), args.indices.contains(i + 1) {
                let base = args.firstIndex(of: "--base").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "main"
                let target = args.firstIndex(of: "--target").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                load(ComparisonRequest(repository: args[i + 1], base: base, target: target))
            } else if let i = args.firstIndex(of: "--pr"), args.indices.contains(i + 1) {
                openPR(args[i + 1])
            } else if let recent = preferences.recentComparisons.first {
                if let url = recent.pullRequestURL { openPR(url) } else { load(recent) }
            }
        } catch { showError(error, title: "Could not load saved reviews") }
    }
    private func buildUI() {
        guard let window else { return }
        let sideController = NSViewController()
        sideController.view = buildSidebar()
        // A separate sidebar material creates a seam through the shared window glass.
        // Keep native source-list controls in a regular split pane instead.
        let side = NSSplitViewItem(viewController: sideController)
        side.minimumThickness = 210; side.maximumThickness = 400
        side.preferredThicknessFraction = 0.19
        side.canCollapseFromWindowResize = false
        let mainController = NSViewController()
        mainController.view = buildMain()
        let main = NSSplitViewItem(viewController: mainController)
        main.minimumThickness = 640
        splitController.addSplitViewItem(side)
        splitController.addSplitViewItem(main)
        let backdrop = NSViewController()
        backdrop.addChild(splitController)
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.tintColor = NSColor(name: "Slopdiff shared contrast") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedWhite: dark ? 0.12 : 0.95, alpha: 0.20)
        }
        glass.cornerRadius = 0
        glass.contentView = splitController.view
        backdrop.view = glass
        window.contentViewController = backdrop
        splitController.splitView.setPosition(250, ofDividerAt: 0)

        func item(_ id: String, _ title: String, _ icon: String, _ action: Selector, text: Bool = false) -> NSToolbarItem {
            let identifier = NSToolbarItem.Identifier(id)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title; item.paletteLabel = title; item.toolTip = title
            let button = NSButton(title: text ? title : "", target: self, action: action)
            button.bezelStyle = .glass
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.image = Icons.image(icon)
            button.imagePosition = text ? .imageLeading : .imageOnly
            button.toolTip = title
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(button.intrinsicContentSize.width + 8)).isActive = true
            item.view = button
            item.target = self; item.action = action
            item.autovalidates = false
            toolbarItems[identifier] = item
            return item
        }
        _ = item("open", "Open comparison", "folder-open", #selector(openComparison))
        _ = item("recent", "Recent comparisons", "chevron-down", #selector(showRecent(_:)))
        refreshButton = item("refresh", "Refresh · ⌘R", "rotate-cw", #selector(refresh))
        for id in ["open", "recent", "refresh"] { toolbarItems[.init(id)]?.isNavigational = true }
        let navigation = NSToolbarItemGroup(itemIdentifier: .init("navigation"),
            images: [Icons.image("arrow-up")!, Icons.image("arrow-down")!], selectionMode: .momentary,
            labels: ["Previous file", "Next file"], target: self, action: #selector(navigateToolbar(_:)))
        navigation.isBordered = true
        (navigation.view as? NSSegmentedControl)?.controlSize = .large
        navigation.view?.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolbarItems[navigation.itemIdentifier] = navigation
        reviewedCheck = NSToolbarItemGroup(itemIdentifier: .init("reviewed"), images: [Icons.image("check")!],
            selectionMode: .selectAny, labels: ["Reviewed"], target: self, action: #selector(toggleReviewed))
        reviewedCheck.isBordered = true; reviewedCheck.autovalidates = false; reviewedCheck.toolTip = "Toggle reviewed"
        (reviewedCheck.view as? NSSegmentedControl)?.controlSize = .large
        reviewedCheck.view?.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolbarItems[reviewedCheck.itemIdentifier] = reviewedCheck
        wrapButton = NSToolbarItemGroup(itemIdentifier: .init("wrap"), titles: ["Wrap"],
            selectionMode: .selectAny, labels: ["Soft wrap"], target: self, action: #selector(wrapChanged))
        wrapButton.isBordered = true; wrapButton.toolTip = "Soft wrap · remembered across launches"
        (wrapButton.view as? NSSegmentedControl)?.controlSize = .large
        wrapButton.view?.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolbarItems[wrapButton.itemIdentifier] = wrapButton
        previewButton = item("preview", "Markdown preview", "file-text", #selector(showPreview))
        commentsButton = item("comments", "Comments", "message-square", #selector(showComments(_:)))
        reviewNext = item("reviewNext", "Review & next", "check-check", #selector(markAndNext), text: true)
        reviewNext.visibilityPriority = .high
        finishButton = item("copy", "Copy review", "copy", #selector(finishReview), text: true)
        finishButton.visibilityPriority = .high
        finishButton.style = .prominent
        (finishButton.view as? NSButton)?.contentTintColor = .controlAccentColor
        _ = item("export", "Export Markdown", "download", #selector(exportReview))

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let context = NSToolbarItem(itemIdentifier: .init("status"))
        let contextView = Style.stack([spinner, status], spacing: 8)
        contextView.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        status.isHidden = true
        context.view = contextView; context.label = "Comparison"; context.visibilityPriority = .low
        context.isHidden = true
        toolbarItems[context.itemIdentifier] = context
        let toolbar = NSToolbar(identifier: "Slopdiff.review")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        installReviewMenu()
        updateActions()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarOrder }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarOrder }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { toolbarItems[itemIdentifier] }
    @objc private func navigateToolbar(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { previousFile() } else { nextFile() }
    }
    private func installReviewMenu() {
        let menu = NSMenu(title: "Review")
        let entries: [(String, Selector, String)] = [
            ("Open comparison…", #selector(openComparison), "o"),
            ("Refresh", #selector(refresh), "r"),
            ("Review & next", #selector(markAndNext), "j"),
            ("Comment on selection", #selector(commentOnSelection), "l"),
            ("Copy review", #selector(finishReview), "\r"),
            ("Export Markdown…", #selector(exportReview), "")
        ]
        for (title, action, key) in entries {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        for (title, action, key) in [("Previous file", #selector(previousFile), "\u{f700}"), ("Next file", #selector(nextFile), "\u{f701}")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .option; item.target = self
        }
        let root = NSMenuItem(); root.submenu = menu
        NSApp.mainMenu?.addItem(root)
    }
    private func buildSidebar() -> NSView {
        let content = NSView()
        search.placeholderString = "Filter files…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let header = Style.stack([search], orientation: .vertical, spacing: 0)
        search.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        sidebar.headerView = nil; sidebar.rowHeight = 27; sidebar.intercellSpacing = .zero
        sidebar.style = .sourceList
        sidebar.backgroundColor = .clear
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.addTableColumn(NSTableColumn(identifier: .init("path")))
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.target = self; sidebar.action = #selector(sidebarSelected)
        let scroll = FadingScrollView()
        scroll.documentView = sidebar; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let filterContent = buildFilters()
        filterContent.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(filterContent)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: filterContent.topAnchor),
            filterContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filterContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filterContent.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return content
    }
    private func buildFilters() -> NSView {
        let filters = Style.stack([testsFilter, docsFilter, noiseFilter], orientation: .vertical, spacing: 7)
        for button in [testsFilter, docsFilter, noiseFilter] {
            button.font = .systemFont(ofSize: 12)
            button.target = self; button.action = #selector(filtersChanged)
            button.toolTip = "Automatically collapse and mark reviewed. Remembered globally; files remain expandable."
        }
        let view = NSView()
        Style.pin(filters, in: view, inset: 12)
        return view
    }
    private func buildMain() -> NSView {
        let main = NSView()
        diff.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(diff)
        NSLayoutConstraint.activate([
            diff.leadingAnchor.constraint(equalTo: main.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            diff.trailingAnchor.constraint(equalTo: main.safeAreaLayoutGuide.trailingAnchor),
            diff.topAnchor.constraint(equalTo: main.safeAreaLayoutGuide.topAnchor),
            diff.bottomAnchor.constraint(equalTo: main.bottomAnchor)
        ])
        empty.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: diff.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: diff.trailingAnchor),
            empty.topAnchor.constraint(equalTo: diff.topAnchor),
            empty.bottomAnchor.constraint(equalTo: diff.bottomAnchor)
        ])
        let logo = NSImageView(image: Icons.image("git-compare-arrows") ?? NSImage())
        logo.contentTintColor = .controlAccentColor
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 40).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let start = Style.button("Open a comparison", icon: "folder-open", target: self, action: #selector(openComparison))
        let welcome = Style.stack([
            logo, Style.label("Less noise. More review.", size: 26, weight: .semibold),
            Style.label("A pull request, two branches, or everything your agent just changed.", size: 13, color: .secondaryLabelColor),
            start, Style.label("Local comments. Copy them back to your agent.", size: 11, color: .tertiaryLabelColor)
        ], orientation: .vertical, spacing: 18)
        welcome.alignment = .centerX; welcome.translatesAutoresizingMaskIntoConstraints = false; empty.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: empty.centerYAnchor, constant: -30)
        ])
        return main
    }
    private func configureCallbacks() {
        diff.isReviewed = { [weak self] in self?.isReviewed($0) ?? false }
        diff.commentCount = { [weak self] file in self?.progress.comments.filter { $0.path == file.path }.count ?? 0 }
        diff.onFocus = { [weak self] in self?.focus($0) }
        diff.onComment = { [weak self] in self?.editComment(selection: $0) }
        diff.onHighlightError = { [weak self] error in self?.showStatus(error.localizedDescription); NSLog("%@", error.localizedDescription) }
        diff.onLayoutBusy = { [weak self] busy in
            if busy { self?.showStatus("Laying out wrapped lines…"); self?.spinner.startAnimation(nil) }
            else if self?.busy == false { self?.spinner.stopAnimation(nil) }
        }
    }
    @objc private func openComparison() {
        guard let window, !busy, window.attachedSheet == nil, settleDraft() else { return }
        comparisonSheet = ComparisonSheet(recent: snapshot?.request ?? preferences.recentComparisons.first) { [weak self] url, request in
            if let url { self?.openPR(url) } else if let request { self?.load(request) }
        }
        comparisonSheet?.present(on: window)
    }
    private func openPR(_ url: String) {
        guard settleDraft() else { return }
        do {
            let pr = try GitHubPR.parse(url)
            let key = pr.repositoryKey.lowercased()
            if let local = preferences.repositoryMappings[key], FileManager.default.fileExists(atPath: local) {
                resolvePR(pr, local: local)
            } else { choosePRCheckout(pr) }
        } catch { showError(error, title: "Cannot open pull request") }
    }
    private func choosePRCheckout(_ pr: GitHubPR) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.message = "Where is \(pr.repositoryKey) checked out? Slopdiff will remember this folder."
        picker.prompt = "Use checkout"
        picker.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let path = picker.url?.path { self?.resolvePR(pr, local: path) }
        }
    }
    private func resolvePR(_ pr: GitHubPR, local: String) {
        guard !busy else { return }
        setBusy(true, message: "Fetching PR metadata and missing Git objects…")
        loadTask = Task { [weak self] in
            do {
                let request = try await Task.detached(priority: .userInitiated) { try pr.resolve(localRepository: local) }.value
                guard let self else { return }
                self.preferences.repositoryMappings[pr.repositoryKey.lowercased()] = local
                try self.savePreferences()
                self.setBusy(false)
                self.load(request)
            } catch {
                guard let self else { return }
                self.setBusy(false)
                self.showError(error, title: "Cannot load \(pr.repositoryKey)", recovery: "Choose checkout…") { self.choosePRCheckout(pr) }
            }
        }
    }
    private func load(_ request: ComparisonRequest) {
        guard !busy, let store, settleDraft() else { return }
        setBusy(true, message: "Reading Git changes…")
        let start = ContinuousClock.now
        let previousPath = files.indices.contains(focused) ? files[focused].path : nil
        loadTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let snapshot = try GitRepository(path: request.repository).load(request)
                    let progress = try store.loadProgress(identity: snapshot.identity)
                    let presentation = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, DiffPresentation.rows(for: $0)) })
                    return (snapshot, progress, presentation)
                }.value
                guard let self else { return }
                self.snapshot = result.0; self.progress = result.1; self.presentations = result.2
                self.sortFiles()
                self.diff.expanded = Set(self.files.filter { self.preferences.filters.skipReason(for: $0) == nil && !self.isReviewed($0) }.map(\.path))
                self.diff.filters = self.preferences.filters
                self.diff.setFiles(self.files, presentations: self.presentations)
                self.rebuildSidebar()
                self.empty.isHidden = true
                self.window?.title = "Slopdiff — \(result.0.title)"
                self.preferences.recentComparisons.removeAll { $0 == request || ($0.pullRequestURL != nil && $0.pullRequestURL == request.pullRequestURL) }
                self.preferences.recentComparisons.insert(request, at: 0)
                self.preferences.recentComparisons = Array(self.preferences.recentComparisons.prefix(12))
                try self.savePreferences()
                self.setBusy(false)
                let elapsed = ContinuousClock.now - start
                if self.files.isEmpty { self.showStatus("No changes in this comparison.") }
                NSLog("Slopdiff loaded %d files in %@ ms", self.files.count, Self.milliseconds(elapsed))
                let index = previousPath.flatMap { path in self.files.firstIndex { $0.path == path } } ?? 0
                if !self.files.isEmpty { self.diff.navigate(to: index, expand: false); self.focus(index) }
                self.updateActions()
                self.performVerificationIfRequested()
            } catch {
                guard let self else { return }
                self.setBusy(false)
                self.showError(error, title: "Could not load comparison", recovery: "Retry") { self.load(request) }
            }
        }
    }
    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.0f", Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
    private func sortFiles() {
        files = (snapshot?.files ?? []).sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : a < b
        }
    }
    private func rank(_ file: FileDiff) -> Int {
        if preferences.filters.skipReason(for: file) == nil, file.category == .production { return 0 }
        if file.isBinary || file.isRemovalOnly || file.isFormattingOnly { return 1 }
        switch file.category { case .production: return 0; case .tests: return 2; case .documentation: return 3; case .generated: return 4 }
    }
    private func isReviewed(_ file: FileDiff) -> Bool {
        preferences.filters.skipReason(for: file) != nil || progress.reviewed[file.path] == file.fingerprint
    }
    private func focus(_ index: Int) {
        guard files.indices.contains(index) else { return }
        focused = index
        if let row = sidebarIndices.firstIndex(of: index) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        }
        updateActions()
    }
    private func updateActions() {
        let hasFile = files.indices.contains(focused)
        reviewNext?.isEnabled = hasFile && !busy
        reviewedCheck?.isEnabled = hasFile && !busy && preferences.filters.skipReason(for: files[focused]) == nil
        reviewedCheck?.setSelected(hasFile && isReviewed(files[focused]), at: 0)
        finishButton?.isEnabled = snapshot != nil && !busy
        refreshButton?.isEnabled = snapshot != nil && !busy
        previewButton?.isEnabled = hasFile && ["md", "markdown", "mdown"].contains((files[focused].path as NSString).pathExtension.lowercased()) && !busy
        commentsButton?.toolTip = "\(progress.comments.count) comments"
        commentsButton?.isEnabled = !progress.comments.isEmpty && !busy
    }
    private func setBusy(_ value: Bool, message: String? = nil) {
        busy = value
        statusDismissal?.cancel()
        status.isHidden = !value
        toolbarItems[.init("status")]?.isHidden = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if let message { status.stringValue = message }
        updateActions()
    }
    private func showStatus(_ message: String) {
        statusDismissal?.cancel()
        status.stringValue = message
        status.isHidden = false
        toolbarItems[.init("status")]?.isHidden = false
        let dismissal = DispatchWorkItem { [weak self] in
            if self?.busy == false {
                self?.status.isHidden = true
                self?.toolbarItems[.init("status")]?.isHidden = true
            }
        }
        statusDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }
    private func updateFilters() {
        testsFilter.state = preferences.filters.tests ? .on : .off
        docsFilter.state = preferences.filters.documentation ? .on : .off
        noiseFilter.state = preferences.filters.generated ? .on : .off
    }
    @objc private func filtersChanged() {
        let previous = preferences.filters
        preferences.filters = ReviewFilters(tests: testsFilter.state == .on, documentation: docsFilter.state == .on, generated: noiseFilter.state == .on)
        do { try savePreferences() } catch { preferences.filters = previous; updateFilters(); showError(error, title: "Could not save filters"); return }
        let path = files.indices.contains(focused) ? files[focused].path : nil
        for file in files {
            if preferences.filters.skipReason(for: file) != nil { diff.expanded.remove(file.path) }
            else if previous.skipReason(for: file) != nil { diff.expanded.insert(file.path) }
        }
        sortFiles(); diff.files = files; diff.filters = preferences.filters
        diff.selection = nil
        diff.rebuild()
        rebuildSidebar()
        if let path, let index = files.firstIndex(where: { $0.path == path }) { diff.navigate(to: index, expand: false) }
        updateActions()
    }
    @objc private func wrapChanged() {
        let previous = preferences.softWrap
        preferences.softWrap = wrapButton.isSelected(at: 0)
        do { try savePreferences(); diff.softWrap = preferences.softWrap }
        catch {
            preferences.softWrap = previous
            wrapButton.setSelected(previous, at: 0)
            showError(error, title: "Could not save wrapping preference")
        }
    }
    private func savePreferences() throws { try store?.savePreferences(preferences) }
    private func saveProgress() throws {
        if let snapshot { try store?.saveProgress(progress, identity: snapshot.identity) }
    }
    @objc private func markAndNext() {
        guard files.indices.contains(focused) else { return }
        let file = files[focused], prior = progress
        progress.reviewed[file.path] = file.fingerprint
        do { try saveProgress() } catch { progress = prior; showError(error, title: "Could not save review progress"); return }
        diff.expanded.remove(file.path)
        let next = ((focused + 1)..<files.count).first { !isReviewed(files[$0]) } ?? (0..<focused).first { !isReviewed(files[$0]) }
        diff.rebuild()
        sidebar.reloadData()
        if let next { diff.navigate(to: next); focus(next) }
        else { showStatus("All files reviewed."); diff.navigate(to: focused, expand: false) }
        updateActions()
    }
    @objc private func toggleReviewed() {
        guard files.indices.contains(focused) else { return }
        setReviewed(files[focused], reviewed: reviewedCheck.isSelected(at: 0))
    }
    private func setReviewed(_ file: FileDiff, reviewed: Bool) {
        let prior = progress
        if reviewed { progress.reviewed[file.path] = file.fingerprint }
        else { progress.reviewed.removeValue(forKey: file.path) }
        do { try saveProgress() } catch { progress = prior; showError(error, title: "Could not save review progress") }
        diff.redraw(); sidebar.reloadData(); updateActions()
    }
    @objc private func previousFile() { if focused > 0 { diff.navigate(to: focused - 1) } }
    @objc private func nextFile() { if focused + 1 < files.count { diff.navigate(to: focused + 1) } }
    @objc private func refresh() {
        guard let request = snapshot?.request else { return }
        if let url = request.pullRequestURL { openPR(url) } else { load(request) }
    }
    private func editComment(selection: LineSelection) {
        guard files.indices.contains(selection.file) else { return }
        let file = files[selection.file]
        presentComment(ReviewComment(path: file.path, side: selection.side, startLine: selection.start, endLine: selection.end, text: "", fingerprint: file.fingerprint), isNew: true)
    }
    private func presentComment(_ comment: ReviewComment, isNew: Bool) {
        guard let window, window.attachedSheet == nil else { return }
        if let commentEditor, !commentEditor.dismissIfUnchanged() { commentEditor.focus(); return }
        commentEditor = CommentEditorController(comment: comment, isNew: isNew, onSave: { [weak self] comment in
            try self?.changeComments {
                if let index = $0.firstIndex(where: { $0.id == comment.id }) { $0[index] = comment } else { $0.append(comment) }
            }
        }, onDelete: isNew ? nil : { [weak self] in try self?.changeComments { $0.removeAll { $0.id == comment.id } } })
        commentEditor?.present(relativeTo: diff.selectionAnchor ?? NSRect(x: diff.bounds.midX, y: diff.bounds.maxY - 60, width: 1, height: 1), of: diff)
    }
    private func settleDraft() -> Bool {
        guard let commentEditor else { return true }
        guard commentEditor.dismissIfUnchanged() else {
            commentEditor.focus()
            showStatus("Save or discard the open comment first.")
            return false
        }
        return true
    }
    private func changeComments(_ change: (inout [ReviewComment]) -> Void) throws {
        let prior = progress
        change(&progress.comments)
        do { try saveProgress() }
        catch { progress = prior; throw error }
        diff.redraw(); sidebar.reloadData(); updateActions()
    }
    @objc private func commentOnSelection() { if let selection = diff.selection { editComment(selection: selection) } }
    @objc private func showComments(_ sender: Any?) {
        let menu = NSMenu()
        for (index, comment) in progress.comments.enumerated() {
            let stale = !files.contains { $0.path == comment.path && $0.fingerprint == comment.fingerprint }
            let label = "\(stale ? "⚠︎ " : "")\(comment.path):\(comment.startLine)–\(comment.endLine)  \(comment.text.prefix(60).replacingOccurrences(of: "\n", with: " "))"
            let item = menu.addItem(withTitle: label, action: #selector(openComment(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        showMenu(menu)
    }
    @objc private func openComment(_ sender: NSMenuItem) {
        guard progress.comments.indices.contains(sender.tag) else { return }
        let comment = progress.comments[sender.tag]
        if let index = files.firstIndex(where: { $0.path == comment.path }) { diff.navigate(to: index) }
        presentComment(comment, isNew: false)
    }
    @objc private func finishReview() {
        guard let snapshot, settleDraft() else { return }
        let text = ReviewExport.markdown(snapshot: snapshot, progress: progress)
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            showStatus("Copied \(progress.comments.count) comments")
        } else { showError(GitError("The clipboard could not be updated. Try again or export a Markdown file."), title: "Could not copy review") }
    }
    @objc private func exportReview() {
        guard let window, let snapshot, settleDraft() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "review.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try ReviewExport.markdown(snapshot: snapshot, progress: self.progress).write(to: url, atomically: true, encoding: .utf8)
                self.showStatus("Exported \(url.lastPathComponent)")
            } catch { self.showError(error, title: "Could not export review") }
        }
    }
    @objc private func showPreview() {
        guard let snapshot, files.indices.contains(focused), !busy else { return }
        let file = files[focused]
        setBusy(true, message: "Loading Markdown preview…")
        Task { [weak self] in
            do {
                let texts = try await Task.detached(priority: .userInitiated) {
                    let git = GitRepository(path: snapshot.request.repository)
                    return try (git.content(snapshot: snapshot, file: file, side: .old), git.content(snapshot: snapshot, file: file, side: .new))
                }.value
                guard let self else { return }
                self.preview = MarkdownPreviewController(path: file.path, old: texts.0, new: texts.1)
                self.preview?.showWindow(nil)
                self.setBusy(false)
            } catch { self?.setBusy(false); self?.showError(error, title: "Could not preview Markdown") }
        }
    }
    @objc private func showRecent(_ sender: Any?) {
        let menu = NSMenu()
        for (index, request) in preferences.recentComparisons.enumerated() {
            let title = request.pullRequestURL ?? "\(URL(fileURLWithPath: request.repository).lastPathComponent) · \(request.base) → \(request.target ?? "Working tree")"
            let item = menu.addItem(withTitle: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No recent comparisons", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: "Choose checkout for a GitHub repository…", action: #selector(remapRepository), keyEquivalent: "")
        reset.target = self
        showMenu(menu)
    }
    private func showMenu(_ menu: NSMenu) {
        guard let window, let content = window.contentView else { return }
        menu.popUp(positioning: nil, at: content.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: content)
    }
    @objc private func remapRepository() {
        if let url = snapshot?.request.pullRequestURL, let pr = try? GitHubPR.parse(url) { choosePRCheckout(pr) }
        else { openComparison() }
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard !busy, preferences.recentComparisons.indices.contains(sender.tag) else { return }
        let request = preferences.recentComparisons[sender.tag]
        if let url = request.pullRequestURL { openPR(url) } else { load(request) }
    }
    func controlTextDidChange(_ obj: Notification) { rebuildSidebar() }
    private func rebuildSidebar() {
        let query = search.stringValue
        sidebarIndices = files.indices.filter { query.isEmpty || files[$0].path.localizedCaseInsensitiveContains(query) }
        sidebar.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarIndices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileCell ?? FileCell()
        cell.identifier = id
        let file = files[sidebarIndices[row]]
        cell.configure(file: file, reviewed: isReviewed(file), reason: preferences.filters.skipReason(for: file))
        cell.onToggle = { [weak self] reviewed in self?.setReviewed(file, reviewed: reviewed) }
        return cell
    }
    @objc private func sidebarSelected() {
        let row = sidebar.selectedRow
        if sidebarIndices.indices.contains(row) { diff.navigate(to: sidebarIndices[row]) }
    }
    private func showError(_ error: Error, title: String, recovery: String? = nil, action: (() -> Void)? = nil) {
        status.stringValue = "\(title): \(error.localizedDescription)"
        NSLog("%@: %@", title, error.localizedDescription)
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let recovery { alert.addButton(withTitle: recovery) }
        alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { action?() } }
    }
    private func performVerificationIfRequested() {
        // Opt-in local harness: uses the real window and scroll surface, never user state by default.
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--capture"), args.indices.contains(i + 1) else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let view = self.window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            NSLog("Slopdiff capture window=%d frame=%@", self.window?.windowNumber ?? 0, NSStringFromRect(self.window?.frame ?? .zero))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                catch { self.showError(error, title: "Could not capture verification image") }
            }
        }
    }
}

private final class FileCell: NSTableCellView {
    private let name = Style.label("", size: 12, weight: .medium)
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onToggle: ((Bool) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.controlSize = .small
        check.target = self; check.action = #selector(toggle)
        let row = Style.stack([check, name], spacing: 8)
        Style.pin(row, in: self, inset: 3)
        check.widthAnchor.constraint(equalToConstant: 15).isActive = true
        check.heightAnchor.constraint(equalToConstant: 15).isActive = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { onToggle?(check.state == .on) }
    func configure(file: FileDiff, reviewed: Bool, reason: String?) {
        name.stringValue = (file.path as NSString).lastPathComponent
        name.textColor = reviewed ? .secondaryLabelColor : .labelColor
        check.state = reviewed ? .on : .off
        check.isEnabled = reason == nil
        check.toolTip = reason.map { "Automatically reviewed: \($0). Change the corresponding global filter to review manually." } ?? "Mark file as reviewed"
        toolTip = file.path + (reason.map { "\nAuto-reviewed: \($0)" } ?? "")
    }
}
