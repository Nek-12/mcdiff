import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class ContextSectionsTests: XCTestCase {
    private func file() -> FileDiff {
        FileDiff(path: "source.swift", hunks: [4, 20].map { offset in
            DiffHunk(header: "", lines: [
                DiffLine(kind: .deletion, text: "let changed = false", oldNumber: offset + 1, newNumber: nil),
                DiffLine(kind: .addition, text: "let changed = true", oldNumber: nil, newNumber: offset + 1)
            ], oldRange: offset..<(offset + 1), newRange: offset..<(offset + 1))
        }, fingerprint: "original-review")
    }
    private static func pairs(_ section: UnchangedSection, tailCount: Int = 10) -> [DiffPair] {
        (0..<(section.count ?? tailCount)).map { offset in
            let number = section.newStart + offset + 1
            let line = DiffLine(kind: .context, text: number == 10 ? "let hiddenNeedle = 10" : "let context\(number) = \(number)",
                                oldNumber: section.oldStart + offset + 1, newNumber: number)
            return DiffPair(old: line, new: line)
        }
    }
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Context did not settle")
    }
    @MainActor
    private func contextRow(_ view: DiffViewport, section: Int) throws -> Int {
        try XCTUnwrap(view.rows.firstIndex {
            if case .context(let value) = $0.content { return value.id == section }
            return false
        })
    }
    @MainActor
    func testContextLoadsOnlyOnClickAndSupportsSearchCopyCommentsAndBothLayouts() async throws {
        _ = NSApplication.shared
        let file = file()
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.softWrap = true
        view.expanded = [file.path]
        var matches = 0
        view.onSearchResults = { _, count in matches = count }
        var requests = 0
        view.contexts.load = { _, section in
            requests += 1
            try await Task.sleep(for: .milliseconds(30))
            return Self.pairs(section)
        }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { !view.isLayoutPending }
        XCTAssertEqual(requests, 0)
        view.search(query: "hiddenNeedle")
        try await wait { !view.isSearchPending }
        XCTAssertEqual(matches, 0)
        let section = file.unchangedSections[1]
        let row = try contextRow(view, section: section.id)
        let position = view.table.rect(ofRow: row).minY - view.scroll.documentVisibleRect.minY
        view.click(row: row, point: .zero, shift: false)
        XCTAssertEqual(view.contextTitle(file: 0, section: section), "Loading unchanged lines…")
        try await wait {
            if case .expanded = view.contexts.state(path: file.path, section: section.id) {
                return !view.isLayoutPending && !view.isSearchPending
            }
            return false
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(view.contextTitle(file: 0, section: section), "Hide unchanged lines")
        XCTAssertEqual(view.table.rect(ofRow: try contextRow(view, section: section.id)).minY - view.scroll.documentVisibleRect.minY,
                       position, accuracy: 1)
        XCTAssertEqual(matches, 1)
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .new, line: 10, importBlock: nil))
        let rich = try await SyntaxService().highlight(file: file, dark: true, context: view.contexts.pageLines(path: file.path, page: 0))
        XCTAssertEqual(rich.old[10]?.string, "let hiddenNeedle = 10")
        XCTAssertEqual(rich.new[10]?.string, "let hiddenNeedle = 10")
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            try await wait { !view.isLayoutPending }
            for side in [DiffSide.old, .new] {
                view.selection = LineSelection(file: 0, side: side, start: 10, end: 10)
                XCTAssertEqual(view.selectedSourceText(), "let hiddenNeedle = 10")
                var commented: LineSelection?
                view.onComment = { commented = $0 }
                view.commitSelection()
                XCTAssertEqual(commented?.side, side)
                XCTAssertEqual(commented?.start, 10)
            }
        }
        view.setComments([ReviewComment(path: file.path, side: .old, startLine: 10, endLine: 10,
                                        text: "Context note", fingerprint: file.fingerprint)])
        XCTAssertEqual(view.commentRange(file.path, .old, 10), 10...10)
        view.click(row: try contextRow(view, section: section.id), point: .zero, shift: false)
        try await wait { !view.isLayoutPending && !view.isSearchPending }
        XCTAssertEqual(matches, 0)
        XCTAssertEqual(view.contextTitle(file: 0, section: section), "Show unchanged lines")
        XCTAssertTrue(view.contexts.pageLines(path: file.path, page: 0).isEmpty)
        XCTAssertEqual(view.files[0].fingerprint, "original-review")
        XCTAssertFalse(view.isReviewed(file))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testFailureCanRetryEmptyTailSettlesAndReviewResetCancelsOldResult() async throws {
        let file = file(), state = ContextSections()
        let section = file.unchangedSections[0]
        state.load = { _, _ in throw GitError("Read failed; retry.") }
        state.toggle(file: file, section: section)
        try await wait { if case .failed = state.state(path: file.path, section: section.id) { return true }; return false }
        state.load = { _, section in Self.pairs(section) }
        state.toggle(file: file, section: section)
        try await wait { if case .expanded = state.state(path: file.path, section: section.id) { return true }; return false }
        let tail = try XCTUnwrap(file.unchangedSections.last)
        var requests = 0
        state.load = { _, _ in requests += 1; return [] }
        state.toggle(file: file, section: tail)
        try await wait { if case .empty = state.state(path: file.path, section: tail.id) { return true }; return false }
        state.toggle(file: file, section: tail)
        XCTAssertEqual(requests, 1)
        state.clear()
        var pending: CheckedContinuation<[DiffPair], Never>?
        state.load = { _, _ in await withCheckedContinuation { pending = $0 } }
        state.toggle(file: file, section: section)
        try await wait { pending != nil }
        state.clear()
        pending?.resume(returning: Self.pairs(section))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.state(path: file.path, section: section.id))
        XCTAssertTrue(state.expandedPairs.isEmpty)
    }

    @MainActor
    func testLargeUnchangedSectionRemainsVirtualizedAndUsesBoundedHighlightPages() async throws {
        _ = NSApplication.shared
        let base = file()
        let file = FileDiff(path: base.path, hunks: base.hunks.map { hunk in
            DiffHunk(header: hunk.header, lines: hunk.lines.map {
                DiffLine(kind: $0.kind, text: String(repeating: "wrapped context ", count: 60),
                         oldNumber: $0.oldNumber, newNumber: $0.newNumber)
            }, oldRange: hunk.oldRange, newRange: hunk.newRange)
        }, fingerprint: base.fingerprint)
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.softWrap = true
        view.expanded = [file.path]
        view.contexts.load = { _, section in
            await Task.detached { Self.pairs(section, tailCount: 30_000) }.value
        }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { !view.isLayoutPending }
        let tail = try XCTUnwrap(file.unchangedSections.last)
        let tailRow = try contextRow(view, section: tail.id)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: tailRow).minY - 150))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        view.click(row: tailRow, point: .zero, shift: false)
        try await wait { view.rows.count > 30_000 && !view.isLayoutPending }
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.table.rect(ofRow: try contextRow(view, section: tail.id)).minY -
                       view.scroll.documentVisibleRect.minY, 150, accuracy: 1)
        var count = 0
        view.table.enumerateAvailableRowViews { _, _ in count += 1 }
        XCTAssertLessThan(count, 150)
        XCTAssertLessThanOrEqual(view.contexts.pageLines(path: file.path, page: 50).count, SyntaxService.pageSize * 2)
        XCTAssertEqual(view.sourceGutter(file: 0).numberWidth, SourceGutter.numberWidth(for: 30_021))
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        XCTAssertTrue(view.contexts.expandedPairs.isEmpty)
        XCTAssertFalse(window.isVisible)
    }
}
