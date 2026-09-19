import AppKit
import SlopdiffCore
import XCTest
@testable import Slopdiff

final class NavigationTests: XCTestCase {
    @MainActor
    private func fixture(longLines: Bool = false) async throws -> (DiffViewport, NSWindow) {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        let files: [FileDiff] = (0..<40).map { (index: Int) in
            let lines = (1...30).map { (number: Int) in
                DiffLine(kind: .addition, text: "let value\(number) = \(index)" +
                         (longLines ? String(repeating: " + anotherValue", count: 70) : ""),
                         oldNumber: nil, newNumber: number)
            }
            return FileDiff(path: "file\(index).swift", hunks: [.init(header: "", lines: lines)], fingerprint: "\(index)")
        }
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        let deadline = Date().addingTimeInterval(10)
        while view.isLayoutPending, Date() < deadline {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @MainActor
    private func header(_ view: DiffViewport, file: Int) throws -> CGFloat {
        view.table.layoutSubtreeIfNeeded()
        return view.table.rect(ofRow: try XCTUnwrap(view.headerRows[file])).minY
    }

    @MainActor
    private func awaitArrival(_ view: DiffViewport, file: Int) async throws -> [CGFloat] {
        let deadline = Date().addingTimeInterval(5)
        var positions: [CGFloat] = []
        while Date() < deadline {
            view.table.layoutSubtreeIfNeeded()
            let y = view.scroll.documentVisibleRect.minY
            positions.append(y)
            var views = 0
            view.table.enumerateAvailableRowViews { _, _ in views += 1 }
            XCTAssertGreaterThan(views, 0)
            XCTAssertLessThan(views, 120)
            let visible = view.table.rows(in: view.scroll.documentVisibleRect)
            let middle = visible.location + visible.length / 2
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: middle, makeIfNecessary: false))
            XCTAssertEqual(cell.convert(cell.bounds, to: view.table).minY,
                           view.table.rect(ofRow: middle).minY, accuracy: 1,
                           "Intermediate scroll positions must have correctly positioned native cells")
            if abs(y - (try header(view, file: file))) < 1, !view.isLayoutPending {
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(view.focusedFile, file)
                return positions
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Navigation did not arrive at the file header")
        return positions
    }

    @MainActor
    private func awaitMovement(_ view: DiffViewport, from start: CGFloat) async throws {
        let deadline = Date().addingTimeInterval(2)
        while abs(view.scroll.documentVisibleRect.minY - start) <= 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(view.scroll.documentVisibleRect.minY, start)
    }

    @MainActor
    func testAnimatedNavigationRendersIntermediateRowsAndKeepsDestinationSelected() async throws {
        let (view, window) = try await fixture()
        defer { window.orderOut(nil) }
        view.selection = LineSelection(file: 0, side: .new, start: 1, end: 3)
        let expanded = view.expanded
        var focused: [Int] = []
        var comments = 0
        view.onFocus = { focused.append($0) }
        view.onComment = { _ in comments += 1 }
        let start = view.scroll.documentVisibleRect.minY
        let end = try header(view, file: 25)
        view.navigate(to: 25, animated: true)
        XCTAssertEqual(view.focusedFile, 25)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, start, accuracy: 1, "The action starts from actual current bounds")
        let positions = try await awaitArrival(view, file: 25)
        XCTAssertTrue(positions.contains { $0 > start + 1 && $0 < end - 1 }, "Actual clip bounds must pass through intermediate content")
        XCTAssertEqual(Set(focused), [25], "Intermediate files must not flash in the sidebar")
        XCTAssertEqual(view.expanded, expanded)
        XCTAssertEqual(view.selection?.start, 1)
        XCTAssertEqual(view.selection?.end, 3)
        XCTAssertEqual(comments, 0)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: try header(view, file: 3)))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(view.focusedFile, 3, "Ordinary scroll focus resumes after animation")
    }

    @MainActor
    func testAnotherClickRetargetsFromCurrentBoundsAndImmediateNavigationStopsMotion() async throws {
        let (view, window) = try await fixture()
        defer { window.orderOut(nil) }
        view.navigate(to: 30, animated: true)
        try await awaitMovement(view, from: 0)
        let interrupted = view.scroll.documentVisibleRect.minY
        view.navigate(to: 8, animated: true)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, interrupted, accuracy: 1)
        _ = try await awaitArrival(view, file: 8)
        view.navigate(to: 35, animated: true)
        try await awaitMovement(view, from: try header(view, file: 8))
        view.navigate(to: 2)
        let stopped = view.scroll.documentVisibleRect.minY
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, stopped, accuracy: 1)
        XCTAssertEqual(stopped, try header(view, file: 2), accuracy: 1)
        XCTAssertEqual(view.focusedFile, 2)
    }

    @MainActor
    func testNativeLiveScrollAndWheelStopAnimationAndRestoreManualFocus() async throws {
        let (view, window) = try await fixture()
        defer { window.orderOut(nil) }
        view.navigate(to: 30, animated: true)
        try await awaitMovement(view, from: 0)
        // AppKit sends this for native thumb dragging as well as gesture scrolling.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view.scroll)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: try header(view, file: 4)))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, try header(view, file: 4), accuracy: 1)
        XCTAssertEqual(view.focusedFile, 4)
        view.navigate(to: 30, animated: true)
        try await awaitMovement(view, from: try header(view, file: 4))
        let event = try XCTUnwrap(NSEvent(cgEvent: try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil,
            units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0))))
        view.table.scrollWheel(with: event)
        // Native wheel scrolling can itself finish over subsequent run-loop turns.
        try await Task.sleep(for: .milliseconds(250))
        let stopped = view.scroll.documentVisibleRect.minY
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, stopped, accuracy: 1)
    }

    @MainActor
    func testLayoutSwitchAndReviewReplacementCancelStaleNavigation() async throws {
        let (view, window) = try await fixture()
        defer { window.orderOut(nil) }
        view.navigate(to: 25, animated: true)
        try await awaitMovement(view, from: 0)
        view.diffLayout = .unified
        XCTAssertEqual(view.focusedFile, 25)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, try header(view, file: 25), accuracy: 1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, try header(view, file: 25), accuracy: 1)
        view.navigate(to: 5, animated: true)
        try await awaitMovement(view, from: try header(view, file: 25))
        view.setFiles([], presentations: [:])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(view.rows.isEmpty)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, 0, accuracy: 1)
    }

    @MainActor
    func testAnimationArrivesAtHeaderAfterAsynchronousWrappingChangesItsPosition() async throws {
        let (view, window) = try await fixture(longLines: true)
        defer { window.orderOut(nil) }
        let unwrapped = try header(view, file: 25)
        view.navigate(to: 25, animated: true)
        view.softWrap = true
        _ = try await awaitArrival(view, file: 25)
        XCTAssertGreaterThan(try header(view, file: 25), unwrapped)
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, try header(view, file: 25), accuracy: 1)
        XCTAssertEqual(view.focusedFile, 25)
        view.navigate(to: 35, animated: true)
        try await awaitMovement(view, from: try header(view, file: 25))
        view.rebuild(keeping: 2)
        _ = try await awaitArrival(view, file: 2)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, try header(view, file: 2), accuracy: 1)
    }

    @MainActor
    func testCodeSelectionInterruptsMotionAndDoesNotCommitAComment() async throws {
        let (view, window) = try await fixture()
        defer { window.orderOut(nil) }
        view.navigate(to: 30, animated: true)
        try await awaitMovement(view, from: 0)
        let range = view.table.rows(in: view.scroll.documentVisibleRect)
        let code = try XCTUnwrap((range.location..<NSMaxRange(range)).first {
            if case .code = view.rows[$0].content { return true }; return false
        })
        let point = NSPoint(x: view.paneWidth + 70, y: view.table.rect(ofRow: code).minY + 5)
        var comments = 0
        view.onComment = { _ in comments += 1 }
        view.click(row: code, point: point, shift: false)
        let stopped = view.scroll.documentVisibleRect.minY
        let anchor = try XCTUnwrap(view.selection)
        view.drag(row: code, point: point, anchor: anchor)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.scroll.documentVisibleRect.minY, stopped, accuracy: 1)
        XCTAssertEqual(view.focusedFile, view.rows[code].file)
        XCTAssertEqual(comments, 0)
    }
}
