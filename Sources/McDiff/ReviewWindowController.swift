import AppKit
import McDiffCore
import UniformTypeIdentifiers

final class ReviewWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let github: GitHubClient
    private var avatarTask: Task<Void, Never>?
    enum Screen { case home, review }
    private(set) var screen: Screen = .home
    private enum Account { case checking, signedOut, signedIn(GitHubUser), failed }
    private var account: Account = .checking
    private var accountTask: Task<Void, Never>?
    private var signInSheet: GitHubSignInController?
    private var pendingPR: String?
    private(set) lazy var home = PRHomeController { [github] query, page in
        try await github.pullRequests(query: query, page: page)
    }
    private var store: ReviewStore?
    private var preferences = ReviewPreferences()
    private var snapshot: ReviewSnapshot?
    private var progress = ReviewProgress()
    private var files: [FileDiff] = []
    private var sidebarIndices: [Int] = []
    private var sidebarNames: [String: String] = [:]
    private var focused = 0
    let reviewDestination = ReviewDestinationController()
    var isReviewReady: Bool { screen == .review && reviewDestination.phase == .ready && snapshot != nil }
    private var comparisonSheet: ComparisonSheet?
    private var branchTask: Task<Void, Never>?
    private var commentEditor: CommentEditorController?
    private let diff = DiffViewport()
    private let comparisonWarning = ComparisonWarningView()
    private let sidebar = ReviewSidebarTableView()
    private let search = NSSearchField()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))
    private var searchMatchingFiles: Set<Int>?
    private let spinner = NSProgressIndicator()
    private var reviewActions: NSToolbarItemGroup!
    private var finishButton: NSToolbarItem!
    private var refreshButton: NSToolbarItem!
    private var commentsButton: NSToolbarItem!
    private var finishSheet: FinishReviewSheet?
    private var finishTask: Task<Void, Never>?
    private var wrapButton: NSToolbarItem!
    private var layoutButton: NSToolbarItem!
    private let splitController = NSSplitViewController()
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let toolbarOrder: [NSToolbarItem.Identifier] = [
        .flexibleSpace, .init("home"), .init("refresh"), .init("sidebarDivider"),
        .init("search"), .space, .init("status"), .flexibleSpace,
        .init("wrap"), .space, .init("split"),
        .space, .init("navigation"), .space, .init("finish")
    ]
    private let emptyToolbarOrder: [NSToolbarItem.Identifier] = [
        .init("welcomeSources"), .init("homeRefresh"), .init("status"), .flexibleSpace,
        .init("pr-home-search"), .space, .init("account")
    ]
    private let loadingToolbarOrder: [NSToolbarItem.Identifier] = [
        .init("home"), .init("status"), .flexibleSpace
    ]
    private let testsFilter = AnimatedCheckbox(checkboxWithTitle: "Tests", target: nil, action: nil)
    private let docsFilter = AnimatedCheckbox(checkboxWithTitle: "Documentation and non-code", target: nil, action: nil)
    private let noiseFilter = AnimatedCheckbox(checkboxWithTitle: "Generated and noise", target: nil, action: nil)
    private let whitespaceAndImportsFilter = AnimatedCheckbox(checkboxWithTitle: "Whitespace and imports", target: nil, action: nil)
    private let metaChangesFilter = AnimatedCheckbox(checkboxWithTitle: "Meta changes", target: nil, action: nil)
    private enum Activity { case comparison, layout, search, account }
    private var activities: Set<Activity> = []
    private var busy: Bool {
        (screen == .review && reviewDestination.phase != .ready) || finishSheet != nil
    }
    private var statusDismissal: DispatchWorkItem?

    init(github: GitHubClient) {
        self.github = github
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "McDiff"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 1080, height: 680)
        window.center()
        window.setFrameAutosaveName("McDiff.review")
        super.init(window: window)
        window.delegate = self
        buildUI()
        configureCallbacks()
        home.setUnavailable("Checking GitHub sign-in…", clearResults: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finishSheet == nil && settleDraft() }

    func start(store suppliedStore: ReviewStore? = nil, arguments: [String] = ProcessInfo.processInfo.arguments) {
        bootstrapAccount()
        do {
            let args = arguments
            store = try suppliedStore ?? ReviewStore()
            preferences = try store!.loadPreferences()
            updateFilters()
            diff.softWrap = preferences.softWrap
            updateWrapButton()
            diff.diffLayout = preferences.diffLayout
            updateLayoutButton()
            if let i = args.firstIndex(of: "--repo"), args.indices.contains(i + 1) {
                let base = args.firstIndex(of: "--base").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "main"
                let target = args.firstIndex(of: "--target").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                load(ComparisonRequest(repository: args[i + 1], base: base, target: target))
            } else if let i = args.firstIndex(of: "--pr"), args.indices.contains(i + 1) {
                openPR(args[i + 1])
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
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.65)
        glass.cornerRadius = 0
        glass.contentView = splitController.view
        let drop = PRDropView()
        drop.onOpenPR = { [weak self] in self?.openPR($0) }
        drop.onPaste = { [weak self] in self?.openPR($0) }
        Style.pin(glass, in: drop)
        let homeView = home.view
        homeView.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(homeView)
        NSLayoutConstraint.activate([
            homeView.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            homeView.topAnchor.constraint(equalTo: drop.safeAreaLayoutGuide.topAnchor),
            homeView.bottomAnchor.constraint(equalTo: drop.bottomAnchor)
        ])
        backdrop.view = drop
        window.contentViewController = backdrop
        splitController.splitView.setPosition(290, ofDividerAt: 0)

        func item(_ id: String, _ title: String, _ icon: Icons.Symbol, _ action: Selector?, text: Bool = false) -> NSToolbarItem {
            let identifier = NSToolbarItem.Identifier(id)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title; item.paletteLabel = title; item.toolTip = title
            item.image = Icons.image(icon)
            if text { item.title = title }
            item.isBordered = true
            item.target = self; item.action = action
            item.autovalidates = false
            toolbarItems[identifier] = item
            return item
        }
        _ = item("home", "Home", .home, #selector(showHome))
        _ = item("homeRefresh", "Refresh pull requests", .refresh, #selector(refresh))
        _ = item("account", "Sign in to GitHub", .account, #selector(accountAction))
        toolbarItems[home.searchItem.itemIdentifier] = home.searchItem
        refreshButton = item("refresh", "Refresh", .refresh, #selector(refresh))
        refreshButton.toolTip = "Refresh comparison (⌘R)"
        let welcomeSources = NSToolbarItemGroup(itemIdentifier: .init("welcomeSources"),
            images: [Icons.image(.folder), Icons.image(.recents)],
            selectionMode: .momentary, labels: ["Open comparison", "Recent comparisons"],
            target: self, action: #selector(welcomeSourceAction(_:)))
        welcomeSources.isBordered = true
        welcomeSources.autovalidates = false
        toolbarItems[welcomeSources.itemIdentifier] = welcomeSources
        let divider = NSTrackingSeparatorToolbarItem(identifier: .init("sidebarDivider"), splitView: splitController.splitView, dividerIndex: 0)
        toolbarItems[divider.itemIdentifier] = divider
        let navigation = NSToolbarItemGroup(itemIdentifier: .init("navigation"))
        commentsButton = item("comments", "Comments", .comment, #selector(showComments(_:)))
        navigation.subitems = [
            commentsButton,
            item("next", "Next file", .next, #selector(nextFile)),
            item("previous", "Previous file", .previous, #selector(previousFile)),
            item("reviewNext", "Review & next", .review, #selector(markAndNext))
        ]
        reviewActions = navigation
        reviewActions.visibilityPriority = .high
        navigation.isBordered = true
        navigation.autovalidates = false
        toolbarItems[navigation.itemIdentifier] = navigation
        wrapButton = item("wrap", "Wrap off", .wrap, #selector(wrapChanged), text: true)
        updateWrapButton()
        layoutButton = item("split", "Unified", .unified, #selector(layoutChanged), text: true)
        updateLayoutButton()
        finishButton = item("finish", "Finish review", .finish, #selector(finishReview), text: true)
        finishButton.style = .prominent
        finishButton.visibilityPriority = .high
        for group in [welcomeSources, navigation] {
            for subitem in group.subitems { subitem.toolTip = subitem.label }
        }
        welcomeSources.subitems[0].toolTip = "Open comparison (⌘O)"
        navigation.subitems[1].toolTip = "Next file (⌥↓)"
        navigation.subitems[2].toolTip = "Previous file (⌥↑)"
        navigation.subitems[3].toolTip = "Mark reviewed and go to the next unreviewed file (⌘J)"

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let context = NSToolbarItem(itemIdentifier: .init("status"))
        context.view = spinner; context.label = "Loading"; context.visibilityPriority = .high
        context.isBordered = false
        toolbarItems[context.itemIdentifier] = context
        search.placeholderString = "Search review…"
        search.cell?.lineBreakMode = .byTruncatingTail
        search.delegate = self
        search.sendsSearchStringImmediately = true
        searchItem.searchField = search
        Icons.configureSearchField(search)
        searchItem.preferredWidthForSearchField = 380
        searchItem.label = "Search review"
        searchItem.toolTip = "Search paths and displayed text (⌘F)"
        search.toolTip = "Search paths and displayed text (⌘F); Return / Shift-Return navigates matches"
        toolbarItems[searchItem.itemIdentifier] = searchItem
        let toolbar = NSToolbar(identifier: "McDiff.review")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        installReviewMenu()
        updateComparisonPresentation()
        updateActions()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        screen == .home ? emptyToolbarOrder : (isReviewReady ? toolbarOrder : loadingToolbarOrder)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarOrder + emptyToolbarOrder
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { toolbarItems[itemIdentifier] }
    private func updateComparisonPresentation() {
        let hasComparison = screen == .review
        splitController.splitViewItems.first?.isCollapsed = !isReviewReady || files.isEmpty
        splitController.view.isHidden = !hasComparison
        home.view.isHidden = hasComparison
        diff.isHidden = !isReviewReady || files.isEmpty
        comparisonWarning.configure(snapshot: isReviewReady ? snapshot : nil)
        reviewDestination.view.isHidden = !hasComparison || (isReviewReady && !files.isEmpty)
        guard let toolbar = window?.toolbar else { return }
        let order = hasComparison ? (isReviewReady ? toolbarOrder : loadingToolbarOrder) : emptyToolbarOrder
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
    private func installReviewMenu() {
        let menu = NSMenu(title: "Review")
        let entries: [(String, Selector, String)] = [
            ("Open comparison…", #selector(openComparison), "o"),
            ("Refresh", #selector(refresh), "r"),
            ("Find in review", #selector(findInReview), "f"),
            ("Review & next", #selector(markAndNext), "j"),
            ("Comment on selection", #selector(commentOnSelection), "l"),
            ("Finish review…", #selector(finishReview), "\r")
        ]
        for (title, action, key) in entries {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            if action == #selector(finishReview) { item.keyEquivalentModifierMask = .control }
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
        let buttons = [testsFilter, docsFilter, noiseFilter, whitespaceAndImportsFilter, metaChangesFilter]
        let filters = Style.stack(buttons, orientation: .vertical, spacing: 7)
        for button in buttons {
            button.font = .systemFont(ofSize: 12)
            button.target = self; button.action = #selector(filtersChanged)
            button.toolTip = "Include these files in review. Uncheck to automatically collapse and mark reviewed. Remembered globally; files remain expandable."
        }
        whitespaceAndImportsFilter.toolTip = "Show whitespace and import changes with full emphasis. Uncheck to ignore whitespace outside strings, imports, and package declarations, and automatically collapse and mark files reviewed when only those change. Remembered globally; files remain expandable."
        metaChangesFilter.toolTip = "Include deleted and removal-only files, and renames, copies, modes, or other metadata without content edits. Uncheck to automatically collapse and mark reviewed. Binary files remain automatically reviewed. Remembered globally; files remain expandable."
        let view = NSView()
        Style.pin(filters, in: view, inset: 12)
        return view
    }
    private func buildMain() -> NSView {
        let main = NSView()
        let content = NSView()
        let stack = Style.stack([comparisonWarning, content], orientation: .vertical, spacing: 0)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(stack)
        diff.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(diff)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            stack.topAnchor.constraint(equalTo: main.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            comparisonWarning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Match the native toolbar group's eight-point inset after the tracking separator.
            diff.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            diff.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            diff.topAnchor.constraint(equalTo: content.topAnchor),
            diff.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        Style.pin(reviewDestination.view, in: content)
        return main
    }
    private func configureCallbacks() {
        reviewDestination.onStateChange = { [weak self] in
            guard let self else { return }
            self.setActivity(.comparison, active: self.screen == .review && self.reviewDestination.phase == .loading)
            self.updateComparisonPresentation()
            self.updateActions()
        }
        reviewDestination.onHome = { [weak self] in self?.showHome() }
        home.onOpenPR = { [weak self] in self?.openPR($0) }
        home.onResume = { [weak self] in self?.resumeReview() }
        home.onAuthenticationRequired = { [weak self] in self?.setAccount(.signedOut) }
        diff.isReviewed = { [weak self] in self?.isReviewed($0) ?? false }
        diff.onReviewToggle = { [weak self] file, reviewed in self?.setReviewed(file, reviewed: reviewed) }
        sidebar.onToggleReviewed = { [weak self] in
            guard let self, self.sidebarIndices.indices.contains(self.sidebar.selectedRow) else { return }
            let file = self.files[self.sidebarIndices[self.sidebar.selectedRow]]
            self.setReviewed(file, reviewed: !self.isReviewed(file))
        }
        diff.onFinishReview = { [weak self] in self?.finishReview() }
        diff.onFocus = { [weak self] index in
            guard let self, self.isReviewReady else { return }
            self.focus(index)
        }
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
        diff.onHighlightError = { [weak self] error in
            guard let self, self.isReviewReady else {
                NSLog("Could not highlight inactive review: %@", error.localizedDescription)
                return
            }
            self.showError(error, title: "Could not highlight code")
        }
        diff.onLayoutBusy = { [weak self] busy in
            self?.setActivity(.layout, active: busy)
        }
    }
    @objc private func openComparison() {
        guard let window, !busy, window.attachedSheet == nil, settleDraft() else { return }
        let recent = snapshot?.request ?? preferences.recentComparisons.first
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipboardURL = clipboard.flatMap { try? GitHubPR.parse($0).url }
        comparisonSheet = ComparisonSheet(recent: recent, clipboardURL: clipboardURL) { [weak self] action in
            self?.handleComparisonAction(action)
        }
        comparisonSheet?.present(on: window)
        if let recent { loadComparisonBranches(path: recent.repository, chooseDefault: false) }
    }
    private func handleComparisonAction(_ action: ComparisonSheet.Action) {
        guard let sheet = comparisonSheet, let sheetWindow = sheet.window else { return }
        switch action {
        case .cancel:
            branchTask?.cancel()
            branchTask = nil
            sheet.dismiss()
            comparisonSheet = nil
        case .chooseRepository:
            let picker = NSOpenPanel()
            picker.canChooseDirectories = true
            picker.canChooseFiles = false
            picker.allowsMultipleSelection = false
            picker.message = "Select the Git checkout or worktree to review."
            picker.beginSheetModal(for: sheetWindow) { [weak self, weak sheet] response in
                guard let self, let sheet, self.comparisonSheet === sheet,
                      response == .OK, let path = picker.url?.path else { return }
                sheet.setRepository(path: path)
                self.loadComparisonBranches(path: path, chooseDefault: true)
            }
        case .open(let input):
            do {
                let resolved = try input.resolve()
                branchTask?.cancel()
                branchTask = nil
                sheet.dismiss()
                comparisonSheet = nil
                if let url = resolved.url { openPR(url) }
                else if let request = resolved.request { load(request) }
            } catch { sheet.showStatus(error.localizedDescription, failed: true) }
        }
    }
    private func loadComparisonBranches(path: String, chooseDefault: Bool) {
        guard let sheet = comparisonSheet else { return }
        branchTask?.cancel()
        sheet.showStatus("Reading branches…")
        branchTask = Task { [weak self, weak sheet] in
            do {
                let branches = try await ComparisonBranches.load(path: path)
                guard let self, let sheet, !Task.isCancelled, self.comparisonSheet === sheet else { return }
                sheet.setBranches(branches, chooseDefault: chooseDefault)
                self.branchTask = nil
            } catch {
                guard let self, let sheet, !Task.isCancelled, self.comparisonSheet === sheet else { return }
                self.branchTask = nil
                sheet.showStatus("Could not read branches: \(error.localizedDescription) Choose the checkout again to retry.", failed: true)
            }
        }
    }
    func openPR(_ url: String) {
        guard window?.attachedSheet == nil, finishSheet == nil, settleDraft() else { return }
        do {
            let pr = try GitHubPR.parse(url)
            navigateToReview(.pullRequest(pr))
            continuePR(pr)
        } catch { showError(error, title: "Cannot open pull request") }
    }
    private func navigateToReview(_ intent: ReviewIntent) {
        pendingPR = nil
        Style.animateStateChange(window?.contentView)
        screen = .review
        reviewDestination.enter(intent)
        updateComparisonPresentation()
        window?.makeFirstResponder(reviewDestination.view)
    }
    private func continuePR(_ pr: GitHubPR) {
        guard screen == .review, reviewDestination.intent == .pullRequest(pr) else { return }
        switch account {
        case .checking:
            pendingPR = pr.url
            reviewDestination.wait("Checking GitHub sign-in…")
            return
        case .signedOut:
            pendingPR = pr.url
            reviewDestination.wait("Sign in to GitHub to open this pull request.", actionTitle: "Sign in") { [weak self] in
                self?.pendingPR = pr.url
                self?.signIn()
            }
            signIn()
            return
        case .failed:
            pendingPR = pr.url
            reviewDestination.fail("Could not check GitHub sign-in.", actionTitle: "Retry") { [weak self] in self?.bootstrapAccount() }
            return
        case .signedIn: break
        }
        if let local = preferences.repositoryMappings[pr.repositoryKey.lowercased()],
           FileManager.default.fileExists(atPath: local) {
            resolvePR(pr, local: local)
        } else {
            reviewDestination.wait("Choose the existing local checkout for \(pr.repositoryKey).",
                                   actionTitle: "Choose checkout…") { [weak self] in self?.choosePRCheckout(pr) }
            choosePRCheckout(pr)
        }
    }
    private func choosePRCheckout(_ pr: GitHubPR) {
        guard let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.message = "Where is \(pr.repositoryKey) checked out? McDiff will remember this folder."
        picker.prompt = "Use checkout"
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let path = picker.url?.path else { return }
            if self.screen != .review || self.reviewDestination.intent != .pullRequest(pr) {
                self.navigateToReview(.pullRequest(pr))
            }
            self.resolvePR(pr, local: path)
        }
    }
    private func resolvePR(_ pr: GitHubPR, local: String) {
        guard let store, screen == .review, reviewDestination.intent == .pullRequest(pr) else { return }
        let previousPath = files.indices.contains(focused) ? files[focused].path : nil
        reviewDestination.load(store: store, github: github, checkout: local, accept: { [weak self] review in
            guard let self else { return }
            try self.installReview(review, previousPath: previousPath, mapping: (pr.repositoryKey.lowercased(), local))
        }, failureAction: { [weak self] error in
            if case GitHubError.unauthenticated = error {
                return ("Sign in", {
                    self?.setAccount(.signedOut)
                    self?.pendingPR = pr.url
                    self?.signIn()
                })
            }
            if error is GitError { return ("Choose checkout…", { self?.choosePRCheckout(pr) }) }
            return ("Retry", { self?.resolvePR(pr, local: local) })
        })
    }
    func load(_ request: ComparisonRequest) {
        guard let store, window?.attachedSheet == nil, finishSheet == nil, settleDraft() else { return }
        let previousPath = files.indices.contains(focused) ? files[focused].path : nil
        navigateToReview(.local(request))
        reviewDestination.load(store: store, github: github, accept: { [weak self] review in
            try self?.installReview(review, previousPath: previousPath)
        })
    }
    private func installReview(_ review: PreparedReview, previousPath: String?, mapping: (String, String)? = nil) throws {
        let request = review.snapshot.request
        var updated = preferences
        if let mapping { updated.repositoryMappings[mapping.0] = mapping.1 }
        updated.recentComparisons.removeAll { $0 == request || ($0.pullRequestURL != nil && $0.pullRequestURL == request.pullRequestURL) }
        updated.recentComparisons.insert(request, at: 0)
        updated.recentComparisons = Array(updated.recentComparisons.prefix(12))
        try store?.savePreferences(updated)
        preferences = updated
        snapshot = review.snapshot
        progress = review.progress
        search.stringValue = ""
        search.placeholderString = Self.searchPlaceholder(for: review.snapshot)
        search.toolTip = "\(review.snapshot.title)\nSearch paths and displayed text (⌘F)"
        searchItem.toolTip = search.toolTip
        home.resumeTitle = review.snapshot.title
        sortFiles()
        diff.expanded = Set(files.filter { preferences.filters.skipReason(for: $0) == nil && !isReviewed($0) }.map(\.path))
        diff.filters = preferences.filters
        diff.markdownContent = review.markdown
        searchMatchingFiles = nil
        diff.setComments(progress.comments)
        let contextSource = ContextSource(snapshot: review.snapshot)
        diff.contexts.resolve = { file in try await contextSource.presentation(file: file) }
        diff.contexts.load = { file, section in try await contextSource.lines(file: file, section: section) }
        diff.setFiles(files, presentations: review.presentations)
        diff.search(query: "")
        rebuildSidebar()
        window?.title = "McDiff — \(review.snapshot.title)"
        let index = previousPath.flatMap { path in files.firstIndex { $0.path == path } } ?? 0
        if !files.isEmpty { diff.navigate(to: index, expand: false); focus(index) }
        if files.isEmpty { showStatus("No changes in this comparison.") }
    }
    private func sortFiles() {
        files = (snapshot?.files ?? []).sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : a < b
        }
        sidebarNames = SidebarFileNames.labels(for: files.map(\.path))
    }
    private func rank(_ file: FileDiff) -> Int {
        switch file.category {
        case .production: return preferences.filters.skipReason(for: file) == nil ? 0 : 1
        case .tests: return 2
        case .documentation: return 3
        case .generated: return 4
        }
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
        reviewActions?.isEnabled = (hasFile || !progress.comments.isEmpty) && !busy
        for item in reviewActions?.subitems.dropFirst() ?? [] {
            item.isEnabled = hasFile && !busy
        }
        finishButton?.isEnabled = snapshot != nil && !busy
        diff.finishReviewEnabled = isReviewReady && !busy
        refreshButton?.isEnabled = snapshot != nil && !busy
        let commentCount = isReviewReady ? progress.comments.count : 0
        commentsButton?.toolTip = "\(commentCount) comments"
        commentsButton?.badge = .count(commentCount)
        commentsButton?.isEnabled = !progress.comments.isEmpty && !busy
        wrapButton?.isEnabled = !busy
        layoutButton?.isEnabled = snapshot != nil && !busy
        searchItem.isEnabled = isReviewReady
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
                self?.finishButton?.toolTip = "Finish review"
            }
        }
        statusDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }
    private func updateFilters() {
        testsFilter.state = preferences.filters.tests ? .off : .on
        docsFilter.state = preferences.filters.documentation ? .off : .on
        noiseFilter.state = preferences.filters.generated ? .off : .on
        whitespaceAndImportsFilter.state = preferences.filters.whitespaceAndImports ? .off : .on
        metaChangesFilter.state = preferences.filters.metaChanges ? .off : .on
    }
    @objc private func filtersChanged() {
        let previous = preferences.filters
        preferences.filters = ReviewFilters(tests: testsFilter.state == .off, documentation: docsFilter.state == .off,
                                            generated: noiseFilter.state == .off, whitespaceAndImports: whitespaceAndImportsFilter.state == .off,
                                            metaChanges: metaChangesFilter.state == .off)
        do { try savePreferences() } catch { preferences.filters = previous; updateFilters(); showError(error, title: "Could not save filters"); return }
        Style.animateStateChange(sidebar.enclosingScrollView?.contentView)
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
        guard !busy else { return }
        let previous = preferences.softWrap
        preferences.softWrap.toggle()
        do { try savePreferences(); diff.softWrap = preferences.softWrap }
        catch {
            preferences.softWrap = previous
            showError(error, title: "Could not save wrapping preference")
        }
        updateWrapButton()
    }
    private func updateWrapButton() {
        let title = preferences.softWrap ? "Wrap on" : "Wrap off"
        wrapButton?.title = title
        wrapButton?.label = title
        wrapButton?.paletteLabel = title
        wrapButton?.toolTip = preferences.softWrap ? "Turn soft wrapping off" : "Turn soft wrapping on"
        let image = Icons.image(.wrap)
        wrapButton?.image = preferences.softWrap
            ? image.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : image
    }
    @objc private func layoutChanged() {
        guard !busy, settleDraft() else { return }
        let previous = preferences.diffLayout
        preferences.diffLayout = previous == .split ? .unified : .split
        do {
            try savePreferences()
            diff.diffLayout = preferences.diffLayout
            updateLayoutButton()
        } catch {
            preferences.diffLayout = previous
            showError(error, title: "Could not save diff layout")
        }
    }
    private func updateLayoutButton() {
        let title = preferences.diffLayout == .split ? "Unified" : "Split"
        layoutButton?.title = title
        layoutButton?.label = title
        layoutButton?.paletteLabel = title
        layoutButton?.toolTip = "Switch to \(title.lowercased()) diff"
        layoutButton?.image = Icons.image(preferences.diffLayout == .split ? .unified : .split)
    }
    private func savePreferences() throws { try store?.savePreferences(preferences) }
    private func saveProgress() throws {
        if let snapshot { try store?.saveProgress(progress, identity: snapshot.identity) }
    }
    @objc private func markAndNext() {
        guard screen == .review, !busy, files.indices.contains(focused) else { return }
        let file = files[focused], prior = progress
        progress.reviewed[file.path] = file.fingerprint
        do { try saveProgress() } catch { progress = prior; showError(error, title: "Could not save review progress"); return }
        diff.expanded.remove(file.path)
        let next = ((focused + 1)..<files.count).first { !isReviewed(files[$0]) } ?? (0..<focused).first { !isReviewed(files[$0]) }
        diff.rebuild()
        refreshReviewState()
        if let next { diff.navigate(to: next); focus(next) }
        else { showStatus("All files reviewed."); diff.navigate(to: focused, expand: false) }
        updateActions()
    }
    private func setReviewed(_ file: FileDiff, reviewed: Bool) {
        guard isReviewReady, !busy, preferences.filters.skipReason(for: file) == nil else { return }
        let prior = progress
        if reviewed { progress.reviewed[file.path] = file.fingerprint }
        else { progress.reviewed.removeValue(forKey: file.path) }
        do {
            try saveProgress()
            if let index = files.firstIndex(where: { $0.path == file.path }) {
                diff.setExpanded(!reviewed, file: index)
            }
        } catch { progress = prior; showError(error, title: "Could not save review progress") }
        diff.redraw(); refreshReviewState(); updateActions()
    }
    private func refreshReviewState() {
        let visible = sidebar.rows(in: sidebar.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) where sidebarIndices.indices.contains(row) {
            guard let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { continue }
            let file = files[sidebarIndices[row]]
            cell.configure(file: file, title: sidebarNames[file.path]!, reviewed: isReviewed(file), reason: preferences.filters.skipReason(for: file))
        }
    }
    @objc private func previousFile() { if screen == .review, !busy, focused > 0 { diff.navigate(to: focused - 1) } }
    @objc private func nextFile() { if screen == .review, !busy, focused + 1 < files.count { diff.navigate(to: focused + 1) } }
    @objc private func refresh() {
        if screen == .home {
            switch account {
            case .signedIn: home.refresh()
            case .failed: bootstrapAccount()
            case .signedOut: signIn()
            case .checking: break
            }
            return
        }
        if !isReviewReady, let intent = reviewDestination.intent {
            switch intent {
            case .local(let request): load(request)
            case .pullRequest(let pr): openPR(pr.url)
            }
        } else if let request = snapshot?.request {
            if let url = request.pullRequestURL { openPR(url) } else { load(request) }
        }
    }
    private func editComment(selection: LineSelection) {
        guard screen == .review, !busy, files.indices.contains(selection.file) else { return }
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
        diff.setComments(progress.comments); sidebar.reloadData(); updateActions()
    }
    @objc private func commentOnSelection() { if let selection = diff.selection { editComment(selection: selection) } }
    @objc private func showComments(_ sender: Any?) {
        guard screen == .review, !busy else { return }
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
        guard screen == .review, !busy, progress.comments.indices.contains(sender.tag) else { return }
        let comment = progress.comments[sender.tag]
        if let index = files.firstIndex(where: { $0.path == comment.path }) { diff.navigate(to: index) }
        presentComment(comment, isNew: false)
    }
    @objc func finishReview() {
        guard let sheet = prepareFinishReview(), let window else { return }
        window.beginSheet(sheet.window!)
    }
    func prepareFinishReview(pasteboard: NSPasteboard = .general) -> FinishReviewSheet? {
        guard screen == .review, !busy, let snapshot, let store, let window,
              window.attachedSheet == nil, settleDraft() else { return nil }
        let text = ReviewExport.markdown(snapshot: snapshot, progress: progress)
        let sheet = FinishReviewSheet { [weak self] action in
            self?.handleFinishAction(action, text: text, pasteboard: pasteboard, snapshot: snapshot, store: store)
        }
        finishSheet = sheet
        handleFinishAction(.copy, text: text, pasteboard: pasteboard, snapshot: snapshot, store: store)
        updateActions()
        return sheet
    }
    private func handleFinishAction(_ action: FinishReviewSheet.Action, text: String, pasteboard: NSPasteboard,
                                    snapshot: ReviewSnapshot, store: ReviewStore) {
        guard let sheet = finishSheet, finishTask == nil, sheet.window?.attachedSheet == nil else { return }
        switch action {
        case .copy:
            do {
                try ReviewOutput.copy(text: text, pasteboard: pasteboard)
                sheet.render(message: "Review copied to clipboard.")
            } catch { sheet.render(message: error.localizedDescription, failed: true) }
        case .cancel:
            closeFinishSheet(.cancelled)
        case .export:
            guard let window = sheet.window else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "review.md"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self, weak sheet] response in
                guard let self, let sheet, self.finishSheet === sheet,
                      response == .OK, let url = panel.url else { return }
                sheet.render(message: "Exporting review…", working: true)
                self.finishTask = Task { [weak self, weak sheet] in
                    do {
                        try await ReviewOutput.export(text: text, to: url)
                        sheet?.render(message: "Exported \(url.lastPathComponent).")
                    } catch {
                        sheet?.render(message: "Could not export: \(error.localizedDescription) Try Export again.", failed: true)
                    }
                    self?.finishTask = nil
                }
            }
        case .reset, .finish:
            sheet.render(message: "Archiving review…", working: true)
            let completion: FinishReviewSheet.Completion = action == .reset ? .reset : .finished
            finishTask = Task { [weak self, weak sheet] in
                do {
                    _ = try await Task.detached {
                        if action == .reset { return try store.resetReview(snapshot: snapshot) }
                        return try store.finishReview(snapshot: snapshot)
                    }.value
                    self?.finishTask = nil
                    self?.closeFinishSheet(completion)
                } catch {
                    self?.finishTask = nil
                    sheet?.render(message: "Could not archive: \(error.localizedDescription) Your active review is unchanged. Try again.", failed: true)
                }
            }
        }
    }
    private func closeFinishSheet(_ completion: FinishReviewSheet.Completion) {
        finishSheet?.dismiss()
        finishSheet = nil
        switch completion {
        case .cancelled: break
        case .reset: resetCompletedReview()
        case .finished: clearCompletedReview()
        }
        updateActions()
    }
    static func searchPlaceholder(for snapshot: ReviewSnapshot) -> String {
        if let url = snapshot.request.pullRequestURL, let pr = try? GitHubPR.parse(url) {
            return "Search PR #\(pr.number) \(snapshot.request.pullRequestTitle ?? pr.repositoryKey)"
        }
        let repository = URL(fileURLWithPath: snapshot.request.repository).lastPathComponent
        func shortRef(_ value: String) -> String {
            [40, 64].contains(value.count) && value.allSatisfy { $0.isASCII && $0.isHexDigit }
                ? String(value.prefix(8)) : value
        }
        return "Search \(repository): \(shortRef(snapshot.request.base)) → \(snapshot.request.target.map(shortRef) ?? "Working tree")"
    }
    private func resetCompletedReview() {
        let currentFile = focused
        progress = ReviewProgress()
        commentEditor = nil
        diff.setComments([])
        diff.expanded = Set(files.filter { preferences.filters.skipReason(for: $0) == nil }.map(\.path))
        diff.setFiles(files, presentations: diff.presentations)
        rebuildSidebar()
        if files.indices.contains(currentFile) { diff.navigate(to: currentFile, expand: false) }
    }
    private func clearCompletedReview() {
        reviewDestination.cancel()
        snapshot = nil
        progress = ReviewProgress()
        commentEditor = nil
        files = []
        focused = 0
        search.stringValue = ""
        search.placeholderString = "Search review…"
        searchMatchingFiles = nil
        diff.expanded = []
        diff.markdownContent = [:]
        diff.setComments([])
        diff.setFiles([], presentations: [:])
        diff.contexts.load = nil
        diff.contexts.resolve = nil
        diff.search(query: "")
        home.resumeTitle = nil
        screen = .home
        rebuildSidebar()
        updateComparisonPresentation()
        window?.title = "McDiff"
        window?.makeFirstResponder(home.table)
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
    @objc private func findInReview() {
        guard screen == .home || isReviewReady else { return }
        (screen == .home ? home.searchItem : searchItem).beginSearchInteraction()
    }

    @objc func paste(_ sender: Any?) {
        guard let url = PRDropView.pullRequest(from: .general) else { NSSound.beep(); return }
        openPR(url.url)
    }

    @objc func showHome() {
        guard finishSheet == nil, window?.attachedSheet == nil, settleDraft() else { return }
        Style.animateStateChange(window?.contentView)
        screen = .home
        pendingPR = nil
        reviewDestination.cancel()
        updateComparisonPresentation()
        window?.makeFirstResponder(home.table)
    }

    func resumeReview() {
        guard snapshot != nil, !busy, window?.attachedSheet == nil, settleDraft() else { return }
        Style.animateStateChange(window?.contentView)
        screen = .review
        reviewDestination.resume(isEmpty: files.isEmpty)
        updateComparisonPresentation()
        window?.makeFirstResponder(diff)
    }

    func bootstrapAccount() {
        guard accountTask == nil else { return }
        setAccount(.checking)
        if pendingPR != nil, screen == .review, case .pullRequest = reviewDestination.intent {
            reviewDestination.wait("Checking GitHub sign-in…")
        }
        accountTask = Task { [weak self, github] in
            do {
                let user = try await github.currentUser()
                guard let self else { return }
                self.accountTask = nil
                self.setAccount(user.map(Account.signedIn) ?? .signedOut)
                self.continuePendingPR()
            } catch {
                guard let self else { return }
                self.accountTask = nil
                if case GitHubError.unauthenticated = error {
                    self.setAccount(.signedOut)
                    self.continuePendingPR()
                } else {
                    self.setAccount(.failed)
                    self.home.setUnavailable("Couldn’t check GitHub sign-in. Refresh to retry.\n\(error.localizedDescription)")
                    if self.screen == .review, case .pullRequest = self.reviewDestination.intent {
                        self.reviewDestination.fail("Couldn’t check GitHub sign-in.\n\(error.localizedDescription)",
                                                    actionTitle: "Retry") { [weak self] in self?.bootstrapAccount() }
                    }
                }
            }
        }
    }

    private func setAccount(_ value: Account) {
        account = value
        avatarTask?.cancel()
        let item = toolbarItems[.init("account")]
        item?.image = Icons.image(.account)
        setActivity(.account, active: false)
        item?.isEnabled = true
        switch value {
        case .checking:
            setActivity(.account, active: true)
            item?.label = "Checking GitHub sign-in"
            item?.isEnabled = false
            home.setUnavailable("Checking GitHub sign-in…")
        case .signedOut:
            item?.label = "Sign in to GitHub"
            home.setUnavailable("Sign in to GitHub to see your open pull requests.", clearResults: true)
        case .signedIn(let user):
            item?.label = "Sign in to GitHub (\(user.login))"
            loadAvatar(user)
            home.setUnavailable(nil, clearResults: true)
            home.refresh()
        case .failed:
            item?.label = "Retry GitHub sign-in"
        }
        item?.toolTip = item?.label
    }

    @objc private func accountAction() {
        guard accountTask == nil, !busy, window?.attachedSheet == nil, settleDraft() else { return }
        switch account {
        case .checking: break
        case .signedOut, .failed, .signedIn: signIn()
        }
    }

    private func loadAvatar(_ user: GitHubUser) {
        guard let url = user.avatarURL, url.scheme == "https" else { return }
        avatarTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let image = NSImage(data: data) else { throw GitHubError.invalidResponse }
                self?.toolbarItems[.init("account")]?.image = Self.toolbarAvatar(from: image)
            } catch is CancellationError {
            } catch {
                NSLog("Could not load GitHub avatar: %@", error.localizedDescription)
            }
        }
    }

    static func toolbarAvatar(from image: NSImage) -> NSImage {
        // 24 points is the largest image that preserves the native circular toolbar button.
        let size = NSSize(width: 24, height: 24)
        let circular = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
        circular.isTemplate = false
        return circular
    }

    private func signIn() {
        guard let window, window.attachedSheet == nil, settleDraft() else { return }
        signInSheet = GitHubSignInController(client: github, onSignedIn: { [weak self] user in
            guard let self else { return }
            self.signInSheet = nil
            self.setAccount(.signedIn(user))
            self.continuePendingPR()
        }, onCancelled: { [weak self] in
            self?.pendingPR = nil
            self?.signInSheet = nil
        })
        signInSheet?.present(on: window)
    }

    private func continuePendingPR() {
        guard let url = pendingPR else { return }
        pendingPR = nil
        guard screen == .review, case .pullRequest(let pr) = reviewDestination.intent, pr.url == url else { return }
        continuePR(pr)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openComparison), #selector(openRecent(_:)), #selector(showRecent(_:)):
            return screen == .home && !busy && window?.attachedSheet == nil
        case #selector(refresh):
            return !busy && window?.attachedSheet == nil
        case #selector(findInReview): return screen == .home || isReviewReady
        case #selector(finishReview):
            return isReviewReady && !busy && !(window?.firstResponder is NSTextView)
                && !(NSApp.keyWindow?.firstResponder is NSTextView)
        case #selector(paste(_:)):
            return finishSheet == nil && window?.attachedSheet == nil && PRDropView.pullRequest(from: .general) != nil
        case #selector(showHome):
            return finishSheet == nil && window?.attachedSheet == nil
        default: return screen == .review && snapshot != nil && !busy
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard isReviewReady, obj.object as? NSSearchField === search else { return }
        diff.search(query: search.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isReviewReady, control === search, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
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
        cell.configure(file: file, title: sidebarNames[file.path]!, reviewed: isReviewed(file), reason: preferences.filters.skipReason(for: file))
        cell.onToggle = { [weak self] reviewed in self?.setReviewed(file, reviewed: reviewed) }
        return cell
    }
    @objc private func sidebarSelected() {
        guard isReviewReady, !busy else { return }
        let row = sidebar.selectedRow
        if sidebarIndices.indices.contains(row) { diff.navigate(to: sidebarIndices[row], animated: true) }
    }
    private func showError(_ error: Error, title: String, recovery: String? = nil, action: (() -> Void)? = nil) {
        NSLog("%@: %@", title, error.localizedDescription)
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let recovery { alert.addButton(withTitle: recovery) }
        for button in alert.buttons { button.bezelStyle = .glass }
        alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { action?() } }
    }
}

private final class ReviewSidebarTableView: NSTableView {
    var onToggleReviewed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") {
            onToggleReviewed?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class FileCell: NSTableCellView {
    private let name = Style.label("", size: 12, weight: .medium)
    private let check = AnimatedCheckbox(checkboxWithTitle: "", target: nil, action: nil)
    private var path: String?
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
    func configure(file: FileDiff, title: String, reviewed: Bool, reason: String?) {
        if path == file.path, (check.state == .on) != reviewed { Style.animateStateChange(check) }
        path = file.path
        name.stringValue = title
        name.textColor = reviewed ? .secondaryLabelColor : .labelColor
        check.configureReview(reviewed: reviewed, reason: reason)
        toolTip = title
    }
}
