import AppKit
import XCTest
import McDiffCore
@testable import McDiff

final class RenderingTests: XCTestCase {
    @MainActor
    func testLastCollapsedFileCanBeFocusedAndExpanded() throws {
        _ = NSApplication.shared
        let viewport = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        let lines = (1...40).map { (number: Int) in DiffLine(kind: .addition, text: "val value\(number) = \(number)", oldNumber: nil, newNumber: number) }
        let production = FileDiff(path: "main.kt", status: "A", hunks: [DiffHunk(header: "@@ -0,0 +1,40 @@", lines: lines)], fingerprint: "a")
        let deleted = FileDiff(path: "deleted.kt", status: "D", hunks: [], fingerprint: "b")
        let files = [production, deleted]
        viewport.layoutSubtreeIfNeeded()
        viewport.expanded = ["main.kt"]
        viewport.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        viewport.layoutSubtreeIfNeeded()
        viewport.navigate(to: 1)
        XCTAssertEqual(viewport.focusedFile, 1)
        XCTAssertTrue(viewport.expanded.contains("deleted.kt"))
        let header = try XCTUnwrap(viewport.headerRows[1])
        XCTAssertEqual(viewport.scroll.documentVisibleRect.minY, viewport.table.rect(ofRow: header).minY, accuracy: 1)
        viewport.setFrameSize(NSSize(width: 900, height: 600))
        viewport.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewport.table.bounds.width, viewport.scroll.contentSize.width, accuracy: 1)
        XCTAssertEqual(viewport.table.tableColumns[0].width, viewport.scroll.contentSize.width, accuracy: 1)
    }

    func testSyntaxPreservesIndentationUnicodeAndColorizesSupportedLanguages() async throws {
        let syntax = SyntaxService()
        let samples = [
            ("Main.kt", "    val message = \"héllo 👋\""),
            ("Main.java", "    String message = \"hello\";"),
            ("main.go", "    func main() { return }"),
            ("main.ts", "    const message: string = 'hello';"),
            ("main.rs", "    let message = \"hello\";"),
            ("main.py", "    message = 'hello'")
        ]
        for (path, text) in samples {
            let file = FileDiff(path: path, hunks: [DiffHunk(header: "", lines: [DiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: 7)])], fingerprint: path)
            let value = try await syntax.highlight(file: file, dark: true)
            let line = try XCTUnwrap(value.new[7], path)
            XCTAssertEqual(line.string, text, path)
            var colors = Set<String>()
            line.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: line.length)) { color, _, _ in
                if let color { colors.insert(String(describing: color)) }
            }
            XCTAssertGreaterThan(colors.count, 1, path)
        }
    }

    func testHugeSingleFileHighlightsOnlyRequestedPage() async throws {
        let lines = (1...30_000).map { (n: Int) in DiffLine(kind: .addition, text: "val line\(n) = \(n)", oldNumber: nil, newNumber: n) }
        let file = FileDiff(path: "Huge.kt", hunks: [DiffHunk(header: "", lines: lines)], fingerprint: "huge")
        let page = 80
        let result = try await SyntaxService().highlight(file: file, dark: true, page: page)
        XCTAssertLessThanOrEqual(result.new.count, SyntaxService.pageSize)
        XCTAssertNotNil(result.new[page * SyntaxService.pageSize + 1])
        XCTAssertNil(result.new[1])
        XCTAssertNil(result.new[30_000])
    }

    @MainActor
    func testLargeReviewCreatesOnlyVisibleRowViewsAndScrollsWithinFrameBudget() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let viewport = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = viewport
        let files = (0..<400).map { file in
            let lines = (1...75).map { (number: Int) in DiffLine(kind: .addition, text: "val value\(number) = \"file \(file)\"", oldNumber: nil, newNumber: number) }
            return FileDiff(path: "src/File\(file).kt", status: "A", hunks: [DiffHunk(header: "@@ -0,0 +1,75 @@", lines: lines)], fingerprint: "\(file)")
        }
        viewport.expanded = Set(files.map(\.path))
        viewport.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        viewport.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(viewport.scroll.bitmapImageRepForCachingDisplay(in: viewport.scroll.bounds))
        var durations: [Double] = []
        for index in stride(from: 0, to: 400, by: 7) {
            let start = ProcessInfo.processInfo.systemUptime
            viewport.navigate(to: index)
            viewport.table.layoutSubtreeIfNeeded()
            viewport.table.displayIfNeeded()
            viewport.scroll.cacheDisplay(in: viewport.scroll.bounds, to: bitmap)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            var views = 0
            viewport.table.enumerateAvailableRowViews { _, _ in views += 1 }
            XCTAssertLessThan(views, 120, "Virtualization must not retain the entire review.")
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        print("SLOPDIFF VIEWPORT: 400 files / 30,000 lines, p95 navigation+layout+draw \(p95) ms, max \(durations.last!) ms")
        XCTAssertLessThan(p95, 32, "Large review drawing has regressed.")
        window.orderOut(nil)
    }

    @MainActor
    func testCommentHitTestingRejectsEmptyHalfAndTrailingSpace() {
        _ = NSApplication.shared
        let viewport = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let file = FileDiff(path: "Main.kt", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "val x = 1", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "one")
        viewport.expanded = [file.path]
        viewport.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        viewport.layoutSubtreeIfNeeded()
        let y = viewport.table.rect(ofRow: 1).minY + 8
        let half = viewport.table.bounds.width / 2
        XCTAssertFalse(viewport.hitsCode(row: 1, point: NSPoint(x: 80, y: y)))
        XCTAssertTrue(viewport.hitsCode(row: 1, point: NSPoint(x: half + 65, y: y)))
        XCTAssertFalse(viewport.hitsCode(row: 1, point: NSPoint(x: half + 300, y: y)))
        XCTAssertFalse(viewport.hitsCode(row: 1, point: NSPoint(x: half + 10, y: y)))
        viewport.commentRange = { _, side, line in side == .new && line == 1 ? 1...1 : nil }
        XCTAssertTrue(viewport.hitsCode(row: 1, point: NSPoint(x: half + 10, y: y)))
    }

    @MainActor
    func testSelectingRangeOpensCommentOnlyAfterGestureFinishes() {
        _ = NSApplication.shared
        let viewport = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let lines = (1...5).map { (n: Int) in DiffLine(kind: .addition, text: "val x\(n) = \(n)", oldNumber: nil, newNumber: n) }
        let file = FileDiff(path: "Main.kt", hunks: [DiffHunk(header: "", lines: lines)], fingerprint: "one")
        viewport.expanded = [file.path]
        viewport.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        viewport.layoutSubtreeIfNeeded()
        var comments: [LineSelection] = []
        viewport.onComment = { comments.append($0) }
        viewport.click(row: 1, point: NSPoint(x: 900, y: 0), shift: false)
        let anchor = viewport.selection!
        viewport.drag(row: 3, point: NSPoint(x: 900, y: 0), anchor: anchor)
        XCTAssertTrue(comments.isEmpty)
        viewport.commitSelection()
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.start, 1)
        XCTAssertEqual(comments.first?.end, 3)
        XCTAssertEqual(comments.first?.side, .new)
    }
}
