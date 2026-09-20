import AppKit
import McDiffCore
import XCTest
@testable import McDiff

private actor InboxLoader {
    var limits: [Int] = []
    var continuation: CheckedContinuation<[PRSummary], Error>?
    func load(_ limit: Int) async throws -> [PRSummary] {
        limits.append(limit)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ result: Result<[PRSummary], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

final class PRHomeTests: XCTestCase {
    private func summary(_ number: Int, title: String = "Fix a bug") throws -> PRSummary {
        PRSummary(pr: try GitHubPR.parse("https://github.com/owner/repo/pull/\(number)"),
                  title: title, createdAt: Date(), isDraft: false)
    }

    @MainActor
    private func waitFor(_ predicate: () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for inbox state")
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func button(_ title: String, in home: PRHomeController) throws -> NSButton {
        try XCTUnwrap(descendants(home.view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor
    func testLoadingIsExplicitDeduplicatedAndEmptyResultIsVisible() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0) }
        _ = home.view
        let initialCalls = await loader.limits
        XCTAssertEqual(initialCalls, [])
        home.refresh()
        XCTAssertTrue(home.isLoading)
        home.refresh()
        await waitFor { await loader.limits.count == 1 }
        await loader.complete(.success([]))
        await waitFor { !home.isLoading }
        XCTAssertTrue(home.filteredResults.isEmpty)
        XCTAssertTrue(descendants(home.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("No open pull requests") })
        XCTAssertFalse(try button("Review", in: home).isEnabled)
    }

    @MainActor
    func testFailurePreservesResultsAndRetryRestoresFilteringAndSelectionCallbacks() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0) }
        home.refresh()
        await waitFor { await loader.limits.count == 1 }
        let summaries = try [summary(1, title: "Fix parser"), summary(2, title: "New toolbar")]
        await loader.complete(.success(summaries))
        await waitFor { !home.isLoading }
        home.searchItem.searchField.stringValue = "toolbar"
        home.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(home.filteredResults.map(\.pr.number), [2])
        var opened: String?
        home.onOpenPR = { opened = $0 }
        home.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try button("Review", in: home).performClick(nil)
        XCTAssertEqual(opened, summaries[1].pr.url)
        opened = nil
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        home.table.keyDown(with: enter)
        XCTAssertEqual(opened, summaries[1].pr.url)
        opened = nil
        home.table.sendAction(home.table.doubleAction, to: home.table.target)
        XCTAssertEqual(opened, summaries[1].pr.url)
        home.refresh()
        await waitFor { await loader.limits.count == 2 }
        await loader.complete(.failure(NSError(domain: "offline", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connection is offline"])))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.results, summaries)
        XCTAssertEqual(home.table.selectedRow, 0)
        XCTAssertTrue(descendants(home.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Connection is offline") })
        try button("Retry", in: home).performClick(nil)
        await waitFor { await loader.limits.count == 3 }
        await loader.complete(.success(summaries))
        await waitFor { !home.isLoading }
        XCTAssertTrue(try button("Retry", in: home).isHidden)
        for query in ["owner/repo", "#1", "no match"] {
            home.searchItem.searchField.stringValue = query
            home.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertEqual(home.filteredResults.count, query == "owner/repo" ? 2 : query == "#1" ? 1 : 0)
        }
        opened = nil
        home.openSelected()
        XCTAssertNil(opened)
    }

    @MainActor
    func testLoadMoreRetriesSameLimitAndStopsAtCap() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0) }
        home.refresh()
        for limit in stride(from: 100, through: 1_000, by: 100) {
            await waitFor { await loader.limits.last == limit }
            if limit == 200 {
                await loader.complete(.failure(NSError(domain: "offline", code: 1)))
                await waitFor { !home.isLoading }
                XCTAssertEqual(home.loadedLimit, 100)
                home.retry()
                await waitFor { await loader.limits.count == 3 }
            }
            await loader.complete(.success(try (1...limit).map { try summary($0) }))
            await waitFor { !home.isLoading }
            XCTAssertEqual(home.results.count, limit)
            home.loadMore()
        }
        XCTAssertFalse(home.isLoading)
        XCTAssertTrue(try button("Load more", in: home).isHidden)
        XCTAssertTrue(descendants(home.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("newest 1,000") })
    }

    @MainActor
    func testOversizedResponseIsRejectedAndCanBeRetried() async throws {
        _ = NSApplication.shared
        let loader = InboxLoader()
        let home = PRHomeController { try await loader.load($0) }
        home.refresh()
        await waitFor { await loader.limits.count == 1 }
        await loader.complete(.success(try (1...101).map { try summary($0) }))
        await waitFor { !home.isLoading }
        XCTAssertTrue(home.results.isEmpty)
        XCTAssertFalse(try button("Retry", in: home).isHidden)
        XCTAssertTrue(descendants(home.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("more pull requests than requested") })
        home.retry()
        await waitFor { await loader.limits.count == 2 }
        await loader.complete(.success(try [summary(1)]))
        await waitFor { !home.isLoading }
        XCTAssertEqual(home.results.count, 1)
    }

    @MainActor
    func testResumeAction() throws {
        _ = NSApplication.shared
        let home = PRHomeController { _ in [] }
        var resumed = false
        home.onResume = { resumed = true }
        home.resumeTitle = "owner/repo"
        try button("Resume owner/repo", in: home).performClick(nil)
        XCTAssertTrue(resumed)
        home.resumeTitle = nil
        XCTAssertTrue(try button("", in: home).isHidden)
    }
}
