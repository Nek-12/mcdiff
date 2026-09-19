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
    private let diff = DiffViewport()
    private let sidebar = NSTableView()
    private let search = NSSearchField()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))
    private var searchMatchingFiles: Set<Int>?
    private let spinner = NSProgressIndicator()
    private var reviewNext: NSToolbarItem!
    private var finishButton: NSToolbarItem!
    private var refreshButton: NSToolbarItem!
    private var commentsButton: NSToolbarItem!
    private var feedbackActions: NSToolbarItemGroup!
    private var wrapButton: NSToolbarItemGroup!
    private let splitController = NSSplitViewController()
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let toolbarOrder: [NSToolbarItem.Identifier] = [
        .init("sources"), .init("sidebarDivider"),
        .init("navigation"), .space, .init("status"), .flexibleSpace,
        .init("search"), .space, .init("wrap"), .space, .init("split"),
        .space, .init("feedback")
    ]
    private let emptyToolbarOrder: [NSToolbarItem.Identifier] = [
        .init("welcomeSources"), .init("status"), .flexibleSpace
    ]
    private let testsFilter = NSButton(checkboxWithTitle: "Tests", target: nil, action: nil)
    private let docsFilter = NSButton(checkboxWithTitle: "Documentation / non-code", target: nil, action: nil)
    private let noiseFilter = NSButton(checkboxWithTitle: "Generated / noise", target: nil, action: nil)
    private let empty = NSView()
    private enum Activity { case comparison, layout, search }
    private var activities: Set<Activity> = []
    private var busy: Bool { activities.contains(.comparison) }
    private var statusDismissal: DispatchWorkItem?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Slopdiff"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { settleDraft() }

    func start() {
        do {
            let args = ProcessInfo.processInfo.arguments
            store = try ReviewStore()
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
        side.minimumThickness = 250; side.maximumThickness = 400
        side.preferredThicknessFraction = 0.19
        side.canCollapse = true
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
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.30)
        glass.cornerRadius = 0
        glass.contentView = splitController.view
        backdrop.view = glass
        window.contentViewController = backdrop
        splitController.splitView.setPosition(290, ofDividerAt: 0)

        func toolbarIcon(_ name: String) -> NSImage? {
            guard let image = (Icons.image(name) ?? NSImage(systemSymbolName: name, accessibilityDescription: nil))?.copy() as? NSImage else { return nil }
            image.size = NSSize(width: 20, height: 20)
            return image
        }
        func item(_ id: String, _ title: String, _ icon: String, _ action: Selector?, text: Bool = false) -> NSToolbarItem {
            let identifier = NSToolbarItem.Identifier(id)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title; item.paletteLabel = title; item.toolTip = title
            item.image = toolbarIcon(icon)
            if text { item.title = title }
            item.isBordered = true
            item.target = self; item.action = action
            item.autovalidates = false
            toolbarItems[identifier] = item
            return item
        }
        let sources = NSToolbarItemGroup(itemIdentifier: .init("sources"),
            images: [toolbarIcon("folder-open")!, toolbarIcon("rotate-cw")!, toolbarIcon("clock.arrow.circlepath")!],
            selectionMode: .momentary, labels: ["Open comparison", "Refresh · ⌘R", "Recent comparisons"],
            target: self, action: #selector(sourceAction(_:)))
        sources.isBordered = true
        sources.autovalidates = false
        refreshButton = sources.subitems[1]
        toolbarItems[sources.itemIdentifier] = sources
        let welcomeSources = NSToolbarItemGroup(itemIdentifier: .init("welcomeSources"),
            images: [toolbarIcon("folder-open")!, toolbarIcon("clock.arrow.circlepath")!],
            selectionMode: .momentary, labels: ["Open comparison", "Recent comparisons"],
            target: self, action: #selector(welcomeSourceAction(_:)))
        welcomeSources.isBordered = true
        welcomeSources.autovalidates = false
        toolbarItems[welcomeSources.itemIdentifier] = welcomeSources
        let divider = NSTrackingSeparatorToolbarItem(identifier: .init("sidebarDivider"), splitView: splitController.splitView, dividerIndex: 0)
        toolbarItems[divider.itemIdentifier] = divider
        let navigation = NSToolbarItemGroup(itemIdentifier: .init("navigation"),
            images: [toolbarIcon("arrow-down")!, toolbarIcon("arrow-up")!, toolbarIcon("check")!], selectionMode: .momentary,
            labels: ["Next file", "Previous file", "Review & next"], target: self, action: #selector(navigateToolbar(_:)))
        reviewNext = navigation
        reviewNext.visibilityPriority = .high
        wrapButton = NSToolbarItemGroup(itemIdentifier: .init("wrap"), titles: ["Wrap"],
            selectionMode: .selectAny, labels: ["Soft wrap"], target: self, action: #selector(wrapChanged))
        wrapButton.subitems.first?.image = toolbarIcon("arrow.turn.down.left")
        for group in [navigation, wrapButton!] {
            group.isBordered = true
            group.autovalidates = false
            toolbarItems[group.itemIdentifier] = group
        }
        let split = item("split", "Split", "rectangle.split.2x1", nil, text: true)
        split.isEnabled = false
        split.toolTip = "Split · not available yet"
        feedbackActions = NSToolbarItemGroup(itemIdentifier: .init("feedback"),
            images: [toolbarIcon("message-square")!, toolbarIcon("copy")!, toolbarIcon("square.and.arrow.down")!],
            selectionMode: .momentary, labels: ["Comments", "Copy review", "Export Markdown"],
            target: self, action: #selector(feedbackAction(_:)))
        feedbackActions.isBordered = true
        feedbackActions.autovalidates = false
        feedbackActions.visibilityPriority = .high
        commentsButton = feedbackActions.subitems[0]
        finishButton = feedbackActions.subitems[1]
        toolbarItems[feedbackActions.itemIdentifier] = feedbackActions

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let context = NSToolbarItem(itemIdentifier: .init("status"))
        context.view = spinner; context.label = "Loading"; context.visibilityPriority = .high
        context.isBordered = false
        toolbarItems[context.itemIdentifier] = context
        search.placeholderString = "Search review…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        searchItem.searchField = search
        searchItem.preferredWidthForSearchField = 230
        searchItem.label = "Search review"
        toolbarItems[searchItem.itemIdentifier] = searchItem
        let toolbar = NSToolbar(identifier: "Slopdiff.review")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        installReviewMenu()
        updateComparisonPresentation()
        updateActions()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        snapshot == nil ? emptyToolbarOrder : toolbarOrder
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarOrder + [.init("welcomeSources")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { toolbarItems[itemIdentifier] }
    private func updateComparisonPresentation() {
        let hasComparison = snapshot != nil
        splitController.splitViewItems.first?.isCollapsed = !hasComparison
        empty.isHidden = hasComparison
        diff.isHidden = !hasComparison
        guard let toolbar = window?.toolbar else { return }
        let order = hasComparison ? toolbarOrder : emptyToolbarOrder
        guard toolbar.items.map(\.itemIdentifier) != order else { return }
        for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
        for (index, identifier) in order.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }
    @objc private func welcomeSourceAction(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: openComparison()
        case 1: showRecent(sender)
        default: break
        }
    }
    @objc private func navigateToolbar(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: nextFile()
        case 1: previousFile()
        case 2: markAndNext()
        default: break
        }
    }
    @objc private func feedbackAction(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: showComments(sender)
        case 1: finishReview()
        case 2: exportReview()
        default: break
        }
    }
    @objc private func sourceAction(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: openComparison()
        case 1: refresh()
        case 2: showRecent(sender)
        default: break
        }
    }
    private func installReviewMenu() {
        let menu = NSMenu(title: "Review")
        let entries: [(String, Selector, String)] = [
            ("Open comparison…", #selector(openComparison), "o"),
            ("Refresh", #selector(refresh), "r"),
            ("Find in review", #selector(findInReview), "f"),
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
            scroll.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
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
            empty.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            empty.topAnchor.constraint(equalTo: main.safeAreaLayoutGuide.topAnchor),
            empty.bottomAnchor.constraint(equalTo: main.bottomAnchor)
        ])
        let logo = NSImageView(image: Icons.image("git-compare-arrows") ?? NSImage())
        logo.contentTintColor = .controlAccentColor
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 40).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let start = Style.button("Open a comparison", icon: "folder-open", target: self, action: #selector(openComparison))
        let welcome = Style.stack([logo, start], orientation: .vertical, spacing: 18)
        welcome.alignment = .centerX; welcome.translatesAutoresizingMaskIntoConstraints = false; empty.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: empty.centerYAnchor)
        ])
        return main
    }
    private func configureCallbacks() {
        diff.isReviewed = { [weak self] in self?.isReviewed($0) ?? false }
        diff.commentCount = { [weak self] file in self?.progress.comments.filter { $0.path == file.path }.count ?? 0 }
        diff.onFocus = { [weak self] in self?.focus($0) }
        diff.onComment = { [weak self] in self?.editComment(selection: $0) }
        diff.onSearchResults = { [weak self] indices, count in
            guard let self else { return }
            self.searchMatchingFiles = self.search.stringValue.isEmpty ? nil : Set(indices)
            self.searchItem.badge = self.search.stringValue.isEmpty ? nil : .count(count)
            self.rebuildSidebar()
        }
        diff.onSearchBusy = { [weak self] searching in
            self?.setActivity(.search, active: searching)
        }
        diff.commentRange = { [weak self] path, side, number in
            self?.progress.comments.first { $0.path == path && $0.side == side && ($0.startLine...$0.endLine).contains(number) }
                .map { $0.startLine...$0.endLine }
        }
        diff.onHighlightError = { [weak self] error in self?.showError(error, title: "Could not highlight code") }
        diff.onLayoutBusy = { [weak self] busy in
            self?.setActivity(.layout, active: busy)
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
                    let git = GitRepository(path: request.repository)
                    var markdown: [String: MarkdownFileContent] = [:]
                    for file in snapshot.files where RenderedMarkdown.accepts(file.path) && !file.isBinary {
                        do {
                            markdown[file.path] = try MarkdownFileContent(old: git.content(snapshot: snapshot, file: file, side: .old),
                                                                          new: git.content(snapshot: snapshot, file: file, side: .new))
                        } catch {
                            markdown[file.path] = MarkdownFileContent(old: nil, new: nil, error: error.localizedDescription)
                        }
                    }
                    return (snapshot, progress, presentation, markdown)
                }.value
                guard let self else { return }
                self.snapshot = result.0; self.progress = result.1; self.presentations = result.2
                self.sortFiles()
                self.diff.expanded = Set(self.files.filter { self.preferences.filters.skipReason(for: $0) == nil && !self.isReviewed($0) }.map(\.path))
                self.diff.filters = self.preferences.filters
                self.diff.markdownContent = result.3
                self.searchMatchingFiles = nil
                self.diff.setFiles(self.files, presentations: self.presentations)
                self.rebuildSidebar()
                self.updateComparisonPresentation()
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
        finishButton?.isEnabled = snapshot != nil && !busy
        feedbackActions?.subitems[2].isEnabled = snapshot != nil && !busy
        refreshButton?.isEnabled = snapshot != nil && !busy
        commentsButton?.toolTip = "\(progress.comments.count) comments"
        commentsButton?.isEnabled = !progress.comments.isEmpty && !busy
    }
    private func setBusy(_ value: Bool, message: String? = nil) {
        setActivity(.comparison, active: value)
        statusDismissal?.cancel()
        spinner.toolTip = message
        updateActions()
    }
    private func setActivity(_ activity: Activity, active: Bool) {
        if active { activities.insert(activity) } else { activities.remove(activity) }
        if activities.isEmpty { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
    private func showStatus(_ message: String) {
        statusDismissal?.cancel()
        NSLog("%@", message)
        finishButton?.toolTip = message
        let dismissal = DispatchWorkItem { [weak self] in
            if self?.busy == false {
                self?.finishButton?.toolTip = "Copy review"
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
        diff.expanded = Self.expansionAfterFilterChange(files: files, expanded: diff.expanded,
                                                      from: previous, to: preferences.filters)
        sortFiles(); diff.files = files; diff.filters = preferences.filters
        searchMatchingFiles = nil
        diff.search(query: search.stringValue)
        diff.selection = nil
        diff.rebuild()
        rebuildSidebar()
        if let path, let index = files.firstIndex(where: { $0.path == path }) { diff.navigate(to: index, expand: false) }
        updateActions()
    }
    static func expansionAfterFilterChange(files: [FileDiff], expanded: Set<String>,
                                           from previous: ReviewFilters, to current: ReviewFilters) -> Set<String> {
        var result = expanded
        for file in files {
            let wasSkipped = previous.skipReason(for: file) != nil
            let isSkipped = current.skipReason(for: file) != nil
            guard wasSkipped != isSkipped else { continue }
            if isSkipped { result.remove(file.path) }
            else { result.insert(file.path) }
        }
        return result
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
        if let comment = progress.comments.first(where: {
            $0.path == file.path && $0.side == selection.side &&
            $0.startLine <= selection.end && $0.endLine >= selection.start
        }) {
            presentComment(comment, isNew: false)
            return
        }
        presentComment(ReviewComment(path: file.path, side: selection.side, startLine: selection.start, endLine: selection.end, text: "", fingerprint: file.fingerprint), isNew: true)
    }
    private func presentComment(_ comment: ReviewComment, isNew: Bool) {
        guard let window, window.attachedSheet == nil else { return }
        if let commentEditor, !commentEditor.dismissIfUnchanged() { commentEditor.focus(); return }
        commentEditor = CommentEditorController(comment: comment, isNew: isNew, onSave: { [weak self] comment in
            try self?.changeComments { try $0.saveComment(comment) }
        }, onDelete: isNew ? nil : { [weak self] in try self?.changeComments { $0.comments.removeAll { $0.id == comment.id } } })
        commentEditor?.present(relativeTo: diff.selectionAnchor ?? NSRect(x: diff.bounds.midX, y: diff.bounds.maxY - 60, width: 1, height: 1), of: diff)
    }
    func settleDraft() -> Bool {
        guard let commentEditor else { return true }
        guard commentEditor.dismissIfUnchanged() else {
            commentEditor.focus()
            showStatus("Save or discard the open comment first.")
            return false
        }
        return true
    }
    private func changeComments(_ change: (inout ReviewProgress) throws -> Void) throws {
        let prior = progress
        do { try change(&progress); try saveProgress() }
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
    @objc private func findInReview() { searchItem.beginSearchInteraction() }
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === search else { return }
        diff.search(query: search.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        diff.nextSearchMatch(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        return true
    }
    private func rebuildSidebar() {
        sidebarIndices = files.indices.filter { searchMatchingFiles?.contains($0) ?? true }
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
        NSLog("%@: %@", title, error.localizedDescription)
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let recovery { alert.addButton(withTitle: recovery) }
        alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { action?() } }
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
