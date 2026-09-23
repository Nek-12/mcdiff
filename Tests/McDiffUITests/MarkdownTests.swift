import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class MarkdownTests: XCTestCase {
    func testGFMFormatsTablesCodeTasksAndKeepsExternalContentInert() throws {
        let source = """
        # Heading

        **bold** and *italic* and ~~removed~~ and `inline`

        - [x] done
        - [ ] pending

        3. third
        4. fourth

        > quotation

        | Name | Value |
        | :--- | ---: |
        | Alice | 12 |
        | Bob | 34 |

        ```swift
        let value = "<script>not executable</script>"
        ```

        [site](https://example.com) ![remote](https://example.com/image.png)

        <script>alert("unsafe")</script>
        """
        let text = RenderedMarkdown.text(source, color: .white, secondary: .gray)
        XCTAssertTrue(text.string.contains("Heading"))
        XCTAssertFalse(text.string.contains("**bold**"))
        XCTAssertTrue(text.string.contains("☑ done"))
        XCTAssertTrue(text.string.contains("☐ pending"))
        XCTAssertTrue(text.string.contains("3. third"))
        XCTAssertTrue(text.string.contains("4. fourth"))
        XCTAssertTrue(text.string.contains("[Image: remote]"))
        XCTAssertTrue(text.string.contains("<script>alert(\"unsafe\")</script>"))
        let heading = (text.string as NSString).range(of: "Heading")
        XCTAssertGreaterThan((text.attribute(.font, at: heading.location, effectiveRange: nil) as! NSFont).pointSize, 14)
        let removed = (text.string as NSString).range(of: "removed")
        XCTAssertEqual(text.attribute(.strikethroughStyle, at: removed.location, effectiveRange: nil) as? Int, 1)
        let alice = (text.string as NSString).range(of: "Alice")
        let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: alice.location, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertEqual(block.startingRow, 1)
        let value = (text.string as NSString).range(of: "12")
        XCTAssertEqual((text.attribute(.paragraphStyle, at: value.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in
            XCTAssertNil(attrs[.link])
            XCTAssertNil(attrs[.attachment])
        }
        let layout = MarkdownTextLayout(text, width: 300)
        XCTAssertGreaterThan(layout.height, 200)
        XCTAssertEqual(layout.manager.glyphRange(for: layout.container).length, layout.manager.numberOfGlyphs)
    }

    @MainActor
    private func ready(_ view: DiffViewport, file: FileDiff? = nil) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            if !view.isLayoutPending, file.map({ view.markdownLayout(for: $0) != nil }) ?? true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Markdown did not finish rendering")
    }

    private func file(_ path: String, lines: Int = 1) -> FileDiff {
        FileDiff(path: path, hunks: [DiffHunk(header: "", lines: (1...lines).map { (n: Int) in
            DiffLine(kind: .addition, text: "# hunk line \(n)", oldNumber: nil, newNumber: n)
        })], fingerprint: path)
    }

    @MainActor
    func testFullBlobsRenderInlineWithAlignedEqualPanesAndSourceCommentsRemainAvailable() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let markdown = file("README.md"), next = file("next.swift")
        let old = "# Full original\n\nThis is outside the hunk."
        let new = "# Full new\n\n" + String(repeating: "Paragraph content with **bold**.\n\n", count: 70)
        view.markdownContent = [markdown.path: MarkdownFileContent(old: old, new: new)]
        view.expanded = [markdown.path, next.path]
        view.setFiles([markdown, next], presentations: [markdown.path: DiffPresentation.rows(for: markdown),
                                                        next.path: DiffPresentation.rows(for: next)])
        XCTAssertTrue(view.rendersMarkdown(markdown))
        try await ready(view, file: markdown)
        let layout = try XCTUnwrap(view.markdownLayout(for: markdown))
        XCTAssertTrue(layout.old.storage.string.contains("outside the hunk"))
        XCTAssertTrue(layout.new.storage.string.contains("Full new"))
        XCTAssertFalse(layout.new.storage.string.contains("hunk line"))
        XCTAssertEqual(layout.old.container.size.width, layout.new.container.size.width)
        XCTAssertEqual(view.table.rect(ofRow: 1).height, layout.height, accuracy: 1)
        XCTAssertEqual(view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY, 38 + layout.height, accuracy: 1)
        XCTAssertFalse(view.hitsCode(row: 1, point: NSPoint(x: 100, y: 60)))
        view.click(row: 1, point: NSPoint(x: 100, y: 60), shift: false)
        XCTAssertNil(view.selection)
        let bitmap = try XCTUnwrap(view.scroll.bitmapImageRepForCachingDisplay(in: view.scroll.bounds))
        view.scroll.cacheDisplay(in: view.scroll.bounds, to: bitmap)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: layout.height / 2))
        view.scroll.cacheDisplay(in: view.scroll.bounds, to: bitmap)
        view.toggleMarkdown(for: 0)
        try await ready(view)
        var comment: LineSelection?
        view.onComment = { comment = $0 }
        view.click(row: 1, point: NSPoint(x: 600, y: 45), shift: false)
        view.commitSelection()
        XCTAssertEqual(comment?.start, 1)
        XCTAssertEqual(comment?.side, .new)
        view.toggleMarkdown(for: 0)
        try await ready(view, file: markdown)
        XCTAssertNil(view.selection)
    }

    @MainActor
    func testHeaderButtonTogglesOnlyItsFileWithoutCollapsingAndResetsForNewReview() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let files = [file("README.md"), file("docs/guide.md"), file("main.swift")]
        let presentations = Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) })
        view.markdownContent = Dictionary(uniqueKeysWithValues: files.prefix(2).map {
            ($0.path, MarkdownFileContent(old: "# Old", new: "# New"))
        })
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: presentations)
        try await ready(view, file: files[0])

        func button(for index: Int) throws -> NSButton {
            let row = try XCTUnwrap(view.headerRows[index])
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true))
            cell.layoutSubtreeIfNeeded()
            let buttons = cell.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            let button = try XCTUnwrap(buttons.first { !($0 is AnimatedCheckbox) })
            let checkbox = try XCTUnwrap(buttons.first { $0 is AnimatedCheckbox })
            XCTAssertLessThan(button.frame.maxX, checkbox.frame.minX)
            return button
        }

        XCTAssertTrue(view.rendersMarkdown(files[0]))
        XCTAssertTrue(view.rendersMarkdown(files[1]))
        XCTAssertEqual(try button(for: 0).toolTip, "Show Markdown source for this file")
        XCTAssertEqual(try button(for: 0).title, "")
        XCTAssertEqual(try button(for: 0).image?.size, NSSize(width: 16, height: 16))
        let buttonSize = try button(for: 0).frame.size
        try button(for: 0).performClick(nil)
        try await ready(view)
        XCTAssertFalse(view.rendersMarkdown(files[0]))
        XCTAssertTrue(view.rendersMarkdown(files[1]))
        XCTAssertTrue(view.expanded.contains(files[0].path))
        XCTAssertEqual(try button(for: 0).toolTip, "Render Markdown for this file")
        XCTAssertEqual(try button(for: 0).frame.size, buttonSize)
        view.rebuild(keeping: 0)
        try await ready(view)
        XCTAssertFalse(view.rendersMarkdown(files[0]))
        for width: CGFloat in [700, 1200, 850] {
            view.setFrameSize(NSSize(width: width, height: 700))
            view.layoutSubtreeIfNeeded()
            _ = try button(for: 0)
        }
        try button(for: 0).performClick(nil)
        try await ready(view, file: files[0])
        XCTAssertTrue(view.rendersMarkdown(files[0]))
        XCTAssertTrue(view.expanded.contains(files[0].path))
        view.toggleMarkdown(for: 0)
        view.setFiles(files, presentations: presentations)
        try await ready(view, file: files[0])
        XCTAssertTrue(view.rendersMarkdown(files[0]))
        XCTAssertTrue(view.rendersMarkdown(files[1]))
        let codeHeader = try XCTUnwrap(view.table.view(atColumn: 0, row: try XCTUnwrap(view.headerRows[2]), makeIfNecessary: true))
        XCTAssertTrue(codeHeader.subviews.compactMap { $0 as? NSButton }
            .filter { !($0 is AnimatedCheckbox) }.allSatisfy(\.isHidden))
    }

    @MainActor
    func testTogglingMarkdownKeepsClickedHeaderBelowViewportTopThroughMeasurement() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let preceding = FileDiff(path: "main.swift", hunks: [DiffHunk(header: "", lines: (1...60).map { (n: Int) in
            DiffLine(kind: .addition, text: String(repeating: "long wrapped line ", count: 15), oldNumber: nil, newNumber: n)
        })], fingerprint: "main")
        let files = [preceding, file("README.md", lines: 100), file("next.swift", lines: 60)]
        view.softWrap = true
        view.markdownContent = ["README.md": MarkdownFileContent(old: "# Old", new: String(repeating: "Rendered paragraph.\n\n", count: 80))]
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        view.navigate(to: 1)
        try await ready(view, file: files[1])

        func headerY() throws -> CGFloat {
            view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY - view.scroll.documentVisibleRect.minY
        }
        let header = try XCTUnwrap(view.headerRows[1])
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: header).minY - 200))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        XCTAssertEqual(try headerY(), 200, accuracy: 1)
        for rendered in [false, true] {
            let row = try XCTUnwrap(view.headerRows[1])
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true))
            let button = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }
                .first { !$0.isHidden && !($0 is AnimatedCheckbox) })
            button.performClick(nil)
            XCTAssertEqual(try headerY(), 200, accuracy: 1, "Click must not navigate to the header")
            try await ready(view, file: rendered ? files[1] : nil)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try headerY(), 200, accuracy: 1, "Async height measurement must retain the header position")
            XCTAssertEqual(view.rendersMarkdown(files[1]), rendered)
            XCTAssertTrue(view.expanded.contains(files[1].path))
            if !rendered {
                // Drop the rendered cache while source is visible, so returning
                // to rendered exercises a real asynchronous height replacement.
                view.markdownContent = ["README.md": MarkdownFileContent(old: "# Old", new: String(repeating: "Newly rendered paragraph.\n\n", count: 100))]
            }
        }
    }

    @MainActor
    func testFileHeadersKeepScreenPositionWhenCollapsedAndExpandedInEitherMarkdownMode() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let preceding = FileDiff(path: "main.swift", hunks: [DiffHunk(header: "", lines: (1...60).map { (n: Int) in
            DiffLine(kind: .addition, text: String(repeating: "wrapped line ", count: 20), oldNumber: nil, newNumber: n)
        })], fingerprint: "main")
        let files = [preceding, file("README.md", lines: 100), file("next.swift", lines: 60)]
        view.softWrap = true
        view.markdownContent = ["README.md": MarkdownFileContent(old: "# Old", new: String(repeating: "Paragraph.\n\n", count: 80))]
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        view.navigate(to: 1)
        try await ready(view, file: files[1])
        for rendered in [true, false] {
            if !rendered { view.toggleMarkdown(for: 1); try await ready(view) }
            let header = try XCTUnwrap(view.headerRows[1])
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: header).minY - 200))
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            for expanded in [false, true] {
                let row = try XCTUnwrap(view.headerRows[1])
                view.click(row: row, point: NSPoint(x: 20, y: view.table.rect(ofRow: row).midY), shift: false)
                XCTAssertEqual(view.table.rect(ofRow: row).minY - view.scroll.documentVisibleRect.minY, 200, accuracy: 1)
                try await ready(view, file: rendered && expanded ? files[1] : nil)
                XCTAssertEqual(view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY -
                               view.scroll.documentVisibleRect.minY, 200, accuracy: 1)
                XCTAssertEqual(view.expanded.contains("README.md"), expanded)
                XCTAssertEqual(view.rendersMarkdown(files[1]), rendered)
            }
        }
    }

    @MainActor
    func testCollapsedExcludedFilesStayVisibleThroughRepeatedNavigationAndCollapse() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let files = [file("main.swift", lines: 1000), file("README.md"), file("package-lock.json", lines: 3000)]
        view.markdownContent = ["README.md": MarkdownFileContent(old: "# Old", new: String(repeating: "Paragraph.\n\n", count: 100))]
        view.expanded = ["main.swift"]
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        for _ in 0..<3 {
            for index in [1, 2] {
                view.navigate(to: index)
                try await ready(view, file: index == 1 ? files[index] : nil)
                let row = try XCTUnwrap(view.headerRows[index])
                XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: row)))
                XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: row + 1)))
                view.click(row: row, point: NSPoint(x: 20, y: view.table.rect(ofRow: row).minY + 15), shift: false)
                try await ready(view)
                try await Task.sleep(for: .milliseconds(50))
                view.layoutSubtreeIfNeeded()
                XCTAssertFalse(view.expanded.contains(files[index].path))
                XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: try XCTUnwrap(view.headerRows[index]))))
                XCTAssertEqual(view.focusedFile, index)
                let bitmap = try XCTUnwrap(view.scroll.bitmapImageRepForCachingDisplay(in: view.scroll.bounds))
                view.scroll.cacheDisplay(in: view.scroll.bounds, to: bitmap)
            }
        }
    }

    @MainActor
    func testLateBlobArrivalAndFailureThenRetryDoNotDisplayStaleContent() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let markdown = file("README.md")
        view.expanded = [markdown.path]
        view.setFiles([markdown], presentations: [markdown.path: DiffPresentation.rows(for: markdown)])
        try await ready(view)
        XCTAssertNil(view.markdownLayout(for: markdown))
        view.markdownContent = [markdown.path: MarkdownFileContent(old: nil, new: nil, error: "Git failed")]
        try await ready(view)
        XCTAssertNil(view.markdownLayout(for: markdown))
        view.markdownContent = [markdown.path: MarkdownFileContent(old: nil, new: "# First")]
        try await ready(view, file: markdown)
        XCTAssertEqual(view.markdownLayout(for: markdown)?.new.storage.string, "First\n")
        view.markdownContent = [markdown.path: MarkdownFileContent(old: "# Original", new: nil)]
        try await ready(view, file: markdown)
        XCTAssertEqual(view.markdownLayout(for: markdown)?.old.storage.string, "Original\n")
        XCTAssertEqual(view.markdownLayout(for: markdown)?.new.storage.string, "")
    }
}
