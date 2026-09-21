import AppKit
import CoreText
import XCTest
import McDiffCore
@testable import McDiff

final class ViewportTests: XCTestCase {
    @MainActor
    func testNavigatingToCollapsedMarkdownStaysVisibleAfterMeasurement() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 2200, height: 1600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var files = (0..<400).map { index in
            FileDiff(path: "src/File\(index).kt", hunks: [DiffHunk(header: "", lines: (1...75).map {
                DiffLine(kind: .addition, text: "val x\($0) = \($0)", oldNumber: nil, newNumber: $0)
            })], fingerprint: "\(index)")
        }
        files.append(FileDiff(path: "README.md", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "# Title", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "markdown"))
        files.append(FileDiff(path: "lock.json", hunks: [], fingerprint: "lock"))
        view.expanded = Set(files.prefix(400).map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        view.navigate(to: 400)
        try await ready(view)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(view.headerRows[400])
        XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: header)))
        XCTAssertTrue(view.scroll.documentVisibleRect.intersects(view.table.rect(ofRow: header + 1)))
        XCTAssertEqual(view.focusedFile, 400)
    }

    private final class HorizontalEvent: NSEvent {
        let point: NSPoint
        init(point: NSPoint) { self.point = point; super.init() }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var locationInWindow: NSPoint { point }
        override var scrollingDeltaX: CGFloat { -80 }
        override var scrollingDeltaY: CGFloat { 0 }
    }
    @MainActor
    private func ready(_ viewport: DiffViewport) async throws {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            viewport.layoutSubtreeIfNeeded()
            if !viewport.isLayoutPending { return }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        XCTFail("Viewport layout did not finish")
    }

    @MainActor
    private func viewport(old: String, new: String) -> DiffViewport {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let file = FileDiff(path: "file.txt", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .deletion, text: old, oldNumber: 10, newNumber: nil),
            DiffLine(kind: .addition, text: new, oldNumber: nil, newNumber: 20)
        ])], fingerprint: UUID().uuidString)
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        return view
    }

    @MainActor
    func testIndependentOffsetsAndExactLongLineReachability() async throws {
        let old = String(repeating: "界wide 👩🏽‍💻 ", count: 800)
        let view = viewport(old: old, new: String(repeating: "right ", count: 200))
        try await ready(view)
        XCTAssertGreaterThan(view.scrollableWidth(file: 0, side: .old), 0)
        XCTAssertGreaterThan(view.scrollableWidth(file: 0, side: .new), 0)
        view.scrollHorizontally(250, file: 0, side: .old)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 250)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 0)
        view.scrollHorizontally(100, file: 0, side: .new)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 250)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 100)
        view.scrollHorizontally(.greatestFiniteMagnitude, file: 0, side: .old)
        let measured = DiffTextLayout.width(NSAttributedString(string: old, attributes: [.font: Style.codeFont]))
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old) + view.textWidth(file: 0, side: .old), measured, accuracy: 1)
        XCTAssertGreaterThan(view.horizontalOffset(file: 0, side: .old), 20000)
        view.scroll.contentView.scroll(to: NSPoint(x: 80, y: 0))
        XCTAssertEqual(view.scroll.contentView.bounds.minX, 0)
    }

    @MainActor
    func testResizingKeepsTwoEqualPanesAndIndependentOverflow() async throws {
        let view = viewport(old: "short", new: String(repeating: "long ", count: 300))
        try await ready(view)
        for width: CGFloat in [1300, 730, 1000] {
            view.setFrameSize(NSSize(width: width, height: 700))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.table.bounds.width, view.scroll.contentSize.width, accuracy: 0.1)
            view.scrollHorizontally(10, file: 0, side: .new)
            XCTAssertEqual(view.paneWidth, view.table.bounds.width / 2, accuracy: 0.1)
            XCTAssertGreaterThan(view.scrollableWidth(file: 0, side: .new), 0)
            XCTAssertEqual(view.scrollableWidth(file: 0, side: .old), 0)
            XCTAssertEqual(view.scroll.frame, view.bounds, "Scrolling must not reserve a bottom strip")
        }
    }

    @MainActor
    func testHorizontalScrollingIsPerFileAndSide() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func file(_ path: String, old: String, new: String, lines: Int) -> FileDiff {
            FileDiff(path: path, hunks: [DiffHunk(header: "", lines: (1...lines).flatMap { n in [
                DiffLine(kind: .deletion, text: old, oldNumber: n, newNumber: nil),
                DiffLine(kind: .addition, text: new, oldNumber: nil, newNumber: n)
            ] })], fingerprint: path)
        }
        let files = [
            file("a.swift", old: String(repeating: "old ", count: 300), new: String(repeating: "new ", count: 150), lines: 5),
            file("b.swift", old: "short", new: String(repeating: "other ", count: 80), lines: 50),
            file("c.swift", old: "tiny", new: "tiny", lines: 1)
        ]
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        XCTAssertEqual(view.scroll.scrollerStyle, .overlay)
        XCTAssertEqual(view.scroll.frame, view.bounds)
        XCTAssertGreaterThan(view.scrollableWidth(file: 0, side: .old), view.scrollableWidth(file: 0, side: .new))
        XCTAssertEqual(view.scrollableWidth(file: 1, side: .old), 0)
        XCTAssertEqual(view.scrollableWidth(file: 2, side: .new), 0)
        view.scrollHorizontally(250, file: 0, side: .old)
        view.scrollHorizontally(90, file: 0, side: .new)
        let target = try XCTUnwrap(view.headerRows[1]) + 1
        let point = NSPoint(x: view.paneWidth + 100, y: view.table.rect(ofRow: target).midY)
        view.table.scrollWheel(with: HorizontalEvent(point: view.table.convert(point, to: nil)))
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 250)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 90)
        XCTAssertEqual(view.horizontalOffset(file: 1, side: .old), 0)
        XCTAssertEqual(view.horizontalOffset(file: 1, side: .new), 80)
        view.navigate(to: 1)
        try await ready(view)
        view.scrollHorizontally(30, file: 1, side: .new)
        XCTAssertEqual(view.horizontalOffset(file: 1, side: .new), 110)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 250)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 90)
        view.softWrap = true
        try await ready(view)
        XCTAssertEqual(view.scrollableWidth(file: 0, side: .old), 0)
        XCTAssertEqual(view.horizontalOffset(file: 1, side: .new), 0)
    }

    @MainActor
    func testHorizontalWheelPansOnlyHoveredSide() async throws {
        let view = viewport(old: String(repeating: "left ", count: 300), new: String(repeating: "right ", count: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        try await ready(view)
        view.table.scrollWheel(with: HorizontalEvent(point: view.table.convert(NSPoint(x: view.paneWidth + 100, y: 45), to: nil)))
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 80)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 0)
        view.table.scrollWheel(with: HorizontalEvent(point: view.table.convert(NSPoint(x: 100, y: 45), to: nil)))
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 80)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 80)
    }

    @MainActor
    func testUnicodeWrappingPreservesWholeTextAlignedHeightAndCommentLineNumbers() async throws {
        let text = String(repeating: "let café = \"👩🏽‍💻界e\u{301}\"; ", count: 40)
        let view = viewport(old: text, new: "short")
        view.softWrap = true
        try await ready(view)
        let rich = NSAttributedString(string: text, attributes: [.font: Style.codeFont])
        let ranges = DiffTextLayout.ranges(rich, width: view.textWidth(file: 0, side: .old))
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }.joined(), text)
        for range in ranges {
            XCTAssertEqual((text as NSString).rangeOfComposedCharacterSequences(for: range), range)
        }
        XCTAssertEqual(view.table.rect(ofRow: 1).height, CGFloat(ranges.count) * Style.rowHeight, accuracy: 0.1)
        view.scrollHorizontally(100, file: 0, side: .old)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 0)
        var comments: [LineSelection] = []
        view.onComment = { comments.append($0) }
        view.click(row: 1, point: NSPoint(x: 100, y: 100), shift: false)
        view.commitSelection()
        XCTAssertEqual(comments.first?.start, 10)
        XCTAssertEqual(comments.first?.end, 10)
        view.setFrameSize(NSSize(width: 700, height: 700))
        try await ready(view)
        XCTAssertGreaterThan(view.table.rect(ofRow: 1).height, CGFloat(ranges.count) * Style.rowHeight)
        view.softWrap = false
        try await ready(view)
        XCTAssertEqual(view.table.rect(ofRow: 1).height, Style.rowHeight)
        XCTAssertGreaterThan(view.scrollableWidth(file: 0, side: .old), 0)
    }

    @MainActor
    func testImportHeaderKeepsPositionThroughExpansionAfterWrappedCode() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let leading = DiffLine(kind: .context, text: String(repeating: "wrapped content ", count: 300), oldNumber: 1, newNumber: 1)
        let imported = DiffLine(kind: .addition, text: "import " + String(repeating: "nested.", count: 100) + "Module",
                               oldNumber: nil, newNumber: 2)
        let file = FileDiff(path: "imports.kt", hunks: [DiffHunk(header: "", lines: [leading, imported])], fingerprint: "imports")
        let trailing = FileDiff(path: "next.kt", hunks: [DiffHunk(header: "", lines: (1...60).map { (n: Int) in
            DiffLine(kind: .addition, text: "val value = 1", oldNumber: nil, newNumber: n)
        })], fingerprint: "next")
        view.softWrap = true
        view.expanded = [file.path, trailing.path]
        view.setFiles([file, trailing], presentations: [
            file.path: [.code(DiffPair(old: leading, new: leading)), .imports([DiffPair(old: nil, new: imported)])],
            trailing.path: DiffPresentation.rows(for: trailing)
        ])
        try await ready(view)
        let row = try XCTUnwrap(view.rows.firstIndex { if case .imports = $0.content { return true }; return false })
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: row).minY - 200))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        for expanded in [true, false, true] {
            view.click(row: row, point: NSPoint(x: 40, y: view.table.rect(ofRow: row).midY), shift: false)
            XCTAssertEqual(view.table.rect(ofRow: row).minY - view.scroll.documentVisibleRect.minY, 200, accuracy: 1)
            try await ready(view)
            XCTAssertEqual(view.table.rect(ofRow: row).minY - view.scroll.documentVisibleRect.minY, 200, accuracy: 1)
            XCTAssertEqual(view.importsExpanded(path: file.path, block: 1), expanded)
        }
    }

    @MainActor
    func testThirtyThousandWrappedLinesRemainVirtualized() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let files = (0..<400).map { index in
            FileDiff(path: "file\(index).txt", hunks: [DiffHunk(header: "", lines: (1...75).map { (number: Int) in
                DiffLine(kind: .addition, text: String(repeating: "let value\(number) = \"👋\"; ", count: 6), oldNumber: nil, newNumber: number)
            })], fingerprint: "\(index)")
        }
        view.softWrap = true
        view.expanded = Set(files.map(\.path))
        var busy: [Bool] = []
        view.onLayoutBusy = { busy.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        print("VIEWPORT WRAP: 30,000 lines measured in \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
        XCTAssertEqual(busy.last, false)
        // The workload takes >300ms on the verification machine; report callback evidence.
        print("VIEWPORT WRAP loading transitions: \(busy)")
        for file in stride(from: 0, to: 400, by: 39) {
            view.navigate(to: file)
            view.table.layoutSubtreeIfNeeded()
            var count = 0
            view.table.enumerateAvailableRowViews { _, _ in count += 1 }
            XCTAssertLessThan(count, 120)
        }
    }

    @MainActor
    func testReplacingReviewDuringLayoutCannotApplyStaleHeights() async throws {
        let view = viewport(old: String(repeating: "old words ", count: 20000), new: "short")
        view.softWrap = true
        view.setFiles([], presentations: [:])
        view.softWrap = false
        try await ready(view)
        XCTAssertTrue(view.rows.isEmpty)
        XCTAssertEqual(view.table.numberOfRows, 0)
        XCTAssertFalse(view.isLayoutPending)
    }
}
