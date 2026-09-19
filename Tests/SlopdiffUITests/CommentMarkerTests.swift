import AppKit
import SlopdiffCore
import XCTest
@testable import Slopdiff

final class CommentMarkerTests: XCTestCase {
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
        view.commentRange = { _, side, line in side == .new && (1...3).contains(line) ? 1...3 : nil }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let deadline = Date().addingTimeInterval(20)
        while view.isLayoutPending, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isLayoutPending)
        view.layoutSubtreeIfNeeded()

        func marker(_ row: Int) throws -> NSBitmapImageRep {
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? DiffCell)
            let image = NSImage(size: NSSize(width: 24, height: cell.bounds.height), flipped: true) { _ in
                NSGraphicsContext.current?.cgContext.translateBy(x: -cell.bounds.width / 2, y: 0)
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
        XCTAssertGreaterThan(try alpha(first, x: 5, y: 8), 0, "The first line has the bubble")
        XCTAssertEqual(try alpha(middle, x: 5, y: 8), 0, "Continuation lines must not repeat the bubble")
        let middleHeight = CGFloat(middle.pixelsHigh) / (CGFloat(middle.pixelsWide) / 24)
        XCTAssertGreaterThan(middleHeight, Style.rowHeight)
        XCTAssertGreaterThan(try alpha(middle, x: 12, y: 1), 0)
        XCTAssertGreaterThan(try alpha(middle, x: 12, y: middleHeight - 2), 0, "Guide spans every wrapped fragment")
        let lastHeight = CGFloat(last.pixelsHigh) / (CGFloat(last.pixelsWide) / 24)
        XCTAssertGreaterThan(try alpha(last, x: 15, y: lastHeight - Style.rowHeight / 2), 0, "Endcap reaches the final wrapped fragment")
        XCTAssertEqual(try alpha(last, x: 12, y: lastHeight - 2), 0, "Guide stops after its final endcap")
        for row in 1...3 {
            XCTAssertTrue(view.hitsCode(row: row, point: NSPoint(x: view.paneWidth + 12, y: view.table.rect(ofRow: row).midY)))
        }
        view.commentRange = { _, side, line in side == .new && line == 2 ? 2...2 : nil }
        let single = try marker(2)
        XCTAssertEqual(try alpha(single, x: 12, y: middleHeight - 2), 0, "A single-line comment has no range guide")
    }
}
