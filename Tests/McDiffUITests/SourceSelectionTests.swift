import AppKit
import CoreText
import McDiffCore
import XCTest
@testable import McDiff

final class SourceSelectionTests: XCTestCase {
    @MainActor
    private func fixture(layout: DiffLayout = .split, texts: [String] = ["alpha beta", "second line", "last value"]) async throws -> (DiffViewport, NSWindow) {
        _ = NSApplication.shared
        let viewport = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let window = NSWindow(contentRect: viewport.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewport
        viewport.diffLayout = layout
        let lines = texts.enumerated().map {
            DiffLine(kind: .context, text: $0.element, oldNumber: $0.offset + 10, newNumber: $0.offset + 20)
        }
        let file = FileDiff(path: "source.txt", hunks: [DiffHunk(header: "", lines: lines)], fingerprint: "selection")
        viewport.expanded = [file.path]
        viewport.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        try await ready(viewport)
        return (viewport, window)
    }

    @MainActor
    private func ready(_ viewport: DiffViewport) async throws {
        for _ in 0..<500 {
            viewport.layoutSubtreeIfNeeded()
            if !viewport.isLayoutPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Selection fixture layout did not finish")
    }

    @MainActor
    private func row(_ viewport: DiffViewport, side: DiffSide, number: Int) throws -> Int {
        try XCTUnwrap(viewport.rows.firstIndex {
            let line = $0.line(on: side)
            return (side == .old ? line?.oldNumber : line?.newNumber) == number
        })
    }

    @MainActor
    private func point(_ viewport: DiffViewport, side: DiffSide, number: Int, offset: Int) throws -> NSPoint {
        let row = try row(viewport, side: side, number: number)
        let line = try XCTUnwrap(viewport.rows[row].line(on: side))
        let displayed = line.text.replacingOccurrences(of: "\t", with: "    ")
        let rich = NSAttributedString(string: displayed, attributes: [.font: McDiff.Style.codeFont])
        let index = SourceTextOffsets.displayOffset(offset, in: line.text)
        let fragments = viewport.textFragments(rich, file: 0, side: side)
        let fragmentIndex = fragments.firstIndex { index >= $0.location && index < NSMaxRange($0) } ?? fragments.count - 1
        let fragment = fragments[fragmentIndex]
        let ct = CTTypesetterCreateLine(CTTypesetterCreateWithAttributedString(rich),
                                       CFRange(location: fragment.location, length: fragment.length))
        let origin = viewport.diffLayout == .split && side == .new ? viewport.table.bounds.width / 2 : 0
        return NSPoint(x: origin + viewport.sourceTextInset(file: 0) + CTLineGetOffsetForStringIndex(ct, index, nil)
                       - viewport.horizontalOffset(file: 0, side: side) + 0.01,
                       y: viewport.table.rect(ofRow: row).minY + CGFloat(fragmentIndex) * McDiff.Style.rowHeight + 8)
    }

    @MainActor
    private func drag(_ viewport: DiffViewport, side: DiffSide, from: (Int, Int), to: (Int, Int)) throws {
        let start = try point(viewport, side: side, number: from.0, offset: from.1)
        let anchor = try XCTUnwrap(viewport.beginPointerSelection(
            row: try row(viewport, side: side, number: from.0), point: start, shift: false))
        viewport.updatePointerSelection(row: try row(viewport, side: side, number: to.0),
                                        point: try point(viewport, side: side, number: to.0, offset: to.1), anchor: anchor)
        viewport.endPointerSelection(anchor)
    }

    @MainActor
    func testSourceDragCopiesExactCharactersAcrossLinesWithoutOpeningComment() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (viewport, window) = try await fixture(layout: layout)
            defer { window.close() }
            var comments = 0
            viewport.onComment = { _ in comments += 1 }
            for side in layout == .split ? [DiffSide.old, .new] : [.new] {
                let first = side == .old ? 10 : 20
                try drag(viewport, side: side, from: (first, 6), to: (first + 1, 6))
                XCTAssertEqual(viewport.selectedSourceText(), "beta\nsecond")
                XCTAssertNil(viewport.selection)
                try drag(viewport, side: side, from: (first + 1, 6), to: (first, 6))
                XCTAssertEqual(viewport.selectedSourceText(), "beta\nsecond")
                XCTAssertEqual(comments, 0)
            }
            XCTAssertFalse(window.isVisible)
            XCTAssertNil(window.attachedSheet)
        }
    }

    @MainActor
    func testNumberGutterCommentsKeepBothOriginalSidesInEitherLayout() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (viewport, window) = try await fixture(layout: layout)
            defer { window.close() }
            var comments: [LineSelection] = []
            viewport.onComment = { comments.append($0) }
            for side in [DiffSide.old, .new] {
                let first = side == .old ? 10 : 20
                let start = try row(viewport, side: side, number: first)
                let end = try row(viewport, side: side, number: first + 2)
                let origin = layout == .split && side == .new ? viewport.table.bounds.width / 2 : 0
                let x = origin + viewport.sourceGutter(file: 0).columnOffset(side) + 2
                let anchor = try XCTUnwrap(viewport.beginPointerSelection(row: start,
                    point: NSPoint(x: x, y: viewport.table.rect(ofRow: start).minY + 8), shift: false))
                viewport.updatePointerSelection(row: end,
                    point: NSPoint(x: x, y: viewport.table.rect(ofRow: end).minY + 8), anchor: anchor)
                viewport.endPointerSelection(anchor)
                XCTAssertEqual(comments.last?.side, side)
                XCTAssertEqual(comments.last?.start, first)
                XCTAssertEqual(comments.last?.end, first + 2)
                XCTAssertEqual(viewport.selectedSourceText(), "alpha beta\nsecond line\nlast value")
            }
            XCTAssertEqual(comments.count, 2)
        }
    }

    @MainActor
    func testTabsAndComposedCharactersCopyOriginalSource() async throws {
        let (viewport, window) = try await fixture(texts: ["\talpha 👨‍👩‍👧‍👦 beta", "next\tvalue"])
        defer { window.close() }
        var comments = 0
        viewport.onComment = { _ in comments += 1 }
        try drag(viewport, side: .new, from: (20, 0), to: (21, 5))
        XCTAssertEqual(viewport.selectedSourceText(), "\talpha 👨‍👩‍👧‍👦 beta\nnext\t")
        try drag(viewport, side: .new, from: (20, 7), to: (20, 18))
        XCTAssertEqual(viewport.selectedSourceText(), "👨‍👩‍👧‍👦")
        XCTAssertEqual(comments, 0)
    }

    @MainActor
    func testWrappedAndHorizontallyScrolledSelectionsUseSourceOffsets() async throws {
        let text = String(repeating: "abcdefghij ", count: 50)
        let (viewport, window) = try await fixture(texts: [text])
        defer { window.close() }
        viewport.scrollHorizontally(400, file: 0, side: .new)
        XCTAssertGreaterThan(viewport.horizontalOffset(file: 0, side: .new), 0)
        try drag(viewport, side: .new, from: (20, 70), to: (20, 82))
        XCTAssertEqual(viewport.selectedSourceText(), (text as NSString).substring(with: NSRange(location: 70, length: 12)))
        viewport.softWrap = true
        try await ready(viewport)
        try drag(viewport, side: .new, from: (20, 5), to: (20, 120))
        XCTAssertEqual(viewport.selectedSourceText(), (text as NSString).substring(with: NSRange(location: 5, length: 115)))
    }

    @MainActor
    func testSavedCommentRailOpensOriginalRangeWhileTrailingSpaceDoesNot() async throws {
        let (viewport, window) = try await fixture(layout: .unified)
        defer { window.close() }
        viewport.setComments([ReviewComment(path: "source.txt", side: .old, startLine: 10, endLine: 11,
                                           text: "Saved", fingerprint: "selection")])
        try await ready(viewport)
        let row = try row(viewport, side: .old, number: 10)
        let marker = try XCTUnwrap(viewport.commentMarkerRect(file: 0, side: .old))
        var comments: [LineSelection] = []
        viewport.onComment = { comments.append($0) }
        XCTAssertNil(viewport.beginPointerSelection(row: row,
            point: NSPoint(x: marker.midX, y: viewport.table.rect(ofRow: row).minY + 8), shift: false))
        XCTAssertEqual(comments.last?.side, .old)
        XCTAssertEqual(comments.last?.start, 10)
        XCTAssertNil(viewport.beginPointerSelection(row: row,
            point: NSPoint(x: 650, y: viewport.table.rect(ofRow: row).minY + 8), shift: false))
        XCTAssertEqual(comments.count, 1)
    }

    @MainActor
    func testChangedLinesAndEmptySplitCellsRetainOriginalSideAndClampTextDrag() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (viewport, window) = try await fixture(layout: layout)
            defer { window.close() }
            let file = FileDiff(path: "source.txt", hunks: [DiffHunk(header: "", lines: [
                DiffLine(kind: .deletion, text: "old text", oldNumber: 10, newNumber: nil),
                DiffLine(kind: .addition, text: "new text", oldNumber: nil, newNumber: 20),
                DiffLine(kind: .addition, text: "added", oldNumber: nil, newNumber: 21)
            ])], fingerprint: "changed")
            viewport.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
            try await ready(viewport)
            var comments = 0
            viewport.onComment = { _ in comments += 1 }
            for side in [DiffSide.old, .new] {
                let number = side == .old ? 10 : 20
                try drag(viewport, side: side, from: (number, 0), to: (number, 3))
                XCTAssertEqual(viewport.selectedSourceText(), side == .old ? "old" : "new")
                let index = try row(viewport, side: side, number: number)
                let anchor = try XCTUnwrap(viewport.beginPointerSelection(row: index,
                    point: try point(viewport, side: side, number: number, offset: 3), shift: false))
                viewport.updatePointerSelection(row: index, point: NSPoint(x: -100, y: viewport.table.rect(ofRow: index).minY + 8), anchor: anchor)
                viewport.endPointerSelection(anchor)
                XCTAssertEqual(viewport.selectedSourceText(), side == .old ? "old" : "new")
                let suffix = try XCTUnwrap(viewport.beginPointerSelection(row: index,
                    point: try point(viewport, side: side, number: number, offset: 3), shift: false))
                viewport.updatePointerSelection(row: index,
                    point: NSPoint(x: viewport.table.bounds.width + 100, y: viewport.table.rect(ofRow: index).minY + 8), anchor: suffix)
                viewport.endPointerSelection(suffix)
                XCTAssertEqual(viewport.selectedSourceText(), " text")
            }
            if layout == .split {
                let index = try row(viewport, side: .new, number: 21)
                for x in [CGFloat(2), viewport.sourceTextInset(file: 0) + 2] {
                    XCTAssertNil(viewport.beginPointerSelection(row: index,
                        point: NSPoint(x: x, y: viewport.table.rect(ofRow: index).minY + 8), shift: false))
                }
            }
            XCTAssertEqual(comments, 0)
        }
    }

    @MainActor
    func testDiffSpaceAndReturnToggleReviewWithoutAdvancingAndRespectAutoReview() async throws {
        let (viewport, window) = try await fixture()
        defer { window.close() }
        var reviewed = false
        var actions = 0
        viewport.isReviewed = { _ in reviewed }
        viewport.onReviewToggle = { _, value in reviewed = value; actions += 1 }
        for (characters, code) in [(" ", UInt16(49)), ("\r", 36)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            viewport.table.keyDown(with: event)
        }
        XCTAssertEqual(actions, 2)
        XCTAssertFalse(reviewed)
        XCTAssertEqual(viewport.focusedFile, 0)
        let skipped = FileDiff(path: "README.md", hunks: [], fingerprint: "docs", category: .documentation)
        viewport.setFiles([skipped], presentations: [:])
        viewport.filters.documentation = true
        viewport.toggleFocusedReviewed()
        XCTAssertEqual(actions, 2)
    }

    @MainActor
    func testReplacingFileOrderClearsCharacterSelectionRatherThanTargetingAnotherFile() async throws {
        let (viewport, window) = try await fixture()
        defer { window.close() }
        try drag(viewport, side: .new, from: (20, 0), to: (20, 5))
        XCTAssertEqual(viewport.selectedSourceText(), "alpha")
        viewport.files = [FileDiff(path: "another.txt", hunks: [], fingerprint: "another")] + viewport.files
        XCTAssertNil(viewport.selectedSourceText())
        XCTAssertNil(viewport.textSelection)
        XCTAssertNil(viewport.selection)
    }

    @MainActor
    func testCharacterSelectionPaintsOnlyItsTextRangeInDarkAppearance() async throws {
        for layout in [DiffLayout.split, .unified] {
            let (viewport, window) = try await fixture(layout: layout)
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            try drag(viewport, side: .new, from: (20, 0), to: (20, 5))
            let index = try row(viewport, side: .new, number: 20)
            let cell = DiffCell(frame: NSRect(x: 0, y: 0, width: viewport.table.bounds.width, height: McDiff.Style.rowHeight))
            cell.owner = viewport
            cell.rowIndex = index
            let image = NSImage(size: cell.bounds.size, flipped: true) { _ in
                window.appearance?.performAsCurrentDrawingAppearance { cell.draw(cell.bounds) }
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let scale = CGFloat(bitmap.pixelsWide) / cell.bounds.width
            let start = try point(viewport, side: .new, number: 20, offset: 0).x
            let end = try point(viewport, side: .new, number: 20, offset: 5).x
            // Sample above glyph ascenders: selected range has a background;
            // the rest of this context line stays transparent.
            let y = Int(2 * scale)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int((start + end) / 2 * scale), y: y)).alphaComponent, 0.8)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: Int((end + 8) * scale), y: y)).alphaComponent, 0)
        }
    }
}
