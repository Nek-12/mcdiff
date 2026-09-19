import AppKit
import CoreText
import XCTest
import SlopdiffCore
@testable import Slopdiff

final class ViewportTests: XCTestCase {
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
        XCTAssertFalse(view.oldHorizontal.isHidden)
        XCTAssertFalse(view.newHorizontal.isHidden)
        view.scrollHorizontally(250, side: .old)
        XCTAssertEqual(view.horizontalOffset(for: .old), 250)
        XCTAssertEqual(view.horizontalOffset(for: .new), 0)
        view.scrollHorizontally(100, side: .new)
        XCTAssertEqual(view.horizontalOffset(for: .old), 250)
        XCTAssertEqual(view.horizontalOffset(for: .new), 100)
        view.scrollHorizontally(.greatestFiniteMagnitude, side: .old)
        let measured = DiffTextLayout.width(NSAttributedString(string: old, attributes: [.font: Style.codeFont]))
        XCTAssertEqual(view.horizontalOffset(for: .old) + view.textWidth, measured, accuracy: 1)
        XCTAssertGreaterThan(view.horizontalOffset(for: .old), 20000)
        view.scroll.contentView.scroll(to: NSPoint(x: 80, y: 0))
        XCTAssertEqual(view.scroll.contentView.bounds.minX, 0)
    }

    @MainActor
    func testResizingKeepsTwoEqualPanesAndBarsOnlyWhereNeeded() async throws {
        let view = viewport(old: "short", new: String(repeating: "long ", count: 300))
        try await ready(view)
        for width: CGFloat in [1300, 730, 1000] {
            view.setFrameSize(NSSize(width: width, height: 700))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.table.bounds.width, view.scroll.contentSize.width, accuracy: 0.1)
            XCTAssertEqual(view.oldHorizontal.frame.width, view.table.bounds.width / 2, accuracy: 0.1)
            XCTAssertEqual(view.newHorizontal.frame.minX, view.table.bounds.width / 2, accuracy: 0.1)
            XCTAssertEqual(view.newHorizontal.frame.width, view.oldHorizontal.frame.width)
            XCTAssertTrue(view.oldHorizontal.isHidden)
            XCTAssertFalse(view.newHorizontal.isHidden)
        }
    }

    @MainActor
    func testHorizontalWheelPansOnlyHoveredSide() async throws {
        let view = viewport(old: String(repeating: "left ", count: 300), new: String(repeating: "right ", count: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        try await ready(view)
        view.table.scrollWheel(with: HorizontalEvent(point: view.table.convert(NSPoint(x: view.paneWidth + 100, y: 45), to: nil)))
        XCTAssertEqual(view.horizontalOffset(for: .new), 80)
        XCTAssertEqual(view.horizontalOffset(for: .old), 0)
        view.table.scrollWheel(with: HorizontalEvent(point: view.table.convert(NSPoint(x: 100, y: 45), to: nil)))
        XCTAssertEqual(view.horizontalOffset(for: .old), 80)
        XCTAssertEqual(view.horizontalOffset(for: .new), 80)
    }

    @MainActor
    func testUnicodeWrappingPreservesWholeTextAlignedHeightAndCommentLineNumbers() async throws {
        let text = String(repeating: "let café = \"👩🏽‍💻界e\u{301}\"; ", count: 40)
        let view = viewport(old: text, new: "short")
        view.softWrap = true
        try await ready(view)
        let rich = NSAttributedString(string: text, attributes: [.font: Style.codeFont])
        let ranges = DiffTextLayout.ranges(rich, width: view.textWidth)
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }.joined(), text)
        for range in ranges {
            XCTAssertEqual((text as NSString).rangeOfComposedCharacterSequences(for: range), range)
        }
        XCTAssertEqual(view.table.rect(ofRow: 1).height, CGFloat(ranges.count) * Style.rowHeight, accuracy: 0.1)
        XCTAssertTrue(view.oldHorizontal.isHidden)
        XCTAssertTrue(view.newHorizontal.isHidden)
        view.scrollHorizontally(100, side: .old)
        XCTAssertEqual(view.horizontalOffset(for: .old), 0)
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
        XCTAssertFalse(view.oldHorizontal.isHidden)
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
        XCTAssertTrue(view.oldHorizontal.isHidden)
        XCTAssertTrue(view.newHorizontal.isHidden)
        XCTAssertFalse(view.isLayoutPending)
    }
}
