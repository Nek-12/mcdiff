import AppKit
import SlopdiffCore
import XCTest
@testable import Slopdiff

final class SearchTests: XCTestCase {
    private func fixture() -> [FileDiff] {
        [
            FileDiff(path: "Needle.kt", hunks: [DiffHunk(header: "", lines: [
                DiffLine(kind: .context, text: "import sample.Needle", oldNumber: 1, newNumber: 1),
                DiffLine(kind: .context, text: "val context = \"needle NEEDLE 👩🏽‍💻 café\"", oldNumber: 2, newNumber: 2),
                DiffLine(kind: .deletion, text: "old needle", oldNumber: 3, newNumber: nil),
                DiffLine(kind: .addition, text: "new needle", oldNumber: nil, newNumber: 3)
            ])], fingerprint: "source"),
            FileDiff(path: "docs/guide.md", hunks: [DiffHunk(header: "", lines: [
                DiffLine(kind: .addition, text: "# hunk only", oldNumber: nil, newNumber: 1)
            ])], fingerprint: "markdown"),
            FileDiff(path: "empty.swift", hunks: [], fingerprint: "empty")
        ]
    }

    private func presentations(_ files: [FileDiff]) -> [String: [PresentedRow]] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) })
    }

    func testSearchPathsOldNewContextImportsAndRepeatedUnicodeOccurrences() async throws {
        let files = fixture()
        let engine = DiffSearchEngine()
        let result = try await engine.search(query: "nEeDlE", files: files, presentations: presentations(files),
                                             markdown: [:], sourcePaths: [])
        XCTAssertEqual(result.files, [0])
        XCTAssertEqual(result.count, 6, "Path, import, two context occurrences, deletion and addition")
        let targets = try (0..<result.count).compactMap { try result.match(at: $0)?.target }
        XCTAssertEqual(targets.first, .path(file: 0))
        XCTAssertEqual(targets[1], .code(file: 0, side: .new, line: 1, importBlock: 1))
        XCTAssertEqual(targets[2], .code(file: 0, side: .new, line: 2, importBlock: nil))
        XCTAssertEqual(targets[3], targets[2], "Repeated occurrences on a line are independently navigable")
        XCTAssertEqual(targets[4], .code(file: 0, side: .old, line: 3, importBlock: nil))
        XCTAssertEqual(targets[5], .code(file: 0, side: .new, line: 3, importBlock: nil))
        let unicode = "👩🏽‍💻 CAFÉ café"
        let ranges = Array(LiteralSearch.matches("café", in: unicode))
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map { (unicode as NSString).substring(with: $0) }, ["CAFÉ", "café"])
        XCTAssertEqual(Array(LiteralSearch.matches("👩🏽‍💻", in: unicode)).first?.length, "👩🏽‍💻".utf16.count)
        XCTAssertTrue(Array(LiteralSearch.matches(".*", in: unicode)).isEmpty, "Search is not a regex")
    }

    func testRenderedMarkdownSearchUsesFullRenderedTextAndCurrentMode() async throws {
        let files = fixture()
        let content = ["docs/guide.md": MarkdownFileContent(old: "# Old needle\n\nOutside **hunks**",
                                                           new: "# New NEEDLE\n\nOutside **hunks**")]
        let engine = DiffSearchEngine()
        let rendered = try await engine.search(query: "outside hunks", files: files, presentations: presentations(files),
                                               markdown: content, sourcePaths: [])
        XCTAssertEqual(rendered.files, [1])
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(try rendered.match(at: 0)?.target, .markdown(file: 1, side: .old))
        XCTAssertEqual(try rendered.match(at: 1)?.target, .markdown(file: 1, side: .new))
        let source = try await engine.search(query: "hunk only", files: files, presentations: presentations(files),
                                             markdown: content, sourcePaths: ["docs/guide.md"])
        XCTAssertEqual(source.count, 1)
        XCTAssertEqual(try source.match(at: 0)?.target, .code(file: 1, side: .new, line: 1, importBlock: nil))
        let absent = try await engine.search(query: "hunk only", files: files, presentations: presentations(files),
                                             markdown: content, sourcePaths: [])
        XCTAssertEqual(absent.count, 0)
    }

    func testLongRepeatedTextCountsWithoutMaterializingEveryOccurrence() async throws {
        let files = [FileDiff(path: "large.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: String(repeating: "x ", count: 100_000), oldNumber: nil, newNumber: 1)
        ])], fingerprint: "large")]
        let result = try await DiffSearchEngine().search(query: "x", files: files, presentations: presentations(files),
                                                        markdown: [:], sourcePaths: [])
        XCTAssertEqual(result.count, 100_000)
        XCTAssertEqual(try result.match(at: 99_999)?.range, NSRange(location: 199_998, length: 1))
    }

    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            if !view.isSearchPending && !view.isLayoutPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search/navigation did not complete")
    }

    @MainActor
    func testNavigationRevealsExcludedAndFoldedHitsWrapsAndClearsWithoutChangingCommentSelection() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let files = fixture()
        view.setFiles(files, presentations: presentations(files))
        view.selection = LineSelection(file: 0, side: .old, start: 3, end: 3)
        var indices: [Int] = [], count = -1
        view.onSearchResults = { indices = $0; count = $1 }
        view.search(query: "needle")
        try await ready(view)
        XCTAssertEqual(indices, [0])
        XCTAssertEqual(count, 6)
        XCTAssertEqual(view.currentSearchMatch?.target, .path(file: 0))
        view.nextSearchMatch()
        try await ready(view)
        XCTAssertTrue(view.expanded.contains("Needle.kt"))
        XCTAssertTrue(view.importsExpanded(path: "Needle.kt", block: 1))
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .new, line: 1, importBlock: 1))
        view.nextSearchMatch(backwards: true)
        try await ready(view)
        view.nextSearchMatch(backwards: true)
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .code(file: 0, side: .new, line: 3, importBlock: nil))
        view.nextSearchMatch()
        try await ready(view)
        XCTAssertEqual(view.currentSearchMatch?.target, .path(file: 0))
        XCTAssertEqual(view.selection?.side, .old)
        XCTAssertEqual(view.selection?.start, 3)
        view.search(query: "nothing matches")
        try await ready(view)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(indices.isEmpty)
        XCTAssertNil(view.currentSearchMatch)
        view.search(query: "")
        XCTAssertEqual(indices, [0, 1, 2])
        XCTAssertEqual(view.searchQuery, "")
        XCTAssertNil(view.currentSearchMatch)
        XCTAssertEqual(view.selection?.start, 3)
    }

    @MainActor
    func testRenderedHitDeepInFullBlobIsMeasuredRevealedAndPaintedWithoutChangingMode() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let files = fixture()
        view.markdownContent = ["docs/guide.md": MarkdownFileContent(old: "",
            new: String(repeating: "Earlier paragraph.\n\n", count: 100) + "Deep **needle** target.")]
        view.setFiles(files, presentations: presentations(files))
        view.search(query: "deep needle")
        try await ready(view)
        let match = try XCTUnwrap(view.currentSearchMatch)
        XCTAssertEqual(match.target, .markdown(file: 1, side: .new))
        XCTAssertTrue(view.rendersMarkdown(files[1]))
        let layout = try XCTUnwrap(view.markdownLayout(for: files[1]))
        let row = try XCTUnwrap(view.headerRows[1]) + 1
        let hitY = view.table.rect(ofRow: row).minY + 18 + layout.new.rect(for: match.range).minY
        XCTAssertGreaterThan(hitY, 1000)
        XCTAssertTrue(view.scroll.documentVisibleRect.contains(NSPoint(x: 100, y: hitY)))
        let bitmap = try XCTUnwrap(view.scroll.bitmapImageRepForCachingDisplay(in: view.scroll.bounds))
        view.scroll.cacheDisplay(in: view.scroll.bounds, to: bitmap)
    }

    @MainActor
    func testSearchRevealsHorizontalAndWrappedOccurrencesAndPaintsClearableHighlights() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let text = String(repeating: "ordinary words ", count: 100) + "needle"
        let file = FileDiff(path: "large.swift", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: 1)
        ])], fingerprint: "long")
        view.setFiles([file], presentations: presentations([file]))
        view.search(query: "needle")
        try await ready(view)
        XCTAssertGreaterThan(view.horizontalOffset(file: 0, side: .new), 1000)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .old), 0)
        let match = try XCTUnwrap(view.currentSearchMatch)
        XCTAssertEqual((text as NSString).substring(with: match.range), "needle")
        view.softWrap = true
        try await ready(view)
        view.nextSearchMatch()
        try await ready(view)
        XCTAssertEqual(view.horizontalOffset(file: 0, side: .new), 0)
        let rich = NSAttributedString(string: text, attributes: [.font: Style.codeFont])
        let fragment = try XCTUnwrap(view.textFragments(rich).firstIndex { NSIntersectionRange($0, match.range).length > 0 })
        let y = view.table.rect(ofRow: 1).minY + CGFloat(fragment) * Style.rowHeight
        XCTAssertTrue(view.scroll.documentVisibleRect.contains(NSPoint(x: 600, y: y)))

        func snapshot() throws -> NSBitmapImageRep {
            let cell = try XCTUnwrap(view.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? DiffCell)
            let image = NSImage(size: cell.bounds.size, flipped: true) { _ in
                cell.draw(cell.bounds)
                return true
            }
            return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        }
        let highlighted = try snapshot()
        view.search(query: "")
        let cleared = try snapshot()
        var differingPixels = 0
        for y in stride(from: 0, to: min(highlighted.pixelsHigh, cleared.pixelsHigh), by: 3) {
            for x in stride(from: highlighted.pixelsWide / 2, to: highlighted.pixelsWide, by: 3) {
                if highlighted.colorAt(x: x, y: y) != cleared.colorAt(x: x, y: y) { differingPixels += 1 }
            }
        }
        XCTAssertGreaterThan(differingPixels, 10, "Visible source search highlighting must disappear on clear")
    }

    @MainActor
    func testRapidQueriesAndReviewReplacementCannotPublishStaleResults() async throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let files = (0..<400).map { index in
            FileDiff(path: "src/File\(index).swift", hunks: [DiffHunk(header: "", lines: (1...75).map { (n: Int) in
                DiffLine(kind: .addition, text: "let repeatedValue = \(n)", oldNumber: nil, newNumber: n)
            })], fingerprint: "\(index)")
        }
        view.setFiles(files, presentations: presentations(files))
        var callbacks: [([Int], Int)] = []
        var busy: [Bool] = []
        view.onSearchResults = { callbacks.append(($0, $1)) }
        view.onSearchBusy = { busy.append($0) }
        view.search(query: "repeated")
        view.search(query: "File399")
        try await ready(view)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.last?.0, [399])
        XCTAssertEqual(callbacks.last?.1, 1)
        XCTAssertEqual(busy, [true, true, false], "Cancelled work must not dismiss the newer search's loading state")
        busy.removeAll()
        view.search(query: "repeated")
        view.search(query: "")
        try await ready(view)
        XCTAssertEqual(busy, [true, false])
        view.search(query: "repeated")
        view.setFiles([], presentations: [:])
        try await ready(view)
        XCTAssertEqual(callbacks.last?.0, [])
        XCTAssertEqual(callbacks.last?.1, 0)
        XCTAssertNil(view.currentSearchMatch)
    }
}
