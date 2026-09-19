import AppKit
import CoreText
import SlopdiffCore

enum CanvasContent {
    case file
    case hunk(String)
    case code(DiffPair)
    case imports([DiffPair], Int)
    case notice(String)
    case padding
}

struct CanvasRow {
    let file: Int
    let content: CanvasContent
    var height: CGFloat {
        switch content {
        case .file: return 38
        case .hunk: return 14
        case .code: return Style.rowHeight
        case .imports: return 30
        case .notice: return 44
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
    let oldHorizontal = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
    let newHorizontal = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
    var files: [FileDiff] = []
    var presentations: [String: [PresentedRow]] = [:]
    private(set) var rows: [CanvasRow] = []
    private(set) var headerRows: [Int: Int] = [:]
    var expanded: Set<String> = []
    var expandedImports: Set<String> = []
    var filters = ReviewFilters()
    var isReviewed: (FileDiff) -> Bool = { _ in false }
    var commentCount: (FileDiff) -> Int = { _ in 0 }
    var onFocus: ((Int) -> Void)?
    var onComment: ((LineSelection) -> Void)?
    var selection: LineSelection?
    var focusedFile = 0
    private var oldOffset: CGFloat = 0
    private var newOffset: CGFloat = 0
    private var oldWidth: CGFloat = 0
    private var newWidth: CGFloat = 0
    private var rowHeights: [CGFloat] = []
    private var layoutTask: Task<Void, Never>?
    private(set) var isLayoutPending = false
    private var measuredPaneWidth: CGFloat = 0
    var onLayoutBusy: ((Bool) -> Void)?
    var softWrap = false {
        didSet {
            guard softWrap != oldValue else { return }
            oldOffset = 0; newOffset = 0
            prepareLayout()
            updateScrollers()
            redraw()
        }
    }
    var paneWidth: CGFloat { scroll.contentSize.width / 2 }
    var textWidth: CGFloat { max(1, paneWidth - 68) }
    private let highlights = NSCache<NSString, HighlightBox>()
    private let lineBreaks = NSCache<NSString, DiffTextLayout.Breaks>()
    private var highlightTask: Task<Void, Never>?
    private let syntax = SyntaxService()
    private var failedHighlights: Set<String> = []
    var onHighlightError: ((Error) -> Void)?
    private var observer: NSObjectProtocol?
    private var paddingHeight: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        highlights.totalCostLimit = 48 * 1024 * 1024
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
        scroll.backgroundColor = Style.canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        for scroller in [oldHorizontal, newHorizontal] {
            // The native persistent-track style keeps overflow discoverable without
            // depending on a trackpad gesture to reveal the overlay thumb.
            scroller.scrollerStyle = .legacy
            scroller.controlSize = .small
            scroller.target = self; scroller.action = #selector(horizontalChanged(_:))
            scroller.isHidden = true
            addSubview(scroller)
        }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            // AppKit also posts while calculating row geometry. Observe after that
            // transaction so focus changes never reenter table layout.
            DispatchQueue.main.async { self?.visibleChanged() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; highlightTask?.cancel(); layoutTask?.cancel() }
    override func layout() {
        super.layout()
        let barHeight: CGFloat = !softWrap && (oldWidth > textWidth || newWidth > textWidth) ? 14 : 0
        scroll.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
        oldHorizontal.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 14)
        newHorizontal.frame = NSRect(x: paneWidth, y: 0, width: paneWidth, height: 14)
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.tableColumns.first?.width = scroll.contentSize.width
        let padding = max(1, scroll.contentSize.height - 38)
        if padding != paddingHeight {
            paddingHeight = padding
            if !rows.isEmpty { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: rows.count - 1)) }
        }
        if softWrap && measuredPaneWidth != paneWidth { prepareLayout() }
        updateScrollers()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlights.removeAllObjects()
        failedHighlights.removeAll()
        table.backgroundColor = Style.canvas
        scroll.backgroundColor = Style.canvas
        redraw()
        visibleChanged()
    }
    func setFiles(_ files: [FileDiff], presentations: [String: [PresentedRow]]) {
        highlightTask?.cancel()
        highlightTask = nil
        self.files = files; self.presentations = presentations
        highlights.removeAllObjects(); failedHighlights.removeAll()
        selection = nil; expandedImports.removeAll()
        oldOffset = 0; newOffset = 0
        rebuild()
    }
    func rebuild(keeping file: Int? = nil) {
        rows.removeAll(keepingCapacity: true); headerRows.removeAll(keepingCapacity: true)
        for (index, file) in files.enumerated() {
            headerRows[index] = rows.count
            rows.append(CanvasRow(file: index, content: .file))
            guard expanded.contains(file.path) else { continue }
            if file.isBinary {
                rows.append(CanvasRow(file: index, content: .notice("Binary file · contents are not rendered")))
            } else if file.hunks.isEmpty {
                rows.append(CanvasRow(file: index, content: .notice("Metadata-only change · \(file.status == "R" ? "renamed from " + file.oldPath : "file mode or identity changed")")))
            }
            for (block, presentation) in (presentations[file.path] ?? []).enumerated() {
                switch presentation {
                case .hunk(let text):
                    if block > 0 { rows.append(CanvasRow(file: index, content: .hunk(text))) }
                case .code(let pair): rows.append(CanvasRow(file: index, content: .code(pair)))
                case .imports(let pairs):
                    rows.append(CanvasRow(file: index, content: .imports(pairs, block)))
                    if expandedImports.contains(importKey(file.path, block)) {
                        rows += pairs.map { CanvasRow(file: index, content: .code($0)) }
                    }
                }
            }
        }
        if !files.isEmpty { rows.append(CanvasRow(file: files.count - 1, content: .padding)) }
        rowHeights = []
        table.reloadData()
        prepareLayout()
        if let file { navigate(to: file, expand: false) }
        visibleChanged()
    }
    func navigate(to file: Int, expand: Bool = true) {
        guard files.indices.contains(file) else { return }
        if expand && !expanded.contains(files[file].path) {
            expanded.insert(files[file].path)
            rebuild()
        }
        guard let row = headerRows[file] else { return }
        let rect = table.rect(ofRow: row)
        let maxY = max(0, table.bounds.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(rect.minY, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        focusedFile = file
        onFocus?(file)
        visibleChanged()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .padding = rows[row].content { return paddingHeight }
        return rowHeights.indices.contains(row) ? rowHeights[row] : rows[row].height
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("diff-row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DiffCell ?? DiffCell()
        cell.identifier = id
        cell.owner = self; cell.rowIndex = row
        cell.needsDisplay = true
        return cell
    }
    func richText(file: FileDiff, side: DiffSide, line: Int) -> NSAttributedString? {
        let value = highlights.object(forKey: highlightKey(file, page: max(0, line - 1) / SyntaxService.pageSize))?.value
        return side == .old ? value?.old[line] : value?.new[line]
    }
    func textFragments(_ text: NSAttributedString) -> [NSRange] {
        guard softWrap else { return [NSRange(location: 0, length: text.length)] }
        let key = "\(textWidth):\(text.string)" as NSString
        if let cached = lineBreaks.object(forKey: key) { return cached.ranges }
        let ranges = DiffTextLayout.ranges(text, width: textWidth)
        lineBreaks.setObject(DiffTextLayout.Breaks(ranges), forKey: key, cost: text.length * 2 + ranges.count * 16)
        return ranges
    }
    private func highlightKey(_ file: FileDiff, page: Int) -> NSString { "\(file.fingerprint):\(Style.dark):\(page)" as NSString }
    func redraw() {
        table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true; row.subviews.forEach { $0.needsDisplay = true } }
    }
    private func visibleChanged() {
        let range = table.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0, !rows.isEmpty else { return }
        let start = min(range.location, rows.count - 1)
        let current = rows[start].file
        if current != focusedFile { focusedFile = current; onFocus?(current) }
        pumpHighlight()
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
        highlightTask = Task { [weak self, syntax] in
            do {
                let value = try await syntax.highlight(file: file, dark: dark, page: page)
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
    func click(row: Int, point: NSPoint, shift: Bool) {
        guard rows.indices.contains(row) else { return }
        let item = rows[row], file = files[item.file]
        switch item.content {
        case .file:
            if expanded.contains(file.path) { expanded.remove(file.path) } else { expanded.insert(file.path) }
            focusedFile = item.file
            rebuild(keeping: item.file)
            onFocus?(item.file)
        case .imports(_, let block):
            let key = importKey(file.path, block)
            if expandedImports.contains(key) { expandedImports.remove(key) } else { expandedImports.insert(key) }
            let origin = scroll.contentView.bounds.origin
            rebuild()
            scroll.contentView.scroll(to: origin)
        case .code(let pair):
            let side: DiffSide = point.x < table.bounds.width / 2 ? .old : .new
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
        guard rows.indices.contains(row), rows[row].file == anchor.file,
              case .code(let pair) = rows[row].content,
              let number = anchor.side == .old ? pair.old?.oldNumber : pair.new?.newNumber else { return }
        selection = LineSelection(file: anchor.file, side: anchor.side, start: min(anchor.start, number), end: max(anchor.start, number))
        redraw()
    }
    var selectionAnchor: NSRect? {
        guard let selection, let row = rows.firstIndex(where: {
            guard $0.file == selection.file, case .code(let pair) = $0.content else { return false }
            return (selection.side == .old ? pair.old?.oldNumber : pair.new?.newNumber) == selection.end
        }) else { return nil }
        let rect = convert(table.rect(ofRow: row), from: table)
        return NSRect(x: selection.side == .old ? bounds.width * 0.25 : bounds.width * 0.75,
                      y: max(18, min(bounds.height - 22, rect.minY)), width: 1, height: Style.rowHeight)
    }
    func commitSelection() { if let selection { onComment?(selection) } }
    func horizontalOffset(for side: DiffSide) -> CGFloat { side == .old ? oldOffset : newOffset }
    func scrollableWidth(for side: DiffSide) -> CGFloat {
        softWrap ? 0 : max(0, (side == .old ? oldWidth : newWidth) - textWidth)
    }
    func scrollHorizontally(_ delta: CGFloat, side: DiffSide = .old) {
        let offset = max(0, min(horizontalOffset(for: side) + delta, scrollableWidth(for: side)))
        if side == .old { oldOffset = offset } else { newOffset = offset }
        updateScrollers(); redraw()
    }
    private func updateScrollers() {
        oldOffset = min(oldOffset, scrollableWidth(for: .old))
        newOffset = min(newOffset, scrollableWidth(for: .new))
        for (side, scroller, width) in [(DiffSide.old, oldHorizontal, oldWidth), (.new, newHorizontal, newWidth)] {
            let hidden = scrollableWidth(for: side) <= 0
            if scroller.isHidden != hidden { scroller.isHidden = hidden; needsLayout = true }
            scroller.knobProportion = min(1, textWidth / max(1, width))
            scroller.doubleValue = Double(horizontalOffset(for: side) / max(1, scrollableWidth(for: side)))
        }
    }
    @objc private func horizontalChanged(_ sender: NSScroller) {
        let side: DiffSide = sender === oldHorizontal ? .old : .new
        switch sender.hitPart {
        case .decrementPage: scrollHorizontally(-textWidth, side: side)
        case .incrementPage: scrollHorizontally(textWidth, side: side)
        default:
            scrollHorizontally(CGFloat(sender.doubleValue) * scrollableWidth(for: side) - horizontalOffset(for: side), side: side)
        }
    }

    private func prepareLayout() {
        layoutTask?.cancel()
        measuredPaneWidth = paneWidth
        let snapshot = rows, width: CGFloat? = softWrap ? textWidth : nil
        let font = Style.codeFont, lineHeight = Style.rowHeight
        isLayoutPending = true
        let worker = Task.detached(priority: .userInitiated) { () -> ([CGFloat], CGFloat, CGFloat)? in
            var heights: [CGFloat] = []
            var oldWidth: CGFloat = 0, newWidth: CGFloat = 0
            for row in snapshot {
                if Task.isCancelled { return nil }
                var height = row.height
                if case .code(let pair) = row.content {
                    for (side, line) in [(DiffSide.old, pair.old), (.new, pair.new)] {
                        guard let line else { continue }
                        autoreleasepool {
                            let text = NSAttributedString(string: line.text.replacingOccurrences(of: "\t", with: "    "), attributes: [.font: font])
                            if width == nil {
                                let measured = DiffTextLayout.width(text)
                                if side == .old { oldWidth = max(oldWidth, measured) } else { newWidth = max(newWidth, measured) }
                            } else {
                                height = max(height, CGFloat(DiffTextLayout.ranges(text, width: width).count) * lineHeight)
                            }
                        }
                    }
                }
                heights.append(height)
            }
            return (heights, oldWidth, newWidth)
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
            let visible = self.table.rows(in: self.scroll.documentVisibleRect)
            let anchor = visible.location != NSNotFound && visible.location < self.rows.count ? visible.location : nil
            let inset = anchor.map { self.scroll.documentVisibleRect.minY - self.table.rect(ofRow: $0).minY } ?? 0
            self.rowHeights = result.0
            if width == nil { self.oldWidth = result.1; self.newWidth = result.2 }
            self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.rows.count))
            if let anchor {
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: self.table.rect(ofRow: anchor).minY + inset))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
            self.isLayoutPending = false
            self.onLayoutBusy?(false)
            self.updateScrollers()
            self.redraw()
            self.layoutTask = nil
        }
    }
    private func importKey(_ path: String, _ block: Int) -> String { "\(path):\(block)" }
    func importsExpanded(path: String, block: Int) -> Bool { expandedImports.contains(importKey(path, block)) }
    func copySelection() {
        guard let selection, files.indices.contains(selection.file) else { return }
        let lines = files[selection.file].hunks.flatMap(\.lines).filter {
            let n = selection.side == .old ? $0.oldNumber : $0.newNumber
            return n.map { $0 >= selection.start && $0 <= selection.end } ?? false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

final class DiffTable: NSTableView {
    weak var owner: DiffViewport?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        let isCode: Bool
        if let owner, owner.rows.indices.contains(index), case .code = owner.rows[index].content { isCode = true } else { isCode = false }
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
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            let point = convert(event.locationInWindow, from: nil)
            owner?.scrollHorizontally(-(event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY), side: point.x < bounds.width / 2 ? .old : .new)
        } else { super.scrollWheel(with: event) }
    }
    @objc func copy(_ sender: Any?) { owner?.copySelection() }
    @objc private func comment(_ sender: Any?) { if let selection = owner?.selection { owner?.onComment?(selection) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if let owner, owner.rows.indices.contains(index), case .code = owner.rows[index].content {
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

final class DiffCell: NSView {
    weak var owner: DiffViewport?
    var rowIndex = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner, owner.rows.indices.contains(rowIndex) else { return }
        let row = owner.rows[rowIndex], file = owner.files[row.file]
        let width = bounds.width, half = width / 2
        switch row.content {
        case .file:
            NSColor.separatorColor.withAlphaComponent(0.30).setFill()
            NSRect(x: 12, y: 0, width: max(0, width - 24), height: 0.5).fill()
            let isOpen = owner.expanded.contains(file.path)
            Icons.draw(isOpen ? "chevron-down" : "chevron-right", in: NSRect(x: 14, y: 12, width: 14, height: 14))
            let title = file.oldPath != file.path ? "\(file.oldPath) → \(file.path)" : file.path
            draw(title, at: NSPoint(x: 36, y: 11), font: .systemFont(ofSize: 12, weight: .medium), color: owner.isReviewed(file) ? .secondaryLabelColor : .labelColor, maxWidth: max(0, width - 200))
            draw("+\(file.additions)", at: NSPoint(x: max(0, width - 118), y: 12), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .systemGreen)
            draw("−\(file.deletions)", at: NSPoint(x: max(0, width - 66), y: 12), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .systemRed)
        case .hunk:
            draw("···", at: NSPoint(x: 34, y: -1), font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
        case .imports(let pairs, let block):
            NSColor.separatorColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 2), xRadius: 5, yRadius: 5).fill()
            let open = owner.importsExpanded(path: file.path, block: block)
            Icons.draw(open ? "chevron-down" : "chevron-right", in: NSRect(x: 19, y: 8, width: 12, height: 12))
            let changed = pairs.filter { $0.old?.kind == .deletion || $0.new?.kind == .addition }.count
            draw("Imports · \(pairs.count) lines\(changed > 0 ? " · \(changed) changed" : "")",
                 at: NSPoint(x: 40, y: 8), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        case .notice(let text):
            draw(text, at: NSPoint(x: 22, y: 15), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .padding:
            break
        case .code(let pair):
            let oldText = pair.old?.text.replacingOccurrences(of: "\t", with: "    ") ?? ""
            let newText = pair.new?.text.replacingOccurrences(of: "\t", with: "    ") ?? ""
            let words = pair.old?.kind == .deletion && pair.new?.kind == .addition ? WordDiff.ranges(old: oldText, new: newText) : (old: [], new: [])
            drawLine(pair.old, side: .old, file: file, fileIndex: row.file, rect: NSRect(x: 0, y: 0, width: half, height: bounds.height), words: words.old, owner: owner)
            drawLine(pair.new, side: .new, file: file, fileIndex: row.file, rect: NSRect(x: half, y: 0, width: width - half, height: bounds.height), words: words.new, owner: owner)
        }
    }
    private func drawLine(_ line: DiffLine?, side: DiffSide, file: FileDiff, fileIndex: Int, rect: NSRect, words: [NSRange], owner: DiffViewport) {
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let line else { return }
        let number = (side == .old ? line.oldNumber : line.newNumber) ?? 0
        let changed = line.kind != .context
        if changed { (side == .old ? Style.removed : Style.added).setFill(); rect.fill() }
        if let selection = owner.selection, selection.file == fileIndex, selection.side == side, (selection.start...selection.end).contains(number) {
            NSColor.controlAccentColor.withAlphaComponent(0.19).setFill(); rect.fill()
            NSColor.controlAccentColor.setFill(); NSRect(x: rect.minX, y: 0, width: 3, height: rect.height).fill()
        }
        let text = line.text.replacingOccurrences(of: "\t", with: "    ")
        let rich = owner.richText(file: file, side: side, line: number) ?? NSAttributedString(string: text, attributes: [.font: Style.codeFont, .foregroundColor: NSColor.labelColor])
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX + 54, y: 0, width: max(0, rect.width - 54), height: rect.height).clip()
        let x = rect.minX + 60 - owner.horizontalOffset(for: side)
        let typesetter = CTTypesetterCreateWithAttributedString(rich)
        let ranges = owner.textFragments(rich)
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
        let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : ""
        draw(marker, at: NSPoint(x: rect.minX + 5, y: 4), font: Style.smallFont, color: side == .old ? .systemRed : .systemGreen)
        let numberString = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        numberString.draw(at: NSPoint(x: rect.minX + 47 - numberString.size(withAttributes: attrs).width, y: 5), withAttributes: attrs)
    }
    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, maxWidth: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if let maxWidth { (text as NSString).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: 20), withAttributes: attrs) }
        else { (text as NSString).draw(at: point, withAttributes: attrs) }
    }
}
