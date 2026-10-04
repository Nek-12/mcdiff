import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class CommentMarkerTests: XCTestCase {
    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testRailsBelongOnlyToCommentedFileSidesAndStayStableAcrossLines() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let lines = (1...80).map { DiffLine(kind: .context, text: "value", oldNumber: $0, newNumber: $0) }
        let files = ["a.swift", "b.swift"].map { FileDiff(path: $0, hunks: [DiffHunk(header: "", lines: lines)], fingerprint: $0) }
        view.expanded = Set(files.map(\.path))
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        view.layoutSubtreeIfNeeded()
        try await ready(view)
        let originalWidth = view.textWidth(file: 0, side: .new)
        XCTAssertNil(view.commentMarkerRect(file: 0, side: .new))
        let comment = ReviewComment(path: files[0].path, side: .new, startLine: 70, endLine: 71, text: "Later", fingerprint: files[0].fingerprint)
        view.setComments([comment])
        try await ready(view)
        XCTAssertEqual(view.textWidth(file: 0, side: .new), originalWidth - 24)
        XCTAssertEqual(view.textWidth(file: 0, side: .old), originalWidth)
        XCTAssertEqual(view.textWidth(file: 1, side: .new), originalWidth)
        XCTAssertNil(view.commentMarkerRect(file: 0, side: .old))
        let marker = try XCTUnwrap(view.commentMarkerRect(file: 0, side: .new))
        XCTAssertEqual(marker.maxX, view.paneWidth - 4)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: 70).minY))
        XCTAssertEqual(view.commentMarkerRect(file: 0, side: .new), marker)
        view.setComments([ReviewComment(path: comment.path, side: .new, startLine: 1, endLine: 1, text: "Moved", fingerprint: comment.fingerprint)])
        XCTAssertFalse(view.isLayoutPending, "Moving a comment within an existing rail does not remeasure")
        XCTAssertEqual(view.commentMarkerRect(file: 0, side: .new), marker)
        view.diffLayout = .unified
        try await ready(view)
        XCTAssertEqual(view.commentRailWidth(file: 0, side: .old), 24)
        XCTAssertEqual(view.commentRailWidth(file: 0, side: .new), 24)
        XCTAssertNil(view.commentMarkerRect(file: 0, side: .old))
        XCTAssertEqual(view.commentMarkerRect(file: 0, side: .new)?.maxX, view.paneWidth - 4)
        view.setComments([])
        try await ready(view)
        XCTAssertEqual(view.commentRailWidth(file: 0, side: .new), 0)
    }

    @MainActor
    func testRailWidthDrivesWrappingHitTestingAndHorizontalOverflow() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let text = String(repeating: "source ", count: 150)
        let line = DiffLine(kind: .context, text: text, oldNumber: 1, newNumber: 1)
        let file = FileDiff(path: "a.swift", hunks: [DiffHunk(header: "", lines: [line])], fingerprint: "rail")
        view.expanded = [file.path]
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        view.layoutSubtreeIfNeeded()
        try await ready(view)
        let overflow = view.scrollableWidth(file: 0, side: .new)
        view.setComments([ReviewComment(path: file.path, side: .new, startLine: 2, endLine: 2, text: "Stale location", fingerprint: "prior")])
        try await ready(view)
        XCTAssertEqual(view.scrollableWidth(file: 0, side: .new), overflow + 24, accuracy: 0.1)
        XCTAssertEqual(view.scrollableWidth(file: 0, side: .old), overflow, accuracy: 0.1)
        let railX = view.table.bounds.width - 12
        XCTAssertFalse(view.hitsCode(row: 1, point: NSPoint(x: railX, y: view.table.rect(ofRow: 1).minY + 8)),
                       "Overflow text is neither painted nor hittable underneath the empty rail")
        view.softWrap = true
        try await ready(view)
        let rich = NSAttributedString(string: text, attributes: [.font: Style.codeFont])
        let fragments = view.textFragments(rich, file: 0, side: .new)
        XCTAssertEqual(fragments, DiffTextLayout.ranges(rich, width: view.textWidth(file: 0, side: .new)))
        XCTAssertEqual(view.table.rect(ofRow: 1).height, CGFloat(fragments.count) * Style.rowHeight, accuracy: 0.1)
        let point = NSPoint(x: view.paneWidth + view.sourceTextInset(file: 0) + 1,
                           y: view.table.rect(ofRow: 1).minY + CGFloat(fragments.count - 1) * Style.rowHeight + 8)
        XCTAssertTrue(view.hitsCode(row: 1, point: point))
        view.setComments([])
        try await ready(view)
        XCTAssertEqual(view.textWidth(file: 0, side: .new), view.textWidth(file: 0, side: .old))
    }

    @MainActor
    func testMultilineCommentHasFirstBubbleContinuousWrappedGuideAndLastEndcap() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let lines = (1...4).map { (n: Int) in
            DiffLine(kind: .context, text: n == 1 || n == 4 ? "value" : String(repeating: "wrapped value ", count: 15),
                     oldNumber: n, newNumber: n)
        }
        let file = FileDiff(path: "code.swift", hunks: [DiffHunk(header: "", lines: lines)], fingerprint: "comment")
        view.softWrap = true
        view.expanded = [file.path]
        view.setComments([ReviewComment(path: file.path, side: .new, startLine: 1, endLine: 3, text: "Range", fingerprint: file.fingerprint)])
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()

        func marker(_ row: Int) throws -> NSBitmapImageRep {
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffCell)
            let image = NSImage(size: NSSize(width: 24, height: cell.bounds.height), flipped: true) { _ in
                NSGraphicsContext.current?.cgContext.translateBy(x: -cell.bounds.width + 24, y: 0)
                cell.draw(cell.bounds)
                return true
            }
            return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        }
        let first = try marker(1), middle = try marker(2), last = try marker(3)
        func alpha(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> CGFloat {
            let scale = CGFloat(bitmap.pixelsWide) / 24
            return try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))).alphaComponent
        }
        func bubbleInk(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
            try (0..<10).flatMap { x in
                try (0..<18).map { y in try alpha(bitmap, x: CGFloat(x), y: CGFloat(y)) }
            }.max() ?? 0
        }
        XCTAssertGreaterThan(try bubbleInk(first), 0, "The first line has the bubble")
        XCTAssertEqual(try bubbleInk(middle), 0, "Continuation lines must not repeat the bubble")
        let middleHeight = CGFloat(middle.pixelsHigh) / (CGFloat(middle.pixelsWide) / 24)
        XCTAssertGreaterThan(middleHeight, Style.rowHeight)
        XCTAssertGreaterThan(try alpha(middle, x: 12, y: 1), 0)
        XCTAssertGreaterThan(try alpha(middle, x: 12, y: middleHeight - 2), 0, "Guide spans every wrapped fragment")
        let lastHeight = CGFloat(last.pixelsHigh) / (CGFloat(last.pixelsWide) / 24)
        XCTAssertGreaterThan(try alpha(last, x: 8, y: lastHeight - Style.rowHeight / 2), 0, "Endcap points left toward the final wrapped fragment")
        XCTAssertEqual(try alpha(last, x: 15, y: lastHeight - Style.rowHeight / 2), 0, "Endcap never points away from source")
        XCTAssertEqual(try alpha(last, x: 12, y: lastHeight - 2), 0, "Guide stops after its final endcap")
        for row in 1...3 {
            XCTAssertTrue(view.hitsCode(row: row, point: NSPoint(x: view.table.bounds.width - 12, y: view.table.rect(ofRow: row).midY)))
        }
        view.setComments([ReviewComment(path: file.path, side: .new, startLine: 2, endLine: 2, text: "Single", fingerprint: file.fingerprint)])
        let single = try marker(2)
        XCTAssertEqual(try alpha(single, x: 12, y: middleHeight - 2), 0, "A single-line comment has no range guide")
    }
}
