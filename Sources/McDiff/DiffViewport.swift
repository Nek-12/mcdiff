import AppKit
import CoreText
import McDiffCore

enum CanvasContent {
    case file
    case hunk(String)
    case code(DiffPair)
    case imports([DiffPair], Int)
    case context(UnchangedSection)
    case notice(String)
    case markdown
    case padding
}

struct CanvasRow {
    let file: Int
    let content: CanvasContent
    var sourceSide: DiffSide? = nil

    func line(on side: DiffSide) -> DiffLine? {
        guard case .code(let pair) = content else { return nil }
        let line = side == .old ? pair.old : pair.new
        return sourceSide == nil || sourceSide == side || line?.kind == .context ? line : nil
    }
    var height: CGFloat {
        switch content {
        case .file: return 38
        case .hunk: return 14
        case .code: return Style.rowHeight
        case .imports, .context: return 30
        case .notice: return 44
        case .markdown: return 120
        case .padding: return 0
        }
    }
}

struct LineSelection {
    let file: Int
    let side: DiffSide
    let start: Int
    let end: Int
}

final class HighlightBox: NSObject {
    let value: HighlightedFile
    init(_ value: HighlightedFile) { self.value = value }
}

final class DiffViewport: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = FadingScrollView()
    let table = DiffTable()
    let pinnedHeader = PinnedFileHeader()
    let contexts = ContextSections()
    private var horizontalMetrics: [String: FileHorizontalMetrics] = [:]
    var files: [FileDiff] = []
    var presentations: [String: [PresentedRow]] = [:]
    var markdownContent: [String: MarkdownFileContent] = [:] {
        didSet {
            markdownTask?.cancel(); markdownTask = nil
            markdownLayouts.removeAllObjects()
            visibleMarkdown.removeAll()
            redraw(); pumpMarkdown()
            if !searchQuery.isEmpty { search(query: searchQuery) }
        }
    }
    private var markdownSourcePaths: Set<String> = []

    func rendersMarkdown(_ file: FileDiff) -> Bool {
        !file.isBinary && RenderedMarkdown.accepts(file.path) && !markdownSourcePaths.contains(file.path)
    }

    func toggleMarkdown(for index: Int) {
        guard files.indices.contains(index), !files[index].isBinary, RenderedMarkdown.accepts(files[index].path) else { return }
        let path = files[index].path
        if markdownSourcePaths.contains(path) { markdownSourcePaths.remove(path) }
        else { markdownSourcePaths.insert(path) }
        if selection?.file == index { selection = nil }
        markdownTask?.cancel(); markdownTask = nil
        visibleMarkdown.removeAll()
        replaceFileRows(at: index)
        if !searchQuery.isEmpty { search(query: searchQuery) }
    }
    private func replaceFileRows(at index: Int, preserving anchor: Int? = nil) {
        guard let header = headerRows[index] else { return }
        let end = headerRows[index + 1] ?? (rows.count - 1)
        replaceRows(in: header..<end, with: fileRows(at: index), preserving: anchor ?? header)
    }
    func setExpanded(_ value: Bool, file index: Int) {
        let path = files[index].path
        guard expanded.contains(path) != value else { return }
        if value { expanded.insert(path) } else { expanded.remove(path) }
        replaceFileRows(at: index)
    }
    private func replaceRows(in range: Range<Int>, with replacement: [CanvasRow], preserving anchor: Int) {
        stopNavigation()
        Style.animateStateChange(scroll.contentView)
        preservingScrollAnchor(row: anchor) {
            // Preserve measured geometry outside the changed section; it defines
            // the clicked header's position while replacement heights are prepared.
            if rowHeights.count == rows.count {
                rowHeights.replaceSubrange(range, with: replacement.map(\.height))
            }
            rows.replaceSubrange(range, with: replacement)
            indexHeaders()
            table.reloadData()
            prepareLayout(preserving: anchor)
        }
        visibleChanged()
    }
    private(set) var rows: [CanvasRow] = []
    private(set) var headerRows: [Int: Int] = [:]
    var expanded: Set<String> = []
    var expandedImports: Set<String> = []
    var filters = ReviewFilters()
    var isReviewed: (FileDiff) -> Bool = { _ in false }
    var onReviewToggle: ((FileDiff, Bool) -> Void)?
    private var comments: [String: [DiffSide: [ReviewComment]]] = [:]
    private var numberWidths: [CGFloat] = []

    func setComments(_ values: [ReviewComment]) {
        let previous = files.indices.map { [commentRailWidth(file: $0, side: .old), commentRailWidth(file: $0, side: .new)] }
        comments = Dictionary(grouping: values, by: \.path).mapValues { Dictionary(grouping: $0, by: \.side) }
        let current = files.indices.map { [commentRailWidth(file: $0, side: .old), commentRailWidth(file: $0, side: .new)] }
        if previous != current { prepareLayout() }
        redraw()
    }

    func commentRange(_ path: String, _ side: DiffSide, _ line: Int) -> ClosedRange<Int>? {
        comments[path]?[side]?.first { ($0.startLine...$0.endLine).contains(line) }.map { $0.startLine...$0.endLine }
    }
    var onFocus: ((Int) -> Void)?
    var onComment: ((LineSelection) -> Void)?
    var selection: LineSelection?
    var focusedFile = 0
    private var rowHeights: [CGFloat] = []
    private var layoutTask: Task<Void, Never>?
    private(set) var isLayoutPending = false
    private var measuredPaneWidth: CGFloat = 0
    var onLayoutBusy: ((Bool) -> Void)?
    var onSearchResults: (([Int], Int) -> Void)?
    var onSearchBusy: ((Bool) -> Void)?
    private(set) var searchQuery = ""
    private(set) var isSearchPending = false
    private(set) var currentSearchMatch: DiffSearchMatch?
    private let searchEngine = DiffSearchEngine()
    private var searchTask: Task<Void, Never>?
    private var searchResults: DiffSearchResults?
    private var searchIndex = -1
    var softWrap = false {
        didSet {
            guard softWrap != oldValue else { return }
            for path in horizontalMetrics.keys {
                horizontalMetrics[path]?.oldOffset = 0
                horizontalMetrics[path]?.newOffset = 0
                horizontalMetrics[path]?.unifiedOffset = 0
            }
            prepareLayout()
            redraw()
        }
    }
    var diffLayout: DiffLayout = .split {
        didSet {
            guard diffLayout != oldValue else { return }
            let file = focusedFile
            Style.animateStateChange(scroll.contentView)
            markdownTask?.cancel(); markdownTask = nil
            markdownLayouts.removeAllObjects(); visibleMarkdown.removeAll()
            markdownHeights.removeAll()
            markdownWidth = paneWidth
            rebuild(keeping: file)
            if !searchQuery.isEmpty { search(query: searchQuery, preserving: currentSearchMatch) }
        }
    }
    var paneWidth: CGFloat { scroll.contentSize.width / (diffLayout == .split ? 2 : 1) }
    func sourceGutter(file: Int) -> SourceGutter {
        SourceGutter(layout: diffLayout, numberWidth: numberWidths[file])
    }
    func sourceTextInset(file: Int) -> CGFloat { sourceGutter(file: file).textLeading }
    private func commentSides(file: Int, side: DiffSide) -> [DiffSide] {
        let sides: [DiffSide] = diffLayout == .split ? [side] : [.old, .new]
        return sides.filter { comments[files[file].path]?[$0] != nil }
    }
    func commentRailWidth(file: Int, side: DiffSide) -> CGFloat {
        CGFloat(commentSides(file: file, side: side).count) * 24
    }
    /// Pane-local marker bounds. Unified context retains independent old/new targets.
    func commentMarkerRect(file: Int, side: DiffSide) -> NSRect? {
        let sides = commentSides(file: file, side: side)
        guard let index = sides.firstIndex(of: side) else { return nil }
        return NSRect(x: paneWidth - CGFloat(sides.count - index) * 24 + 4, y: 3, width: 16, height: 16)
    }
    func textWidth(file: Int, side: DiffSide) -> CGFloat {
        max(1, paneWidth - sourceTextInset(file: file) - 8 - commentRailWidth(file: file, side: side))
    }
    private let highlights = NSCache<NSString, HighlightBox>()
    private let lineBreaks = NSCache<NSString, DiffTextLayout.Breaks>()
    private var highlightTask: Task<Void, Never>?
    private let syntax = SyntaxService()
    private var failedHighlights: Set<String> = []
    var onHighlightError: ((Error) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var navigationAnimation: FileNavigationAnimation?
    private var paddingHeight: CGFloat = 1
    private let markdownLayouts = NSCache<NSString, MarkdownPairLayout>()
    private let markdownRenderer = MarkdownLayoutService()
    private var visibleMarkdown: [NSString: MarkdownPairLayout] = [:]
    private var markdownHeights: [String: CGFloat] = [:]
    private var markdownTask: Task<Void, Never>?
    private var markdownWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        contexts.onChange = { [weak self] path, section in self?.contextChanged(path: path, section: section) }
        highlights.totalCostLimit = 48 * 1024 * 1024
        markdownLayouts.totalCostLimit = 32 * 1024 * 1024
        markdownLayouts.countLimit = 12
        lineBreaks.totalCostLimit = 4 * 1024 * 1024
        table.owner = self
        table.style = .plain
        table.headerView = nil
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = Style.canvas
        table.usesAlternatingRowBackgroundColors = false
        table.rowSizeStyle = .custom
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self; table.delegate = self
        scroll.contentView = VerticalClipView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.topFadeHeight = 0
        scroll.backgroundColor = Style.canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        pinnedHeader.cell.owner = self
        pinnedHeader.isHidden = true
        addSubview(pinnedHeader)
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.updatePinnedHeader()
            // AppKit also posts while calculating row geometry. Observe after that
            // transaction so focus changes never reenter table layout.
            DispatchQueue.main.async { self?.visibleChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
            object: scroll, queue: .main) { [weak self] _ in self?.stopNavigation() })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        navigationAnimation?.stop()
        highlightTask?.cancel(); layoutTask?.cancel(); markdownTask?.cancel(); searchTask?.cancel()
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.tableColumns.first?.width = scroll.contentSize.width
        let padding = max(1, scroll.contentSize.height - 38)
        if padding != paddingHeight {
            paddingHeight = padding
            if !rows.isEmpty { updateRowHeights(IndexSet(integer: rows.count - 1)) }
        }
        if softWrap && measuredPaneWidth != paneWidth { prepareLayout() }
        if markdownWidth != paneWidth {
            markdownWidth = paneWidth
            markdownTask?.cancel(); markdownTask = nil
            markdownLayouts.removeAllObjects()
            visibleMarkdown.removeAll()
            redraw()
            pumpMarkdown()
        }
        updatePinnedHeader()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlights.removeAllObjects()
        failedHighlights.removeAll()
        markdownTask?.cancel(); markdownTask = nil
        markdownLayouts.removeAllObjects()
        visibleMarkdown.removeAll()
        table.backgroundColor = Style.canvas
        scroll.backgroundColor = Style.canvas
        redraw()
        visibleChanged()
    }
    func setFiles(_ files: [FileDiff], presentations: [String: [PresentedRow]]) {
        contexts.clear()
        stopNavigation()
        highlightTask?.cancel()
        highlightTask = nil
        self.files = files; self.presentations = presentations
        numberWidths = files.map { file in
            let maximum = file.hunks.lazy.flatMap(\.lines).reduce(1) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
            return SourceGutter.numberWidth(for: maximum)
        }
        markdownSourcePaths.removeAll()
        highlights.removeAllObjects(); failedHighlights.removeAll()
        markdownTask?.cancel(); markdownTask = nil
        markdownLayouts.removeAllObjects(); markdownHeights.removeAll()
        visibleMarkdown.removeAll()
        selection = nil; expandedImports.removeAll()
        horizontalMetrics.removeAll()
        rebuild()
        search(query: searchQuery)
    }
    func search(query: String, preserving preferredMatch: DiffSearchMatch? = nil) {
        let queryChanged = query != searchQuery
        searchTask?.cancel()
        searchQuery = query
        searchResults = nil
        searchIndex = -1
        currentSearchMatch = nil
        redraw()
        guard !query.isEmpty else {
            isSearchPending = false
            onSearchBusy?(false)
            onSearchResults?(Array(files.indices), 0)
            return
        }
        isSearchPending = true
        onSearchBusy?(true)
        let files = files, presentations = presentations, markdown = markdownContent, sourcePaths = markdownSourcePaths, layout = diffLayout
        let context = contexts.expandedPairs
        searchTask = Task { [weak self, searchEngine] in
            do {
                let results = try await searchEngine.search(query: query, files: files, presentations: presentations,
                                                            markdown: markdown, sourcePaths: sourcePaths, layout: layout, context: context)
                var index = 0
                if let preferredMatch { index = try await searchEngine.index(of: preferredMatch, in: results) ?? 0 }
                let first = try await searchEngine.resolve(results, at: index)
                guard !Task.isCancelled, let self else { return }
                self.searchResults = results
                self.searchIndex = first == nil ? -1 : index
                self.currentSearchMatch = first
                self.onSearchResults?(results.files, results.count)
                if queryChanged, let first { await self.revealSearchMatch(first) }
                guard !Task.isCancelled else { return }
                self.isSearchPending = false
                self.onSearchBusy?(false)
                self.redraw()
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected search failure: \(error)")
                NSLog("Search failed: %@", error.localizedDescription)
                guard !Task.isCancelled, let self else { return }
                self.isSearchPending = false
                self.onSearchBusy?(false)
            }
        }
    }
    func nextSearchMatch(backwards: Bool = false) {
        guard let results = searchResults, results.count > 0 else { return }
        searchTask?.cancel()
        searchIndex = (searchIndex + (backwards ? -1 : 1) + results.count) % results.count
        let index = searchIndex
        isSearchPending = true
        onSearchBusy?(true)
        searchTask = Task { [weak self, searchEngine] in
            do {
                let match = try await searchEngine.resolve(results, at: index)
                guard !Task.isCancelled, let self, let match else { return }
                self.currentSearchMatch = match
                await self.revealSearchMatch(match)
                guard !Task.isCancelled else { return }
                self.isSearchPending = false
                self.onSearchBusy?(false)
                self.redraw()
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected search navigation failure: \(error)")
                NSLog("Search navigation failed: %@", error.localizedDescription)
                guard !Task.isCancelled, let self else { return }
                self.isSearchPending = false
                self.onSearchBusy?(false)
            }
        }
    }
    private func revealSearchMatch(_ match: DiffSearchMatch) async {
        let file = match.target.file
        guard files.indices.contains(file) else { return }
        var changed = false
        switch match.target {
        case .path: break
        case .code(_, _, _, let block):
            changed = expanded.insert(files[file].path).inserted
            if let block { changed = expandedImports.insert(importKey(files[file].path, block)).inserted || changed }
        case .markdown:
            changed = expanded.insert(files[file].path).inserted
        }
        if changed { rebuild() }
        focusedFile = file
        onFocus?(file)
        scrollToSearchMatch(match)
        await layoutTask?.value
        guard !Task.isCancelled else { return }
        scrollToSearchMatch(match)
        if case .markdown = match.target {
            while markdownLayout(for: files[file]) == nil, let rendering = markdownTask {
                await rendering.value
                guard !Task.isCancelled else { return }
                scrollToSearchMatch(match)
            }
        }
    }
    private func scrollToSearchMatch(_ match: DiffSearchMatch) {
        stopNavigation()
        let file = match.target.file
        guard let header = headerRows[file] else { return }
        table.layoutSubtreeIfNeeded()
        var rect = table.rect(ofRow: header)
        switch match.target {
        case .path: break
        case .code(_, let side, let number, _):
            guard let row = rows.indices.first(where: {
                guard rows[$0].file == file, let line = rows[$0].line(on: side) else { return false }
                return (side == .old ? line.oldNumber : line.newNumber) == number
            }), case .code(let pair) = rows[row].content,
               let line = side == .old ? pair.old : pair.new else { return }
            let text = NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "),
                                          attributes: [.font: Style.codeFont])
            let fragments = textFragments(text, file: file, side: side)
            let fragment = fragments.firstIndex { NSIntersectionRange($0, match.range).length > 0 } ?? 0
            rect = table.rect(ofRow: row)
            rect.origin.y += CGFloat(fragment) * Style.rowHeight
            rect.size.height = Style.rowHeight
            if !softWrap {
                let ct = CTLineCreateWithAttributedString(text)
                let x = CTLineGetOffsetForStringIndex(ct, match.range.location, nil)
                let target = max(0, x - 24)
                scrollHorizontally(target - horizontalOffset(file: file, side: side), file: file, side: side)
            }
        case .markdown(_, let side):
            let row = header + 1
            guard rows.indices.contains(row), case .markdown = rows[row].content else { return }
            rect = table.rect(ofRow: row)
            if let pair = markdownLayout(for: files[file]) {
                let layout = side == .old ? pair.old : pair.new
                rect.origin.y += 18 + layout.rect(for: match.range).minY
                rect.size.height = max(Style.rowHeight, layout.rect(for: match.range).height)
            }
        }
        // Keep context around the match; unlike sidebar navigation this reveals
        // the occurrence, which may be deep inside a file or wrapped source line.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(table.rect(ofRow: header).minY, rect.minY - 80)))
        scroll.reflectScrolledClipView(scroll.contentView)
        visibleChanged()
    }
    func rebuild(keeping file: Int? = nil) {
        stopNavigation()
        rows = files.indices.flatMap { fileRows(at: $0) }
        if !files.isEmpty { rows.append(CanvasRow(file: files.count - 1, content: .padding)) }
        indexHeaders()
        rowHeights = []
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        prepareLayout()
        if let file { navigate(to: file, expand: false) }
        visibleChanged()
    }
    private func indexHeaders() {
        headerRows.removeAll(keepingCapacity: true)
        for (index, row) in rows.enumerated() {
            if case .file = row.content { headerRows[row.file] = index }
        }
    }
    private func fileRows(at index: Int) -> [CanvasRow] {
        let file = files[index]
        var result = [CanvasRow(file: index, content: .file)]
        guard expanded.contains(file.path) else { return result }
        if file.isBinary {
            result.append(CanvasRow(file: index, content: .notice("Binary file · contents are not rendered")))
        } else if rendersMarkdown(file) {
            result.append(CanvasRow(file: index, content: .markdown))
            return result
        } else if file.hunks.isEmpty {
            result.append(CanvasRow(file: index, content: .notice("Metadata-only change · \(file.status == "R" ? "renamed from " + file.oldPath : "file mode or identity changed")")))
        }
        var code: [DiffPair] = []
        let sections = Dictionary(uniqueKeysWithValues: file.unchangedSections.map { ($0.id, $0) })
        var hunk = -1
        func appendContext(_ hunkIndex: Int) {
            guard let section = sections[hunkIndex] else { return }
            result.append(CanvasRow(file: index, content: .context(section)))
            if case .expanded(let pairs) = contexts.state(path: file.path, section: section.id) {
                result += sourceRows(pairs, file: index)
            }
        }
        func flush() {
            result += sourceRows(code, file: index)
            code.removeAll(keepingCapacity: true)
        }
        for (block, presentation) in (presentations[file.path] ?? []).enumerated() {
            switch presentation {
            case .hunk(let text):
                flush()
                hunk += 1
                appendContext(hunk)
                if block > 0 && sections[hunk] == nil { result.append(CanvasRow(file: index, content: .hunk(text))) }
            case .code(let pair): code.append(pair)
            case .imports(let pairs):
                flush()
                result.append(CanvasRow(file: index, content: .imports(pairs, block)))
                if expandedImports.contains(importKey(file.path, block)) {
                    result += sourceRows(pairs, file: index)
                }
            }
        }
        flush()
        appendContext(file.hunks.count)
        return result
    }
    private func contextChanged(path: String, section: Int) {
        guard let file = files.firstIndex(where: { $0.path == path }) else { return }
        switch contexts.state(path: path, section: section) {
        case .loading, .failed, .empty:
            redraw()
            return
        case .expanded, nil: break
        }
        let anchor = rows.firstIndex {
            guard $0.file == file, case .context(let value) = $0.content else { return false }
            return value.id == section
        }
        highlightTask?.cancel(); highlightTask = nil
        highlights.removeAllObjects(); failedHighlights.removeAll()
        let originalMaximum = files[file].hunks.flatMap(\.lines).reduce(1) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        let maximum = (contexts.expandedPairs[path] ?? [:]).values.reduce(originalMaximum) {
            max($0, $1.last?.old?.oldNumber ?? 0, $1.last?.new?.newNumber ?? 0)
        }
        numberWidths[file] = SourceGutter.numberWidth(for: maximum)
        if let anchor { replaceFileRows(at: file, preserving: anchor) }
        if !searchQuery.isEmpty { search(query: searchQuery, preserving: currentSearchMatch) }
    }
    func contextTitle(file: Int, section: UnchangedSection) -> String {
        switch contexts.state(path: files[file].path, section: section.id) {
        case .loading: return "Loading unchanged lines…"
        case .expanded: return "Hide unchanged lines"
        case .empty: return "No more unchanged lines"
        case .failed(let message): return "\(message.replacingOccurrences(of: "\n", with: " ")) — Retry"
        case nil: return section.count == nil ? "Show rest of file" : "Show unchanged lines"
        }
    }
    private func sourceRows(_ pairs: [DiffPair], file: Int) -> [CanvasRow] {
        DiffPresentation.sourceRows(pairs, layout: diffLayout).map {
            CanvasRow(file: file, content: .code($0.pair), sourceSide: $0.side)
        }
    }
    func navigate(to file: Int, expand: Bool = true, animated: Bool = false) {
        guard files.indices.contains(file) else { return }
        stopNavigation()
        if expand && !expanded.contains(files[file].path) {
            expanded.insert(files[file].path)
            rebuild()
        }
        guard let destination = headerOffset(for: file) else { return }
        focusedFile = file
        onFocus?(file)
        if animated, abs(destination - scroll.documentVisibleRect.minY) > 1 {
            let animation = FileNavigationAnimation(viewport: self, file: file, origin: scroll.documentVisibleRect.minY)
            navigationAnimation = animation
            animation.start()
        } else {
            scrollVertically(to: destination)
        }
    }
    private func headerOffset(for file: Int) -> CGFloat? {
        guard let row = headerRows[file] else { return nil }
        table.layoutSubtreeIfNeeded()
        return min(table.rect(ofRow: row).minY, max(0, table.bounds.height - scroll.contentSize.height))
    }
    private func scrollVertically(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.layoutSubtreeIfNeeded()
        visibleChanged()
    }
    fileprivate func advanceNavigation(_ animation: FileNavigationAnimation) {
        guard navigationAnimation === animation, let destination = headerOffset(for: animation.file) else { return }
        scrollVertically(to: animation.origin + (destination - animation.origin) * CGFloat(animation.currentValue))
        if animation.currentProgress >= 1 { navigationAnimation = nil }
    }
    fileprivate func stopNavigation() {
        let animation = navigationAnimation
        navigationAnimation = nil
        animation?.stop()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .padding = rows[row].content { return paddingHeight }
        if case .markdown = rows[row].content { return markdownHeights[files[rows[row].file].path] ?? rows[row].height }
        return rowHeights.indices.contains(row) ? rowHeights[row] : rows[row].height
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("diff-row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DiffCell ?? DiffCell()
        cell.identifier = id
        cell.owner = self; cell.rowIndex = row
        cell.updateHeaderButton()
        cell.needsDisplay = true
        return cell
    }
    func richText(file: FileDiff, side: DiffSide, line: Int) -> NSAttributedString? {
        let value = highlights.object(forKey: highlightKey(file, page: max(0, line - 1) / SyntaxService.pageSize))?.value
        return side == .old ? value?.old[line] : value?.new[line]
    }
    func textFragments(_ text: NSAttributedString, file: Int, side: DiffSide) -> [NSRange] {
        guard softWrap else { return [NSRange(location: 0, length: text.length)] }
        let textWidth = textWidth(file: file, side: side)
        let key = "\(textWidth):\(text.string)" as NSString
        if let cached = lineBreaks.object(forKey: key) { return cached.ranges }
        let ranges = DiffTextLayout.ranges(text, width: textWidth)
        lineBreaks.setObject(DiffTextLayout.Breaks(ranges), forKey: key, cost: text.length * 2 + ranges.count * 16)
        return ranges
    }
    private func highlightKey(_ file: FileDiff, page: Int) -> NSString { "\(file.fingerprint):\(Style.dark):\(page)" as NSString }
    func redraw() {
        table.enumerateAvailableRowViews { row, _ in
            row.needsDisplay = true
            row.subviews.forEach {
                ($0 as? DiffCell)?.updateHeaderButton()
                $0.needsDisplay = true
            }
        }
        updatePinnedHeader()
    }
    private func updatePinnedHeader() {
        let top = scroll.documentVisibleRect.minY
        let row = table.row(at: NSPoint(x: 0, y: max(0, top)))
        guard rows.indices.contains(row), let header = headerRows[rows[row].file] else {
            pinnedHeader.isHidden = true
            return
        }
        let headerRect = table.rect(ofRow: header)
        let next = headerRows[rows[row].file + 1].map { table.rect(ofRow: $0).minY } ?? table.bounds.maxY
        let height = headerRect.height
        let offset = min(0, next - top - height)
        let visibleHeight = max(0, height + offset)
        pinnedHeader.isHidden = top < headerRect.minY || visibleHeight == 0
        pinnedHeader.frame = NSRect(x: scroll.frame.minX, y: scroll.frame.maxY - height,
                                    width: scroll.contentSize.width, height: height)
        pinnedHeader.setHeaderFrame(NSRect(x: 0, y: offset, width: pinnedHeader.bounds.width, height: height))
        pinnedHeader.cell.rowIndex = header
        pinnedHeader.cell.updateHeaderButton()
        pinnedHeader.cell.needsDisplay = true
        pinnedHeader.needsDisplay = true
    }
    private func visibleChanged() {
        updatePinnedHeader()
        let range = table.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0, !rows.isEmpty else { return }
        let start = min(range.location, rows.count - 1)
        let current = navigationAnimation?.file ?? rows[start].file
        if current != focusedFile { focusedFile = current; onFocus?(current) }
        pumpHighlight()
        pumpMarkdown()
    }
    private func markdownKey(_ file: FileDiff) -> NSString {
        "\(file.path):\(file.fingerprint):\(markdownWidth):\(diffLayout):\(Style.dark)" as NSString
    }
    func markdownLayout(for file: FileDiff) -> MarkdownPairLayout? {
        visibleMarkdown[markdownKey(file)] ?? markdownLayouts.object(forKey: markdownKey(file))
    }
    private func invalidateMarkdownHeights() {
        let indices = IndexSet(rows.indices.filter { if case .markdown = rows[$0].content { return true }; return false })
        guard !indices.isEmpty else { return }
        updateRowHeights(indices)
    }
    private func updateRowHeights(_ indices: IndexSet) {
        // AppKit otherwise animates cell frames after publishing final row
        // geometry, leaving newly revealed wrapped text outside the painted cell.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: indices)
        }
    }
    private func pumpMarkdown() {
        guard markdownTask == nil, paneWidth > 40 else { return }
        let range = table.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        let visible = rows[range.location..<min(rows.count, range.location + range.length)]
        let keys = Set(visible.compactMap { row -> NSString? in
            guard case .markdown = row.content else { return nil }
            return markdownKey(files[row.file])
        })
        visibleMarkdown = visibleMarkdown.filter { keys.contains($0.key) }
        for key in keys where visibleMarkdown[key] == nil {
            visibleMarkdown[key] = markdownLayouts.object(forKey: key)
        }
        guard let row = visible.first(where: {
            guard case .markdown = $0.content else { return false }
            let file = files[$0.file]
            return markdownContent[file.path] != nil && markdownContent[file.path]?.error == nil &&
                markdownLayout(for: file) == nil
        }) else { return }
        let file = files[row.file], key = markdownKey(files[row.file])
        guard let content = markdownContent[file.path] else { return }
        let width = max(1, paneWidth - 40), mode = diffLayout
        var color = NSColor.labelColor, secondary = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.labelColor.cgColor)!
            secondary = NSColor(cgColor: NSColor.secondaryLabelColor.cgColor)!
        }
        markdownTask = Task { [weak self, markdownRenderer] in
            let layout: MarkdownPairLayout
            do { layout = try await markdownRenderer.layout(content: content, width: width, color: color, secondary: secondary, mode: mode) }
            catch { return } // The renderer only throws cancellation.
            guard !Task.isCancelled, let self else { return }
            self.markdownLayouts.setObject(layout, forKey: key, cost: layout.cost)
            self.visibleMarkdown[key] = layout
            self.preservingScrollAnchor {
                self.markdownHeights[file.path] = layout.height
                self.invalidateMarkdownHeights()
            }
            self.redraw()
            self.markdownTask = nil
            self.pumpMarkdown()
        }
    }
    private func preservingScrollAnchor(row: Int? = nil, _ update: () -> Void) {
        let visible = table.rows(in: scroll.documentVisibleRect)
        let anchor = row ?? (visible.location != NSNotFound && visible.location < rows.count ? visible.location : nil)
        let inset = anchor.map {
            if row != nil, !pinnedHeader.isHidden, pinnedHeader.cell.rowIndex == $0 {
                return -pinnedHeader.cell.convert(pinnedHeader.cell.bounds, to: pinnedHeader).minY
            }
            return scroll.documentVisibleRect.minY - table.rect(ofRow: $0).minY
        } ?? 0
        update()
        table.layoutSubtreeIfNeeded()
        if let anchor {
            let rect = table.rect(ofRow: anchor)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + min(inset, max(0, rect.height - 1))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func pumpHighlight() {
        guard highlightTask == nil else { return }
        let range = table.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        let visible = rows[range.location..<min(rows.count, range.location + range.length)]
        let pages = visible.flatMap { row -> [(Int, Int)] in
            guard case .code(let pair) = row.content else { return [] }
            return [pair.old?.oldNumber, pair.new?.newNumber].compactMap { $0 }.map { (row.file, max(0, $0 - 1) / SyntaxService.pageSize) }
        }
        guard let (index, page) = pages.first(where: { index, page in
            let key = highlightKey(files[index], page: page)
            return highlights.object(forKey: key) == nil && !failedHighlights.contains(key as String)
        }) else { return }
        let file = files[index], key = highlightKey(file, page: page), dark = Style.dark
        let context = contexts.pageLines(path: file.path, page: page)
        highlightTask = Task { [weak self, syntax] in
            do {
                let value = try await syntax.highlight(file: file, dark: dark, page: page, context: context)
                guard !Task.isCancelled, let self else { return }
                self.highlights.setObject(HighlightBox(value), forKey: key, cost: value.cost)
                self.redraw()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failedHighlights.insert(key as String)
                self.onHighlightError?(error)
            }
            self?.highlightTask = nil
            self?.pumpHighlight()
        }
    }
    func hitsCode(row: Int, point: NSPoint) -> Bool {
        guard rows.indices.contains(row), case .code(let pair) = rows[row].content else { return false }
        let side = sourceSide(row: row, x: point.x)
        guard let line = side == .old ? pair.old : pair.new,
              let number = side == .old ? line.oldNumber : line.newNumber else { return false }
        let file = files[rows[row].file]
        let origin: CGFloat = diffLayout == .unified || side == .old ? 0 : table.bounds.width / 2
        let localX = point.x - origin
        let index = rows[row].file
        if let marker = commentMarkerRect(file: index, side: side),
           localX >= marker.minX && localX <= marker.maxX && commentRange(file.path, side, number) != nil { return true }
        let sourceTextInset = sourceTextInset(file: index)
        guard localX >= sourceTextInset,
              localX < sourceTextInset + textWidth(file: index, side: side),
              !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let rich = richText(file: file, side: side, line: number) ??
            NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: [.font: Style.codeFont])
        let fragments = textFragments(rich, file: index, side: side)
        let fragmentIndex = Int((point.y - table.rect(ofRow: row).minY) / Style.rowHeight)
        guard fragments.indices.contains(fragmentIndex) else { return false }
        let fragment = fragments[fragmentIndex]
        let ct = CTTypesetterCreateLine(CTTypesetterCreateWithAttributedString(rich),
                                       CFRange(location: fragment.location, length: fragment.length))
        let x = localX - sourceTextInset + horizontalOffset(file: rows[row].file, side: side)
        return x >= 0 && x <= CTLineGetTypographicBounds(ct, nil, nil, nil)
    }
    func sourceSide(row: Int, x: CGFloat) -> DiffSide {
        guard diffLayout == .unified, rows.indices.contains(row) else {
            return x < table.bounds.width / 2 ? .old : .new
        }
        if case .code(let pair) = rows[row].content,
           pair.new?.kind == .context, pair.old != nil {
            if let marker = commentMarkerRect(file: rows[row].file, side: .old),
               x >= marker.minX && x <= marker.maxX { return .old }
            return .new
        }
        return rows[row].sourceSide ?? .new
    }
    func click(row: Int, point: NSPoint, shift: Bool) {
        guard rows.indices.contains(row) else { return }
        stopNavigation()
        let item = rows[row], file = files[item.file]
        switch item.content {
        case .file:
            focusedFile = item.file
            setExpanded(!expanded.contains(file.path), file: item.file)
            onFocus?(item.file)
        case .imports(let pairs, let block):
            let key = importKey(file.path, block)
            let wasExpanded = expandedImports.contains(key)
            if wasExpanded { expandedImports.remove(key) } else { expandedImports.insert(key) }
            let code = sourceRows(pairs, file: item.file)
            let replacement = [item] + (wasExpanded ? [] : code)
            replaceRows(in: row..<(row + 1 + (wasExpanded ? code.count : 0)), with: replacement, preserving: row)
        case .context(let section):
            contexts.toggle(file: file, section: section)
        case .code(let pair):
            let side = sourceSide(row: row, x: point.x)
            guard let number = side == .old ? pair.old?.oldNumber : pair.new?.newNumber else { return }
            if shift, let selection, selection.file == item.file, selection.side == side {
                self.selection = LineSelection(file: item.file, side: side, start: min(selection.start, number), end: max(selection.start, number))
            } else {
                selection = LineSelection(file: item.file, side: side, start: number, end: number)
            }
            focusedFile = item.file; onFocus?(item.file)
            redraw()
        default: break
        }
    }
    func drag(row: Int, point: NSPoint, anchor: LineSelection) {
        stopNavigation()
        guard rows.indices.contains(row), rows[row].file == anchor.file,
              let line = rows[row].line(on: anchor.side),
              let number = anchor.side == .old ? line.oldNumber : line.newNumber else { return }
        selection = LineSelection(file: anchor.file, side: anchor.side, start: min(anchor.start, number), end: max(anchor.start, number))
        redraw()
    }
    var selectionAnchor: NSRect? {
        guard let selection, let row = rows.firstIndex(where: {
            guard $0.file == selection.file, let line = $0.line(on: selection.side) else { return false }
            return (selection.side == .old ? line.oldNumber : line.newNumber) == selection.end
        }) else { return nil }
        let rect = convert(table.rect(ofRow: row), from: table)
        return NSRect(x: diffLayout == .unified ? bounds.midX : selection.side == .old ? bounds.width * 0.25 : bounds.width * 0.75,
                      y: max(18, min(bounds.height - 22, rect.minY)), width: 1, height: Style.rowHeight)
    }
    func commitSelection() { if let selection { onComment?(selection) } }
    func horizontalOffset(file: Int, side: DiffSide) -> CGFloat {
        guard !softWrap, files.indices.contains(file), let value = horizontalMetrics[files[file].path] else { return 0 }
        let offset = diffLayout == .unified ? value.unifiedOffset : side == .old ? value.oldOffset : value.newOffset
        return min(offset, scrollableWidth(file: file, side: side))
    }
    func scrollableWidth(file: Int, side: DiffSide) -> CGFloat {
        guard !softWrap, files.indices.contains(file), !rendersMarkdown(files[file]),
              let value = horizontalMetrics[files[file].path] else { return 0 }
        let width = diffLayout == .unified ? max(value.oldWidth, value.newWidth) : side == .old ? value.oldWidth : value.newWidth
        return max(0, width - textWidth(file: file, side: side))
    }
    func scrollHorizontally(_ delta: CGFloat, file: Int, side: DiffSide) {
        guard files.indices.contains(file) else { return }
        let path = files[file].path
        var value = horizontalMetrics[path] ?? FileHorizontalMetrics()
        let offset = max(0, min(horizontalOffset(file: file, side: side) + delta, scrollableWidth(file: file, side: side)))
        if diffLayout == .unified { value.unifiedOffset = offset }
        else if side == .old { value.oldOffset = offset } else { value.newOffset = offset }
        horizontalMetrics[path] = value
        redraw()
    }

    private func prepareLayout(preserving anchor: Int? = nil) {
        layoutTask?.cancel()
        measuredPaneWidth = paneWidth
        let snapshot = rows, paths = files.map(\.path)
        let wrapWidths: [[DiffSide: CGFloat]]? = softWrap ? files.indices.map {
            [.old: textWidth(file: $0, side: .old), .new: textWidth(file: $0, side: .new)]
        } : nil
        let font = Style.codeFont, lineHeight = Style.rowHeight
        isLayoutPending = true
        let worker = Task.detached(priority: .userInitiated) { () -> ([CGFloat], [Int: FileHorizontalMetrics])? in
            var heights: [CGFloat] = []
            var widths: [Int: FileHorizontalMetrics] = [:]
            for row in snapshot {
                if Task.isCancelled { return nil }
                var height = row.height
                if case .file = row.content { widths[row.file] = FileHorizontalMetrics() }
                if case .code = row.content {
                    for (side, line) in [(DiffSide.old, row.line(on: .old)), (.new, row.line(on: .new))] {
                        guard let line else { continue }
                        autoreleasepool {
                            let text = NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: [.font: font])
                            if let width = wrapWidths?[row.file][side] {
                                height = max(height, CGFloat(DiffTextLayout.ranges(text, width: width).count) * lineHeight)
                            } else {
                                let measured = DiffTextLayout.width(text)
                                var value = widths[row.file] ?? FileHorizontalMetrics()
                                if side == .old { value.oldWidth = max(value.oldWidth, measured) }
                                else { value.newWidth = max(value.newWidth, measured) }
                                widths[row.file] = value
                            }
                        }
                    }
                }
                heights.append(height)
            }
            return (heights, widths)
        }
        layoutTask = Task { [weak self] in
            let busy = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                self?.onLayoutBusy?(true)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            busy.cancel()
            guard !Task.isCancelled, let self, let result else { return }
            let resized = IndexSet(self.rows.indices.filter { index in
                guard case .code = self.rows[index].content else { return false }
                return self.tableView(self.table, heightOfRow: index) != result.0[index]
            })
            let visibleAnchor = anchor.flatMap {
                self.table.rect(ofRow: $0).intersects(self.scroll.documentVisibleRect) ? $0 : nil
            }
            self.preservingScrollAnchor(row: visibleAnchor) {
                self.rowHeights = result.0
                if wrapWidths == nil {
                    for (file, measured) in result.1 {
                        var value = self.horizontalMetrics[paths[file]] ?? FileHorizontalMetrics()
                        value.oldWidth = measured.oldWidth
                        value.newWidth = measured.newWidth
                        self.horizontalMetrics[paths[file]] = value
                    }
                }
                // Invalidating unchanged rows can leave reused views at earlier
                // offsets. Width-only preparation must not change table geometry.
                if !resized.isEmpty { self.updateRowHeights(resized) }
            }
            self.isLayoutPending = false
            self.onLayoutBusy?(false)
            self.redraw()
            self.layoutTask = nil
        }
    }
    private func importKey(_ path: String, _ block: Int) -> String { "\(path):\(block)" }
    func importsExpanded(path: String, block: Int) -> Bool { expandedImports.contains(importKey(path, block)) }
    func copySelection() {
        guard let text = selectedSourceText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func selectedSourceText() -> String? {
        guard let selection, files.indices.contains(selection.file) else { return nil }
        let file = files[selection.file]
        let context = (contexts.expandedPairs[file.path] ?? [:]).values.flatMap { pairs in
            pairs.compactMap { selection.side == .old ? $0.old : $0.new }
        }
        let lines = (file.hunks.flatMap(\.lines) + context).filter {
            let n = selection.side == .old ? $0.oldNumber : $0.newNumber
            return n.map { $0 >= selection.start && $0 <= selection.end } ?? false
        }.sorted {
            (selection.side == .old ? $0.oldNumber! : $0.newNumber!) <
                (selection.side == .old ? $1.oldNumber! : $1.newNumber!)
        }
        return lines.map(\.text).joined(separator: "\n")
    }
}

private final class FileNavigationAnimation: NSAnimation {
    weak var viewport: DiffViewport?
    let file: Int
    let origin: CGFloat

    init(viewport: DiffViewport, file: Int, origin: CGFloat) {
        self.viewport = viewport
        self.file = file
        self.origin = origin
        super.init(duration: 0.22, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var currentProgress: NSAnimation.Progress {
        didSet { viewport?.advanceNavigation(self) }
    }
}

final class DiffTable: NSTableView {
    weak var owner: DiffViewport?
    override var acceptsFirstResponder: Bool { true }
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let owner, !owner.rows.isEmpty else { return }
        let visible = rows(in: clipRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let end = min(owner.rows.count, NSMaxRange(visible))
        let half = bounds.width / 2
        // Adjacent translucent rows must share one painted surface. Independent
        // cell backing layers lose edge coverage at fractional scroll positions.
        for side in [DiffSide.old, .new] {
            var run: NSRect?
            func flush() {
                guard let rect = run else { return }
                (side == .old ? McDiff.Style.removed : McDiff.Style.added).setFill()
                rect.fill()
                run = nil
            }
            for index in visible.location..<end {
                let row = owner.rows[index]
                guard let line = row.line(on: side), line.kind != .context else {
                    flush()
                    continue
                }
                let rowRect = rect(ofRow: index)
                let rect = NSRect(x: owner.diffLayout == .unified || side == .old ? 0 : half,
                                  y: rowRect.minY, width: owner.diffLayout == .unified ? bounds.width : half, height: rowRect.height)
                if let prior = run, prior.maxY == rect.minY {
                    run = prior.union(rect)
                } else {
                    flush()
                    run = rect
                }
            }
            flush()
        }
    }
    override func mouseDown(with event: NSEvent) {
        owner?.stopNavigation()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        let isCode: Bool
        if let owner, owner.rows.indices.contains(index), case .code = owner.rows[index].content {
            guard owner.hitsCode(row: index, point: point) else { return }
            isCode = true
        } else { isCode = false }
        owner?.click(row: index, point: point, shift: event.modifierFlags.contains(.shift))
        guard isCode else { return }
        guard let anchor = owner?.selection else { return }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            autoscroll(with: next)
            owner?.drag(row: row(at: point), point: point, anchor: anchor)
        }
        owner?.commitSelection()
    }
    override func scrollWheel(with event: NSEvent) {
        owner?.stopNavigation()
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if let owner, owner.rows.indices.contains(row) {
            let item = owner.rows[row]
            if case .padding = item.content { super.scrollWheel(with: event); return }
            let side = owner.sourceSide(row: row, x: point.x)
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
                owner.scrollHorizontally(-(event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY),
                                         file: item.file, side: side)
                return
            }
        }
        super.scrollWheel(with: event)
    }
    @objc func copy(_ sender: Any?) { owner?.copySelection() }
    @objc private func comment(_ sender: Any?) { if let selection = owner?.selection { owner?.onComment?(selection) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if let owner, owner.rows.indices.contains(index), case .code = owner.rows[index].content {
            guard owner.hitsCode(row: index, point: point) else { return nil }
            if owner.selection == nil { owner.click(row: index, point: point, shift: false) }
            let menu = NSMenu()
            let add = menu.addItem(withTitle: "Comment on selected lines", action: #selector(comment(_:)), keyEquivalent: "")
            add.target = self
            let copy = menu.addItem(withTitle: "Copy selected code", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            return menu
        }
        return nil
    }
}

private final class VerticalClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }
}

final class PinnedFileHeader: NSView {
    let cell = DiffCell()
    private let material = NSVisualEffectView()
    private let fade = CAGradientLayer()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        material.material = .headerView
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        material.wantsLayer = true
        material.layer?.cornerRadius = 5
        material.layer?.masksToBounds = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.82, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        material.layer?.mask = fade
        addSubview(material)
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 5
        cell.layer?.masksToBounds = true
        addSubview(cell)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setHeaderFrame(_ frame: NSRect) {
        material.frame = frame
        cell.frame = frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = material.bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func scrollWheel(with event: NSEvent) {
        cell.owner?.table.scrollWheel(with: event)
    }
}

final class DiffCell: NSView {
    weak var owner: DiffViewport?
    var rowIndex = 0
    private var markdownButton: NSButton?
    private var reviewCheckbox: AnimatedCheckbox?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let owner, owner.rows.indices.contains(rowIndex), case .file = owner.rows[rowIndex].content else {
            super.mouseDown(with: event)
            return
        }
        owner.stopNavigation()
        owner.click(row: rowIndex, point: .zero, shift: false)
    }

    func updateHeaderButton() {
        var disclosureTip: String?
        if let owner, owner.rows.indices.contains(rowIndex) {
            let row = owner.rows[rowIndex]
            switch row.content {
            case .file:
                disclosureTip = owner.expanded.contains(owner.files[row.file].path) ? "Collapse file" : "Expand file"
            case .imports(_, let block):
                disclosureTip = owner.importsExpanded(path: owner.files[row.file].path, block: block) ? "Collapse imports" : "Expand imports"
            case .context(let section):
                if case .failed(let message) = owner.contexts.state(path: owner.files[row.file].path, section: section.id) {
                    disclosureTip = message
                } else { disclosureTip = owner.contextTitle(file: row.file, section: section) }
            default: break
            }
        }
        if toolTip != disclosureTip { toolTip = disclosureTip }
        guard let owner, owner.rows.indices.contains(rowIndex),
              case .file = owner.rows[rowIndex].content else {
            markdownButton?.isHidden = true
            reviewCheckbox?.isHidden = true
            return
        }
        let file = owner.files[owner.rows[rowIndex].file]
        if reviewCheckbox == nil {
            let check = AnimatedCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggleReviewed))
            check.controlSize = .small
            check.setFrameSize(NSSize(width: 15, height: 15))
            addSubview(check)
            reviewCheckbox = check
        }
        reviewCheckbox?.isHidden = false
        reviewCheckbox?.configureReview(reviewed: owner.isReviewed(file), reason: owner.filters.skipReason(for: file))
        needsLayout = true
        guard !file.isBinary, RenderedMarkdown.accepts(file.path) else {
            markdownButton?.isHidden = true
            return
        }
        if markdownButton == nil {
            let button = NSButton(title: "", target: self, action: #selector(toggleMarkdown))
            button.bezelStyle = .glass
            button.controlSize = .regular
            button.imagePosition = .imageOnly
            addSubview(button)
            markdownButton = button
        }
        markdownButton?.isHidden = false
        markdownButton?.image = Icons.image(owner.rendersMarkdown(file) ? "file-code" : "file-text")
        markdownButton?.toolTip = owner.rendersMarkdown(file) ? "Show Markdown source for this file" : "Render Markdown for this file"
        markdownButton?.sizeToFit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let check = reviewCheckbox, !check.isHidden {
            check.setFrameOrigin(NSPoint(x: max(0, bounds.width - 12 - check.frame.width),
                                         y: (bounds.height - check.frame.height) / 2))
        }
        if let button = markdownButton, !button.isHidden {
            button.setFrameOrigin(NSPoint(x: max(0, bounds.width - 12 - 15 - 8 - button.frame.width),
                                          y: (bounds.height - button.frame.height) / 2))
        }
    }

    @objc private func toggleReviewed() {
        guard let owner, owner.rows.indices.contains(rowIndex), case .file = owner.rows[rowIndex].content,
              let check = reviewCheckbox else { return }
        owner.onReviewToggle?(owner.files[owner.rows[rowIndex].file], check.state == .on)
    }

    @objc private func toggleMarkdown() {
        guard let owner, owner.rows.indices.contains(rowIndex), case .file = owner.rows[rowIndex].content else { return }
        owner.toggleMarkdown(for: owner.rows[rowIndex].file)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, owner.rows.indices.contains(rowIndex) else { return }
        let row = owner.rows[rowIndex], file = owner.files[row.file]
        let width = bounds.width, half = width / 2
        switch row.content {
        case .file:
            NSColor.separatorColor.withAlphaComponent(0.30).setFill()
            NSRect(x: 0, y: 0, width: max(0, width - 12), height: 0.5).fill()
            let isOpen = owner.expanded.contains(file.path)
            Icons.draw(isOpen ? "chevron-down" : "chevron-right", in: NSRect(x: 2, y: 12, width: 14, height: 14))
            let title = file.headerTitle
            let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            let additions = "+\(file.additions)", deletions = "−\(file.deletions)"
            let addedWidth = (additions as NSString).size(withAttributes: [.font: countFont]).width
            let removedWidth = (deletions as NSString).size(withAttributes: [.font: countFont]).width
            let buttonWidth = 15 + 12 + (markdownButton.flatMap { $0.isHidden ? nil : $0.frame.width + 8 } ?? 0)
            let available = max(0, width - 12 - buttonWidth - 24 - 10 - addedWidth - 6 - removedWidth)
            let titleWidth = min(available, (title as NSString).size(withAttributes: [.font: titleFont]).width)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let titleText = NSMutableAttributedString(string: title, attributes: [
                .font: titleFont, .foregroundColor: owner.isReviewed(file) ? NSColor.secondaryLabelColor : .labelColor,
                .paragraphStyle: paragraph
            ])
            for range in LiteralSearch.matches(owner.searchQuery, in: title) {
                let active = owner.currentSearchMatch == DiffSearchMatch(target: .path(file: row.file), range: range)
                titleText.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(active ? 0.70 : 0.35), range: range)
            }
            titleText.draw(in: NSRect(x: 24, y: 11, width: titleWidth, height: 20))
            draw(additions, at: NSPoint(x: 24 + titleWidth + 10, y: 12), font: countFont, color: .systemGreen)
            draw(deletions, at: NSPoint(x: 24 + titleWidth + 10 + addedWidth + 6, y: 12), font: countFont, color: .systemRed)
        case .hunk:
            draw("···", at: NSPoint(x: 34, y: -1), font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
        case .imports(let pairs, let block):
            NSColor.separatorColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 2, width: max(0, width - 12), height: bounds.height - 4), xRadius: 5, yRadius: 5).fill()
            let open = owner.importsExpanded(path: file.path, block: block)
            Icons.draw(open ? "chevron-down" : "chevron-right", in: NSRect(x: 7, y: 8, width: 12, height: 12))
            let changed = pairs.filter { $0.old?.kind == .deletion || $0.new?.kind == .addition }.count
            draw("Imports · \(pairs.count) lines\(changed > 0 ? " · \(changed) changed" : "")",
                 at: NSPoint(x: 28, y: 8), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        case .context(let section):
            let state = owner.contexts.state(path: file.path, section: section.id)
            let icon: String
            switch state {
            case .expanded: icon = "chevron-down"
            case .failed: icon = "rotate-cw"
            default: icon = "chevron-right"
            }
            if case .empty = state {} else {
                Icons.draw(icon, in: NSRect(x: 7, y: 8, width: 12, height: 12))
            }
            draw(owner.contextTitle(file: row.file, section: section),
                 at: NSPoint(x: 28, y: 8), font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
                 maxWidth: max(0, width - 40))
        case .notice(let text):
            draw(text, at: NSPoint(x: 22, y: 15), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .padding:
            break
        case .markdown:
            if let error = owner.markdownContent[file.path]?.error {
                draw("Could not load Markdown: \(error) · Refresh to retry", at: NSPoint(x: 20, y: 18),
                     font: .systemFont(ofSize: 12), color: .secondaryLabelColor, maxWidth: width - 40)
            } else if let layout = owner.markdownLayout(for: file) {
                let panes: [(DiffSide, MarkdownTextLayout, CGFloat)] = owner.diffLayout == .split
                    ? [(.old, layout.old, 0), (.new, layout.new, half)]
                    : [(.new, layout.new, 0)]
                for (side, text, x) in panes {
                    NSGraphicsContext.saveGraphicsState()
                    let pane = NSRect(x: x, y: 0, width: owner.paneWidth, height: bounds.height)
                    pane.clip()
                    let current = owner.currentSearchMatch.flatMap { $0.target == .markdown(file: row.file, side: side) ? $0.range : nil }
                    text.draw(at: NSPoint(x: x + 20, y: 18), visible: visibleRect.intersection(pane),
                              search: owner.searchQuery, currentMatch: current)
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else {
                draw("Rendering Markdown…", at: NSPoint(x: 20, y: 18),
                     font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            }
        case .code(let pair):
            let oldText = pair.old?.text.replacingOccurrences(of: "\t", with: "    ") ?? ""
            let newText = pair.new?.text.replacingOccurrences(of: "\t", with: "    ") ?? ""
            let words = pair.old?.kind == .deletion && pair.new?.kind == .addition ? WordDiff.ranges(old: oldText, new: newText) : (old: [], new: [])
            if let side = row.sourceSide {
                drawLine(side == .old ? pair.old : pair.new, side: side, file: file, fileIndex: row.file,
                         rect: bounds, words: side == .old ? words.old : words.new, owner: owner)
            } else {
                drawLine(pair.old, side: .old, file: file, fileIndex: row.file, rect: NSRect(x: 0, y: 0, width: half, height: bounds.height), words: words.old, owner: owner)
                drawLine(pair.new, side: .new, file: file, fileIndex: row.file, rect: NSRect(x: half, y: 0, width: width - half, height: bounds.height), words: words.new, owner: owner)
            }
        }
    }
    private func drawLine(_ line: DiffLine?, side: DiffSide, file: FileDiff, fileIndex: Int, rect: NSRect, words: [NSRange], owner: DiffViewport) {
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let line else { return }
        let number = (side == .old ? line.oldNumber : line.newNumber) ?? 0
        if let selection = owner.selection, selection.file == fileIndex,
           selection.side == side || (owner.diffLayout == .unified && line.kind == .context),
           let selectedNumber = selection.side == .old ? line.oldNumber : line.newNumber,
           (selection.start...selection.end).contains(selectedNumber) {
            NSColor.controlAccentColor.withAlphaComponent(0.19).setFill(); rect.fill()
            NSColor.controlAccentColor.setFill(); NSRect(x: rect.minX, y: 0, width: 3, height: rect.height).fill()
        }
        let text = line.text.replacingOccurrences(of: "\t", with: "    ")
        let rich = owner.richText(file: file, side: side, line: number) ?? NSAttributedString(string: text, attributes: [.font: Style.codeFont, .foregroundColor: NSColor.labelColor])
        NSGraphicsContext.saveGraphicsState()
        let inset = owner.sourceTextInset(file: fileIndex)
        let textWidth = owner.textWidth(file: fileIndex, side: side)
        NSRect(x: rect.minX + inset, y: 0, width: textWidth, height: rect.height).clip()
        let x = rect.minX + inset - owner.horizontalOffset(file: fileIndex, side: side)
        let typesetter = CTTypesetterCreateWithAttributedString(rich)
        let ranges = owner.textFragments(rich, file: fileIndex, side: side)
        for (index, fragment) in ranges.enumerated() {
            let y = CGFloat(index) * Style.rowHeight
            guard NSRect(x: rect.minX, y: y, width: rect.width, height: Style.rowHeight).intersects(visibleRect) else { continue }
            let ct = CTTypesetterCreateLine(typesetter, CFRange(location: fragment.location, length: fragment.length))
            (side == .old ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.22).setFill()
            for word in words {
                let range = NSIntersectionRange(word, fragment)
                guard range.length > 0 else { continue }
                let left = CTLineGetOffsetForStringIndex(ct, range.location, nil)
                let right = CTLineGetOffsetForStringIndex(ct, NSMaxRange(range), nil)
                NSBezierPath(roundedRect: NSRect(x: x + min(left, right), y: y + 2, width: max(2, abs(right - left)), height: Style.rowHeight - 4), xRadius: 3, yRadius: 3).fill()
            }
            if !owner.searchQuery.isEmpty {
                let margin = owner.searchQuery.utf16.count
                let leftIndex = CTLineGetStringIndexForPosition(ct, CGPoint(x: rect.minX + inset - 6 - x, y: 0))
                let rightIndex = CTLineGetStringIndexForPosition(ct, CGPoint(x: rect.minX + inset + textWidth - x, y: 0))
                let start = max(0, (leftIndex == kCFNotFound ? fragment.location : leftIndex) - margin)
                let end = min(rich.length, (rightIndex == kCFNotFound ? NSMaxRange(fragment) : rightIndex) + margin)
                for found in LiteralSearch.matches(owner.searchQuery, in: text, range: NSRange(location: start, length: end - start)) {
                    let range = NSIntersectionRange(found, fragment)
                    guard range.length > 0 else { continue }
                    let active: Bool
                    if let match = owner.currentSearchMatch, case .code(let index, let matchSide, let matchLine, _) = match.target {
                        active = index == fileIndex && matchSide == side && matchLine == number && match.range == found
                    } else { active = false }
                    NSColor.systemYellow.withAlphaComponent(active ? 0.70 : 0.35).setFill()
                    let left = CTLineGetOffsetForStringIndex(ct, range.location, nil)
                    let right = CTLineGetOffsetForStringIndex(ct, NSMaxRange(range), nil)
                    NSRect(x: x + min(left, right), y: y + 2, width: max(2, abs(right - left)), height: Style.rowHeight - 4).fill()
                }
            }
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: x, y: y + 3 + Style.codeFont.ascender)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(ct, context)
                context.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if owner.diffLayout == .unified {
            if let number = line.oldNumber {
                drawGutter(number: number, side: .old, file: file, fileIndex: fileIndex, rect: rect, owner: owner)
            }
            if let number = line.newNumber {
                drawGutter(number: number, side: .new, file: file, fileIndex: fileIndex, rect: rect, owner: owner)
            }
        } else {
            drawGutter(number: number, side: side, file: file, fileIndex: fileIndex, rect: rect, owner: owner)
        }
        let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : ""
        draw(marker, at: NSPoint(x: rect.minX + owner.sourceGutter(file: fileIndex).changeLeading, y: 4),
             font: Style.smallFont, color: line.kind == .deletion ? .systemRed : .systemGreen)
    }
    private func drawGutter(number: Int, side: DiffSide, file: FileDiff, fileIndex: Int, rect: NSRect, owner: DiffViewport) {
        if let range = owner.commentRange(file.path, side, number),
           let marker = owner.commentMarkerRect(file: fileIndex, side: side) {
            let marker = marker.offsetBy(dx: rect.minX, dy: 0)
            if number == range.lowerBound {
                Icons.draw("message-square", in: marker, color: .labelColor)
            }
            if range.lowerBound != range.upperBound {
                let start: CGFloat = number == range.lowerBound ? 19 : 0
                let end: CGFloat = number == range.upperBound ? rect.height - Style.rowHeight / 2 : rect.height
                NSColor.secondaryLabelColor.setFill()
                NSRect(x: marker.midX - 0.5, y: start, width: 1, height: max(0, end - start)).fill()
                if number == range.upperBound {
                    NSRect(x: marker.midX - 6, y: end - 0.5, width: 6, height: 1).fill()
                }
            }
        }
        let numberString = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: SourceGutter.numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let gutter = owner.sourceGutter(file: fileIndex)
        numberString.draw(at: NSPoint(x: rect.minX + gutter.columnOffset(side) + gutter.numberTrailing - numberString.size(withAttributes: attrs).width, y: 5), withAttributes: attrs)
    }
    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, maxWidth: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if let maxWidth { (text as NSString).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: 20), withAttributes: attrs) }
        else { (text as NSString).draw(at: point, withAttributes: attrs) }
    }
}
