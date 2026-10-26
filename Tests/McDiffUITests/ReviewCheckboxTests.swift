import AppKit
@testable import McDiffCore
import XCTest
@testable import McDiff

final class ReviewCheckboxTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            if !view.isLayoutPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Diff layout did not finish")
    }

    @MainActor
    private func footerText(_ viewport: DiffViewport) throws -> String {
        let footer = try XCTUnwrap(viewport.table.view(atColumn: 0, row: viewport.rows.count - 1, makeIfNecessary: true))
        return try XCTUnwrap(descendants(footer).compactMap { $0 as? NSTextField }.first?.stringValue)
    }

    @MainActor
    func testBothCheckboxesPersistReviewStateAndChangeExpansionWithoutMovingHeader() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await Task.detached {
            _ = try ProcessRunner.run("/usr/bin/git", ["init", "-b", "main"], directory: directory.path)
            _ = try ProcessRunner.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                                     "commit", "--allow-empty", "-m", "Initial"], directory: directory.path)
            for source in ["wearOsMain", "androidMain"] {
                let folder = directory.appendingPathComponent("src/\(source)/kotlin")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try (1...100).map { "val line\($0) = \"\(String(repeating: "long line ", count: 25))\"" }
                    .joined(separator: "\n").write(to: folder.appendingPathComponent("auth.kt"), atomically: true, encoding: .utf8)
            }
            return try GitRepository(path: directory.path).load(ComparisonRequest(repository: directory.path, base: "main"))
        }.value
        let storage = directory.appendingPathComponent(".git/review")
        let store = try ReviewStore(directory: storage)
        try store.savePreferences(ReviewPreferences(softWrap: true))
        let controller = ReviewWindowController(github: GitHubClient(clientID: "test", credentials: NoCredentials()))
        controller.start(store: store, arguments: ["--repo", directory.path])
        for _ in 0..<400 {
            if controller.isReviewReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.screen, .review)
        let window = try XCTUnwrap(controller.window)
        defer { window.delegate = nil; controller.close() }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffViewport }.first)
        try await ready(viewport)
        XCTAssertEqual(try footerText(viewport), "2 files left to review")
        XCTAssertTrue(viewport.finishReviewEnabled)
        let sidebar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }
            .first { $0.tableColumns.first?.identifier.rawValue == "path" })
        viewport.navigate(to: 1)
        try await ready(viewport)
        let header = try XCTUnwrap(viewport.headerRows[1])
        viewport.scroll.contentView.scroll(to: NSPoint(x: 0, y: viewport.table.rect(ofRow: header).minY - 120))
        viewport.scroll.reflectScrolledClipView(viewport.scroll.contentView)
        let path = viewport.files[1].path
        let sidebarCell = try XCTUnwrap(sidebar.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let sidebarCheck = try XCTUnwrap(descendants(sidebarCell).compactMap { $0 as? AnimatedCheckbox }.first)
        let label = try XCTUnwrap(descendants(sidebarCell).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "wearOsMain/…/auth.kt")
        XCTAssertEqual(sidebarCell.toolTip, label.stringValue)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingMiddle)
        let originalHeader = viewport.table.convert(viewport.table.rect(ofRow: header), to: viewport).minY
        for fromHeader in [true, false] {
            for reviewed in [true, false] {
                let cell = try XCTUnwrap(viewport.table.view(atColumn: 0, row: header, makeIfNecessary: true) as? DiffCell)
                cell.layoutSubtreeIfNeeded()
                let headerCheck = try XCTUnwrap(cell.subviews.compactMap { $0 as? AnimatedCheckbox }.first)
                XCTAssertEqual(cell.bounds.maxX - headerCheck.frame.maxX, 12, accuracy: 0.5)
                let button = fromHeader ? headerCheck : sidebarCheck
                button.performClick(nil)
                try await ready(viewport)
                XCTAssertEqual(viewport.isReviewed(viewport.files[1]), reviewed)
                XCTAssertEqual(try footerText(viewport), reviewed ? "1 file left to review" : "2 files left to review")
                XCTAssertEqual(viewport.expanded.contains(path), !reviewed)
                XCTAssertEqual(sidebarCheck.state == .on, reviewed)
                let refreshed = try XCTUnwrap(viewport.table.view(atColumn: 0, row: header, makeIfNecessary: true))
                XCTAssertEqual(refreshed.subviews.compactMap { $0 as? AnimatedCheckbox }.first?.state == .on, reviewed)
                XCTAssertEqual(viewport.table.convert(viewport.table.rect(ofRow: header), to: viewport).minY, originalHeader, accuracy: 1)
                XCTAssertEqual(try store.loadProgress(identity: snapshot.identity).reviewed[path] != nil, reviewed)
            }
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.attachedSheet)

        // Leave no presentation host: failure must be tested without opening an alert sheet.
        controller.window = nil
        try FileManager.default.moveItem(at: storage, to: directory.appendingPathComponent(".git/saved-review"))
        try Data("not a directory".utf8).write(to: storage)
        sidebarCheck.performClick(nil)
        XCTAssertFalse(viewport.isReviewed(viewport.files[1]))
        XCTAssertEqual(try footerText(viewport), "2 files left to review")
        XCTAssertTrue(viewport.expanded.contains(path))
        XCTAssertEqual(sidebarCheck.state, .off)
        let failedHeader = try XCTUnwrap(viewport.table.view(atColumn: 0, row: header, makeIfNecessary: true))
        XCTAssertEqual(failedHeader.subviews.compactMap { $0 as? AnimatedCheckbox }.first?.state, .off)

        let search = try XCTUnwrap(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }
            .first { $0.itemIdentifier.rawValue == "search" }?.searchField)
        search.stringValue = "wearOsMain"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        for _ in 0..<400 {
            if sidebar.numberOfRows == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(sidebar.numberOfRows, 1)
        XCTAssertEqual(try footerText(viewport), "2 files left to review")
        let filteredCell = try XCTUnwrap(sidebar.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(filteredCell.toolTip, "wearOsMain/…/auth.kt")
    }

    @MainActor
    func testAutoReviewAndMarkdownControlsStayIndependentAndReusedRowsHideCheckboxes() throws {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let file = FileDiff(path: "docs/readme.md", hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "# Hello", oldNumber: nil, newNumber: 1)
        ])], fingerprint: "markdown", category: .documentation)
        view.expanded = [file.path]
        view.isReviewed = { _ in true }
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        let cell = DiffCell(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        cell.owner = view
        cell.updateHeaderButton()
        cell.layoutSubtreeIfNeeded()
        let check = try XCTUnwrap(cell.subviews.compactMap { $0 as? AnimatedCheckbox }.first)
        let markdown = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }.first { !($0 is AnimatedCheckbox) })
        XCTAssertEqual(check.state, .on)
        XCTAssertFalse(check.isEnabled)
        XCTAssertLessThan(markdown.frame.maxX, check.frame.minX)
        markdown.performClick(nil)
        XCTAssertTrue(view.rendersMarkdown(file))
        XCTAssertTrue(view.expanded.contains(file.path))
        cell.rowIndex = 1
        cell.updateHeaderButton()
        XCTAssertTrue(check.isHidden)
        XCTAssertTrue(markdown.isHidden)
    }
}

private struct NoCredentials: GitHubCredentialStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data?) throws {}
}
