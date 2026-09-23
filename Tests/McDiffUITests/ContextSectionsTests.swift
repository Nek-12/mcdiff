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
    private static func resolved(_ file: FileDiff, tailCount: Int = 4) -> [PresentedRow] {
        let count = file.hunks.last!.oldRange!.upperBound + tailCount
        var old = (1...count).map { $0 == 10 ? "let hiddenNeedle = 10" : "let context\($0) = \($0)" }
        var new = old
        for line in file.hunks.flatMap(\.lines) {
            if let number = line.oldNumber { old[number - 1] = line.text }
            if let number = line.newNumber { new[number - 1] = line.text }
        }
        return DiffPresentation.rows(for: file, oldSource: old.joined(separator: "\n") + "\n",
                                     newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
    }
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GitError("Context did not settle")
    }
    @MainActor
    private func contextRow(_ view: DiffViewport, section: Int) throws -> Int {
        try XCTUnwrap(view.rows.firstIndex {
            if case .context(let value) = $0.content { return value.id == section }
            return false
        })
    }
    @MainActor
    func testManualContextSupportsSearchCopyCommentsAndBothLayouts() async throws {
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
        let rich = try await SyntaxService().highlight(file: file, dark: true, context: view.contextPageLines(file: 0, page: 0))
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
        XCTAssertTrue(view.contextPageLines(file: 0, page: 0).isEmpty)
        XCTAssertEqual(view.files[0].fingerprint, "original-review")
        XCTAssertFalse(view.isReviewed(file))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticSmallContextKeepsLargeGapFoldedAndSupportsBothSidesWithoutChangingReview() async throws {
        _ = NSApplication.shared
        let file = file()
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.softWrap = true
        var requests = 0
        view.contexts.resolve = { file in
            requests += 1
            try await Task.sleep(for: .milliseconds(30))
            return Self.resolved(file)
        }
        view.contexts.load = { _, section in Self.pairs(section) }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { !view.isLayoutPending }
        XCTAssertEqual(requests, 0, "A collapsed file must stay lazy")
        let headerPosition = view.table.rect(ofRow: 0).minY - view.scroll.documentVisibleRect.minY
        view.setExpanded(true, file: 0)
        XCTAssertEqual(view.contextTitle(file: 0, section: file.unchangedSections[0]), "Loading unchanged lines…")
        try await wait {
            if case .ready = view.contexts.preparation(path: file.path) { return !view.isLayoutPending }
            return false
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(view.table.rect(ofRow: 0).minY - view.scroll.documentVisibleRect.minY, headerPosition, accuracy: 1)
        XCTAssertEqual(view.rows.compactMap { row -> Int? in
            if case .context(let section) = row.content { return section.oldStart }; return nil
        }, [5])
        XCTAssertEqual(view.rows.compactMap { row -> Int? in
            if case .code(let pair) = row.content, pair.old?.kind == .context { return pair.old?.oldNumber }; return nil
        }, [1, 2, 3, 4, 22, 23, 24, 25])
        var matches = -1
        view.onSearchResults = { _, count in matches = count }
        view.search(query: "context3")
        try await wait { !view.isSearchPending }
        XCTAssertEqual(matches, 1)
        view.search(query: "hiddenNeedle")
        try await wait { !view.isSearchPending }
        XCTAssertEqual(matches, 0)
        let rich = try await SyntaxService().highlight(file: file, dark: true, context: view.contextPageLines(file: 0, page: 0))
        XCTAssertEqual(rich.old[3]?.string, "let context3 = 3")
        XCTAssertEqual(rich.new[3]?.string, "let context3 = 3")
        XCTAssertNil(rich.new[10])
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            try await wait { !view.isLayoutPending }
            for side in [DiffSide.old, .new] {
                view.selection = LineSelection(file: 0, side: side, start: 3, end: 3)
                XCTAssertEqual(view.selectedSourceText(), "let context3 = 3")
                var commented: LineSelection?
                view.onComment = { commented = $0 }
                view.commitSelection()
                XCTAssertEqual(commented?.side, side)
                XCTAssertEqual(commented?.start, 3)
            }
        }
        let section = file.unchangedSections[1]
        view.click(row: try contextRow(view, section: section.id), point: .zero, shift: false)
        try await wait { !view.isLayoutPending && !view.isSearchPending && matches == 1 }
        view.click(row: try contextRow(view, section: section.id), point: .zero, shift: false)
        try await wait { !view.isLayoutPending && !view.isSearchPending && matches == 0 }
        XCTAssertEqual(view.contextPageLines(file: 0, page: 0).count, 8, "Automatic lines remain after a manual gap collapses")
        view.setExpanded(false, file: 0)
        view.setExpanded(true, file: 0)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(view.files[0].fingerprint, "original-review")
        XCTAssertFalse(view.isReviewed(file))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticResolutionFailureOffersRetryAndResetDiscardsPendingResult() async throws {
        _ = NSApplication.shared
        let file = file()
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.expanded = [file.path]
        view.contexts.resolve = { _ in throw GitError("Read failed. Refresh or retry.") }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { if case .failed = view.contexts.preparation(path: file.path) { return true }; return false }
        let section = file.unchangedSections[0]
        XCTAssertTrue(view.contextTitle(file: 0, section: section).contains("Read failed. Refresh or retry. — Retry"))
        view.contexts.resolve = { Self.resolved($0) }
        view.click(row: try contextRow(view, section: section.id), point: .zero, shift: false)
        try await wait { if case .ready = view.contexts.preparation(path: file.path) { return true }; return false }
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        try await wait { pending != nil }
        view.setFiles([], presentations: [:])
        pending?.resume(returning: Self.resolved(file))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(view.presentations.isEmpty)
        XCTAssertTrue(view.rows.isEmpty)
        XCTAssertNil(view.contexts.preparation(path: file.path))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticReadsStayLimitedToVisibleExpandedFilesInLargeReview() async throws {
        _ = NSApplication.shared
        let files = (0..<400).map { index in
            FileDiff(path: "file\(index).swift", hunks: file().hunks, fingerprint: "\(index)")
        }
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.expanded = Set(files.map(\.path))
        var requested: Set<String> = []
        view.contexts.resolve = { file in requested.insert(file.path); return Self.resolved(file) }
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        view.layoutSubtreeIfNeeded()
        try await wait { !requested.isEmpty && !view.isLayoutPending }
        XCTAssertLessThan(requested.count, 10)
        XCTAssertFalse(requested.contains(files.last!.path))
        view.navigate(to: 399)
        try await wait { requested.contains(files.last!.path) && !view.isLayoutPending }
        XCTAssertLessThan(requested.count, 20)
        var available = 0
        view.table.enumerateAvailableRowViews { _, _ in available += 1 }
        XCTAssertLessThan(available, 150)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticImportRunSearchExpandsOmittedLinesWithOriginalCommentAndCopyTargets() async throws {
        _ = NSApplication.shared
        let old = ["package sample", "", "import ("] + (1...40).map { "\t\"module\($0)\"" } +
            [")", "", "func main() {}"] + (1...10).map { "// tail \($0)" }
        var new = old
        new[12] = "\t\"replacement10\""
        new[30] = "\t\"replacement28\""
        let file = FileDiff(path: "source.go", hunks: [9..<16, 27..<34].map { range in
            DiffHunk(header: "", lines: range.flatMap { index -> [DiffLine] in
                if old[index] == new[index] {
                    return [DiffLine(kind: .context, text: old[index], oldNumber: index + 1, newNumber: index + 1)]
                }
                return [DiffLine(kind: .deletion, text: old[index], oldNumber: index + 1, newNumber: nil),
                        DiffLine(kind: .addition, text: new[index], oldNumber: nil, newNumber: index + 1)]
            }, oldRange: range, newRange: range)
        }, fingerprint: "imports")
        let resolved = DiffPresentation.rows(for: file, oldSource: old.joined(separator: "\n") + "\n",
                                             newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.expanded = [file.path]
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { pending != nil && !view.isLayoutPending }
        let before = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 13 })
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: before).minY + 4))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        let inset = view.table.rect(ofRow: before).minY - view.scroll.documentVisibleRect.minY
        pending?.resume(returning: resolved)
        try await wait { if case .ready = view.contexts.preparation(path: file.path) { return !view.isLayoutPending }; return false }
        let after = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 13 })
        XCTAssertEqual(view.table.rect(ofRow: after).minY - view.scroll.documentVisibleRect.minY, inset, accuracy: 1)
        XCTAssertEqual(view.rows.filter { if case .imports = $0.content { return true }; return false }.count, 1)
        XCTAssertEqual(view.rows.filter { if case .context = $0.content { return true }; return false }.count, 1)
        view.setComments([ReviewComment(path: file.path, side: .old, startLine: 23, endLine: 23,
                                        text: "Omitted import note", fingerprint: file.fingerprint)])
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            view.search(query: "")
            view.search(query: "module20")
            try await wait { !view.isSearchPending && !view.isLayoutPending }
            guard case .code(file: 0, side: .new, line: 23, importBlock: .some) = view.currentSearchMatch?.target else {
                return XCTFail("Omitted imports must be searchable as imports")
            }
            XCTAssertTrue(view.rows.contains { $0.line(on: .old)?.oldNumber == 23 })
            for side in [DiffSide.old, .new] {
                view.selection = LineSelection(file: 0, side: side, start: 23, end: 23)
                XCTAssertEqual(view.selectedSourceText(), "\t\"module20\"")
                var selected: LineSelection?
                view.onComment = { selected = $0 }
                view.commitSelection()
                XCTAssertEqual(selected?.side, side)
                XCTAssertEqual(selected?.start, 23)
            }
        }
        XCTAssertEqual(view.commentRange(file.path, .old, 23), 23...23)
        let rich = try await SyntaxService().highlight(file: file, dark: true, context: view.contextPageLines(file: 0, page: 0))
        XCTAssertEqual(rich.old[23]?.string, "    \"module20\"")
        XCTAssertEqual(rich.new[23]?.string, "    \"module20\"")
        XCTAssertNil(rich.new[50], "Ordinary folded remainder must not enter highlight pages")
        XCTAssertFalse(view.isReviewed(file))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticHighlightPagesStayBoundedForThirtyThousandOmittedImports() async throws {
        _ = NSApplication.shared
        let old = (1...30_000).map { "import module\($0).Name" }
        var new = old
        new[15_000] = "import changed.Name"
        let file = FileDiff(path: "large.kt", hunks: [
            DiffHunk(header: "", lines: [
                DiffLine(kind: .deletion, text: old[15_000], oldNumber: 15_001, newNumber: nil),
                DiffLine(kind: .addition, text: new[15_000], oldNumber: nil, newNumber: 15_001)
            ], oldRange: 15_000..<15_001, newRange: 15_000..<15_001)
        ], fingerprint: "large-imports")
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.expanded = [file.path]
        view.contexts.resolve = { file in
            await Task.detached {
                DiffPresentation.rows(for: file, oldSource: old.joined(separator: "\n") + "\n",
                                      newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
            }.value
        }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { if case .ready = view.contexts.preparation(path: file.path) { return !view.isLayoutPending }; return false }
        let importRow = try XCTUnwrap(view.rows.firstIndex { if case .imports = $0.content { return true }; return false })
        for page in [0, 50, 117] {
            let lines = view.contextPageLines(file: 0, page: page)
            XCTAssertFalse(lines.isEmpty)
            XCTAssertLessThanOrEqual(lines.count, SyntaxService.pageSize * 2)
            XCTAssertTrue(lines.allSatisfy { ($0.newNumber! - 1) / SyntaxService.pageSize == page })
        }
        XCTAssertTrue(view.contextPageLines(file: 0, page: 200).isEmpty)
        view.click(row: importRow, point: .zero, shift: false)
        try await wait { !view.isLayoutPending }
        XCTAssertEqual(view.rows.count, 30_003)
        var available = 0
        view.table.enumerateAvailableRowViews { _, _ in available += 1 }
        XCTAssertLessThan(available, 150)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testAutomaticResolutionPreservesSourcePositionAfterScrollingDuringReadAndWrapping() async throws {
        _ = NSApplication.shared
        let old = (1...65).map { "let value\($0) = \"" + String(repeating: "wrapped text ", count: 18) + "\"" }
        var new = old
        new[5] = "let changed = true"
        let file = FileDiff(path: "wrapped.swift", hunks: [DiffHunk(header: "", lines: (4..<60).flatMap { index -> [DiffLine] in
            if old[index] == new[index] {
                return [DiffLine(kind: .context, text: old[index], oldNumber: index + 1, newNumber: index + 1)]
            }
            return [DiffLine(kind: .deletion, text: old[index], oldNumber: index + 1, newNumber: nil),
                    DiffLine(kind: .addition, text: new[index], oldNumber: nil, newNumber: index + 1)]
        }, oldRange: 4..<60, newRange: 4..<60)], fingerprint: "wrapped")
        let resolved = DiffPresentation.rows(for: file, oldSource: old.joined(separator: "\n") + "\n",
                                             newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.softWrap = true
        view.expanded = [file.path]
        var pending: CheckedContinuation<[PresentedRow], Never>?
        view.contexts.resolve = { _ in await withCheckedContinuation { pending = $0 } }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await wait { pending != nil && !view.isLayoutPending }
        let before = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 35 })
        let position = view.table.rect(ofRow: before).minY + 25
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        XCTAssertGreaterThan(view.scroll.documentVisibleRect.minY, 500)
        let inset = view.table.rect(ofRow: before).minY - view.scroll.documentVisibleRect.minY
        pending?.resume(returning: resolved)
        try await wait { if case .ready = view.contexts.preparation(path: file.path) { return !view.isLayoutPending }; return false }
        let after = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 35 })
        XCTAssertEqual(view.table.rect(ofRow: after).minY - view.scroll.documentVisibleRect.minY, inset, accuracy: 1)
        XCTAssertGreaterThan(view.scroll.documentVisibleRect.minY, 500)
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
        XCTAssertLessThanOrEqual(view.contextPageLines(file: 0, page: 50).count, SyntaxService.pageSize * 2)
        XCTAssertEqual(view.sourceGutter(file: 0).numberWidth, SourceGutter.numberWidth(for: 30_021))
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        XCTAssertTrue(view.contexts.expandedPairs.isEmpty)
        XCTAssertFalse(window.isVisible)
    }
}
