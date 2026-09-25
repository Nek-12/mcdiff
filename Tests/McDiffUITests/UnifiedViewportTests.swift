import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class UnifiedViewportTests: XCTestCase {
    @MainActor
    private func ready(_ view: DiffViewport, markdown: FileDiff? = nil) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            if !view.isLayoutPending, !view.isSearchPending,
               markdown.map({ view.markdownLayout(for: $0) != nil }) ?? true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Unified layout did not complete")
    }

    @MainActor
    private func makeView(_ files: [FileDiff], layout: DiffLayout = .unified) -> (DiffViewport, NSWindow) {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        view.diffLayout = layout
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        return (view, window)
    }

    private func changedFile(path: String = "code.swift", count: Int = 2, long: Bool = false) -> FileDiff {
        let suffix = long ? String(repeating: " café 👩🏽‍💻 value ", count: 100) : ""
        let lines = (1...count).map { DiffLine(kind: .deletion, text: "old value \($0)" + suffix, oldNumber: $0, newNumber: nil) } +
            (1...count).map { DiffLine(kind: .addition, text: "new value \($0)" + suffix, oldNumber: nil, newNumber: $0) } +
            [DiffLine(kind: .context, text: "shared context", oldNumber: count + 1, newNumber: count + 2)]
        return FileDiff(path: path, hunks: [DiffHunk(header: "", lines: lines)], fingerprint: path)
    }

    @MainActor
    func testUnifiedCodeSelectionKeepsOriginalSidesAndBothContextCommentGutters() async throws {
        let (view, window) = makeView([changedFile()])
        defer { window.orderOut(nil) }
        try await ready(view)
        XCTAssertEqual(view.paneWidth, view.table.bounds.width)
        XCTAssertEqual(view.rows.count, 7, "Header, two deletions, two additions, one context, padding")
        var comments: [LineSelection] = []
        view.onComment = { comments.append($0) }
        for (row, side, number) in [(1, DiffSide.old, 1), (2, .old, 2), (3, .new, 1), (4, .new, 2), (5, .new, 4)] {
            let point = NSPoint(x: view.sourceTextInset(file: 0) + 6, y: view.table.rect(ofRow: row).minY + 8)
            XCTAssertTrue(view.hitsCode(row: row, point: point))
            XCTAssertFalse(view.hitsCode(row: row, point: NSPoint(x: view.sourceGutter(file: 0).changeLeading + 3, y: point.y)),
                           "The change-sign column is not source text")
            XCTAssertFalse(view.hitsCode(row: row, point: NSPoint(x: 900, y: point.y)), "Trailing space is not code")
            view.click(row: row, point: point, shift: false)
            view.commitSelection()
            XCTAssertEqual(comments.last?.side, side)
            XCTAssertEqual(comments.last?.start, number)
        }
        view.setComments([
            ReviewComment(path: "code.swift", side: .old, startLine: 3, endLine: 3, text: "old", fingerprint: "code.swift"),
            ReviewComment(path: "code.swift", side: .new, startLine: 4, endLine: 4, text: "new", fingerprint: "code.swift")
        ])
        for (side, line) in [(DiffSide.old, 3), (.new, 4)] {
            let marker = try XCTUnwrap(view.commentMarkerRect(file: 0, side: side))
            let point = NSPoint(x: marker.midX, y: view.table.rect(ofRow: 5).minY + 8)
            XCTAssertTrue(view.hitsCode(row: 5, point: point))
            view.click(row: 5, point: point, shift: false)
            view.commitSelection()
            XCTAssertEqual(comments.last?.side, side)
            XCTAssertEqual(comments.last?.start, line)
        }
        view.click(row: 1, point: NSPoint(x: view.sourceTextInset(file: 0) + 6, y: 46), shift: false)
        let anchor = try XCTUnwrap(view.selection)
        view.drag(row: 2, point: .zero, anchor: anchor)
        XCTAssertEqual(view.selection?.end, 2)
        view.drag(row: 4, point: .zero, anchor: anchor)
        XCTAssertEqual(view.selection?.end, 2, "Dragging into an addition must not select its paired hidden deletion")
        XCTAssertNotNil(view.selectionAnchor)
    }

    @MainActor
    func testUnifiedWrappingUsesOnlyDisplayedLineAndHorizontalOffsetIsPerFile() async throws {
        let long = String(repeating: "long words ", count: 200)
        let file = FileDiff(path: "a.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: long, oldNumber: 1, newNumber: nil),
            DiffLine(kind: .addition, text: "short", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "a")
        let (view, window) = makeView([file, changedFile(path: "b.swift", long: true)])
        defer { window.orderOut(nil) }
        try await ready(view)
        view.scrollHorizontally(200, file: 0, side: .old)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 200)
        XCTAssertEqual(view.horizontalOffset(file: 1, side: .new), 0)
        view.softWrap = true
        try await ready(view)
        XCTAssertGreaterThan(view.table.rect(ofRow: 1).height, Style.rowHeight)
        XCTAssertEqual(view.table.rect(ofRow: 2).height, Style.rowHeight, "Hidden counterpart must not inflate unified rows")
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 0)
        let y = view.table.rect(ofRow: 1).maxY - Style.rowHeight + 4
        XCTAssertTrue(view.hitsCode(row: 1, point: NSPoint(x: view.sourceTextInset(file: 0) + 6, y: y)))
        view.click(row: 1, point: NSPoint(x: view.sourceTextInset(file: 0) + 6, y: y), shift: false)
        XCTAssertEqual(view.selection?.start, 1)
    }

    @MainActor
    func testLayoutSwitchReturnsToFocusedFileHeaderAcrossAsyncWrappingAndRapidChanges() async throws {
        let files = [changedFile(path: "before.swift", count: 80, long: true),
                     changedFile(path: "focused.swift", count: 80, long: true)]
        let (view, window) = makeView(files, layout: .split)
        defer { window.orderOut(nil) }
        view.softWrap = true
        try await ready(view)
        for mode in [DiffLayout.unified, .split, .unified, .split] {
            view.navigate(to: 1)
            let target = try XCTUnwrap(view.headerRows[1]) + 30
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: target).minY + 5))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            view.diffLayout = mode
            try await ready(view)
            let header = try XCTUnwrap(view.headerRows[1])
            XCTAssertEqual(view.scroll.documentVisibleRect.minY, view.table.rect(ofRow: header).minY, accuracy: 0.1)
            XCTAssertEqual(view.focusedFile, 1)
        }
        view.diffLayout = .unified
        view.diffLayout = .split
        view.diffLayout = .unified
        try await ready(view)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY,
                       view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY, accuracy: 0.1)
    }

    @MainActor
    func testLayoutSwitchUsesClickedFileEvenWhenPreviousFileTailIsVisible() async throws {
        let (view, window) = makeView([changedFile(path: "before.swift", count: 20),
                                       changedFile(path: "focused.swift", count: 20)], layout: .split)
        defer { window.orderOut(nil) }
        try await ready(view)
        let header = try XCTUnwrap(view.headerRows[1])
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: header).minY - 40))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        view.click(row: header + 1, point: NSPoint(x: 110, y: view.table.rect(ofRow: header + 1).midY), shift: false)
        XCTAssertEqual(view.focusedFile, 1)
        view.diffLayout = .unified
        try await ready(view)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY,
                       view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY, accuracy: 0.1)
    }

    @MainActor
    func testUnifiedImportsExpandCollapseWithoutConsumingAdjacentCode() async throws {
        let file = FileDiff(path: "imports.kt", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: "import Old", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .deletion, text: "import Older", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .addition, text: "import New", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .context, text: "run()", oldNumber: 3, newNumber: 2)
        ])], fingerprint: "imports")
        let (view, window) = makeView([file])
        defer { window.orderOut(nil) }
        try await ready(view)
        XCTAssertEqual(view.rows.count, 4)
        view.click(row: 1, point: .zero, shift: false)
        try await ready(view)
        XCTAssertEqual(view.rows.count, 7)
        XCTAssertEqual(view.rows[2].line(on: .old)?.text, "import Old")
        XCTAssertEqual(view.rows[3].line(on: .old)?.text, "import Older")
        XCTAssertEqual(view.rows[4].line(on: .new)?.text, "import New")
        view.click(row: 1, point: .zero, shift: false)
        try await ready(view)
        XCTAssertEqual(view.rows.count, 4)
        XCTAssertEqual(view.rows[2].line(on: .new)?.text, "run()")
    }

    @MainActor
    func testUnifiedMarkdownOnlyRendersAndSearchesNewContentButSourceKeepsDeletionComments() async throws {
        let file = changedFile(path: "guide.md")
        let (view, window) = makeView([file])
        defer { window.orderOut(nil) }
        view.markdownContent = [file.path: MarkdownFileContent(old: String(repeating: "Removed **needle**\n\n", count: 100),
                                                             new: "# New visible needle")]
        view.toggleMarkdown(for: 0)
        try await ready(view, markdown: file)
        let unified = try XCTUnwrap(view.markdownLayout(for: file))
        XCTAssertEqual(unified.old.storage.length, 0)
        XCTAssertTrue(unified.new.storage.string.contains("New visible needle"))
        XCTAssertLessThan(unified.height, 150, "Old hidden content must not contribute height")
        view.search(query: "needle")
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .markdown(file: 0, side: .new))
        view.nextSearchMatch()
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .markdown(file: 0, side: .new))
        view.diffLayout = .split
        try await ready(view, markdown: file)
        XCTAssertGreaterThan(try XCTUnwrap(view.markdownLayout(for: file)).old.storage.length, 100)
        view.diffLayout = .unified
        view.toggleMarkdown(for: 0)
        try await ready(view)
        XCTAssertFalse(view.rendersMarkdown(file))
        XCTAssertEqual(view.rows[1].line(on: .old)?.text, "old value 1")
        view.click(row: 1, point: NSPoint(x: 110, y: 45), shift: false)
        XCTAssertEqual(view.selection?.side, .old)
        XCTAssertEqual(view.selection?.start, 1)
    }

    @MainActor
    func testUnifiedSearchNavigatesInDisplayOrderAndDoesNotTargetHiddenCounterparts() async throws {
        let (view, window) = makeView([changedFile()])
        defer { window.orderOut(nil) }
        view.search(query: "value")
        for (side, number, row) in [(DiffSide.old, 1, 1), (.old, 2, 2), (.new, 1, 3), (.new, 2, 4)] {
            try await ready(view)
            XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: side, line: number, importBlock: nil))
            XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: row)))
            view.nextSearchMatch()
        }
        try await ready(view)
        view.nextSearchMatch()
        try await ready(view)
        let selected = view.currentSearchMatch
        for mode in [DiffLayout.split, .unified] {
            view.diffLayout = mode
            try await ready(view)
            XCTAssertEqual(view.currentSearchMatch, selected, "A layout change preserves the selected search occurrence")
        }
    }

    @MainActor
    func testThirtyThousandUnifiedSourceRowsRemainVirtualizedAcrossLayouts() async throws {
        let files = (0..<400).map { changedFile(path: "file\($0).swift", count: 37) }
        let (view, window) = makeView(files)
        defer { window.orderOut(nil) }
        view.softWrap = true
        try await ready(view)
        XCTAssertEqual(view.rows.count, 30_401, "400 × (74 changed lines + context + header), plus padding")
        for mode in [DiffLayout.unified, .split, .unified] {
            view.diffLayout = mode
            try await ready(view)
            for file in stride(from: 0, to: 400, by: 39) {
                view.navigate(to: file)
                view.table.layoutSubtreeIfNeeded()
                var count = 0
                view.table.enumerateAvailableRowViews { _, _ in count += 1 }
                XCTAssertLessThan(count, 120)
            }
        }
    }

    @MainActor
    func testUnifiedTintIsFullWidthAndContinuousAtFractionalScrollPositionsInDarkAppearance() async throws {
        let (view, window) = makeView([changedFile(count: 8)])
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        try await ready(view)
        let size = NSSize(width: view.table.bounds.width, height: Style.rowHeight * 17)
        for scale: CGFloat in [1, 2] {
            for offset: CGFloat in [0, 0.25, 0.5, 0.75] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                    pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.translateBy(x: 0, y: -38 - offset)
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.table.drawBackground(inClipRect: NSRect(x: 0, y: 38, width: size.width, height: size.height))
                }
                NSGraphicsContext.restoreGraphicsState()
                for block in 0...1 {
                    let first = Int((CGFloat(block * 8) * Style.rowHeight + 3) * scale)
                    let last = Int((CGFloat((block + 1) * 8) * Style.rowHeight - 3) * scale)
                    let expected = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: first))
                    XCTAssertGreaterThan(expected.alphaComponent, 0)
                    for x in [bitmap.pixelsWide / 4, bitmap.pixelsWide * 3 / 4] {
                        for y in first..<last {
                            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001)
                            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
                            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
                        }
                    }
                }
                let contextY = Int((Style.rowHeight * 16.5) * scale)
                XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: contextY)?.alphaComponent, 0)
                XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: contextY)?.alphaComponent, 0)
            }
        }
    }

    @MainActor
    func testUnifiedContextRendersBothCommentMarkersAtRightEdge() async throws {
        let (view, window) = makeView([changedFile()])
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        view.setComments([
            ReviewComment(path: "code.swift", side: .old, startLine: 3, endLine: 3, text: "old", fingerprint: "code.swift"),
            ReviewComment(path: "code.swift", side: .new, startLine: 4, endLine: 4, text: "new", fingerprint: "code.swift")
        ])
        try await ready(view)
        let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: 5, makeIfNecessary: true) as? DiffCell)
        let image = NSImage(size: NSSize(width: 48, height: cell.bounds.height), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: -cell.bounds.width + 48, y: 0)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { cell.draw(cell.bounds) }
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsWide) / 48
        for x: CGFloat in [5, 29] {
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(8 * scale))).alphaComponent, 0)
        }
    }

}
