import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class PRHomeTests: XCTestCase {
    @MainActor
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Home")
    }

    private static func page(_ number: Int, count: Int = 240) throws -> PRPage {
        let start = (number - 1) * PRPage.pageSize
        let end = min(start + PRPage.pageSize, count)
        return PRPage(items: try (start..<max(start, end)).map {
            PRSummary(pr: try GitHubPR.parse("https://github.com/owner/repo/pull/\($0 + 1)"),
                      title: "PR \($0 + 1)", createdAt: Date(), isDraft: false)
        }, totalCount: count)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testContinuousListLoadsDestinationAndPreloadsWithoutPageControls() async throws {
        _ = NSApplication.shared
        let home = PRHomeController { _, number in try Self.page(number) }
        home.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        home.view.layoutSubtreeIfNeeded()
        home.refresh()
        await waitFor { home.inbox.item(at: 0) != nil && !home.isLoading }
        XCTAssertEqual(home.table.numberOfRows, 240)
        home.scroll.contentView.scroll(to: NSPoint(x: 0, y: home.table.rect(ofRow: 160).minY))
        home.scroll.reflectScrolledClipView(home.scroll.contentView)
        await waitFor { home.inbox.item(at: 160) != nil && !home.isLoading }
        XCTAssertEqual(home.inbox.item(at: 160)?.pr.number, 161)
        XCTAssertLessThanOrEqual((0..<240).filter { home.inbox.item(at: $0) != nil }.count, 150)
        let titles = descendants(home.view).compactMap { ($0 as? NSButton)?.title }
        XCTAssertFalse(titles.contains("Next"))
        XCTAssertFalse(titles.contains("Previous"))
        XCTAssertFalse(titles.contains("Review"))
        XCTAssertFalse(titles.contains("Open on GitHub"))
        let listFrame = home.scroll.convert(home.scroll.bounds, to: home.view)
        XCTAssertLessThanOrEqual(home.view.bounds.maxY - listFrame.maxY, 8)
    }

    @MainActor
    func testSelectionIsExplicitAndPlaceholdersDoNotOpenReviews() async throws {
        _ = NSApplication.shared
        let home = PRHomeController { _, number in try Self.page(number) }
        var opened: [String] = []
        home.onOpenPR = { opened.append($0) }
        home.refresh()
        await waitFor { home.inbox.item(at: 0) != nil && !home.isLoading }
        home.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(opened.isEmpty)
        home.openSelected()
        XCTAssertEqual(opened, ["https://github.com/owner/repo/pull/1"])
        home.table.selectRowIndexes(IndexSet(integer: 220), byExtendingSelection: false)
        home.openSelected()
        XCTAssertEqual(opened.count, 1)
    }

    @MainActor
    func testSearchUsesServerAndClearsOldListImmediately() async throws {
        _ = NSApplication.shared
        let home = PRHomeController { query, number in
            if query == "remote search" { return try Self.page(number, count: 1) }
            return try Self.page(number)
        }
        home.refresh()
        await waitFor { home.inbox.count == 240 && !home.isLoading }
        home.searchItem.searchField.stringValue = "remote search"
        home.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(home.isLoading)
        XCTAssertEqual(home.table.numberOfRows, 0)
        await waitFor { home.inbox.count == 1 && !home.isLoading }
        XCTAssertEqual(home.inbox.item(at: 0)?.title, "PR 1", "Do not locally filter server results")
    }

    @MainActor
    func testEmptyAndFailureStatesRemainActionable() async throws {
        _ = NSApplication.shared
        let home = PRHomeController { _, _ in PRPage(items: [], totalCount: 0) }
        home.refresh()
        await waitFor { !home.isLoading }
        let text = descendants(home.view).compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        XCTAssertTrue(text.contains("No matching open pull requests"))
        let failed = PRHomeController { _, _ in throw GitError("Offline; check your connection") }
        failed.refresh()
        await waitFor { !failed.isLoading }
        let retry = try XCTUnwrap(descendants(failed.view).compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
        XCTAssertFalse(retry.isHidden)
        XCTAssertTrue(retry.isEnabled)
    }

    @MainActor
    func testResumeAction() throws {
        _ = NSApplication.shared
        let home = PRHomeController { _, _ in PRPage(items: [], totalCount: 0) }
        var resumed = false
        home.onResume = { resumed = true }
        home.resumeTitle = "owner/repo"
        let resume = try XCTUnwrap(descendants(home.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Resume owner/repo" })
        resume.performClick(nil)
        XCTAssertTrue(resumed)
    }
}
