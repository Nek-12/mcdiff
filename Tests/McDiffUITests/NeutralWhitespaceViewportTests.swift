import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class NeutralWhitespaceViewportTests: XCTestCase {
    private func fixture() -> FileDiff {
        FileDiff(path: "mixed.txt", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: "count    = 1", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .deletion, text: "tail = 2", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .deletion, text: "message = \"old value\"", oldNumber: 3, newNumber: nil),
            DiffLine(kind: .addition, text: "inserted = 0", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .addition, text: "count = 1", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .addition, text: "tail    = 2", oldNumber: nil, newNumber: 3),
            DiffLine(kind: .addition, text: "message = \"new value\"", oldNumber: nil, newNumber: 4)
        ])], fingerprint: "mixed", whitespaceChanges: [
            WhitespaceChange(oldNumber: 1, newNumber: 2),
            WhitespaceChange(oldNumber: 2, newNumber: 3)
        ])
    }

    @MainActor
    private func makeView(layout: DiffLayout) -> (DiffViewport, NSWindow) {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.diffLayout = layout
        view.filters.whitespaceAndImports = true
        let file = fixture()
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        return (view, window)
    }

    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending || view.isSearchPending {
            guard Date() < deadline else { XCTFail("Diff layout/search did not complete"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testMixedInsertionKeepsNeutralOriginalTextsAndRestoresRawRowsWhenDisabled() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (view, window) = makeView(layout: layout)
            defer { window.close() }
            try await ready(view)
            let neutral = view.rows.filter { $0.line(on: .new)?.newNumber == 2 }
            XCTAssertEqual(neutral.count, 1)
            let row = try XCTUnwrap(neutral.first)
            XCTAssertEqual(row.line(on: .old)?.text, "count    = 1")
            XCTAssertEqual(row.line(on: .new)?.text, "count = 1")
            XCTAssertEqual(row.line(on: .old)?.oldNumber, 1)
            XCTAssertEqual(row.line(on: .new)?.oldNumber, 1)
            XCTAssertEqual(row.line(on: .old)?.kind, .context)
            XCTAssertEqual(row.line(on: .new)?.kind, .context)
            XCTAssertTrue(view.rows.contains { $0.line(on: .new)?.newNumber == 1 && $0.line(on: .new)?.kind == .addition })
            XCTAssertTrue(view.rows.contains { $0.line(on: .old)?.oldNumber == 3 && $0.line(on: .old)?.kind == .deletion })
            XCTAssertTrue(view.rows.contains { $0.line(on: .new)?.newNumber == 4 && $0.line(on: .new)?.kind == .addition })

            view.filters.whitespaceAndImports = false
            view.rebuild()
            try await ready(view)
            XCTAssertTrue(view.rows.contains { $0.line(on: .old)?.oldNumber == 1 && $0.line(on: .old)?.kind == .deletion })
            XCTAssertTrue(view.rows.contains { $0.line(on: .new)?.newNumber == 2 && $0.line(on: .new)?.kind == .addition })
            XCTAssertFalse(view.rows.contains { $0.line(on: .new)?.kind == .context })
        }
    }

    func testSearchOnlyIndexesDisplayedNeutralTextInUnifiedAndBothOriginalTextsInSplit() async throws {
        let file = fixture()
        let engine = DiffSearchEngine()
        for layout in [DiffLayout.split, .unified] {
            for (query, expected) in [("count    =", layout == .split ? 1 : 0), ("count =", 1)] {
                let results = try await engine.search(query: query, files: [file],
                    presentations: [file.path: DiffPresentation.rows(for: file)], markdown: [:],
                    sourcePaths: [file.path], layout: layout, ignoringWhitespace: true)
                XCTAssertEqual(results.count, expected)
                if expected == 1 {
                    XCTAssertEqual(try results.match(at: 0)?.target,
                        .code(file: 0, side: query == "count =" ? .new : .old,
                              line: query == "count =" ? 2 : 1, importBlock: nil))
                }
            }
        }
        let raw = try await engine.search(query: "count    =", files: [file],
            presentations: [file.path: DiffPresentation.rows(for: file)], markdown: [:],
            sourcePaths: [file.path], layout: .unified, ignoringWhitespace: false)
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(try raw.match(at: 0)?.target, .code(file: 0, side: .old, line: 1, importBlock: nil))
    }

    @MainActor
    func testViewportSearchTracksTheCheckboxAndDisplayedLayout() async throws {
        let (view, window) = makeView(layout: .unified)
        defer { window.close() }
        view.search(query: "count    =")
        try await ready(view)
        XCTAssertNil(view.currentSearchMatch)
        view.filters.whitespaceAndImports = false
        view.rebuild()
        view.search(query: "count    =")
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .old, line: 1, importBlock: nil))
        view.filters.whitespaceAndImports = true
        view.diffLayout = .split
        view.rebuild()
        view.search(query: "count    =")
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .old, line: 1, importBlock: nil))
        view.search(query: "count =")
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .new, line: 2, importBlock: nil))
    }

    @MainActor
    func testSplitNeutralCodeSelectionUsesOriginalSideTextAndLineRange() async throws {
        let (view, window) = makeView(layout: .split)
        defer { window.close() }
        try await ready(view)
        let first = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 2 })
        let last = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 3 })
        for (side, start, end, expected) in [
            (DiffSide.old, 1, 2, "count    = 1\ntail = 2"),
            (.new, 2, 3, "count = 1\ntail    = 2")
        ] {
            let x = (side == .old ? 0 : view.table.bounds.width / 2) + view.sourceTextInset(file: 0) + 6
            let point = NSPoint(x: x, y: view.table.rect(ofRow: first).minY + 8)
            XCTAssertTrue(view.hitsCode(row: first, point: point))
            view.click(row: first, point: point, shift: false)
            view.drag(row: last, point: .zero, anchor: try XCTUnwrap(view.selection))
            XCTAssertEqual(view.selection?.side, side)
            XCTAssertEqual(view.selection?.start, start)
            XCTAssertEqual(view.selection?.end, end)
            XCTAssertEqual(view.selectedSourceText(), expected)
        }
    }

    @MainActor
    func testUnifiedNeutralCommentsAndCopyRetainBothOriginalSides() async throws {
        let (view, window) = makeView(layout: .unified)
        defer { window.close() }
        view.setComments([
            ReviewComment(path: "mixed.txt", side: .old, startLine: 1, endLine: 2, text: "Old", fingerprint: "mixed"),
            ReviewComment(path: "mixed.txt", side: .new, startLine: 2, endLine: 3, text: "New", fingerprint: "mixed")
        ])
        try await ready(view)
        let row = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 2 })
        var selected: LineSelection?
        view.onComment = { selected = $0 }
        for (side, number, expected) in [(DiffSide.old, 1, "count    = 1"), (.new, 2, "count = 1")] {
            let marker = try XCTUnwrap(view.commentMarkerRect(file: 0, side: side))
            let point = NSPoint(x: marker.midX, y: view.table.rect(ofRow: row).minY + 8)
            XCTAssertTrue(view.hitsCode(row: row, point: point))
            view.click(row: row, point: point, shift: false)
            view.commitSelection()
            XCTAssertEqual(selected?.side, side)
            XCTAssertEqual(selected?.start, number)
            XCTAssertEqual(view.selectedSourceText(), expected)
            XCTAssertNotNil(view.selectionAnchor)
        }
        let source = NSPoint(x: view.sourceTextInset(file: 0) + 6, y: view.table.rect(ofRow: row).minY + 8)
        view.click(row: row, point: source, shift: false)
        XCTAssertEqual(view.selection?.side, .new)
        view.selection = LineSelection(file: 0, side: .old, start: 1, end: 2)
        XCTAssertEqual(view.selectedSourceText(), "count    = 1\ntail = 2")
    }

    @MainActor
    func testUnifiedNeutralWrappingMeasuresOnlyTheDisplayedNewText() async throws {
        let (view, window) = makeView(layout: .unified)
        defer { window.close() }
        let oldText = String(repeating: " ", count: 2000) + "count = 1"
        let file = FileDiff(path: "wrapped.txt", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: oldText, oldNumber: 1, newNumber: nil),
            DiffLine(kind: .addition, text: "count = 1", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "wrap", whitespaceChanges: [WhitespaceChange(oldNumber: 1, newNumber: 1)])
        view.softWrap = true
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        try await ready(view)
        XCTAssertEqual(view.table.rect(ofRow: 1).height, Style.rowHeight, accuracy: 0.1)
        view.selection = LineSelection(file: 0, side: .old, start: 1, end: 1)
        XCTAssertEqual(view.selectedSourceText(), oldText)
        view.softWrap = false
        try await ready(view)
        XCTAssertEqual(view.scrollableWidth(file: 0, side: .new), 0)
    }

    @MainActor
    func testNeutralRowsPaintNoTintWordEmphasisOrSignsButKeepBothUnifiedNumbers() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (view, window) = makeView(layout: layout)
            defer { window.close() }
            try await ready(view)
            let row = try XCTUnwrap(view.rows.firstIndex { $0.line(on: .new)?.newNumber == 2 })
            let size = NSSize(width: view.table.bounds.width, height: view.table.bounds.height)
            let background = NSImage(size: size, flipped: true) { _ in
                view.table.drawBackground(inClipRect: NSRect(origin: .zero, size: size))
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(background.tiffRepresentation)))
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            let y = Int(view.table.rect(ofRow: row).midY * scale)
            for x in [bitmap.pixelsWide / 4, bitmap.pixelsWide * 3 / 4] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
            }
            let cell = DiffCell(frame: NSRect(x: 0, y: 0, width: size.width, height: Style.rowHeight))
            cell.owner = view
            cell.rowIndex = row
            let image = NSImage(size: cell.bounds.size, flipped: true) { _ in
                window.appearance?.performAsCurrentDrawingAppearance { cell.draw(cell.bounds) }
                return true
            }
            let painted = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            for x in 0..<painted.pixelsWide {
                for y in 0..<painted.pixelsHigh {
                    guard let color = painted.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.1 else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    XCTAssertLessThan(channels.max()! - channels.min()!, 0.25,
                                      "Neutral plain text must have no colored sign or word emphasis")
                }
            }
            if layout == .unified {
                let gutter = view.sourceGutter(file: 0)
                for side in [DiffSide.old, .new] {
                    let start = Int(gutter.columnOffset(side) * scale)
                    let end = Int((gutter.columnOffset(side) + gutter.numberTrailing) * scale)
                    XCTAssertTrue((start..<end).contains { x in
                        (0..<painted.pixelsHigh).contains { y in
                            (painted.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                        }
                    }, "Both original line-number columns remain visible")
                }
            }
        }
    }
}
