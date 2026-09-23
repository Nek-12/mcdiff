import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class StickyHeaderTests: XCTestCase {
    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            view.table.layoutSubtreeIfNeeded()
            if !view.isLayoutPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Diff layout did not finish")
    }

    @MainActor
    func testHeaderPinsAndNextHeaderPushesItAwayInBothLayouts() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let files = (0..<3).map { index in
            FileDiff(path: "file\(index).swift", hunks: [DiffHunk(header: "", lines: (1...50).map {
                DiffLine(kind: .addition, text: "let value\($0) = \($0)", oldNumber: nil, newNumber: $0)
            })], fingerprint: "\(index)")
        }
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            view.navigate(to: 0)
            try await ready(view)
            XCTAssertEqual(view.scroll.topFadeHeight, 0, "Source must not fade beneath the header")
            let next = try XCTUnwrap(view.headerRows[1])
            let nextY = view.table.rect(ofRow: next).minY
            for (origin, expected) in [(CGFloat(200), CGFloat(0)), (nextY - 19, CGFloat(-19))] {
                view.scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
                view.scroll.reflectScrolledClipView(view.scroll.contentView)
                try await ready(view)
                let cell = view.pinnedHeader.cell
                let rect = cell.convert(cell.bounds, to: view.table)
                XCTAssertEqual(cell.rowIndex, 0)
                XCTAssertEqual(rect.minY - view.scroll.documentVisibleRect.minY, expected, accuracy: 1)
                XCTAssertEqual(rect.height, 38, accuracy: 1)
                XCTAssertEqual(view.scroll.topFadeHeight, 0, "The gradient belongs to the header, not the scrolling code")
            }
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: nextY - 10))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            try await ready(view)
            let incoming = try XCTUnwrap(view.table.view(atColumn: 0, row: next, makeIfNecessary: true) as? DiffCell)
            incoming.layoutSubtreeIfNeeded()
            let check = try XCTUnwrap(incoming.subviews.compactMap { $0 as? AnimatedCheckbox }.first)
            let point = check.convert(NSPoint(x: check.bounds.midX, y: check.bounds.midY), to: view)
            XCTAssertTrue(view.hitTest(point) === check, "The pushed-out header must not intercept the incoming controls")
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: nextY + 100))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            try await ready(view)
            let cell = view.pinnedHeader.cell
            XCTAssertEqual(cell.rowIndex, next)
            XCTAssertEqual(cell.convert(cell.bounds, to: view.table).minY - view.scroll.documentVisibleRect.minY, 0, accuracy: 1)
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testPinnedHeaderControlsTargetCurrentFileAndRetainPositionThroughRemeasurement() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let file = FileDiff(path: "README.md", hunks: [DiffHunk(header: "", lines: (1...100).map {
            DiffLine(kind: .addition, text: "Paragraph \($0) " + String(repeating: "long words ", count: 30),
                     oldNumber: nil, newNumber: $0)
        })], fingerprint: "markdown")
        view.filters = ReviewFilters(tests: false, documentation: false, generated: false)
        view.softWrap = true
        view.markdownContent = [file.path: MarkdownFileContent(old: nil, new: String(repeating: "Paragraph.\n\n", count: 100))]
        var reviewed = false
        view.isReviewed = { _ in reviewed }
        view.onReviewToggle = { [weak view] selected, state in
            XCTAssertEqual(selected.path, file.path)
            reviewed = state
            view?.setExpanded(!state, file: 0)
            view?.redraw()
        }
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        for _ in 0..<400 {
            if view.markdownLayout(for: file) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(view.markdownLayout(for: file))
        try await ready(view)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        view.pinnedHeader.cell.layoutSubtreeIfNeeded()
        let markdown = try XCTUnwrap(view.pinnedHeader.cell.subviews.compactMap { $0 as? NSButton }
            .first { !($0 is AnimatedCheckbox) })
        markdown.performClick(nil)
        try await ready(view)
        XCTAssertFalse(view.rendersMarkdown(file))
        XCTAssertTrue(view.expanded.contains(file.path))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, 0, accuracy: 1)
        for state in [true, false] {
            let checkbox = try XCTUnwrap(view.pinnedHeader.cell.subviews.compactMap { $0 as? AnimatedCheckbox }.first)
            checkbox.performClick(nil)
            try await ready(view)
            XCTAssertEqual(reviewed, state)
            XCTAssertEqual(view.expanded.contains(file.path), !state)
            XCTAssertEqual(view.scroll.documentVisibleRect.minY, 0, accuracy: 1)
        }
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.pinnedHeader.cell.mouseDown(with: event)
        try await ready(view)
        XCTAssertFalse(view.expanded.contains(file.path))
        XCTAssertFalse(reviewed, "Disclosure must not mark a file reviewed")
        XCTAssertNil(view.selection)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, 0, accuracy: 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testHeaderFadesAtBottomWhileSourceKeepsOnlyBottomFade() throws {
        _ = NSApplication.shared
        let scroll = FadingScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        scroll.topFadeHeight = 0
        scroll.layoutSubtreeIfNeeded()
        let mask = try XCTUnwrap(scroll.layer?.mask)
        let image = NSImage(size: scroll.bounds.size, flipped: scroll.isFlipped) { _ in
            mask.render(in: NSGraphicsContext.current!.cgContext)
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsHigh) / scroll.bounds.height
        func alpha(_ y: CGFloat) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(y * scale))).alphaComponent
        }
        XCTAssertGreaterThan(try alpha(8), 0.99)
        XCTAssertGreaterThan(try alpha(36), 0.99)
        XCTAssertGreaterThan(try alpha(39), 0.99)
        XCTAssertGreaterThan(try alpha(60), 0.99)
        XCTAssertLessThan(try alpha(199), 0.15)

        let header = PinnedFileHeader(frame: NSRect(x: 0, y: 0, width: 100, height: 38))
        header.setHeaderFrame(header.bounds)
        let material = try XCTUnwrap(header.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        let headerMask = try XCTUnwrap(material.layer?.mask)
        let headerImage = NSImage(size: material.bounds.size, flipped: material.isFlipped) { _ in
            headerMask.render(in: NSGraphicsContext.current!.cgContext)
            return true
        }
        let headerBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(headerImage.tiffRepresentation)))
        let headerScale = CGFloat(headerBitmap.pixelsHigh) / 38
        XCTAssertGreaterThan(try XCTUnwrap(headerBitmap.colorAt(x: 50, y: Int(25 * headerScale))).alphaComponent, 0.99)
        XCTAssertLessThan(try XCTUnwrap(headerBitmap.colorAt(x: 50, y: Int(37 * headerScale))).alphaComponent, 0.25)
    }
}
